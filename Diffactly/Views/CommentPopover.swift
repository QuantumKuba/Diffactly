import SwiftUI
import AppKit

// MARK: - Popover over the passage

/// Shows a comment's popover over its passage in one editor: it opens after
/// the pointer rests on the passage (closing again when it leaves) or on a
/// click (staying open), follows the passage while it moves, and reports when
/// the user closes it. Kept apart from the suggestion card, which wins where
/// both mark the same text.
final class CommentPopoverController: NSObject, NSPopoverDelegate {
    weak var textView: DiffTextView?
    /// Asks to open (id) or close (nil) a comment's popover; `pinned` when on purpose.
    var onPresent: ((UUID?, Bool) -> Void)?
    /// The user closed the popover (clicked elsewhere or pressed Esc).
    var onClosed: ((UUID) -> Void)?

    private var popover: NSPopover?
    private(set) var shownID: UUID?
    private var shownRequestID: UUID?
    private var pinned = false
    private var hoverID: UUID?
    private var cardHovered = false
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?

    /// Opens, moves or closes the popover to match the presentation. While a
    /// suggestion card is open (`suppressed`) the comment steps aside.
    func update(presentation: CommentPresentation?, marks: [CommentMark], suppressed: Bool, content: (UUID) -> AnyView?) {
        guard let textView else { return }
        guard let presentation, let mark = marks.first(where: { $0.id == presentation.id }) else {
            if shownID != nil { close() }
            return
        }
        if suppressed {
            if shownID == presentation.id {
                close()
                // Not while SwiftUI is updating the view.
                DispatchQueue.main.async { [onClosed] in onClosed?(presentation.id) }
            }
            return
        }
        if shownID == presentation.id, let popover, popover.isShown {
            if presentation.requestID != shownRequestID {
                shownRequestID = presentation.requestID
                if presentation.pinned { pinned = true }
            }
            if let rect = anchor(for: mark.range, in: textView), rect != popover.positioningRect {
                popover.positioningRect = rect
            }
            return
        }
        guard let view = content(presentation.id) else { return }
        show(presentation, view: view, range: mark.range, in: textView)
    }

    private func show(_ presentation: CommentPresentation, view: AnyView, range: NSRange, in textView: DiffTextView) {
        close()
        if !NSIntersectsRect(textView.rect(for: range) ?? .zero, textView.visibleRect) {
            textView.scrollRangeToVisible(range)
        }
        guard let rect = anchor(for: range, in: textView) else { return }
        let id = presentation.id
        let host = NSHostingController(rootView: AnyView(
            view
                .onHover { [weak self] inside in self?.cardHover(inside) }
                .simultaneousGesture(TapGesture().onEnded { [weak self] in self?.pin(id) })
        ))
        host.sizingOptions = [.preferredContentSize]
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = host
        self.popover = popover
        shownID = id
        shownRequestID = presentation.requestID
        pinned = presentation.pinned
        cardHovered = false
        popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
        // A new comment (or "Edit") takes the keyboard so typing goes into it.
        if presentation.startsEditing {
            DispatchQueue.main.async { host.view.window?.makeKey() }
        }
    }

    private func anchor(for range: NSRange, in textView: DiffTextView) -> NSRect? {
        guard let rect = textView.rect(for: range) else { return nil }
        let visible = rect.intersection(textView.visibleRect)
        return visible.isEmpty ? rect : visible
    }

    func close() {
        openWork?.cancel()
        closeWork?.cancel()
        let popover = self.popover
        self.popover = nil
        shownID = nil
        shownRequestID = nil
        pinned = false
        cardHovered = false
        popover?.close()
    }

    private func pin(_ id: UUID) {
        guard shownID == id, !pinned else { return }
        pinned = true
        onPresent?(id, true)
    }

    /// The pointer moved onto (id) or off (nil) a commented passage.
    func hoverChanged(_ id: UUID?) {
        guard id != hoverID else { return }
        hoverID = id
        openWork?.cancel()
        guard let id else { scheduleHoverClose(); return }
        closeWork?.cancel()
        if shownID == id, popover?.isShown == true { return }
        if pinned, popover?.isShown == true { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hoverID == id else { return }
            self.onPresent?(id, false)
        }
        openWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func cardHover(_ inside: Bool) {
        cardHovered = inside
        if inside { closeWork?.cancel() } else { scheduleHoverClose() }
    }

    private func scheduleHoverClose() {
        guard popover?.isShown == true, !pinned else { return }
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.pinned, !self.cardHovered, let shown = self.shownID, self.hoverID != shown else { return }
            self.onPresent?(nil, false)
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === popover, let id = shownID else { return }
        popover = nil
        shownID = nil
        shownRequestID = nil
        pinned = false
        onClosed?(id)
    }
}

// MARK: - Card

/// Looks up a comment by id for a popover (it may be gone by the time
/// SwiftUI redraws).
struct CommentCardHost: View {
    @ObservedObject var document: DiffDocument
    let id: UUID

