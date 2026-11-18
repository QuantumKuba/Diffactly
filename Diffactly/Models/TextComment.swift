import Foundation
import DiffactlyCore

/// A note the user pinned to a passage in one of the editors, like a review
/// comment in a document editor.
///
/// The document keeps `range` on the passage while the text is edited. When
/// an edit deletes the whole passage the comment is *detached*: it stays in
/// the list with the text it was attached to, and comes back if the passage
/// does (e.g. after an undo).
@MainActor
final class TextComment: ObservableObject, Identifiable {
    let id: UUID
    /// The editor the passage is in (flips when the sides are swapped).
    var side: DiffDocument.Side
    /// Where the passage is now (UTF-16, kept current by the document). For a
    /// detached comment, an empty range where the passage used to be.
    var range: NSRange
    /// The passage as it reads now (as it last read, once detached).
    var quote: String
    /// The passage when the comment was written.
    let originalQuote: String
    /// The passage was deleted; the comment no longer marks any text.
    var isDetached = false

    @Published var body: String
    @Published var isResolved = false
    let createdAt: Date
    @Published var editedAt: Date

    init(id: UUID = UUID(), side: DiffDocument.Side, range: NSRange, quote: String, originalQuote: String? = nil,
         body: String = "", createdAt: Date = Date()) {
        self.id = id
        self.side = side
        self.range = range
        self.quote = quote
        self.originalQuote = originalQuote ?? quote
        self.body = body
        self.createdAt = createdAt
        self.editedAt = createdAt
    }

    /// Blank comments (abandoned before anything was written) are discarded.
    var isBlank: Bool { body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Shows in the editor (open, or resolved while those are shown).
    func isVisible(showingResolved: Bool) -> Bool { !isDetached && (!isResolved || showingResolved) }

    /// The passage for lists and popovers: one line, shortened.
    var snippet: String {
        let source = isDetached ? originalQuote : quote
        let flat = source.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count > 140 ? String(flat.prefix(140)) + "…" : flat
    }
}

/// How a comment's passage is painted in its editor.
struct CommentMark: Equatable {
    var id: UUID
    var range: NSRange
    var isResolved: Bool
}

/// Which comment's popover is open, and whether the user opened it on
/// purpose (pinned) or it's only showing while the pointer rests on it.
struct CommentPresentation: Equatable {
    let requestID = UUID()
    var id: UUID
    var pinned: Bool
    /// Open with the text field focused (a new comment, or "Edit").
    var startsEditing = false
}

// MARK: - Comments in a document

extension DiffDocument {

    func comment(id: UUID?) -> TextComment? {
        guard let id else { return nil }
        return comments.first { $0.id == id }
    }

    /// Comments that still mark text, sorted the way they read (original
    /// first, then top to bottom), for the editors and next/previous.
    var navigableComments: [TextComment] {
        comments.filter { $0.isVisible(showingResolved: showsResolvedComments) || ($0.id == presentedComment?.id && !$0.isDetached) }
            .sorted { ($0.side == .left ? 0 : 1, $0.range.location) < ($1.side == .left ? 0 : 1, $1.range.location) }
    }

    var openCommentCount: Int { comments.filter { !$0.isResolved }.count }

    /// The tints for one editor: open comments (resolved ones too while
    /// they're shown, and always the one whose popover is open).
    func commentMarks(for side: Side) -> [CommentMark] {
        let length = (text(for: side) as NSString).length
        return comments.compactMap { c in
            guard c.side == side, !c.isDetached, c.range.length > 0, NSMaxRange(c.range) <= length,
                  c.isVisible(showingResolved: showsResolvedComments) || c.id == presentedComment?.id else { return nil }
            return CommentMark(id: c.id, range: c.range, isResolved: c.isResolved)
        }
    }

    // MARK: Adding and editing

