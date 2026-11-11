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
                Text("Attach the rest of your paper or project, for example its folder of .tex files. The model reads them as background to keep terms, notation and facts consistent. They stay with this window until you close it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                DisclosureGroup(isExpanded: $isExpanded) {
                    ForEach(library.items) { item in row(item) }
                } label: {
                    Text(summary).font(.callout)
                }
            }
            HStack(spacing: 8) {
                Button("Add Files or Folder…") { library.addViaPanel() }
                Menu("More") {
                    Button("Add Text from Clipboard") { library.addFromPasteboard() }
                    Menu("Add from Open Tab") {
                        let others = DocumentRouter.shared.documents.filter { $0 !== document }
                        if others.isEmpty { Text("No other tabs open") }
                        ForEach(Array(others.enumerated()), id: \.offset) { _, other in
                            Menu(other.displayTabTitle) {
                                ForEach([DiffDocument.Side.left, .right], id: \.self) { side in
                                    Button(label(for: other, side)) { library.addTab(other, side: side) }
                                        .disabled(other.text(for: side).isEmpty)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Turn All On") { library.items.forEach { library.setEnabled(true, id: $0.id) } }
                        .disabled(library.items.isEmpty)
                    Button("Turn All Off") { library.items.forEach { library.setEnabled(false, id: $0.id) } }
                        .disabled(library.items.isEmpty)
                    Button("Remove All", role: .destructive) { library.removeAll() }
                        .disabled(library.items.isEmpty)
                }
                .fixedSize()
                if library.isLoading { ProgressView().controlSize(.small) }
            }
            if let message = library.lastMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
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
    }

    private var summary: String {
        let on = library.items.filter { $0.isEnabled && !library.isOpen($0, openFileNames) }.count
        return "\(on) of \(library.items.count) document\(library.items.count == 1 ? "" : "s") in use"
    }

    private func label(for document: DiffDocument, _ side: DiffDocument.Side) -> String {
        let name = side == .left ? document.leftName : document.rightName
        return name.map { "\(document.title(for: side)) (\($0))" } ?? document.title(for: side)
    }

    private func row(_ item: ReferenceLibrary.Item) -> some View {
        let open = library.isOpen(item, openFileNames)
        return HStack(spacing: 6) {
            Toggle(isOn: Binding(get: { item.isEnabled }, set: { library.setEnabled($0, id: item.id) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(open ? "Open in this tab, so not sent twice" : detail(item))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(open)
            Spacer(minLength: 4)
            Button {
                library.remove(id: item.id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove \(item.name)")
        }
        .help(item.name)
    }

    private func detail(_ item: ReferenceLibrary.Item) -> String {
        let size = "≈ \((item.text.count / 4).formatted(.number.notation(.compactName))) tokens"
        switch item.origin {
        case .file: return size
        case .tab: return "\(size) · follows the open tab"
        case .pasted: return "\(size) · pasted"
        }
    }
}
