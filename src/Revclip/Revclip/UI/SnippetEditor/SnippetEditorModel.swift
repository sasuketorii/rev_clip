//
//  SnippetEditorModel.swift
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

import AppKit
import Observation

struct SnippetFolderDraft: Identifiable, Hashable {
    var id: String
    var title: String
    var enabled: Bool
    var snippets: [SnippetDraft]
}

struct SnippetDraft: Identifiable, Hashable {
    var id: String
    var folderID: String
    var title: String
    var content: String
    var enabled: Bool
}

enum SnippetEditorSelection: Hashable {
    case folder(String)
    case snippet(String)
}

@MainActor
@Observable
final class SnippetEditorModel {
    var folders: [SnippetFolderDraft] = []
    var selection: SnippetEditorSelection?
    var titleDraft = ""
    var contentDraft = ""
    var query = ""
    var savedFlash = false
    var errorMessage: String?
    private var isApplyingSelection = false
    private var savedFlashWorkItem: DispatchWorkItem?

    var visibleFolders: [SnippetFolderDraft] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return folders
        }
        return folders.compactMap { folder in
            let matchingSnippets = folder.snippets.filter {
                $0.title.localizedStandardContains(trimmed) || $0.content.localizedStandardContains(trimmed)
            }
            if folder.title.localizedStandardContains(trimmed) {
                return folder
            }
            if matchingSnippets.isEmpty {
                return nil
            }
            var copy = folder
            copy.snippets = matchingSnippets
            return copy
        }
    }

    var selectedSnippet: SnippetDraft? {
        guard case .snippet(let id) = selection else {
            return nil
        }
        return folders.flatMap(\.snippets).first { $0.id == id }
    }

    var selectedItemEnabled: Bool {
        switch selection {
        case .folder(let id): return folders.first { $0.id == id }?.enabled ?? false
        case .snippet: return selectedSnippet?.enabled ?? false
        case nil: return false
        }
    }

    var selectedFolderEnabled: Bool {
        guard let snippet = selectedSnippet else { return true }
        return folders.first { $0.id == snippet.folderID }?.enabled ?? false
    }

    var isEditingSnippet: Bool {
        if case .snippet = selection { return true }
        return false
    }

    func reload() {
        guard let catalog = RCDatabaseManager.shared().fetchSnippetCatalog() else {
            errorMessage = NSLocalizedString("Failed to read snippets. Please try again.", comment: "")
            return
        }
        folders = catalog.compactMap { folder in
            guard let dictionary = folder as? [String: Any] else {
                return nil
            }
            let identifier = string(dictionary["identifier"])
            guard !identifier.isEmpty else {
                return nil
            }
            let snippets = (dictionary["snippets"] as? [[String: Any]] ?? []).compactMap { snippet -> SnippetDraft? in
                let snippetID = string(snippet["identifier"])
                guard !snippetID.isEmpty else {
                    return nil
                }
                return SnippetDraft(
                    id: snippetID,
                    folderID: string(snippet["folder_id"], fallback: identifier),
                    title: string(snippet["title"]),
                    content: string(snippet["content"]),
                    enabled: bool(snippet["enabled"], fallback: true)
                )
            }
            return SnippetFolderDraft(
                id: identifier,
                title: string(dictionary["title"]),
                enabled: bool(dictionary["enabled"], fallback: true),
                snippets: snippets
            )
        }
        switch selection {
        case .folder(let id) where folders.contains(where: { $0.id == id }): break
        case .snippet(let id) where folders.contains(where: { $0.snippets.contains(where: { $0.id == id }) }): break
        default: selection = folders.first.map { .folder($0.id) }
        }
        applySelectionToDrafts()
    }

    func select(_ selection: SnippetEditorSelection?) {
        guard persistDraftIfNeeded() else { return }
        self.selection = selection
        applySelectionToDrafts()
    }

    @discardableResult
    func persistDraftIfNeeded() -> Bool {
        guard !isApplyingSelection else {
            return true
        }
        switch selection {
        case .folder(let id):
            guard let index = folders.firstIndex(where: { $0.id == id }) else {
                return reportSaveFailure()
            }
            let title = normalized(titleDraft, fallback: NSLocalizedString("Untitled Folder", comment: ""))
            if folders[index].title == title {
                return true
            }
            guard RCDatabaseManager.shared().updateSnippetFolder([
                "identifier": id,
                "title": title,
            ]) else { return reportSaveFailure() }
            folders[index].title = title
            notifySnippetsChanged()
        case .snippet(let id):
            guard let folderIndex = folders.firstIndex(where: { folder in folder.snippets.contains(where: { $0.id == id }) }),
                  let snippetIndex = folders[folderIndex].snippets.firstIndex(where: { $0.id == id }) else {
                return reportSaveFailure()
            }
            let title = normalized(titleDraft, fallback: NSLocalizedString("Untitled Snippet", comment: ""))
            let content = contentDraft
            if folders[folderIndex].snippets[snippetIndex].title == title,
               folders[folderIndex].snippets[snippetIndex].content == content {
                return true
            }
            guard RCDatabaseManager.shared().updateSnippet([
                "identifier": id,
                "title": title,
                "content": content,
            ]) else { return reportSaveFailure() }
            folders[folderIndex].snippets[snippetIndex].title = title
            folders[folderIndex].snippets[snippetIndex].content = content
            notifySnippetsChanged()
        case nil:
            break
        }
        return true
    }

    func save() -> Bool {
        guard persistDraftIfNeeded() else { return false }
        flashSaved()
        return true
    }

    func addFolder() {
        guard persistDraftIfNeeded() else { return }
        let identifier = UUID().uuidString
        let title = NSLocalizedString("New Folder", comment: "")
        let inserted = RCDatabaseManager.shared().insertSnippetFolder([
            "identifier": identifier,
            "folder_index": folders.count,
            "enabled": 1,
            "title": title,
        ])
        guard inserted else {
            NSSound.beep()
            return
        }
        reload()
        selection = .folder(identifier)
        applySelectionToDrafts()
        notifySnippetsChanged()
    }

    func addSnippet() {
        guard persistDraftIfNeeded() else { return }
        let folderID: String
        switch selection {
        case .folder(let id):
            folderID = id
        case .snippet(let id):
            folderID = folders.first(where: { $0.snippets.contains(where: { $0.id == id }) })?.id ?? folders.first?.id ?? ""
        case nil:
            folderID = folders.first?.id ?? ""
        }
        if folderID.isEmpty {
            addFolder()
            if let created = folders.first?.id {
                selection = .folder(created)
            }
        }
        guard let resolvedFolderID = (selection.map { sel -> String in
            switch sel {
            case .folder(let id): return id
            case .snippet(let id):
                return folders.first(where: { $0.snippets.contains(where: { $0.id == id }) })?.id ?? folderID
            }
        } ?? folders.first?.id), !resolvedFolderID.isEmpty,
              let folderIndex = folders.firstIndex(where: { $0.id == resolvedFolderID }) else {
            NSSound.beep()
            return
        }

        let snippetID = UUID().uuidString
        let title = NSLocalizedString("New Snippet", comment: "")
        let inserted = RCDatabaseManager.shared().insertSnippet([
            "identifier": snippetID,
            "snippet_index": folders[folderIndex].snippets.count,
            "enabled": 1,
            "title": title,
            "content": "",
        ], inFolder: resolvedFolderID)
        guard inserted else {
            NSSound.beep()
            return
        }
        reload()
        selection = .snippet(snippetID)
        applySelectionToDrafts()
        notifySnippetsChanged()
    }

    func deleteSelection() {
        guard persistDraftIfNeeded() else { return }
        switch selection {
        case .folder(let id):
            guard RCDatabaseManager.shared().deleteSnippetFolder(id) else {
                NSSound.beep()
                return
            }
            RCHotKeyService.shared().unregisterSnippetFolderHotKey(id)

        case .snippet(let id):
            guard RCDatabaseManager.shared().deleteSnippet(id) else {
                NSSound.beep()
                return
            }
        case nil:
            return
        }
        selection = nil
        reload()
        notifySnippetsChanged()
    }

    func toggleEnabled() {
        guard persistDraftIfNeeded() else { return }
        let updated: Bool
        switch selection {
        case .folder(let id):
            guard let folder = folders.first(where: { $0.id == id }) else { return }
            updated = RCDatabaseManager.shared().updateSnippetFolder([
                "identifier": id, "enabled": folder.enabled ? 0 : 1,
            ])
        case .snippet(let id):
            guard let snippet = selectedSnippet else { return }
            updated = RCDatabaseManager.shared().updateSnippet([
                "identifier": id, "enabled": snippet.enabled ? 0 : 1,
            ])
        case nil: return
        }
        guard updated else { reportSaveFailure(); return }
        reload()
        RCHotKeyService.shared().reloadFolderHotKeys()
        notifySnippetsChanged()
    }

    var canReorder: Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func moveFolders(from offsets: IndexSet, to destination: Int) {
        guard canReorder, persistDraftIfNeeded(), destination >= 0, destination <= folders.count,
              offsets.allSatisfy({ folders.indices.contains($0) }) else { return }
        var reordered = folders
        reordered.move(fromOffsets: offsets, toOffset: destination)
        guard RCDatabaseManager.shared().updateSnippetFolderIndexes(reordered.map(\.id)) else {
            reportSaveFailure(); return
        }
        folders = reordered
        notifySnippetsChanged()
    }

    func moveSnippets(in folderID: String, from offsets: IndexSet, to destination: Int) {
        guard canReorder, persistDraftIfNeeded(),
              let index = folders.firstIndex(where: { $0.id == folderID }),
              destination >= 0, destination <= folders[index].snippets.count,
              offsets.allSatisfy({ folders[index].snippets.indices.contains($0) }) else { return }
        var reordered = folders
        reordered[index].snippets.move(fromOffsets: offsets, toOffset: destination)
        persistPlacement(reordered)
    }

    func moveSelectedSnippet(to folderID: String) {
        guard persistDraftIfNeeded(), let snippet = selectedSnippet,
              snippet.folderID != folderID,
              let source = folders.firstIndex(where: { $0.id == snippet.folderID }),
              let target = folders.firstIndex(where: { $0.id == folderID }) else { return }
        var reordered = folders
        reordered[source].snippets.removeAll { $0.id == snippet.id }
        var moved = snippet
        moved.folderID = folderID
        reordered[target].snippets.append(moved)
        persistPlacement(reordered)
    }

    func importSnippets(from url: URL, merge: Bool) -> String? {
        guard persistDraftIfNeeded() else { return errorMessage }
        do {
            try RCSnippetImportExportService.shared().importSnippets(from: url, merge: merge)
            selection = nil
            reload()
            RCHotKeyService.shared().reloadFolderHotKeys()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func exportSnippets(to url: URL) -> String? {
        guard persistDraftIfNeeded() else { return errorMessage }
        do {
            try RCSnippetImportExportService.shared().exportSnippets(to: url)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func persistPlacement(_ reordered: [SnippetFolderDraft]) {
        var placements: [[String: Any]] = []
        for folder in reordered {
            for (index, snippet) in folder.snippets.enumerated() {
                placements.append([
                    "identifier": snippet.id,
                    "folder_id": folder.id,
                    "snippet_index": index,
                ])
            }
        }
        guard RCDatabaseManager.shared().updateSnippetPlacement(placements) else {
            reportSaveFailure(); return
        }
        folders = reordered
        notifySnippetsChanged()
    }

    private func applySelectionToDrafts() {
        isApplyingSelection = true
        defer { isApplyingSelection = false }
        switch selection {
        case .folder(let id):
            titleDraft = folders.first(where: { $0.id == id })?.title ?? ""
            contentDraft = ""
        case .snippet(let id):
            if let snippet = folders.flatMap(\.snippets).first(where: { $0.id == id }) {
                titleDraft = snippet.title
                contentDraft = snippet.content
            }
        case nil:
            titleDraft = ""
            contentDraft = ""
        }
    }

    @discardableResult
    private func reportSaveFailure() -> Bool {
        errorMessage = NSLocalizedString("Failed to save snippets. Your changes have not been saved.", comment: "")
        savedFlash = false
        return false
    }

    private func flashSaved() {
        savedFlash = true
        savedFlashWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.savedFlash = false
        }
        savedFlashWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func notifySnippetsChanged() {
        NotificationCenter.default.post(name: .RCSnippetsDidChange, object: nil)
    }

    private func string(_ value: Any?, fallback: String = "") -> String {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return fallback
    }

    private func bool(_ value: Any?, fallback: Bool) -> Bool {
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            return (string as NSString).boolValue
        }
        return fallback
    }

    private func normalized(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
