import SwiftUI

/// An editable title label for a split or diff pane.
/// Double-clicking or right-clicking ("Rename…") shows an inline text field.
/// Pressing Return or clicking away commits the change.
/// Pressing Esc cancels editing.
/// Blank or whitespace-only inputs revert to the default title ("Original" / "Changed").
struct EditableSplitTitle: View {
    @ObservedObject var document: DiffDocument
    let side: DiffDocument.Side

    @State private var isEditing = false
    @State private var draftTitle = ""
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isEditing {
                TextField(side.defaultTitle, text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.accentColor, lineWidth: 1.5)
                    )
                    .frame(minWidth: 50, maxWidth: 180)
                    .focused($isFocused)
                    .onSubmit {
                        commit()
                    }
                    .onExitCommand {
                        cancel()
                    }
                    .onChange(of: isFocused) { _, focused in
                        if !focused && isEditing {
                            commit()
                        }
                    }
                    .onAppear {
                        isFocused = true
                    }
            } else {
                Text(document.title(for: side))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isHovering ? Color.secondary.opacity(0.15) : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onHover { isHovering = $0 }
                    .onTapGesture(count: 2) {
                        startEditing()
                    }
                    .help("Double-click to rename")
                    .contextMenu {
                        Button("Rename…") {
                            startEditing()
                        }
                        if document.title(for: side) != side.defaultTitle {
                            Button("Reset to “\(side.defaultTitle)”") {
                                document.setTitle(side.defaultTitle, for: side)
                            }
                        }
                    }
            }
        }
    }

    private func startEditing() {
        draftTitle = document.title(for: side)
        isEditing = true
    }

    private func commit() {
        guard isEditing else { return }
        isEditing = false
        isFocused = false
        document.setTitle(draftTitle, for: side)
    }

    private func cancel() {
        guard isEditing else { return }
        isEditing = false
        isFocused = false
        draftTitle = document.title(for: side)
    }
}
