import SwiftUI
import DiffactlyCore

/// The "Reference Documents" part of the AI sheet: background files for this
/// window's session, such as the rest of the paper being edited.
struct ReferenceDocumentsSection: View {
    @ObservedObject var library: ReferenceLibrary
    @ObservedObject var document: DiffDocument
    /// Files open in this window; references with the same name are skipped.
    let openFileNames: Set<String>
    @State private var isExpanded = true

    var body: some View {
        Section {
            if library.items.isEmpty {
                Text("Attach the rest of your paper or project, for example its folder of .tex files. The model reads them as background to keep terms, notation and facts consistent. Other open tabs are listed here automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                DisclosureGroup(isExpanded: $isExpanded) {
                    let attached = library.attachedItems
                    let tabs = library.tabItems
                    ForEach(attached) { item in row(item) }
                    if !tabs.isEmpty {
                        Text("Other open tabs")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, attached.isEmpty ? 0 : 4)
                        ForEach(tabs) { item in row(item) }
                    }
                } label: {
                    Text(summary).font(.callout)
                }
            }
            HStack(spacing: 8) {
                Button("Add Files or Folder…") { library.addViaPanel() }
                Menu("More") {
                    Button("Add Text from Clipboard") { library.addFromPasteboard() }
                    Divider()
                    Button("Turn All On") { library.setAllEnabled(true) }
                        .disabled(library.items.isEmpty)
                    Button("Turn All Off") { library.setAllEnabled(false) }
                        .disabled(library.items.isEmpty)
                    Button("Remove All Attached", role: .destructive) { library.removeAll() }
                        .disabled(library.attachedItems.isEmpty)
                }
                .fixedSize()
                if library.isLoading { ProgressView().controlSize(.small) }
            }
            if let message = library.lastMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if let folder = library.projectFolder {
                Label("Files you attach are remembered for “\(folder.lastPathComponent)”.", systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help(folder.path)
            }
        } header: {
            HStack {
                Text("Reference Documents")
                Spacer()
                if !library.items.isEmpty {
                    Text("≈ \((library.characterCount(excludingFileNames: openFileNames) / 4).formatted(.number.notation(.compactName))) tokens")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            library.add(urls.filter(\.isFileURL))
            return true
        }
        .onAppear { library.syncOpenTabs() }
    }

    private var summary: String {
        let on = library.items.filter { $0.isEnabled && !library.isOpen($0, openFileNames) && !library.isSuperseded($0) }.count
        return "\(on) of \(library.items.count) document\(library.items.count == 1 ? "" : "s") in use"
    }

    private func row(_ item: ReferenceLibrary.Item) -> some View {
        let open = library.isOpen(item, openFileNames)
        let superseded = library.isSuperseded(item)
        return HStack(spacing: 6) {
            Toggle(isOn: Binding(get: { item.isEnabled }, set: { library.setEnabled($0, id: item.id) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(open ? "Open in this tab, so not sent twice" : superseded ? "Open in another tab; that version is used" : detail(item))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(open || superseded)
            Spacer(minLength: 4)
            if !item.isTab {
                Button {
                    library.remove(id: item.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove \(item.name)")
            }
        }
        .help(item.name)
    }

    private func detail(_ item: ReferenceLibrary.Item) -> String {
        let size = "≈ \((item.text.count / 4).formatted(.number.notation(.compactName))) tokens"
        switch item.origin {
        case .file: return size
        case .tab: return "\(size) · open tab, follows its edits"
        case .pasted: return "\(size) · pasted"
        }
    }
}