    /// Adds a comment on a passage (without its surrounding whitespace) and,
    /// by default, opens its popover ready for writing.
    @discardableResult
    func addComment(side: Side, range: NSRange, body: String = "", present: Bool = true) -> TextComment? {
        let ns = text(for: side) as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= ns.length else { return nil }
        let r = Self.trimmed(range, in: ns)
        guard r.length > 0 else { return nil }
        let comment = TextComment(side: side, range: r, quote: ns.substring(with: r), body: body)
        comments.append(comment)
        if present {
            if mode != .edit { mode = .edit }
            presentedSuggestion = nil
            currentCommentID = comment.id
            presentedComment = CommentPresentation(id: comment.id, pinned: true, startsEditing: true)
        }
        commentsChanged()
        return comment
    }

    /// `range` without leading and trailing whitespace.
    private static func trimmed(_ range: NSRange, in ns: NSString) -> NSRange {
        func isSpace(_ unit: unichar) -> Bool {
            Unicode.Scalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
        }
        var r = range
        while r.length > 0, isSpace(ns.character(at: r.location)) { r.location += 1; r.length -= 1 }
        while r.length > 0, isSpace(ns.character(at: NSMaxRange(r) - 1)) { r.length -= 1 }
        return r
    }

    /// Menu command: comments the passage selected in an editor.
    func addCommentForSelection() {
        guard let selection, selection.range.location != NSNotFound, !selection.text.isEmpty else { return }
        let range = SelectionRewrite.locate(selection.text, in: text(for: selection.side), near: selection.range) ?? selection.range
        addComment(side: selection.side, range: range)
    }

    func deleteComment(_ id: UUID) {
        comments.removeAll { $0.id == id }
        if presentedComment?.id == id { presentedComment = nil }
        if currentCommentID == id { currentCommentID = nil }
        commentsChanged()
    }

    func deleteComments(where shouldDelete: (TextComment) -> Bool) {
        let gone = Set(comments.filter(shouldDelete).map(\.id))
        guard !gone.isEmpty else { return }
        comments.removeAll { gone.contains($0.id) }
        if let presented = presentedComment, gone.contains(presented.id) { presentedComment = nil }
        if let current = currentCommentID, gone.contains(current) { currentCommentID = nil }
        commentsChanged()
    }

    func setResolved(_ id: UUID, _ resolved: Bool) {
        guard let comment = comment(id: id), comment.isResolved != resolved else { return }
        comment.isResolved = resolved
        comment.editedAt = Date()
        objectWillChange.send()   // repaints the tints
        commentsChanged()
    }

    // MARK: Popover

    /// Opens (id) or closes (nil) a comment's popover. Pointing at a passage
    /// never replaces a popover (or suggestion card) the user opened on purpose.
    func presentComment(_ id: UUID?, pinned: Bool, editing: Bool = false) {
        if let current = presentedComment, current.pinned, !pinned, id != current.id { return }
        guard let id else { presentedComment = nil; return }
        if pinned {
            presentedSuggestion = nil
        } else if presentedSuggestion != nil {
            return
        }
        currentCommentID = id
        presentedComment = CommentPresentation(id: id, pinned: pinned, startsEditing: editing)
    }

    /// The user closed a popover. A comment closed before anything was
    /// written in it goes away.
    func commentCardClosed(_ id: UUID) {
        if presentedComment?.id == id { presentedComment = nil }
        if let comment = comment(id: id), comment.isBlank { deleteComment(id) } else { commentsChanged() }
    }

    /// Selects a comment's passage, scrolls to it and opens its popover.
    func revealComment(_ id: UUID, editing: Bool = false) {
        guard let comment = comment(id: id) else { return }
        if mode != .edit { mode = .edit }
        currentCommentID = id
        guard !comment.isDetached else { return }
        selectionRequest = SelectionRequest(side: comment.side, range: comment.range)
        presentedSuggestion = nil
        presentedComment = CommentPresentation(id: id, pinned: true, startsEditing: editing)
    }

    func showNextComment() { moveComment(by: 1) }
    func showPreviousComment() { moveComment(by: -1) }

