import SwiftUI
import AppKit

// MARK: - Sidebar

/// Every comment in the window, by editor and position: click one to select
/// its passage and open it. Resolved and detached comments are listed too.
struct CommentsSidebar: View {
    @ObservedObject var document: DiffDocument
    @State private var showsResolved = true

    var body: some View {
        HStack(spacing: 0) {
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                if document.comments.isEmpty {
                    empty
                } else {
                    list
                }
            }
            .frame(width: 280)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Comments").font(.headline)
            if document.openCommentCount > 0 {
                Text("\(document.openCommentCount)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(DiffPalette.comment)
            }
            Spacer(minLength: 4)
            Button { document.showPreviousComment() } label: { Image(systemName: "chevron.up") }
                .help("Previous comment (⌥⌘[)")
                .disabled(document.navigableComments.isEmpty)
            Button { document.showNextComment() } label: { Image(systemName: "chevron.down") }
                .help("Next comment (⌥⌘])")
                .disabled(document.navigableComments.isEmpty)
            Menu {
                Toggle("Highlight Resolved Comments in Text", isOn: $document.showsResolvedComments)
                Divider()
                Button("Delete Resolved Comments", role: .destructive) { document.deleteComments { $0.isResolved } }
                    .disabled(!document.comments.contains(where: \.isResolved))
                Button("Delete Detached Comments", role: .destructive) { document.deleteComments { $0.isDetached } }
                    .disabled(!document.comments.contains(where: \.isDetached))
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Button { document.isShowingComments = false } label: { Image(systemName: "xmark") }
                .help("Hide comments")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(.bar)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "text.bubble")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No Comments").font(.headline).foregroundStyle(.secondary)
            Text("Select text in either editor and choose Add Comment… from the context menu, or press ⇧⌘M.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        let sorted = document.comments.sorted { ($0.side == .left ? 0 : 1, $0.range.location) < ($1.side == .left ? 0 : 1, $1.range.location) }
        let open = sorted.filter { !$0.isResolved && !$0.isDetached }
        let detached = sorted.filter { !$0.isResolved && $0.isDetached }
        let resolved = sorted.filter(\.isResolved)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4, pinnedViews: []) {
                    ForEach([DiffDocument.Side.left, .right], id: \.self) { side in
                        let rows = open.filter { $0.side == side }
                        if !rows.isEmpty {
                            sectionTitle(document.title(for: side))
                            ForEach(rows) { CommentRow(comment: $0, document: document) }
                        }
                    }
                    if !detached.isEmpty {
                        sectionTitle("Detached")
                            .help("The text these comments were on was deleted.")
                        ForEach(detached) { CommentRow(comment: $0, document: document) }
                    }
                    if !resolved.isEmpty {
                        DisclosureGroup(isExpanded: $showsResolved) {
                            ForEach(resolved) { CommentRow(comment: $0, document: document) }
                        } label: {
                            sectionTitle("Resolved (\(resolved.count))")
                        }
                    }
                }
                .padding(8)
            }
            .onChange(of: document.presentedComment?.id) { _, id in
                if let id { withAnimation { proxy.scrollTo(id) } }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.top, 8)
    }
}

/// One comment in the sidebar: the passage, the note and its state.
struct CommentRow: View {
    @ObservedObject var comment: TextComment
    @ObservedObject var document: DiffDocument
    /// Detached comments have no passage to open over, so they open here.
    @State private var showsCard = false

