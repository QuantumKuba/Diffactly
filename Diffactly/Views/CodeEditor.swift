import SwiftUI
import AppKit

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
    /// Context menu → "Rewrite … with AI": the passage and its range.
    var onRewriteSelection: ((String, NSRange) -> Void)? = nil
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
        applyWrapping(textView, scrollView)
        textView.apply(
            highlights: highlights,
            searchMatches: searchMatches,
            currentMatchID: currentMatch?.id,
            isSearchPresented: isSearchPresented
        )
        ruler.marks = highlights
        return scrollView
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
        if context.coordinator.wrapLines != wrapLines {
            context.coordinator.wrapLines = wrapLines
            applyWrapping(textView, scrollView)
        }

        let searchChanged = textView.searchMatches != searchMatches
            || textView.currentMatchID != currentMatch?.id
            || textView.isSearchPresented != isSearchPresented

        if textView.highlights != highlights || searchChanged {
            textView.apply(
                highlights: highlights,
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
    }

    /// The smallest ranges (old and new, UTF-16) that turn `old` into `new`:
    /// everything outside them is a shared prefix or suffix. Never splits a
    /// composed character such as an emoji or an accented letter.
    static func changedRanges(old: String, new: String) -> (old: NSRange, new: NSRange) {
        let a = Array(old.utf16), b = Array(new.utf16)
        var prefix = 0
        let limit = min(a.count, b.count)
        while prefix < limit, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let oldNS = old as NSString, newNS = new as NSString
        // Back the prefix up to the start of the character it ends inside.
        for ns in [oldNS, newNS] where prefix > 0 && prefix < ns.length {
            prefix = min(prefix, ns.rangeOfComposedCharacterSequence(at: prefix).location)
        }
        // Shrink the suffix so it starts at a character boundary in both strings.
        for ns in [oldNS, newNS] where suffix > 0 {
            let boundary = ns.length - suffix
            guard boundary > prefix, boundary < ns.length else { continue }
            let r = ns.rangeOfComposedCharacterSequence(at: boundary)
            if r.location < boundary { suffix = ns.length - NSMaxRange(r) }
        }
        suffix = min(suffix, a.count - prefix, b.count - prefix)
        return (NSRange(location: prefix, length: a.count - prefix - suffix),
                NSRange(location: prefix, length: b.count - prefix - suffix))
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

    final class Coordinator: NSObject, NSTextViewDelegate {
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
        super.mouseDown(with: event)
    }

    func apply(
        highlights: EditorHighlights,
        searchMatches: [SearchMatch] = [],
        currentMatchID: UUID? = nil,
        isSearchPresented: Bool = false
    ) {
        self.highlights = highlights
        self.searchMatches = searchMatches
        self.currentMatchID = currentMatchID
        self.isSearchPresented = isSearchPresented

        guard let layout = layoutManager else { return }
        let length = (string as NSString).length
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: length))

        // Skip highlights computed for a different (stale) version of the text.
        if highlights.text == string {
            for word in highlights.words where NSMaxRange(word.range) <= length && word.range.length > 0 {
                layout.addTemporaryAttribute(.backgroundColor, value: DiffPalette.wordTint(word.style, appearance: effectiveAppearance), forCharacterRange: word.range)
            }
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
            searchMatches: searchMatches,
            currentMatchID: currentMatchID,
            isSearchPresented: isSearchPresented
        )
    }

    /// Full-width tints behind changed lines.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
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
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Context menu

    /// Adds "Rewrite Selection with AI…" (or "Rewrite Paragraph…" when nothing
    /// is selected) to the top of the standard text menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard onRewriteSelection != nil, !string.isEmpty else { return menu }
        let hasSelection = selectedRange().length > 0
        let item = NSMenuItem(
            title: hasSelection ? "Rewrite Selection with AI…" : "Rewrite Paragraph with AI…",
            action: hasSelection ? #selector(rewriteSelectionWithAI(_:)) : #selector(rewriteParagraphWithAI(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        if !hasSelection {
            // Remember where the click landed; the paragraph there is the target.
            let point = convert(event.locationInWindow, from: nil)
            item.representedObject = characterIndexForInsertion(at: point)
        }
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc func rewriteSelectionWithAI(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0 else { return }
        onRewriteSelection?((string as NSString).substring(with: range), range)
    }

    @objc func rewriteParagraphWithAI(_ sender: Any?) {
        let ns = string as NSString
        let index = min((sender as? NSMenuItem)?.representedObject as? Int ?? selectedRange().location, max(0, ns.length - 1))
        var range = ns.paragraphRange(for: NSRange(location: index, length: 0))
        // Leave the line break out so the paragraph structure isn't touched.
        while range.length > 0, let scalar = Unicode.Scalar(ns.character(at: NSMaxRange(range) - 1)), CharacterSet.newlines.contains(scalar) {
            range.length -= 1
        }
        guard range.length > 0 else { return }
        setSelectedRange(range)
        onRewriteSelection?(ns.substring(with: range), range)
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
