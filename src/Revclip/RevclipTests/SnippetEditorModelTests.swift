import XCTest
import SwiftUI
@testable import Revclip

final class SnippetEditorModelTests: XCTestCase {
    @MainActor
    func testTemplateEditorRendersAtMinimumWindowWidth() {
        let model = SnippetEditorModel()
        model.folders = [SnippetFolderDraft(id: "folder", title: "Examples", enabled: true,
            snippets: [SnippetDraft(id: "template", folderID: "folder", title: "Greeting", content: "Hello", enabled: true)])]
        model.selection = .snippet("template")
        model.titleDraft = "Greeting"
        model.contentDraft = "Hello"
        let view = NSHostingView(rootView: SnippetEditorView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        // fittingSize is the ideal width of the first ViewThatFits candidate,
        // not its minimum width. Check the rendered bounds and retain the image
        // to inspect the stacked controls at the supported minimum window size.
        XCTAssertEqual(view.bounds.width, 760, accuracy: 0.5)
        XCTAssertEqual(view.bounds.height, 600, accuracy: 0.5)
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            XCTFail("Could not render template editor"); return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Template editor — \(Bundle.main.preferredLocalizations.first ?? "unknown")"
        attachment.lifetime = .keepAlways
        add(attachment)
        window.contentView = nil
    }

    @MainActor
    func testLanguageChangeKeepsUnsavedTemplateDraft() {
        let original = RCLocalization.selectedLanguage()
        defer { RCLocalization.setLanguage(original) }
        let model = SnippetEditorModel()
        model.folders = [SnippetFolderDraft(id: "folder", title: "Examples", enabled: true,
            snippets: [SnippetDraft(id: "template", folderID: "folder", title: "Greeting", content: "Saved content", enabled: true)])]
        model.selection = .snippet("template")
        model.titleDraft = "Unsaved title"
        model.contentDraft = "Unsaved content"
        model.query = "Greeting"
        let view = NSHostingView(rootView: SnippetEditorView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        for language in ["en", "ja"] {
            RCLocalization.setLanguage(language)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(model.titleDraft, "Unsaved title")
            XCTAssertEqual(model.contentDraft, "Unsaved content")
            XCTAssertEqual(model.query, "Greeting")
            XCTAssertEqual(model.selection, .snippet("template"))
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                XCTFail("Could not render language switch"); return
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let image = NSImage(size: view.bounds.size)
            image.addRepresentation(bitmap)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Live language switch — \(language)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        window.contentView = nil
    }

    @MainActor
    func testMenuVisibilityTracksSelectedItemAndParentFolder() {
        let model = SnippetEditorModel()
        model.folders = [SnippetFolderDraft(id: "folder", title: "Folder", enabled: false,
            snippets: [SnippetDraft(id: "template", folderID: "folder", title: "Template", content: "text", enabled: true)])]
        model.selection = .folder("folder")
        XCTAssertFalse(model.selectedItemEnabled)
        model.selection = .snippet("template")
        XCTAssertTrue(model.selectedItemEnabled)
        XCTAssertFalse(model.selectedFolderEnabled)
        model.selection = nil
        XCTAssertFalse(model.selectedItemEnabled)
    }

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
        XCTAssertTrue(model.selectedItemEnabled)
        model.toggleEnabled()
        model.reload()
        XCTAssertFalse(model.selectedItemEnabled)
        XCTAssertEqual(model.selectedSnippet?.content, "保存された本文")
        model.toggleEnabled()
        model.select(.folder(first))
        model.toggleEnabled()
        model.select(.snippet(a))
        XCTAssertTrue(model.selectedItemEnabled)
        XCTAssertFalse(model.selectedFolderEnabled)
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