    private var isCurrent: Bool {
        document.presentedComment?.id == comment.id || (showsCard && comment.isDetached)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(comment.isDetached || comment.isResolved ? Color.secondary.opacity(0.5) : DiffPalette.comment)
                    .frame(width: 3)
                Text("“\(comment.snippet)”")
                    .font(.callout)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .fixedSize(horizontal: false, vertical: true)
            Text(comment.isBlank ? "Empty comment" : comment.body)
                .font(.callout)
                .foregroundStyle(comment.isBlank ? .tertiary : (comment.isResolved ? .secondary : .primary))
                .lineLimit(4)
            HStack(spacing: 6) {
                Text(comment.editedAt, format: .relative(presentation: .named))
                if comment.isDetached {
                    Label("Detached", systemImage: "exclamationmark.triangle")
                }
                if comment.isResolved {
                    Label("Resolved", systemImage: "checkmark.circle")
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCurrent ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture { open() }
        .help(comment.isDetached ? "Its text was deleted. Click to read or edit the comment." : "Click to show this comment in the text")
        .contextMenu {
            Button("Show in Text") { document.revealComment(comment.id) }
                .disabled(comment.isDetached)
            Button("Edit…") { open(editing: true) }
            Button(comment.isResolved ? "Reopen" : "Resolve") { document.setResolved(comment.id, !comment.isResolved) }
            Divider()
            Button("Delete", role: .destructive) { document.deleteComment(comment.id) }
        }
        .popover(isPresented: $showsCard, arrowEdge: .leading) {
            CommentCard(comment: comment, document: document, onDone: { showsCard = false })
        }
        .onChange(of: showsCard) { _, shown in
            if !shown, document.comment(id: comment.id)?.isBlank == true { document.deleteComment(comment.id) }
        }
        .id(comment.id)
    }

    private func open(editing: Bool = false) {
        if comment.isDetached {
            document.currentCommentID = comment.id
            showsCard = true
        } else {
            document.revealComment(comment.id, editing: editing)
        }
    }
}

// MARK: - Status bar

/// "💬 3 comments" in the status bar: shows or hides the sidebar, with
/// next / previous in its menu.
struct CommentsStatusItem: View {
    @ObservedObject var document: DiffDocument
    var compact = false

    var body: some View {
        let open = document.openCommentCount
        let total = document.comments.count
        let title: String
        if compact {
            title = "\(open > 0 ? open : total)"
        } else if open > 0 || total == 0 {
            title = "\(open) comment\(open == 1 ? "" : "s")"
        } else {
            title = "\(total) resolved"
        }
        return Menu {
            Button(document.isShowingComments ? "Hide Comments" : "Show Comments") { document.isShowingComments.toggle() }
            Divider()
            Button("Next Comment") { document.showNextComment() }
                .disabled(document.navigableComments.isEmpty)
            Button("Previous Comment") { document.showPreviousComment() }
                .disabled(document.navigableComments.isEmpty)
            Divider()
            Toggle("Highlight Resolved Comments in Text", isOn: $document.showsResolvedComments)
        } label: {
            Label(title, systemImage: open > 0 ? "text.bubble.fill" : "text.bubble")
                .foregroundStyle(open > 0 ? DiffPalette.comment : Color.secondary)
        } primaryAction: {
            document.isShowingComments.toggle()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Comments: \(open) open, \(total - open) resolved. Click to \(document.isShowingComments ? "hide" : "show") the list.")
    }
}

// MARK: - Menu bar

/// Edit ▸ Add Comment… and friends.
struct CommentCommands: Commands {
    @FocusedObject private var document: DiffDocument?

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Divider()
            // The focused editor answers ⇧⌘M itself (it can comment the
            // paragraph at the caret); this covers a selection elsewhere.
            Button("Add Comment…") { document?.addCommentForSelection() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(document?.selection == nil)
            Button(document?.isShowingComments == true ? "Hide Comments" : "Show Comments") {
                document?.isShowingComments.toggle()
            }
            .keyboardShortcut("m", modifiers: [.command, .option, .shift])
            .disabled(document == nil)
            Button("Next Comment") { document?.showNextComment() }
                .keyboardShortcut("]", modifiers: [.command, .option])
                .disabled(document?.navigableComments.isEmpty != false)
            Button("Previous Comment") { document?.showPreviousComment() }
                .keyboardShortcut("[", modifiers: [.command, .option])
                .disabled(document?.navigableComments.isEmpty != false)
            Toggle("Highlight Resolved Comments", isOn: Binding(
                get: { document?.showsResolvedComments ?? false },
                set: { document?.showsResolvedComments = $0 }
            ))
            .disabled(document == nil)
        }
    }
}
