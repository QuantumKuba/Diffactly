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
    var onFileDrop: (URL) -> Void
    /// Receives the selected text (empty when the caret is just a caret).
    var onSelectionChange: (String) -> Void = { _ in }

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
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
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
        textView.apply(highlights)
        ruler.marks = highlights
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        textView.onFileDrop = onFileDrop
        textView.placeholder = placeholder

        if textView.string != text {
            // External change (file opened, swap, transform): replace undoably.
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            if textView.shouldChangeText(in: full, replacementString: text) {
                textView.textStorage?.replaceCharacters(in: full, with: NSAttributedString(string: text, attributes: textView.typingAttributes))
                textView.didChangeText()
            }
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
        if context.coordinator.wrapLines != wrapLines {
            context.coordinator.wrapLines = wrapLines
            applyWrapping(textView, scrollView)
        }
        if textView.highlights != highlights {
            textView.apply(highlights)
            context.coordinator.ruler?.marks = highlights
        }
        if let request = focusRequest, request.id != context.coordinator.lastFocusID {
            context.coordinator.lastFocusID = request.id
            if let lines = focusLines {
                DispatchQueue.main.async { textView.reveal(lines: lines) }
            }
        }
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
            DispatchQueue.main.async { [weak self] in self?.parent.onSelectionChange(selected) }
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
    private(set) var highlights = EditorHighlights()

    func apply(_ newValue: EditorHighlights) {
        highlights = newValue
        guard let layout = layoutManager else { return }
        let length = (string as NSString).length
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
        // Skip highlights computed for a different (stale) version of the text.
        if newValue.text == string {
            for word in newValue.words where NSMaxRange(word.range) <= length && word.range.length > 0 {
                layout.addTemporaryAttribute(.backgroundColor, value: DiffPalette.wordTint(word.style, appearance: effectiveAppearance), forCharacterRange: word.range)
            }
        }
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply(highlights)
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

    // Undo/redo shortcuts work even when SwiftUI's menu doesn't route them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command || event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "z", window?.firstResponder === self {
            if event.modifierFlags.contains(.shift) { undoManager?.redo() } else { undoManager?.undo() }
            return true
        }
        return super.performKeyEquivalent(with: event)
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
