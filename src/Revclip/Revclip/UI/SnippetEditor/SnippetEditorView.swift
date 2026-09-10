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
        VStack(spacing: 0) {
            HSplitView {
                sidebar
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                editor
                    .frame(minWidth: 420)
            }
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
            Text(model.selection == nil
                 ? NSLocalizedString("Select a folder or template", comment: "")
                 : model.isEditingSnippet
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
                if !model.selectedFolderEnabled {
                    Label(NSLocalizedString("This folder is hidden from the menu.", comment: ""), systemImage: "eye.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(NSLocalizedString("Template Content", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $model.contentDraft)
                    .accessibilityLabel(NSLocalizedString("Template Content", comment: ""))
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
                    Text(model.selection == nil
                         ? NSLocalizedString("Add a folder to organize your templates.", comment: "")
                         : NSLocalizedString("Add a template to this folder.", comment: ""))
                } actions: {
                    Button(NSLocalizedString(model.selection == nil ? "Add Folder" : "Add Template", comment: "")) {
                        if model.selection == nil { model.addFolder() }
                        else { model.addSnippet() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                Text(NSLocalizedString("Changes are saved when you switch items or close the editor.", comment: ""))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .padding(20)
        .background(.clear)
    }

    private var toolbar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button(NSLocalizedString("Add Folder", comment: ""), systemImage: "folder.badge.plus", action: model.addFolder)
                Button(NSLocalizedString("Add Template", comment: ""), systemImage: "doc.badge.plus", action: model.addSnippet)
                    .disabled(model.folders.isEmpty)
                Spacer()
                Button(model.savedFlash ? NSLocalizedString("Saved!", comment: "") : NSLocalizedString("Save", comment: "")) {
                    _ = model.save()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model.selection == nil)
                .buttonStyle(.borderedProminent)
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    selectionActions
                    Spacer(minLength: 16)
                    transferActions
                }
                VStack(alignment: .leading, spacing: 10) {
                    selectionActions
                    transferActions
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var selectionActions: some View {
        HStack(spacing: 12) {
            Button(model.isEditingSnippet
                   ? NSLocalizedString("Delete Template", comment: "")
                   : NSLocalizedString("Delete Folder", comment: ""),
                   systemImage: "trash", action: confirmDelete)
                .disabled(model.selection == nil)
            Toggle(NSLocalizedString("Show in Menu", comment: ""), isOn: Binding(
                get: { model.selectedItemEnabled },
                set: { if $0 != model.selectedItemEnabled { model.toggleEnabled() } }
            ))
            .toggleStyle(.checkbox)
            .disabled(model.selection == nil)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var transferActions: some View {
        HStack(spacing: 12) {
            Button(NSLocalizedString("Import Templates...", comment: ""), systemImage: "square.and.arrow.down", action: importSnippets)
            Button(NSLocalizedString("Export All Templates...", comment: ""), systemImage: "square.and.arrow.up", action: exportSnippets)
        }
        .fixedSize(horizontal: true, vertical: false)
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
            alert.informativeText = String(format: NSLocalizedString("Target snippet: %@", comment: ""), model.titleDraft)
        } else {
            alert.messageText = NSLocalizedString("Delete this folder and all its snippets?", comment: "")
            alert.informativeText = String(format: NSLocalizedString("Target folder: %@", comment: ""), model.titleDraft)
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
        panel.nameFieldStringValue = "templates.revclipsnippets"
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
