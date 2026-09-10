import XCTest
@testable import Revclip

final class SnippetEditorModelTests: XCTestCase {
    @MainActor
    func testFailedSaveKeepsDraftAndSelectionWithoutClaimingSuccess() {
        let model = SnippetEditorModel()
        let missing = UUID().uuidString
        model.folders = [SnippetFolderDraft(id: missing, title: "original", enabled: true, snippets: [])]
        model.selection = .folder(missing)
        model.titleDraft = "unsaved"
        XCTAssertFalse(model.save())
        XCTAssertFalse(model.savedFlash)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.folders[0].title, "original")
        model.select(nil)
        XCTAssertEqual(model.selection, .folder(missing))
        XCTAssertEqual(model.titleDraft, "unsaved")
    }

    @MainActor
    func testDeletedSelectionIsReconciledAndCannotClaimASave() {
        let model = SnippetEditorModel()
        model.selection = .snippet(UUID().uuidString)
        model.titleDraft = "stale"
        XCTAssertFalse(model.save())
        model.reload()
        if case .snippet = model.selection { XCTFail("Missing snippet must not remain selected") }
        XCTAssertNotEqual(model.titleDraft, "stale")
    }

    @MainActor
    func testRealDatabaseSaveReorderMoveAndFilteredReorderProtection() {
        let db = RCDatabaseManager.shared()
        let first = UUID().uuidString, second = UUID().uuidString
        let a = UUID().uuidString, b = UUID().uuidString
        XCTAssertTrue(db.insertSnippetFolder(["identifier":first,"title":"audit first"]))
        XCTAssertTrue(db.insertSnippetFolder(["identifier":second,"title":"audit second"]))
        defer { _ = db.deleteSnippetFolder(first); _ = db.deleteSnippetFolder(second) }
        XCTAssertTrue(db.insertSnippet(["identifier":a,"title":"A","content":"before","snippet_index":0], inFolder:first))
        XCTAssertTrue(db.insertSnippet(["identifier":b,"title":"B","content":"B","snippet_index":1], inFolder:first))
        let model = SnippetEditorModel()
        model.reload(); model.select(.snippet(a)); model.contentDraft = "保存された本文"
        XCTAssertTrue(model.save())
        model.reload()
        XCTAssertEqual(model.selectedSnippet?.content, "保存された本文")
        model.query = "B"
        model.moveSnippets(in:first,from:IndexSet(integer:0),to:2)
        XCTAssertEqual(model.folders.first { $0.id == first }?.snippets.map(\.id), [a,b])
        model.query = ""
        model.moveSnippets(in:first,from:IndexSet(integer:0),to:2)
        model.reload()
        XCTAssertEqual(model.folders.first { $0.id == first }?.snippets.map(\.id), [b,a])
        model.moveSelectedSnippet(to:second); model.reload()
        XCTAssertEqual(model.selectedSnippet?.folderID,second)
        XCTAssertEqual(model.selectedSnippet?.content,"保存された本文")
    }
}