    private func moveComment(by offset: Int) {
        let ordered = navigableComments
        guard !ordered.isEmpty else { return }
        let current = (presentedComment?.id ?? currentCommentID).flatMap { id in ordered.firstIndex { $0.id == id } }
        let next = current.map { ($0 + offset + ordered.count) % ordered.count } ?? (offset > 0 ? 0 : ordered.count - 1)
        revealComment(ordered[next].id)
    }

    // MARK: Following the text

    /// Moves each comment on `side` along with its passage. A comment whose
    /// passage is deleted is detached (and reattached if the passage comes
    /// straight back, e.g. after an undo).
    func trackComments(on side: Side, from old: String) {
        let affected = comments.filter { $0.side == side }
        guard !affected.isEmpty else { return }
        let new = text(for: side)
        let ns = new as NSString
        let change = TrackedRange.changedRanges(old: old, new: new)
        for comment in affected {
            if comment.isDetached {
                comment.range = NSRange(location: min(TrackedRange.shift(comment.range.location, change: change), ns.length), length: 0)
                // Only text that just came back counts, not any other occurrence.
                for quote in Set([comment.quote, comment.originalQuote]) where change.new.length > 0 {
                    if let found = SelectionRewrite.locate(quote, in: new, near: change.new),
                       NSIntersectionRange(found, change.new) == found {
                        comment.range = found
                        comment.quote = quote
                        comment.isDetached = false
                        break
                    }
                }
                continue
            }
            var outcome = TrackedRange.follow(comment.range, passage: comment.quote, change: change, new: new)
            if case .edited = outcome,
               change.old.location <= comment.range.location, NSMaxRange(change.old) >= NSMaxRange(comment.range) {
                // The whole passage was replaced. When the replaced text was
                // mostly the passage (e.g. an accepted rewrite of it), the
                // comment moves to the new text; when it was a much bigger
                // edit (new text pasted over everything), it detaches.
                let replacement = Self.trimmed(change.new, in: ns)
                outcome = replacement.length > 0 && comment.range.length * 2 >= change.old.length ? .edited(replacement) : .removed
            }
            switch outcome {
            case .intact(let range):
                comment.range = range
            case .edited(let range):
                comment.range = range
                comment.quote = ns.substring(with: range)
            case .removed:
                comment.range = NSRange(location: min(TrackedRange.shift(comment.range.location, change: change), ns.length), length: 0)
                comment.isDetached = true
            }
        }
        commentsChanged(debounce: 1.0)
    }

    /// Swapping the texts takes their comments along.
    func swapCommentSides() {
        for comment in comments { comment.side = comment.side.other }
    }

    // MARK: Saving with files

    /// A side's file is about to be replaced or closed: its comments are saved
    /// with it and leave the window (they come back when it's reopened).
    /// Comments on pasted text stay and follow the new text instead.
    func releaseComments(on side: Side) {
        guard let url = url(for: side) else { return }
        saveComments(for: url)
        deleteCommentsWithoutSaving { $0.side == side }
    }

    /// Brings back the comments saved for a file just opened on `side`,
    /// finding each passage again (or detaching it if the file changed).
    func restoreComments(for url: URL, on side: Side) {
        guard let commentStore else { return }
        let text = text(for: side)
        let length = (text as NSString).length
        for saved in commentStore.comments(for: url) where comment(id: saved.id) == nil {
            let comment = saved.comment(on: side)
            let hint = NSRange(location: min(saved.location, length), length: 0)
            if !saved.isDetached,
               let found = SelectionRewrite.locate(saved.quote, in: text, near: hint) ?? SelectionRewrite.locate(saved.originalQuote, in: text, near: hint) {
                comment.range = found
                comment.quote = (text as NSString).substring(with: found)
            } else {
                comment.range = hint
                comment.isDetached = true
            }
            comments.append(comment)
        }
    }

