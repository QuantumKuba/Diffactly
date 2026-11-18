import SwiftUI
import AppKit
import DiffactlyCore

/// Editable, line-numbered text view that paints diff highlights without
/// touching the text itself (so undo, selection and typing stay intact).
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var highlights: EditorHighlights
    var placeholder: String
    var wrapLines: Bool
    var focusRequest: DiffDocument.FocusRequest?
    var focusLines: ClosedRange<Int>?
    var side: DiffDocument.Side = .left
    var searchMatches: [SearchMatch] = []
    var currentMatch: SearchMatch? = nil
    var isSearchPresented: Bool = false
    var onFileDrop: (URL) -> Void
    /// Receives the selected text (empty when the caret is just a caret) and its UTF-16 range.
    var onSelectionChange: (String, NSRange) -> Void = { _, _ in }
    /// Selects and reveals a range once (e.g. a passage the AI just rewrote).
    var selectionRequest: DiffDocument.SelectionRequest? = nil
    /// Context menu → "Rewrite … with AI…" (the AI sheet): the passage and its range.
    var onRewriteSelection: ((String, NSRange) -> Void)? = nil
    /// Context menu → "Humanize Selection" (an inline suggestion): the passage and its range.
    var onSuggestRewrite: ((String, NSRange) -> Void)? = nil
    /// Context menu → "Humanize Selection with Options…": the same, with the card open on its settings first.
    var onSuggestRewriteWithOptions: ((String, NSRange) -> Void)? = nil
    /// The prompt's name for those menu items, e.g. "Humanize".
    var quickRewriteTitle: String = "Humanize"
    /// Pending AI suggestions in this editor.
    var suggestionMarks: [SuggestionMark] = []
    /// The suggestion whose card should be open (it may be in the other editor).
    var presentedSuggestion: SuggestionPresentation? = nil
    /// Asks to open (id) or close (nil) a suggestion's card; `pinned` when the
    /// user clicked rather than just pointed at it.
    var onPresentSuggestion: ((UUID?, Bool) -> Void)? = nil
    /// The card was closed by the user (clicked elsewhere or pressed Esc).
    var onSuggestionCardClosed: ((UUID) -> Void)? = nil
    /// Builds a suggestion's card.
    var suggestionCard: ((UUID) -> AnyView)? = nil
    /// Text highlighted as a source for AI rewrites in this editor.
    var sourceMarks: [NSRange] = []
    /// Highlights in both editors (for "Clear AI Source Highlights").
    var totalSourceMarks = 0
    /// Context menu → mark, unmark or clear AI source highlights.
    var onSourceMarkAction: ((SourceMarkAction) -> Void)? = nil
    /// Passages in this editor linked to the other side (see PassageLinks.swift).
    var linkMarks: [LinkMark] = []
    /// A link is waiting for its other end in the other editor.
    var isLinkPendingOnOtherSide = false
    /// The other editor's title, for menu items ("Link to Text in Original").
    var otherSideTitle = ""
    /// Context menu → make, follow or remove links.
    var onLinkAction: ((LinkAction) -> Void)? = nil
    /// The pointer moved onto (id) or off (nil) a linked passage.
    var onLinkHover: ((UUID?) -> Void)? = nil
    /// Comments on passages in this editor (see TextComment.swift).
    var commentMarks: [CommentMark] = []
    /// The comment whose popover should be open (it may be in the other editor).
    var presentedComment: CommentPresentation? = nil
    /// Asks to open (id) or close (nil) a comment's popover; `pinned` when on purpose.
    var onPresentComment: ((UUID?, Bool) -> Void)? = nil
    /// The comment's popover was closed by the user.
    var onCommentClosed: ((UUID) -> Void)? = nil
    /// Builds a comment's popover.
    var commentCard: ((UUID) -> AnyView)? = nil
    /// Context menu / ⇧⌘M → "Add Comment…": the passage and its range.
    var onAddComment: ((String, NSRange) -> Void)? = nil
    var onFocus: (() -> Void)? = nil
    var onFind: (() -> Void)? = nil
    var onFindNext: (() -> Void)? = nil
    var onFindPrevious: (() -> Void)? = nil
    var onUseSelection: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let textView = DiffTextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.placeholder = placeholder
        textView.onFileDrop = onFileDrop
        textView.onFocus = onFocus
        textView.onFind = onFind
        textView.onFindNext = onFindNext
        textView.onFindPrevious = onFindPrevious
        textView.onUseSelection = onUseSelection
        textView.onRewriteSelection = onRewriteSelection
        textView.onSuggestRewrite = onSuggestRewrite
        textView.onSuggestRewriteWithOptions = onSuggestRewriteWithOptions
        textView.quickRewriteTitle = quickRewriteTitle
        textView.sourceMarks = sourceMarks
        textView.totalSourceMarks = totalSourceMarks
        textView.onSourceMarkAction = onSourceMarkAction
        textView.linkMarks = linkMarks
        textView.isLinkPendingOnOtherSide = isLinkPendingOnOtherSide
        textView.otherSideTitle = otherSideTitle
        textView.onLinkAction = onLinkAction
        textView.onLinkHover = onLinkHover
        let coordinator = context.coordinator
        textView.onSuggestionHover = { [weak coordinator] id in coordinator?.hoverChanged(id) }
        textView.onSuggestionClick = { [weak coordinator] id in coordinator?.parent.onPresentSuggestion?(id, true) }
        coordinator.wireComments(textView)
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = false
        textView.isIncrementalSearchingEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = DiffTextView.font
        textView.typingAttributes = [.font: DiffTextView.font, .foregroundColor: NSColor.textColor]
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let ruler = LineNumberRuler(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        ruler.onCommentClick = { [weak coordinator] id in coordinator?.parent.onPresentComment?(id, true) }
        textView.commentMarks = commentMarks
        ruler.commentMarks = commentMarks
        applyWrapping(textView, scrollView)
        textView.apply(
            highlights: highlights,
            suggestionMarks: suggestionMarks,
            searchMatches: searchMatches,
            currentMatchID: currentMatch?.id,
            isSearchPresented: isSearchPresented
        )
        ruler.marks = highlights
        return scrollView
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.closeCard()
        coordinator.commentPopover.close()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        textView.onFileDrop = onFileDrop
        textView.placeholder = placeholder
        textView.onFocus = onFocus
        textView.onFind = onFind
        textView.onFindNext = onFindNext
        textView.onFindPrevious = onFindPrevious
        textView.onUseSelection = onUseSelection
        textView.onRewriteSelection = onRewriteSelection
        textView.onSuggestRewrite = onSuggestRewrite
        textView.onSuggestRewriteWithOptions = onSuggestRewriteWithOptions
        textView.quickRewriteTitle = quickRewriteTitle
        textView.totalSourceMarks = totalSourceMarks
        textView.onSourceMarkAction = onSourceMarkAction
        textView.onAddComment = onAddComment

        if textView.string != text {
            // External change (file opened, swap, transform, AI rewrite): replace
            // only the part that differs, undoably, so ⌘Z restores exactly that
            // edit and the scroll position survives small changes.
            let old = textView.string as NSString
            let change = Self.changedRanges(old: textView.string, new: text)
            let inserted = (text as NSString).substring(with: change.new)
            if textView.shouldChangeText(in: change.old, replacementString: inserted) {
                textView.textStorage?.replaceCharacters(in: change.old, with: NSAttributedString(string: inserted, attributes: textView.typingAttributes))
                textView.didChangeText()
            }
            let replacedEverything = change.old.location == 0 && change.old.length == old.length
            textView.setSelectedRange(NSRange(location: replacedEverything ? 0 : NSMaxRange(change.new), length: 0))
        }
        if let request = selectionRequest, request.side == side, request.id != context.coordinator.lastSelectionRequestID {
            context.coordinator.lastSelectionRequestID = request.id
            if NSMaxRange(request.range) <= (textView.string as NSString).length {
                textView.setSelectedRange(request.range)
                DispatchQueue.main.async {
                    textView.scrollRangeToVisible(request.range)
                    if request.range.length > 0 { textView.showFindIndicator(for: request.range) }
                }
            }
        }
        textView.sourceMarks = sourceMarks
        textView.linkMarks = linkMarks
        textView.isLinkPendingOnOtherSide = isLinkPendingOnOtherSide
        textView.otherSideTitle = otherSideTitle
        if context.coordinator.wrapLines != wrapLines {
            context.coordinator.wrapLines = wrapLines
            applyWrapping(textView, scrollView)
        }

        let searchChanged = textView.searchMatches != searchMatches
            || textView.currentMatchID != currentMatch?.id
            || textView.isSearchPresented != isSearchPresented

        let commentsChanged = textView.commentMarks != commentMarks
        if commentsChanged {
            textView.commentMarks = commentMarks
            context.coordinator.ruler?.commentMarks = commentMarks
        }
        if textView.highlights != highlights || searchChanged || textView.suggestionMarks != suggestionMarks || commentsChanged {
            textView.apply(
                highlights: highlights,
                suggestionMarks: suggestionMarks,
                searchMatches: searchMatches,
                currentMatchID: currentMatch?.id,
                isSearchPresented: isSearchPresented
            )
            context.coordinator.ruler?.marks = highlights
        }
        if let request = focusRequest, request.id != context.coordinator.lastFocusID {
            context.coordinator.lastFocusID = request.id
            if let lines = focusLines {
                DispatchQueue.main.async { textView.reveal(lines: lines) }
            }
        }
        if let current = currentMatch, current.side == side, current.id != context.coordinator.lastScrolledMatchID {
            context.coordinator.lastScrolledMatchID = current.id
            let length = (textView.string as NSString).length
            if NSMaxRange(current.range) <= length {
                DispatchQueue.main.async {
                    textView.scrollRangeToVisible(current.range)
                    textView.showFindIndicator(for: current.range)
                }
            }
        }
        context.coordinator.updateCard()
        context.coordinator.updateCommentPopover()
    }

    /// The smallest ranges (old and new, UTF-16) that turn `old` into `new`
    /// (see `TrackedRange.changedRanges`).
    static func changedRanges(old: String, new: String) -> (old: NSRange, new: NSRange) {
        TrackedRange.changedRanges(old: old, new: new)
    }

    private func applyWrapping(_ textView: DiffTextView, _ scrollView: NSScrollView) {
        guard let container = textView.textContainer else { return }
        if wrapLines {
            container.widthTracksTextView = true
            textView.isHorizontallyResizable = false
            scrollView.hasHorizontalScroller = false
            textView.frame.size.width = scrollView.contentSize.width
        } else {
            container.widthTracksTextView = false
            container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
            scrollView.hasHorizontalScroller = true
        }
        (textView.textContainer?.layoutManager).map { $0.ensureLayout(for: container) }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSPopoverDelegate {
        var parent: CodeEditor
        weak var textView: DiffTextView?
        weak var ruler: LineNumberRuler?
        var lastFocusID: UUID?
        var lastScrolledMatchID: UUID?
        var lastSelectionRequestID: UUID?
        var wrapLines: Bool

        init(_ parent: CodeEditor) {
            self.parent = parent
            self.wrapLines = parent.wrapLines
        }

        // MARK: Suggestion card

        private var popover: NSPopover?
        /// The suggestion the card shows.
        private(set) var shownID: UUID?
        private var shownRequestID: UUID?
        /// Opened (or since clicked) on purpose, so pointing away doesn't close it.
        private(set) var pinned = false
        private var hoverID: UUID?
        private var cardHovered = false
        private var openWork: DispatchWorkItem?
        private var closeWork: DispatchWorkItem?

        /// Opens, moves or closes the card to match `parent.presentedSuggestion`.
        func updateCard() {
            guard let textView else { return }
            guard let presentation = parent.presentedSuggestion,
                  let mark = parent.suggestionMarks.first(where: { $0.id == presentation.id }) else {
                if shownID != nil { closeCard() }
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
            show(presentation, range: mark.range, in: textView)
        }

        private func show(_ presentation: SuggestionPresentation, range: NSRange, in textView: DiffTextView) {
            closeCard()
            guard let content = parent.suggestionCard?(presentation.id) else { return }
            if !NSIntersectsRect(textView.rect(for: range) ?? .zero, textView.visibleRect) {
                textView.scrollRangeToVisible(range)
            }
            guard let rect = anchor(for: range, in: textView) else { return }
            let id = presentation.id
            let host = NSHostingController(rootView: AnyView(
                content
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
        }

        /// Where the card points: the part of the passage that's on screen.
        private func anchor(for range: NSRange, in textView: DiffTextView) -> NSRect? {
            guard let rect = textView.rect(for: range) else { return nil }
            let visible = rect.intersection(textView.visibleRect)
            return visible.isEmpty ? rect : visible
        }

        func closeCard() {
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
            parent.onPresentSuggestion?(id, true)
        }

        /// The pointer moved onto (id) or off (nil) a suggestion's passage:
        /// open its card after a short rest, close an unpinned one shortly
        /// after leaving.
        func hoverChanged(_ id: UUID?) {
            guard id != hoverID else { return }
            hoverID = id
            openWork?.cancel()
            guard let id else { scheduleHoverClose(); return }
            closeWork?.cancel()
            if shownID == id, popover?.isShown == true { return }
            // Pointing at another passage doesn't take over a card opened on purpose.
            if pinned, popover?.isShown == true { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.hoverID == id else { return }
                self.parent.onPresentSuggestion?(id, false)
            }
            openWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
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
                self.parent.onPresentSuggestion?(nil, false)
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
            parent.onSuggestionCardClosed?(id)
        }

        // MARK: Comment popover

        /// Shows comment popovers, apart from the suggestion card.
        let commentPopover = CommentPopoverController()

        func wireComments(_ textView: DiffTextView) {
            commentPopover.textView = textView
            commentPopover.onPresent = { [weak self] id, pinned in self?.parent.onPresentComment?(id, pinned) }
            commentPopover.onClosed = { [weak self] id in self?.parent.onCommentClosed?(id) }
            textView.onCommentHover = { [weak self] id in self?.commentPopover.hoverChanged(id) }
            textView.onCommentClick = { [weak self] id in self?.parent.onPresentComment?(id, true) }
            textView.onAddComment = parent.onAddComment
        }

        func updateCommentPopover() {
            // A suggestion card open on this editor's passage wins.
            let suggestionShown = shownID != nil && popover?.isShown == true
            commentPopover.update(presentation: parent.presentedComment, marks: parent.commentMarks,
                                  suppressed: suggestionShown) { [parent] id in parent.commentCard?(id) }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let range = tv.selectedRange()
            let selected = range.length > 0 ? (tv.string as NSString).substring(with: range) : ""
            // AppKit can fire this while SwiftUI is mid-update (e.g. when the text
            // is replaced externally); publishing then is illegal, so hop a turn.
            DispatchQueue.main.async { [weak self] in self?.parent.onSelectionChange(selected, range) }
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            ruler?.textDidChange()
            if parent.text != tv.string { parent.text = tv.string }
        }
    }
}

// MARK: - Text view

final class DiffTextView: NSTextView {
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    var placeholder = ""
    var onFileDrop: ((URL) -> Void)?
    var onFocus: (() -> Void)?
    var onFind: (() -> Void)?
    var onFindNext: (() -> Void)?
    var onFindPrevious: (() -> Void)?
    var onUseSelection: (() -> Void)?
    var onRewriteSelection: ((String, NSRange) -> Void)?
    var onSuggestRewrite: ((String, NSRange) -> Void)?
    var onSuggestRewriteWithOptions: ((String, NSRange) -> Void)?
    var quickRewriteTitle = "Humanize"
    /// AI source highlights, painted behind the text with a bar in the margin.
    var sourceMarks: [NSRange] = [] { didSet { if sourceMarks != oldValue { needsDisplay = true } } }
    var totalSourceMarks = 0
    var onSourceMarkAction: ((SourceMarkAction) -> Void)?
    /// Linked passages, painted behind the text (stronger when highlighted).
    var linkMarks: [LinkMark] = [] { didSet { if linkMarks != oldValue { needsDisplay = true } } }
    var isLinkPendingOnOtherSide = false
    var otherSideTitle = ""
    var onLinkAction: ((LinkAction) -> Void)?
    var onLinkHover: ((UUID?) -> Void)?
    private var hoveredLink: UUID?
    var onSuggestionHover: ((UUID?) -> Void)?
    var onSuggestionClick: ((UUID) -> Void)?
    private(set) var suggestionMarks: [SuggestionMark] = []
    /// Commented passages (painted under suggestions; see `apply`).
    var commentMarks: [CommentMark] = []
    var onCommentHover: ((UUID?) -> Void)?
    var onCommentClick: ((UUID) -> Void)?
    var onAddComment: ((String, NSRange) -> Void)?
    private var hoveredComment: UUID?
    private var hoverArea: NSTrackingArea?
    private var hoveredSuggestion: UUID?
    private(set) var highlights = EditorHighlights()
    private(set) var searchMatches: [SearchMatch] = []
    private(set) var currentMatchID: UUID?
    private(set) var isSearchPresented: Bool = false

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        let point = convert(event.locationInWindow, from: nil)
        let clicked = event.clickCount == 1 && event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty
            ? suggestionID(at: point) : nil
        let clickedComment = clicked == nil && event.clickCount == 1 && event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty
            ? commentID(at: point) : nil
        super.mouseDown(with: event)   // tracks the drag until the button goes up
        // A plain click (not a drag-selection) on a suggestion opens its card.
        if let clicked, selectedRange().length == 0 { onSuggestionClick?(clicked) }
        // ...or, where there's no suggestion, on a comment opens the comment.
        if let clickedComment, selectedRange().length == 0 { onCommentClick?(clickedComment) }
    }

    // MARK: Suggestions under the pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        // Accepted rewrites open on a click only: they'd pop up all over a rewritten text.
        let suggestion = suggestionMarks.isEmpty ? nil : suggestionID(at: point, includingHistory: false)
        setHovered(suggestion)
        setHoveredComment(suggestion == nil ? commentID(at: point) : nil)
        setHoveredLink(linkID(at: point))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovered(nil)
        setHoveredComment(nil)
        setHoveredLink(nil)
    }

    private func setHoveredLink(_ id: UUID?) {
        guard id != hoveredLink else { return }
        hoveredLink = id
        onLinkHover?(id)
    }

    /// The smallest linked passage under `point` (view coordinates).
    func linkID(at point: NSPoint) -> UUID? {
        let real = linkMarks.filter { !$0.isPending }
        guard !real.isEmpty, let index = characterIndex(onTextAt: point) else { return nil }
        return real.filter { NSLocationInRange(index, $0.range) }.min { $0.range.length < $1.range.length }?.id
    }

    private func setHovered(_ id: UUID?) {
        guard id != hoveredSuggestion else { return }
        hoveredSuggestion = id
        onSuggestionHover?(id)
    }

    /// The suggestion whose passage is under `point` (view coordinates); a
    /// pending one wins over an accepted rewrite's history.
    func suggestionID(at point: NSPoint, includingHistory: Bool = true) -> UUID? {
        guard !suggestionMarks.isEmpty, let index = characterIndex(onTextAt: point) else { return nil }
        let here = suggestionMarks.filter { NSLocationInRange(index, $0.range) }
        if let pending = here.first(where: { !$0.style.isHistory }) { return pending.id }
        return includingHistory ? here.min { $0.range.length < $1.range.length }?.id : nil
    }

    /// The character under `point` (view coordinates), only on the text
    /// itself, not the empty space after a short line.
    func characterIndex(onTextAt point: NSPoint) -> Int? {
        guard let layout = layoutManager, let container = textContainer, layout.numberOfGlyphs > 0 else { return nil }
        let origin = textContainerOrigin
        let p = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: p, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layout.numberOfGlyphs else { return nil }
        let glyphRect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard glyphRect.insetBy(dx: -3, dy: -1).contains(p) else { return nil }
        return layout.characterIndexForGlyph(at: glyph)
    }

    /// The area `range` covers, in view coordinates.
    func rect(for range: NSRange) -> NSRect? {
        guard let layout = layoutManager, let container = textContainer, NSMaxRange(range) <= (string as NSString).length else { return nil }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        return rect
    }

    func apply(
        highlights: EditorHighlights,
        suggestionMarks: [SuggestionMark] = [],
        searchMatches: [SearchMatch] = [],
        currentMatchID: UUID? = nil,
        isSearchPresented: Bool = false
    ) {
        self.highlights = highlights
        self.suggestionMarks = suggestionMarks
        self.searchMatches = searchMatches
        self.currentMatchID = currentMatchID
        self.isSearchPresented = isSearchPresented

        guard let layout = layoutManager else { return }
        let length = (string as NSString).length
        let all = NSRange(location: 0, length: length)
        for key in [NSAttributedString.Key.backgroundColor, .foregroundColor, .underlineStyle, .underlineColor] {
            layout.removeTemporaryAttribute(key, forCharacterRange: all)
        }

        // Skip highlights computed for a different (stale) version of the text.
        if highlights.text == string {
            for word in highlights.words where NSMaxRange(word.range) <= length && word.range.length > 0 {
                layout.addTemporaryAttribute(.backgroundColor, value: DiffPalette.wordTint(word.style, appearance: effectiveAppearance), forCharacterRange: word.range)
            }
        }

        // Comments: an amber wash with a thick underline (suggestions paint over them).
        for mark in commentMarks where NSMaxRange(mark.range) <= length && mark.range.length > 0 {
            layout.addTemporaryAttributes([
                .backgroundColor: DiffPalette.commentTint(resolved: mark.isResolved, appearance: effectiveAppearance),
                .underlineStyle: mark.isResolved
                    ? NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
                    : NSUnderlineStyle.thick.rawValue,
                .underlineColor: DiffPalette.commentUnderline(resolved: mark.isResolved),
            ], forCharacterRange: mark.range)
        }

        // Pending AI suggestions: a tint and an underline (dotted while the model writes).
        for mark in suggestionMarks where NSMaxRange(mark.range) <= length && mark.range.length > 0 {
            let underline: Int
            switch mark.style {
            case .pending: underline = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
            case .accepted, .history: underline = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDash.rawValue
            default: underline = NSUnderlineStyle.single.rawValue
            }
            layout.addTemporaryAttributes([
                .backgroundColor: DiffPalette.suggestionTint(mark.style, appearance: effectiveAppearance),
                .underlineStyle: underline,
                .underlineColor: DiffPalette.suggestionUnderline(mark.style),
            ], forCharacterRange: mark.range)
        }

        if isSearchPresented {
            let isDark = (effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            let matchColor = NSColor.systemYellow.withAlphaComponent(isDark ? 0.35 : 0.40)
            let activeColor = NSColor.systemOrange
            for match in searchMatches where NSMaxRange(match.range) <= length && match.range.length > 0 {
                let isCurrent = (match.id == currentMatchID)
                if isCurrent {
                    layout.addTemporaryAttribute(.backgroundColor, value: activeColor, forCharacterRange: match.range)
                    layout.addTemporaryAttribute(.foregroundColor, value: NSColor.white, forCharacterRange: match.range)
                } else {
                    layout.addTemporaryAttribute(.backgroundColor, value: matchColor, forCharacterRange: match.range)
                }
            }
        }
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply(
            highlights: highlights,
            suggestionMarks: suggestionMarks,
            searchMatches: searchMatches,
            currentMatchID: currentMatchID,
            isSearchPresented: isSearchPresented
        )
    }

    /// Full-width tints behind changed lines.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        defer {
            drawLinkMarks(in: rect)
            drawSourceMarks(in: rect)
        }
        guard highlights.text == string, let layout = layoutManager, let container = textContainer else { return }
        let length = (string as NSString).length
        let origin = textContainerOrigin
        let visibleGlyphs = layout.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let visibleChars = layout.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        for mark in highlights.lines {
            let range = mark.range
            guard NSMaxRange(range) <= length else { continue }
            guard range.location <= NSMaxRange(visibleChars) + 1, NSMaxRange(range) + 1 >= visibleChars.location else { continue }
            var lineRect: NSRect
            if range.location >= length {
                lineRect = layout.extraLineFragmentRect
            } else {
                let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: range.location, length: max(1, range.length)), actualCharacterRange: nil)
                lineRect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                let first = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                let last = layout.lineFragmentRect(forGlyphAt: max(glyphs.location, NSMaxRange(glyphs) - 1), effectiveRange: nil)
                lineRect = first.union(last)
            }
            guard lineRect.height > 0 else { continue }
            let fill = NSRect(x: 0, y: lineRect.minY + origin.y, width: bounds.width, height: lineRect.height)
            guard fill.intersects(rect) else { continue }
            DiffPalette.lineTint(mark.style, appearance: effectiveAppearance).setFill()
            fill.fill()
        }
    }

    /// Linked passages: a blue wash (stronger while its other end is pointed
    /// at), outlined; the half of a link being made gets a dashed outline.
    private func drawLinkMarks(in rect: NSRect) {
        guard !linkMarks.isEmpty, let layout = layoutManager, let container = textContainer else { return }
        let length = (string as NSString).length
        let origin = textContainerOrigin
        for mark in linkMarks where mark.range.length > 0 && NSMaxRange(mark.range) <= length {
            let glyphs = layout.glyphRange(forCharacterRange: mark.range, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { r, _ in
                let box = r.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -1, dy: 0)
                guard box.intersects(rect) else { return }
                let path = NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2)
                DiffPalette.linkTint(highlighted: mark.isHighlighted, appearance: self.effectiveAppearance).setFill()
                path.fill()
                if mark.isHighlighted || mark.isPending {
                    DiffPalette.linkNS.withAlphaComponent(0.7).setStroke()
                    path.lineWidth = 1
                    if mark.isPending { path.setLineDash([3, 2], count: 2, phase: 0) }
                    path.stroke()
                }
            }
        }
    }

    /// AI source highlights: a tint behind the text and a bar in the margin.
    private func drawSourceMarks(in rect: NSRect) {
        guard !sourceMarks.isEmpty, let layout = layoutManager, let container = textContainer else { return }
        let length = (string as NSString).length
        let origin = textContainerOrigin
        let tint = DiffPalette.sourceMarkTint(appearance: effectiveAppearance)
        for range in sourceMarks where range.length > 0 && NSMaxRange(range) <= length {
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var top = CGFloat.greatestFiniteMagnitude, bottom = -CGFloat.greatestFiniteMagnitude
            layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { r, _ in
                let box = r.offsetBy(dx: origin.x, dy: origin.y)
                top = min(top, box.minY)
                bottom = max(bottom, box.maxY)
                guard box.intersects(rect) else { return }
                tint.setFill()
                NSBezierPath(roundedRect: box.insetBy(dx: -1, dy: 0), xRadius: 2, yRadius: 2).fill()
            }
            let bar = NSRect(x: max(0, origin.x - 5), y: top, width: 3, height: bottom - top)
            guard bar.height > 0, bar.intersects(rect) else { continue }
            DiffPalette.sourceMarkNS.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty, !placeholder.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: DiffTextView.font, .foregroundColor: NSColor.placeholderTextColor]
            (placeholder as NSString).draw(at: NSPoint(x: textContainerOrigin.x + 5, y: textContainerOrigin.y), withAttributes: attrs)
        }
    }

    /// Scrolls to and flashes the given 1-based lines.
    func reveal(lines: ClosedRange<Int>) {
        let ns = string as NSString
        var lineStart = 0, line = 1
        while line < lines.lowerBound, lineStart < ns.length {
            let r = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            lineStart = NSMaxRange(r)
            line += 1
        }
        var end = lineStart
        var l = line
        while l <= lines.upperBound, end < ns.length {
            end = NSMaxRange(ns.lineRange(for: NSRange(location: end, length: 0)))
            l += 1
        }
        var range = NSRange(location: min(lineStart, ns.length), length: max(0, end - lineStart))
        if range.length > 0, ns.character(at: NSMaxRange(range) - 1) == 10 { range.length -= 1 }
        scrollRangeToVisible(range)
        if range.length > 0 { showFindIndicator(for: range) }
    }

    // Undo/redo and search shortcuts work even when SwiftUI's menu doesn't route them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command || flags == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "z", window?.firstResponder === self {
            if event.modifierFlags.contains(.shift) { undoManager?.redo() } else { undoManager?.undo() }
            return true
        }
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "f" {
            onFind?()
            return true
        }
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "g" {
            onFindNext?()
            return true
        }
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "g" {
            onFindPrevious?()
            return true
        }
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "e" {
            onUseSelection?()
            return true
        }
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "m",
           onAddComment != nil, window?.firstResponder === self, !string.isEmpty {
            addCommentAtCaret()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Context menu

    /// Adds the AI items to the top of the standard text menu: an inline
    /// suggestion ("Humanize Selection") and the AI sheet ("Rewrite Selection
    /// with AI…"), for the paragraph under the pointer when nothing is selected.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        addCommentItems(to: menu, for: event)
        guard onRewriteSelection != nil || onSuggestRewrite != nil || onSourceMarkAction != nil || onLinkAction != nil, !string.isEmpty else { return menu }
        let hasSelection = selectedRange().length > 0
        // Remember where the click landed; the paragraph there is the target.
        let clickIndex = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        let noun = hasSelection ? "Selection" : "Paragraph"
        var items: [NSMenuItem] = []
        if onSuggestRewrite != nil {
            let item = NSMenuItem(title: "\(quickRewriteTitle) \(noun)", action: #selector(suggestRewrite(_:)), keyEquivalent: hasSelection ? "e" : "")
            item.keyEquivalentModifierMask = [.command, .option]
            item.target = self
            item.representedObject = hasSelection ? nil : clickIndex
            item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
            item.toolTip = "Suggest a rewrite you can accept or reject, using your current AI settings"
            items.append(item)
        }
        if onSuggestRewriteWithOptions != nil {
            let item = NSMenuItem(title: "\(quickRewriteTitle) \(noun) with Options…", action: #selector(suggestRewriteWithOptions(_:)), keyEquivalent: hasSelection ? "e" : "")
            item.keyEquivalentModifierMask = [.command, .option, .shift]
            item.target = self
            item.representedObject = hasSelection ? nil : clickIndex
            item.toolTip = "Choose the prompt, strength, model and more before anything is sent"
            items.append(item)
        }
        if onRewriteSelection != nil {
            let item = NSMenuItem(title: "Rewrite \(noun) with AI…", action: #selector(rewriteWithAI(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = hasSelection ? nil : clickIndex
            if onSuggestRewrite == nil { item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil) }
            items.append(item)
        }
        items += historyItems(at: clickIndex)
        items += linkItems(clickIndex: clickIndex, hasSelection: hasSelection)
        items += sourceMarkItems(clickIndex: clickIndex, hasSelection: hasSelection)
        for (i, item) in items.enumerated() { menu.insertItem(item, at: i) }
        menu.insertItem(.separator(), at: items.count)
        return menu
    }

    /// "Show Rewrite History…" on a passage an AI rewrite was accepted into.
    private func historyItems(at index: Int) -> [NSMenuItem] {
        guard let mark = suggestionMarks.filter({ $0.style.isHistory && (NSLocationInRange(index, $0.range) || NSMaxRange($0.range) == index) })
            .min(by: { $0.range.length < $1.range.length }) else { return [] }
        let item = NSMenuItem(title: "Show AI Rewrite History…", action: #selector(showRewriteHistory(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = mark.id
        item.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        item.toolTip = "See what this passage said before the AI rewrite, and put it back if you like"
        return [item]
    }

    @objc func showRewriteHistory(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? UUID else { return }
        onSuggestionClick?(id)
    }

    /// Making a link from the selection, and following or removing the links
    /// under the pointer.
    private func linkItems(clickIndex: Int, hasSelection: Bool) -> [NSMenuItem] {
        guard onLinkAction != nil else { return [] }
        var items: [NSMenuItem] = []
        let other = otherSideTitle.isEmpty ? "Other Side" : otherSideTitle
        if hasSelection {
            let title = isLinkPendingOnOtherSide ? "Link to the Text Picked in \(other)" : "Link Selection to Text in \(other)…"
            let item = NSMenuItem(title: title, action: #selector(linkSelection(_:)), keyEquivalent: "l")
            item.keyEquivalentModifierMask = [.command, .option]
            item.target = self
            item.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
            item.toolTip = isLinkPendingOnOtherSide
                ? "Pair this text with the text you picked in \(other)"
                : "Pick this text, then select the text that says the same in \(other) and link them"
            items.append(item)
        }
        let index = hasSelection ? selectedRange().location : clickIndex
        if let mark = linkMarks.filter({ !$0.isPending && NSLocationInRange(index, $0.range) }).min(by: { $0.range.length < $1.range.length }) {
            let reveal = NSMenuItem(title: "Go to Linked Text in \(other)", action: #selector(revealLink(_:)), keyEquivalent: "")
            reveal.target = self
            reveal.representedObject = mark.id
            if items.isEmpty { reveal.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil) }
            items.append(reveal)
            let remove = NSMenuItem(title: "Remove Link", action: #selector(removeLink(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = mark.id
            items.append(remove)
        }
        if linkMarks.contains(where: \.isPending) {
            let cancel = NSMenuItem(title: "Cancel Linking", action: #selector(cancelLink(_:)), keyEquivalent: "")
            cancel.target = self
            items.append(cancel)
        }
        return items
    }

    @objc func linkSelection(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0 else { return }
        onLinkAction?(.linkSelection(range))
    }

    @objc func revealLink(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? UUID else { return }
        onLinkAction?(.reveal(id))
    }

    @objc func removeLink(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? UUID else { return }
        onLinkAction?(.remove(id))
    }

    @objc func cancelLink(_ sender: Any?) {
        onLinkAction?(.cancelPending)
    }

    /// "Use Selection as AI Source", and removing highlights.
    private func sourceMarkItems(clickIndex: Int, hasSelection: Bool) -> [NSMenuItem] {
        guard onSourceMarkAction != nil else { return [] }
        var items: [NSMenuItem] = []
        let selected = selectedRange()
        let covered = hasSelection && sourceMarks.contains { NSIntersectionRange($0, selected) == selected }
        if hasSelection, !covered {
            let item = NSMenuItem(title: "Use Selection as AI Source", action: #selector(markSourceSelection(_:)), keyEquivalent: "u")
            item.keyEquivalentModifierMask = [.command, .option]
            item.target = self
            item.image = NSImage(systemSymbolName: "highlighter", accessibilityDescription: nil)
            item.toolTip = "Highlight this text so AI rewrites of a passage in the other editor take exactly this as their counterpart"
            items.append(item)
        }
        let index = covered ? selected.location : clickIndex
        if sourceMarks.contains(where: { NSLocationInRange(index, $0) || NSMaxRange($0) == index }) {
            let item = NSMenuItem(title: "Remove AI Source Highlight", action: #selector(unmarkSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = index
            if items.isEmpty { item.image = NSImage(systemSymbolName: "highlighter", accessibilityDescription: nil) }
            items.append(item)
        }
        if totalSourceMarks > 1 || (totalSourceMarks == 1 && items.isEmpty) {
            let item = NSMenuItem(title: "Clear All AI Source Highlights", action: #selector(clearSourceMarks(_:)), keyEquivalent: "")
            item.target = self
            items.append(item)
        }
        return items
    }

    @objc func markSourceSelection(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0 else { return }
        onSourceMarkAction?(.add(range))
    }

    @objc func unmarkSource(_ sender: Any?) {
        guard let index = (sender as? NSMenuItem)?.representedObject as? Int else { return }
        onSourceMarkAction?(.remove(at: index))
    }

    @objc func clearSourceMarks(_ sender: Any?) {
        onSourceMarkAction?(.clearAll)
    }

    /// The selection, or (for a menu item that carries a click position) the
    /// paragraph there, without its line break. Selects a paragraph target.
    private func target(for sender: Any?) -> (String, NSRange)? {
        let ns = string as NSString
        if let index = (sender as? NSMenuItem)?.representedObject as? Int {
            var range = ns.paragraphRange(for: NSRange(location: min(index, max(0, ns.length - 1)), length: 0))
            // Leave the line break out so the paragraph structure isn't touched.
            while range.length > 0, let scalar = Unicode.Scalar(ns.character(at: NSMaxRange(range) - 1)), CharacterSet.newlines.contains(scalar) {
                range.length -= 1
            }
            guard range.length > 0 else { return nil }
            setSelectedRange(range)
            return (ns.substring(with: range), range)
        }
        let range = selectedRange()
        guard range.length > 0 else { return nil }
        return (ns.substring(with: range), range)
    }

    @objc func suggestRewrite(_ sender: Any?) {
        guard let (text, range) = target(for: sender) else { return }
        onSuggestRewrite?(text, range)
    }

    @objc func suggestRewriteWithOptions(_ sender: Any?) {
        guard let (text, range) = target(for: sender) else { return }
        onSuggestRewriteWithOptions?(text, range)
    }

    @objc func rewriteWithAI(_ sender: Any?) {
        guard let (text, range) = target(for: sender) else { return }
        onRewriteSelection?(text, range)
    }

    // Dropping a file loads its contents instead of inserting its path.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let onFileDrop,
           let url = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first {
            onFileDrop(url)
            return true
        }
        return super.performDragOperation(sender)
    }
}

// MARK: - Line numbers

final class LineNumberRuler: NSRulerView {
    private weak var diffTextView: DiffTextView?
    private var lineStarts: [Int] = [0]
    var marks = EditorHighlights() {
        didSet {
            markByLine = Dictionary(marks.lines.map { ($0.line, $0.style) }, uniquingKeysWith: { a, _ in a })
            needsDisplay = true
        }
    }
    private var markByLine: [Int: EditorHighlights.Style] = [:]
    /// Comments get a bubble beside the first line of their passage; clicking it opens them.
    var commentMarks: [CommentMark] = [] { didSet { if commentMarks != oldValue { needsDisplay = true } } }
    var onCommentClick: ((UUID) -> Void)?
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    init(textView: DiffTextView) {
        self.diffTextView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        textDidChange()
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: nil)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func boundsChanged(_ note: Notification) {
        if let view = note.object as? NSClipView, view === scrollView?.contentView { needsDisplay = true }
    }

    func textDidChange() {
        guard let tv = diffTextView else { return }
        var starts = [0]
        var offset = 0
        for unit in tv.string.utf16 {
            offset += 1
            if unit == 10 { starts.append(offset) }
        }
        lineStarts = starts
        let digits = max(2, String(starts.count).count)
        let thickness = CGFloat(digits) * 7.5 + 22
        if abs(ruleThickness - thickness) > 0.5 { ruleThickness = thickness }
        needsDisplay = true
    }

    private func lineIndex(for charIndex: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= charIndex { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = diffTextView, let layout = tv.layoutManager, let container = tv.textContainer else { return }
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

        let visible = tv.visibleRect
        let origin = tv.textContainerOrigin
        let relativeY = convert(NSPoint.zero, from: tv).y
        let glyphs = layout.glyphRange(forBoundingRect: visible.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let ns = tv.string as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        let markedAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let commentedLines = Dictionary(commentMarks.map { (lineIndex(for: $0.range.location) + 1, $0.isResolved) }, uniquingKeysWith: { a, b in a && b })

        func draw(line: Int, fragment: NSRect) {
            let y = fragment.minY + origin.y + relativeY
            let mark = markByLine[line]
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: bounds.width - size.width - 10, y: y + (fragment.height - size.height) / 2), withAttributes: mark == nil ? attrs : markedAttrs)
            if let mark {
                DiffPalette.gutterMark(mark).setFill()
                NSBezierPath(roundedRect: NSRect(x: bounds.width - 5, y: y + 1, width: 3, height: max(2, fragment.height - 2)), xRadius: 1.5, yRadius: 1.5).fill()
            }
            if let resolved = commentedLines[line] { drawCommentBubble(resolved: resolved, lineY: y, lineHeight: fragment.height) }
        }

        var line = lineIndex(for: chars.location)
        var location = lineStarts[line]
        while line < lineStarts.count, location <= NSMaxRange(chars), location < ns.length {
            let glyph = layout.glyphIndexForCharacter(at: location)
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            draw(line: line + 1, fragment: fragment)
            line += 1
            guard line < lineStarts.count else { break }
            location = lineStarts[line]
        }
        // Trailing empty line (text ends with a newline, or is empty).
        if location >= ns.length, line < lineStarts.count {
            let extra = layout.extraLineFragmentRect
            if extra.height > 0 { draw(line: line + 1, fragment: extra) }
        }
    }
}

// MARK: - Comments in the editor

extension DiffTextView {
    /// The comment whose passage is under `point` (the shortest one where
    /// comments overlap).
    func commentID(at point: NSPoint) -> UUID? {
        guard !commentMarks.isEmpty, let index = characterIndex(onTextAt: point) else { return nil }
        return commentMarks.filter { NSLocationInRange(index, $0.range) }.min { $0.range.length < $1.range.length }?.id
    }

    fileprivate func setHoveredComment(_ id: UUID?) {
        guard id != hoveredComment else { return }
        hoveredComment = id
        onCommentHover?(id)
    }

    /// "Add Comment…" (and "Show Comment" on a commented passage) above the
    /// standard text items; the AI items are inserted above these.
    fileprivate func addCommentItems(to menu: NSMenu, for event: NSEvent) {
        guard onAddComment != nil, !string.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        let hasSelection = selectedRange().length > 0
        var items: [NSMenuItem] = []
        if let id = commentID(at: point), onCommentClick != nil {
            let show = NSMenuItem(title: "Show Comment", action: #selector(showComment(_:)), keyEquivalent: "")
            show.target = self
            show.representedObject = id
            show.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)
            items.append(show)
        }
        let add = NSMenuItem(title: hasSelection ? "Add Comment…" : "Add Comment to Paragraph…", action: #selector(addComment(_:)), keyEquivalent: "m")
        add.keyEquivalentModifierMask = [.command, .shift]
        add.target = self
        add.representedObject = hasSelection ? nil : characterIndexForInsertion(at: point)
        if items.isEmpty { add.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil) }
        items.append(add)
        for (i, item) in items.enumerated() { menu.insertItem(item, at: i) }
        menu.insertItem(.separator(), at: items.count)
    }

    /// ⇧⌘M: comments the selection, or the paragraph at the caret.
    fileprivate func addCommentAtCaret() {
        let item = NSMenuItem()
        item.representedObject = selectedRange().length > 0 ? nil : selectedRange().location
        addComment(item)
    }

    @objc func addComment(_ sender: Any?) {
        guard let (text, range) = target(for: sender) else { return }
        onAddComment?(text, range)
    }

    @objc func showComment(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? UUID else { return }
        onCommentClick?(id)
    }
}

extension LineNumberRuler {
    /// A small speech bubble at the left edge of the gutter.
    fileprivate func drawCommentBubble(resolved: Bool, lineY: CGFloat, lineHeight: CGFloat) {
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            .applying(.init(paletteColors: [resolved ? .tertiaryLabelColor : DiffPalette.commentNS]))
        guard let image = NSImage(systemSymbolName: resolved ? "text.bubble" : "text.bubble.fill", accessibilityDescription: "Comment")?
            .withSymbolConfiguration(config) else { return }
        let size = image.size
        image.draw(in: NSRect(x: 3, y: lineY + (lineHeight - size.height) / 2, width: size.width, height: size.height))
    }

    override func mouseDown(with event: NSEvent) {
        guard let id = commentID(at: convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            return
        }
        onCommentClick?(id)
    }

    /// The comment starting on the line at `point` (ruler coordinates).
    func commentID(at point: NSPoint) -> UUID? {
        guard !commentMarks.isEmpty, let tv = clientView as? DiffTextView,
              let layout = tv.layoutManager, let container = tv.textContainer, layout.numberOfGlyphs > 0 else { return nil }
        let p = tv.convert(point, from: self)
        let y = p.y - tv.textContainerOrigin.y
        let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: y), in: container)
        let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard y >= fragment.minY, y <= fragment.maxY else { return nil }
        let line = lineIndex(for: layout.characterIndexForGlyph(at: glyph))
        return commentMarks.first { lineIndex(for: $0.range.location) == line }?.id
    }
}
