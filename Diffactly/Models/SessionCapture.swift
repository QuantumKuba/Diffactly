import Foundation
import DiffactlyCore

/// One tab as it goes into a saved session: its manifest entry and the
/// texts it refers to.
struct CapturedTab: Equatable {
    var tab: SessionManifest.Tab
    var texts: [String: String]
}

extension DiffDocument {

    // MARK: Saving

    /// Everything about this tab worth keeping: texts, files, titles, view
    /// settings, comments, highlights, pending suggestions and, through the
    /// window's AI sheet, its choices, results and references.
    func captureSession(bookmarks: BookmarkCache? = nil) -> CapturedTab {
        let bookmarks = bookmarks ?? .shared
        let folder = "\(SessionPackage.tabsFolder)/\(sessionTabID.uuidString)"
        var texts: [String: String] = [:]

        func side(_ side: Side) -> SessionManifest.SideState {
            let url = url(for: side)
            let name = side == .left ? leftName : rightName
            let path = "\(folder)/\(side.rawValue).\(Self.textExtension(for: name))"
            texts[path] = text(for: side)
            return SessionManifest.SideState(
                title: title(for: side), textFile: path, fileName: name,
                filePath: url?.path, fileBookmark: url.flatMap { bookmarks.data(for: $0) })
        }

        var references: [SessionManifest.ReferenceState] = []
        if let rewriteSession {
            let saved = rewriteSession.references.sessionState(folder: "\(folder)/References", bookmarks: bookmarks)
            references = saved.references
            texts.merge(saved.texts) { a, _ in a }
        }

        let tab = SessionManifest.Tab(
            id: sessionTabID,
            title: tabTitle,
            left: side(.left),
            right: side(.right),
            view: SessionManifest.ViewState(
                mode: mode, options: options, collapseUnchanged: collapseUnchanged, wrapLines: wrapLines,
                showInsights: showInsights, showsResolvedComments: showsResolvedComments, showsComments: isShowingComments),
            comments: comments.filter { !$0.isBlank }.map { c in
                SessionManifest.CommentState(
                    id: c.id, side: c.side, location: c.range.location, length: c.range.length, quote: c.quote,
                    originalQuote: c.originalQuote, body: c.body, isResolved: c.isResolved, isDetached: c.isDetached,
                    created: c.createdAt, edited: c.editedAt)
            },
            highlights: sourceMarks.map { .init(side: $0.side, location: $0.range.location, length: $0.range.length, text: $0.text) },
            suggestions: suggestions.compactMap(Self.suggestionState),
            ai: rewriteSession?.sessionState(),
            references: references,
            acceptedRewrites: acceptedRewrites.isEmpty ? nil : acceptedRewrites.map { r in
                .init(side: r.side, location: r.range.location, length: r.range.length, text: r.text,
                      steps: r.steps.map { .init(original: $0.original, rewrite: $0.rewrite, label: $0.label, date: $0.date, suggestion: $0.suggestion) })
            },
            links: links.isEmpty ? nil : links.map { l in
                .init(leftLocation: l.left.location, leftLength: l.left.length, leftText: l.leftText,
                      rightLocation: l.right.location, rightLength: l.right.length, rightText: l.rightText, isAutomatic: l.isAutomatic)
            })
        return CapturedTab(tab: tab, texts: texts)
    }

    /// Suggestions are kept with their finished versions; one still being set
    /// up, written or that failed before giving any answer has nothing to keep.
    static func suggestionState(_ suggestion: AISuggestion) -> SessionManifest.SuggestionState? {
        let versions = suggestion.versions
        guard !versions.isEmpty else { return nil }
        let shown = suggestion.shownVersionID.flatMap { id in versions.firstIndex { $0.id == id } } ?? versions.count - 1
        return SessionManifest.SuggestionState(
            side: suggestion.side, location: suggestion.range.location, length: suggestion.range.length,
            original: suggestion.original, isStale: suggestion.status == .stale, shownVersion: shown,
            versions: versions.map { version in
                var state = versionState(version)
                let parts = (suggestion.refinementsByVersion[version.id] ?? []).compactMap(refinementState)
                state.refinements = parts.isEmpty ? nil : parts
                return state
            })
    }

    private static func versionState(_ v: AISuggestion.Version) -> SessionManifest.VersionState {
        .init(text: v.text, label: v.label, basisLabel: v.basisLabel, date: v.date,
              duration: v.duration, didAudit: v.didAudit, truncation: v.truncation)
    }

    /// A rewritten part is kept with its finished versions, like a suggestion.
    private static func refinementState(_ part: AISuggestion) -> SessionManifest.RefinementState? {
        let versions = part.versions
        guard !versions.isEmpty else { return nil }
        let shown = part.shownVersionID.flatMap { id in versions.firstIndex { $0.id == id } } ?? versions.count - 1
        return .init(location: part.range.location, length: part.range.length, original: part.original,
                     shownVersion: part.usesParentWording ? nil : shown, versions: versions.map(versionState))
    }

    /// The text file's extension: the open file's, so it opens in the right
    /// editor (".tex", ".md"), or "txt".
    static func textExtension(for fileName: String?) -> String {
        let ext = ((fileName ?? "") as NSString).pathExtension.lowercased()
        let valid = !ext.isEmpty && ext.count <= 12 && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return valid ? ext : "txt"
    }

    // MARK: Restoring