    /// Something about the comments changed: save those on files soon.
    func commentsChanged(debounce: TimeInterval = 0.4) {
        contentChanged.send()
        guard commentStore != nil, leftURL != nil || rightURL != nil else { return }
        commentSaveTask?.cancel()
        commentSaveTask = Task { @MainActor [self] in
            try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            saveFileComments()
        }
    }

    /// Saves the comments of both file-backed sides now.
    func saveFileComments() {
        commentSaveTask?.cancel()
        commentSaveTask = nil
        for url in Set([leftURL, rightURL].compactMap { $0?.standardizedFileURL }) { saveComments(for: url) }
    }

    private func saveComments(for url: URL) {
        guard let commentStore else { return }
        let file = url.standardizedFileURL
        let sides = [Side.left, .right].filter { self.url(for: $0)?.standardizedFileURL == file }
        let mine = comments.filter { sides.contains($0.side) && !$0.isBlank }
        commentStore.save(mine.map(CommentStore.Saved.init), for: file)
    }

    private func deleteCommentsWithoutSaving(where shouldDelete: (TextComment) -> Bool) {
        let gone = Set(comments.filter(shouldDelete).map(\.id))
        guard !gone.isEmpty else { return }
        comments.removeAll { gone.contains($0.id) }
        if let presented = presentedComment, gone.contains(presented.id) { presentedComment = nil }
        if let current = currentCommentID, gone.contains(current) { currentCommentID = nil }
    }

    func url(for side: Side) -> URL? { side == .left ? leftURL : rightURL }
}

// MARK: - Saved comments

/// Comments saved per file (by path), in the app's support folder, so they're
/// back when the file is opened again. Passages are found again by their text.
struct CommentStore {
    struct Saved: Codable, Equatable {
        var id: UUID
        var body: String
        /// The passage as it last read in Diffactly, and when first commented.
        var quote: String
        var originalQuote: String
        /// Where the passage was (a hint for finding it again).
        var location: Int
        var isResolved: Bool
        var isDetached: Bool
        var createdAt: Date
        var editedAt: Date
    }

    struct File: Codable, Equatable {
        var comments: [Saved]
        var saved: Date
    }

    let url: URL

    static let shared: CommentStore = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return CommentStore(url: support.appendingPathComponent("Diffactly/Comments.json"))
    }()

    /// Most files kept; the least recently saved go first.
    static let fileLimit = 200

    func all() -> [String: File] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: File].self, from: data)) ?? [:]
    }

    func comments(for file: URL) -> [Saved] {
        all()[Self.key(file)]?.comments ?? []
    }

    /// Replaces what's saved for `file` (nothing saved when `comments` is empty).
    func save(_ comments: [Saved], for file: URL) {
        var files = all()
        let key = Self.key(file)
        if files[key]?.comments == comments { return }
        files[key] = comments.isEmpty ? nil : File(comments: comments, saved: Date())
        if files.count > Self.fileLimit {
            for (old, _) in files.sorted(by: { $0.value.saved < $1.value.saved }).prefix(files.count - Self.fileLimit) {
                files[old] = nil
            }
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(files).write(to: url, options: .atomic)
        } catch {
            // Losing saved comments only costs the notes on reopening; the
            // window still has them.
        }
    }

    static func key(_ file: URL) -> String { file.standardizedFileURL.path }
}

extension CommentStore.Saved {
    @MainActor
    init(_ comment: TextComment) {
        self.init(id: comment.id, body: comment.body, quote: comment.quote, originalQuote: comment.originalQuote,
                  location: comment.range.location, isResolved: comment.isResolved, isDetached: comment.isDetached,
                  createdAt: comment.createdAt, editedAt: comment.editedAt)
    }

    @MainActor
    func comment(on side: DiffDocument.Side) -> TextComment {
        let comment = TextComment(id: id, side: side, range: NSRange(location: location, length: 0), quote: quote,
                                  originalQuote: originalQuote, body: body, createdAt: createdAt)
        comment.isResolved = isResolved
        comment.isDetached = isDetached
        comment.editedAt = editedAt
        return comment
    }
}