    var body: some View {
        if let comment = document.comment(id: id) {
            CommentCard(comment: comment, document: document,
                        startsEditing: document.presentedComment?.id == id && document.presentedComment?.startsEditing == true)
        } else {
            Text("This comment was deleted.")
                .foregroundStyle(.secondary)
                .padding(16)
        }
    }
}

/// A comment: the passage it's on, the note, and Edit / Resolve / Delete.
/// A new comment opens in editing mode; closing it before writing anything
/// discards it.
struct CommentCard: View {
    @ObservedObject var comment: TextComment
    @ObservedObject var document: DiffDocument
    var startsEditing = false
    /// Called after Delete (e.g. to close a popover that isn't the editor's).
    var onDone: (() -> Void)? = nil

    @State private var isEditing = false
    /// The text before editing began, restored by Cancel.
    @State private var bodyBeforeEditing = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            quote
            if isEditing { editor } else { note }
            Divider()
            buttons
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            if startsEditing || comment.isBlank { beginEditing() }
        }
        .onChange(of: comment.body) { document.commentsChanged() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: comment.isResolved ? "checkmark.bubble" : "text.bubble.fill")
                .foregroundStyle(comment.isResolved ? Color.secondary : DiffPalette.comment)
            Text(comment.isBlank && isEditing ? "New Comment" : "Comment")
                .font(.callout.weight(.semibold))
            Text("· \(document.title(for: comment.side))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if comment.isResolved {
                Label("Resolved", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !comment.isBlank {
                Text(comment.editedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var quote: some View {
        if comment.isDetached {
            Label("The text this comment was on was deleted.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(comment.isDetached ? Color.secondary.opacity(0.5) : DiffPalette.comment)
                .frame(width: 3)
            Text("“\(comment.snippet)”")
                .font(.callout)
                .italic()
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.tail)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var note: some View {
        Text(comment.body)
            .font(.body)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onTapGesture(count: 2) { beginEditing() }
    }

    private var editor: some View {
        TextEditor(text: $comment.body)
            .font(.body)
            .focused($fieldFocused)
            .scrollContentBackground(.hidden)
            .padding(4)
            .frame(height: 96)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            .overlay(alignment: .topLeading) {
                if comment.body.isEmpty {
                    Text("Add a comment…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 8) {
            // A comment being written for the first time has Cancel instead.
            if !(isEditing && bodyBeforeEditing.isEmpty) {
                Button(role: .destructive) {
                    document.deleteComment(comment.id)
                    onDone?()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete this comment")
            }
            Spacer()
            if isEditing {
                Button("Cancel") { cancelEditing() }
                    .keyboardShortcut(.cancelAction)
                Button(comment.isResolved || !bodyBeforeEditing.isEmpty ? "Save" : "Comment") { finishEditing() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(comment.isBlank)
                    .help("Save the comment (⌘↩)")
            } else {
                Button("Edit") { beginEditing() }
                Button(comment.isResolved ? "Reopen" : "Resolve") {
                    document.setResolved(comment.id, !comment.isResolved)
                }
                .keyboardShortcut(.defaultAction)
                .help(comment.isResolved
                      ? "Mark the comment as open again"
                      : "Mark the comment as done. Resolved comments stay in the list but no longer mark the text.")
            }
        }
        .controlSize(.regular)
    }

    private func beginEditing() {
        bodyBeforeEditing = comment.body
        isEditing = true
        // After the popover has become key.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { fieldFocused = true }
    }

    private func finishEditing() {
        let trimmed = comment.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed != comment.body { comment.body = trimmed }
        if comment.body != bodyBeforeEditing { comment.editedAt = Date() }
        isEditing = false
        document.commentsChanged()
    }

    private func cancelEditing() {
        if bodyBeforeEditing.isEmpty {
            // Never written: Cancel takes the new comment away again.
            document.deleteComment(comment.id)
            onDone?()
        } else {
            comment.body = bodyBeforeEditing
            isEditing = false
        }
    }
}
