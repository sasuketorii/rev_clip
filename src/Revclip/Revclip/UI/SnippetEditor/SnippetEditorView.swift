//
//  SnippetEditorView.swift
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SnippetEditorView: View {
    @Bindable var model: SnippetEditorModel
    @State private var collapsedFolders: Set<String> = []

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            editor
                .frame(minWidth: 420)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            toolbar
        }
        .background(.ultraThinMaterial)
        .alert(
            NSLocalizedString("An unknown error occurred.", comment: ""),
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button(NSLocalizedString("OK", comment: ""), role: .cancel) {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    NSLocalizedString("Search Snippets", comment: ""),
                    text: $model.query
                )
                .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().opacity(0.25)

            List(selection: selectionBinding) {
                ForEach(model.visibleFolders) { folder in
                    DisclosureGroup(isExpanded: Binding(
                        get: { !collapsedFolders.contains(folder.id) },
                        set: { expanded in
                            if expanded { collapsedFolders.remove(folder.id) }
                            else { collapsedFolders.insert(folder.id) }
                        }
                    )) {
                        ForEach(folder.snippets) { snippet in
                            snippetRow(snippet)
                                .tag(SnippetEditorSelection.snippet(snippet.id))
                        }
                        .onMove { offsets, destination in
                            model.moveSnippets(in: folder.id, from: offsets, to: destination)
                        }
                        .moveDisabled(!model.canReorder)
                    } label: {
                        folderRow(folder)
                            .tag(SnippetEditorSelection.folder(folder.id))
                    }
                }
                .onMove(perform: model.moveFolders)
                .moveDisabled(!model.canReorder)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(.ultraThinMaterial)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.isEditingSnippet
                 ? NSLocalizedString("Snippet", comment: "")
                 : NSLocalizedString("Folder", comment: ""))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)

            TextField(
                NSLocalizedString("Title:", comment: ""),
                text: $model.titleDraft
            )
            .textFieldStyle(.plain)
            .font(.system(.title3, design: .default).weight(.semibold))
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
            }
            .disabled(model.selection == nil)

            if let snippet = model.selectedSnippet {
                Picker(NSLocalizedString("Folder", comment: ""), selection: Binding(
                    get: { snippet.folderID },
                    set: { model.moveSelectedSnippet(to: $0) }
                )) {
                    ForEach(model.folders) { folder in Text(folder.title).tag(folder.id) }
                }
                TextEditor(text: $model.contentDraft)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                    }
            } else {
                ContentUnavailableView {
                    Label(
                        NSLocalizedString("Folder", comment: ""),
                        systemImage: "folder"
                    )
                } description: {
                    Text(NSLocalizedString("Add Snippet", comment: ""))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                Text(NSLocalizedString("Save with ⌘S", comment: ""))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .padding(20)
        .background(.clear)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Menu {
                Button(NSLocalizedString("Add Folder", comment: ""), action: model.addFolder)
                Button(NSLocalizedString("Add Snippet", comment: ""), action: model.addSnippet)
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 36)

            Button(action: confirmDelete) {
                Image(systemName: "minus")
            }
            .disabled(model.selection == nil)
            .help(NSLocalizedString("Delete", comment: ""))

            Button(NSLocalizedString("Enabled", comment: ""), systemImage: "eye", action: model.toggleEnabled)
            .disabled(model.selection == nil)

            Button(NSLocalizedString("Import", comment: ""), systemImage: "square.and.arrow.down", action: importSnippets)
            Button(NSLocalizedString("Export", comment: ""), systemImage: "square.and.arrow.up", action: exportSnippets)

            Spacer()

            Button(model.savedFlash ? NSLocalizedString("Saved!", comment: "") : NSLocalizedString("Save", comment: "")) {
                _ = model.save()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(model.selection == nil)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var selectionBinding: Binding<SnippetEditorSelection?> {
        Binding(
            get: { model.selection },
            set: { model.select($0) }
        )
    }

    private func folderRow(_ folder: SnippetFolderDraft) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
            Text(folder.title.isEmpty ? NSLocalizedString("Untitled Folder", comment: "") : folder.title)
                .lineLimit(1)
            Spacer()
            if !folder.enabled {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.tertiary)
            }
        }
        .opacity(folder.enabled ? 1 : 0.45)
        .contentShape(Rectangle())
        .onTapGesture {
            model.select(.folder(folder.id))
        }
    }

    private func snippetRow(_ snippet: SnippetDraft) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.title.isEmpty ? NSLocalizedString("Untitled Snippet", comment: "") : snippet.title)
                    .lineLimit(1)
                if !snippet.content.isEmpty {
                    Text(snippet.content)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if !snippet.enabled {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.tertiary)
            }
        }
        .opacity(snippet.enabled ? 1 : 0.45)
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        if model.isEditingSnippet {
            alert.messageText = NSLocalizedString("Delete this snippet?", comment: "")
        } else {
            alert.messageText = NSLocalizedString("Delete this folder and all its snippets?", comment: "")
        }
        alert.addButton(withTitle: NSLocalizedString("Delete", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        if alert.runModal() == .alertFirstButtonReturn {
            model.deleteSelection()
        }
    }

    private func importSnippets() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "revclipsnippets") ?? .data,
            .xml,
            .propertyList,
        ]
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        let mergeAlert = NSAlert()
        mergeAlert.messageText = NSLocalizedString("How do you want to import snippets?", comment: "")
        mergeAlert.informativeText = NSLocalizedString("Choose whether to merge with existing snippets or replace them all.", comment: "")
        mergeAlert.addButton(withTitle: NSLocalizedString("Merge with existing snippets", comment: ""))
        mergeAlert.addButton(withTitle: NSLocalizedString("Replace all snippets", comment: ""))
        mergeAlert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        let response = mergeAlert.runModal()
        if response == .alertThirdButtonReturn {
            return
        }
        let merge = response == .alertFirstButtonReturn
        if let message = model.importSnippets(from: url, merge: merge) {
            model.errorMessage = message
        }
    }

    private func exportSnippets() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "revclipsnippets") ?? .data]
        panel.nameFieldStringValue = "snippets.revclipsnippets"
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        if let message = model.exportSnippets(to: url) {
            model.errorMessage = message
        }
    }
}

@objc(RCSnippetEditorHost)
@MainActor
final class RCSnippetEditorHost: NSObject, NSWindowDelegate {
    private let model = SnippetEditorModel()

    @objc(installInWindow:)
    static func install(in window: NSWindow) -> RCSnippetEditorHost {
        let host = RCSnippetEditorHost()
        let hostingView = NSHostingView(rootView: SnippetEditorView(model: host.model))
        hostingView.wantsLayer = true
        window.contentView = hostingView
        window.delegate = host
        host.model.reload()
        return host
    }

    @objc func reload() { model.reload() }
    @objc func saveChanges() -> Bool { model.persistDraftIfNeeded() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.persistDraftIfNeeded()
    }
}