    /// Puts a saved tab back into this window (meant for a fresh one).
    func restoreSession(_ tab: SessionManifest.Tab, texts: [String: String], bookmarks: BookmarkCache? = nil) {
        let bookmarks = bookmarks ?? .shared
        rejectAllSuggestions()
        acceptedRewrites = []
        links = []
        pendingLink = nil
        comments = []
        sourceMarks = []
        presentedComment = nil
        presentedSuggestion = nil
        currentCommentID = nil
        sessionTabID = tab.id

        // References first: the files below would otherwise pull in the ones
        // remembered for their folder.
        if let rewriteSession {
            rewriteSession.references.restore(tab.references, texts: texts, bookmarks: bookmarks)
        }
        for (side, state) in [(Side.left, tab.left), (.right, tab.right)] {
            setTitle(state.title, for: side)
            let url = state.filePath == nil && state.fileBookmark == nil ? nil : bookmarks.resolve(state.fileBookmark, path: state.filePath)
            restoreFile(url, name: state.fileName, for: side)
            setText(texts[state.textFile] ?? "", for: side)
        }

        let view = tab.view
        options = view.options
        collapseUnchanged = view.collapseUnchanged
        wrapLines = view.wrapLines
        showInsights = view.showInsights
        showsResolvedComments = view.showsResolvedComments
        isShowingComments = view.showsComments
        mode = view.mode

        for saved in tab.comments { comments.append(restoredComment(saved)) }
        for saved in tab.highlights {
            let range = NSRange(location: saved.location, length: saved.length)
            if let found = locate(saved.text, on: saved.side, near: range) {
                sourceMarks.append(SourceMark(side: saved.side, range: found, text: saved.text))
            }
        }
        for saved in tab.suggestions { restoreSuggestion(saved) }
        for saved in tab.acceptedRewrites ?? [] {
            guard !saved.steps.isEmpty,
                  let found = locate(saved.text, on: saved.side, near: NSRange(location: saved.location, length: saved.length)) else { continue }
            acceptedRewrites.append(AcceptedRewrite(
                side: saved.side, range: found, text: saved.text,
                steps: saved.steps.map { .init(original: $0.original, rewrite: $0.rewrite, label: $0.label, date: $0.date, suggestion: $0.suggestion) }))
        }
        for saved in tab.links ?? [] {
            guard let left = locate(saved.leftText, on: .left, near: NSRange(location: saved.leftLocation, length: saved.leftLength)),
                  let right = locate(saved.rightText, on: .right, near: NSRange(location: saved.rightLocation, length: saved.rightLength)) else { continue }
            links.append(PassageLink(left: left, leftText: saved.leftText, right: right, rightText: saved.rightText, isAutomatic: saved.isAutomatic))
        }
        if let ai = tab.ai { rewriteSession?.restore(ai) }
        tabTitle = tab.title
    }

    /// `text` at `range` on `side`, or found again nearby (nil when it's gone).
    private func locate(_ text: String, on side: Side, near range: NSRange) -> NSRange? {
        let ns = self.text(for: side) as NSString
        if range.length > 0, NSMaxRange(range) <= ns.length, ns.substring(with: range) == text { return range }
        guard !text.isEmpty else { return nil }
        return SelectionRewrite.locate(text, in: ns as String, near: NSRange(location: min(range.location, ns.length), length: 0))
    }

    private func restoredComment(_ saved: SessionManifest.CommentState) -> TextComment {
        let range = NSRange(location: saved.location, length: saved.length)
        let comment = TextComment(id: saved.id, side: saved.side, range: range, quote: saved.quote,
                                  originalQuote: saved.originalQuote, body: saved.body, createdAt: saved.created)
        comment.isResolved = saved.isResolved
        comment.editedAt = saved.edited
        let length = (text(for: saved.side) as NSString).length
        if !saved.isDetached, let found = locate(saved.quote, on: saved.side, near: range) {
            comment.range = found
        } else {
            comment.range = NSRange(location: min(saved.location, length), length: 0)
            comment.isDetached = true
        }
        return comment
    }

    private func restoreSuggestion(_ saved: SessionManifest.SuggestionState) {
        let range = NSRange(location: saved.location, length: saved.length)
        let found = locate(saved.original, on: saved.side, near: range)
        guard let suggestion = restoredSuggestion(saved, at: found ?? range) else { return }
        if found == nil {
            // Its passage was edited: it can be regenerated, not accepted.
            let length = (text(for: saved.side) as NSString).length
            guard NSMaxRange(suggestion.range) <= length else { return }
            suggestion.status = .stale
        }
        addSuggestion(suggestion, present: false)
    }

    /// A suggestion with its saved versions and rewritten parts (not added).
    func restoredSuggestion(_ saved: SessionManifest.SuggestionState, at range: NSRange? = nil) -> AISuggestion? {
        guard !saved.versions.isEmpty else { return nil }
        let range = range ?? NSRange(location: saved.location, length: saved.length)
        let suggestion = AISuggestion(side: saved.side, range: range, original: saved.original, status: .ready)
        suggestion.adoptVersions(saved.versions.map(Self.version), showing: min(max(saved.shownVersion, 0), saved.versions.count - 1))
        for (index, version) in saved.versions.enumerated() {
            for part in version.refinements ?? [] {
                suggestion.restoreRefinement(
                    versionIndex: index, range: NSRange(location: part.location, length: part.length), original: part.original,
                    versions: part.versions.map(Self.version), showing: part.shownVersion, usesParentWording: part.shownVersion == nil)
            }
        }
        return suggestion
    }

    private static func version(_ saved: SessionManifest.VersionState) -> AISuggestion.Version {
        AISuggestion.Version(text: saved.text, label: saved.label, basisLabel: saved.basisLabel, date: saved.date,
                             duration: saved.duration, didAudit: saved.didAudit, truncation: saved.truncation)
    }
}
