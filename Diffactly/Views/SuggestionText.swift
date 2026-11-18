import SwiftUI
import AppKit
import DiffactlyCore

// MARK: - What the card's text shows

/// The suggestion as the card shows it: the combined text (the version on
/// show with its rewritten parts in place), optionally as changes from the
/// passage, with each rewritten part tinted and numbered. Keeps track of
/// which shown characters are which in the combined text, since struck-out
/// words and part numbers aren't part of it.
struct SuggestionDisplay {
    struct Segment: Equatable {
        var display: NSRange
        /// Where it starts in the combined text; nil for text that isn't in it.
        var composedLocation: Int?
    }

    var string: NSAttributedString
    var segments: [Segment]

    private enum Kind { case equal, added, removed, badge }

    private struct Run {
        var text: String
        var kind: Kind
        var composedLocation: Int?
        var length: Int { (text as NSString).length }
    }

    /// `showsChanges` marks what the combined text changes from the passage;
    /// `focused` is the part to stand out (the row under the pointer).
    @MainActor
    init(_ suggestion: AISuggestion, showsChanges: Bool, focused: UUID?) {
        let parts = suggestion.composedParts
        let partRanges = AISuggestion.composedRanges(parts)
        let composed = parts.map(\.text).joined()
        let refined: [(range: NSRange, id: UUID, number: Int)] = zip(parts, partRanges)
            .compactMap { part, range in part.refinement.map { (range, $0.id) } }
            .enumerated().map { ($1.0, $1.1, $0 + 1) }

        var runs = Self.runs(composed: composed, original: suggestion.original, showsChanges: showsChanges)
        runs = Self.split(runs, at: Set(refined.flatMap { [$0.range.location, NSMaxRange($0.range)] }))
        // A number in front of each rewritten part, matching its row.
        for part in refined.reversed() {
            guard let i = runs.firstIndex(where: { $0.composedLocation == part.range.location && $0.length > 0 }) else { continue }
            runs.insert(Run(text: Self.badge(part.number), kind: .badge, composedLocation: nil), at: i)
        }

        let out = NSMutableAttributedString()
        var segments: [Segment] = []
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        for run in runs where run.length > 0 {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            switch run.kind {
            case .equal: break
            case .added: attributes[.backgroundColor] = DiffPalette.addedNS.withAlphaComponent(0.22)
            case .removed:
                attributes[.foregroundColor] = DiffPalette.removedNS
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attributes[.backgroundColor] = DiffPalette.removedNS.withAlphaComponent(0.12)
            case .badge:
                attributes[.foregroundColor] = DiffPalette.refinedNS
                attributes[.font] = NSFont.systemFont(ofSize: NSFont.systemFontSize - 1, weight: .semibold)
            }
            if let at = run.composedLocation,
               let part = refined.first(where: { NSLocationInRange(at, $0.range) }) {
                let isFocused = part.id == focused
                attributes[.underlineStyle] = (isFocused ? NSUnderlineStyle.thick : .single).rawValue
                attributes[.underlineColor] = DiffPalette.refinedNS
                if !showsChanges || run.kind == .equal || isFocused {
                    attributes[.backgroundColor] = DiffPalette.refinedNS.withAlphaComponent(isFocused ? 0.26 : 0.10)
                }
                attributes[.link] = Self.link(part.id)
            }
            segments.append(Segment(display: NSRange(location: out.length, length: run.length), composedLocation: run.composedLocation))
            out.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        string = out
        self.segments = segments
    }

    /// The pieces to show, each with where it is in the combined text.
    private static func runs(composed: String, original: String, showsChanges: Bool) -> [Run] {
        let plain = [Run(text: composed, kind: .equal, composedLocation: 0)]
        guard showsChanges else { return plain }
        let lead = (String(composed.prefix { $0.isWhitespace }) as NSString).length
        let core = composed.trimmingCharacters(in: .whitespacesAndNewlines)
        let changes = DiffEngine.inlineChanges(original.trimmingCharacters(in: .whitespacesAndNewlines), core)
        // The changes must spell out the combined text exactly, or the
        // selection couldn't be traced back to it.
        guard changes.filter({ $0.kind != .removed }).map(\.text).joined() == core else { return plain }
        var at = lead
        return changes.map { change in
            switch change.kind {
            case .removed:
                return Run(text: change.text, kind: .removed, composedLocation: nil)
            case .equal, .added:
                defer { at += (change.text as NSString).length }
                return Run(text: change.text, kind: change.kind == .equal ? .equal : .added, composedLocation: at)
            }
        }
    }

    /// Splits runs so none crosses one of `points` in the combined text.
    private static func split(_ runs: [Run], at points: Set<Int>) -> [Run] {
        runs.flatMap { run -> [Run] in
            guard let start = run.composedLocation else { return [run] }
            let ns = run.text as NSString
            let cuts = points.filter { $0 > start && $0 < start + ns.length }.sorted()
            guard !cuts.isEmpty else { return [run] }
            var pieces: [Run] = []
            var from = start
            for cut in cuts + [start + ns.length] {
                pieces.append(Run(text: ns.substring(with: NSRange(location: from - start, length: cut - from)),
                                  kind: run.kind, composedLocation: from))
                from = cut
            }
            return pieces
        }
    }

    static func badge(_ number: Int) -> String {
        // ① … ⑳, then plain numbers.
        if (1...20).contains(number), let scalar = Unicode.Scalar(0x2460 + number - 1) { return String(Character(scalar)) + "\u{2009}" }
        return "(\(number))\u{2009}"
    }

    static func link(_ id: UUID) -> URL { URL(string: "diffactly-part:\(id.uuidString)")! }

    static func partID(_ link: Any) -> UUID? {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url, url.scheme == "diffactly-part" else { return nil }
        return UUID(uuidString: String(url.absoluteString.dropFirst("diffactly-part:".count)))
    }

    /// The part of the combined text a selection of the shown text covers
    /// (struck-out words and numbers drop out).
    func composedRange(forDisplay range: NSRange) -> NSRange {
        let inText = segments.filter { $0.composedLocation != nil }
        let start = inText.lazy.compactMap { s -> Int? in
            guard NSMaxRange(s.display) > range.location else { return nil }
            return s.composedLocation! + max(0, range.location - s.display.location)
        }.first
        let end = inText.reversed().lazy.compactMap { s -> Int? in
            guard s.display.location < NSMaxRange(range) else { return nil }
            return s.composedLocation! + min(s.display.length, NSMaxRange(range) - s.display.location)
        }.first
        guard let start, let end, end > start else { return NSRange(location: start ?? 0, length: 0) }
        return NSRange(location: start, length: end - start)
    }

    /// Where `range` of the combined text is shown.
    func displayRange(forComposed range: NSRange) -> NSRange? {
        func locate(_ point: Int, atEnd: Bool) -> Int? {
            segments.lazy.compactMap { s -> Int? in
                guard let c = s.composedLocation else { return nil }
                let inside = atEnd ? (point > c && point <= c + s.display.length) : (point >= c && point < c + s.display.length)
                return inside ? s.display.location + point - c : nil
            }.first
        }
        guard let start = locate(range.location, atEnd: false), let end = locate(NSMaxRange(range), atEnd: true), end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }
}

// MARK: - The text view

/// A request to select part of the combined text (from the editor).
struct TextSelectionRequest: Equatable {
    let id = UUID()
    var range: NSRange
}

/// The card's text: read-only, selectable (the selection is reported in the
/// combined text, for rewriting part of it), with rewritten parts clickable.
struct SuggestionTextView: NSViewRepresentable {
    let display: SuggestionDisplay
    @Binding var selection: NSRange
    var request: TextSelectionRequest?
    var onPartClicked: (UUID) -> Void = { _ in }
    var maxHeight: CGFloat = 260

    private static let inset = NSSize(width: 6, height: 7)

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = Self.inset
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        textView.delegate = context.coordinator
        textView.setAccessibilityLabel("Suggested text")

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView, let storage = textView.textStorage else { return }
        if !storage.isEqual(to: display.string) {
            let kept = textView.selectedRange()
            context.coordinator.isUpdating = true
            storage.setAttributedString(display.string)
            if NSMaxRange(kept) <= storage.length { textView.setSelectedRange(kept) }
            context.coordinator.isUpdating = false
        }
        if let request, request.id != context.coordinator.appliedRequest {
            context.coordinator.appliedRequest = request.id
            if let range = display.displayRange(forComposed: request.range) {
                DispatchQueue.main.async {
                    textView.window?.makeFirstResponder(textView)
                    textView.setSelectedRange(range)
                    textView.scrollRangeToVisible(range)
                }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let textView = scroll.documentView as? NSTextView, let container = textView.textContainer else { return nil }
        let width = proposal.width ?? 432
        // Lay the text out at that width on the side, to measure it.
        let probe = NSTextContainer(size: NSSize(width: max(width - Self.inset.width * 2, 40), height: .greatestFiniteMagnitude))
        probe.lineFragmentPadding = container.lineFragmentPadding
        let storage = NSTextStorage(attributedString: display.string)
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        manager.addTextContainer(probe)
        manager.ensureLayout(for: probe)
        let height = manager.usedRect(for: probe).height + Self.inset.height * 2
        return CGSize(width: width, height: min(max(height, 40), maxHeight))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SuggestionTextView
        var appliedRequest: UUID?
        var isUpdating = false

        init(_ parent: SuggestionTextView) { self.parent = parent }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView else { return }
            let range = parent.display.composedRange(forDisplay: textView.selectedRange())
            if parent.selection != range { parent.selection = range }
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let id = SuggestionDisplay.partID(link) else { return false }
            parent.onPartClicked(id)
            return true
        }
    }
}

// MARK: - Rewritten parts

/// Under the text: rewriting the selected words on their own, and the parts
/// rewritten so far, each with its own versions. What the text above shows
/// is the combination Accept puts in.
struct SuggestionPartsSection: View {
    @ObservedObject var suggestion: AISuggestion
    let document: DiffDocument
    let session: RewriteSession
    /// The selection in the combined text.
    let selection: NSRange
    @Binding var focusedPart: UUID?
    let onRefine: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            selectionBar
            let parts = suggestion.refinements
            if !parts.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                        RefinedPartRow(part: part, number: index + 1, versionNumber: suggestion.shownVersionNumber,
                                       isFocused: focusedPart == part.id,
                                       onHover: { inside in
                                           if inside { focusedPart = part.id } else if focusedPart == part.id { focusedPart = nil }
                                       },
                                       onRegenerate: {
                                           session.regenerate(part, document: document, store: .shared)
                                           document.suggestionStatusChanged()
                                       },
                                       onRemove: {
                                           suggestion.removeRefinement(part)
                                           if focusedPart == part.id { focusedPart = nil }
                                           document.suggestionStatusChanged()
                                       })
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var selectionBar: some View {
        if suggestion.canRefine {
            if selection.length > 0 {
                if suggestion.versionRange(forComposed: selection) != nil {
                    HStack(spacing: 8) {
                        Text("“\(snippet)”")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Button(action: onRefine) {
                            Label("Rewrite Just This", systemImage: "sparkles")
                        }
                        .controlSize(.small)
                        .help("Rewrite only the selected words, keeping the rest of this version. The part gets versions of its own.")
                    }
                } else {
                    Text("This overlaps a part that’s already rewritten. Pick words outside it, or use that part’s own versions below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if suggestion.refinements.isEmpty {
                Text("Select words above to rewrite just them. Each part keeps versions of its own.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var snippet: String {
        let text = suggestion.composedReplacement as NSString
        guard NSMaxRange(selection) <= text.length else { return "" }
        return text.substring(with: selection).trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
    }
}

/// One rewritten part: its number (as in the text), what it reads now, and
/// its versions, including keeping the paragraph version's own wording.
struct RefinedPartRow: View {
    @ObservedObject var part: AISuggestion
    let number: Int
    /// The number of the paragraph version the part belongs to.
    let versionNumber: Int?
    let isFocused: Bool
    let onHover: (Bool) -> Void
    let onRegenerate: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(SuggestionDisplay.badge(number).trimmingCharacters(in: .whitespaces))
                .font(.callout.weight(.semibold))
                .foregroundStyle(DiffPalette.refined)
            VStack(alignment: .leading, spacing: 1) {
                Text(part.chosenText.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " "))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(part.usesParentWording ? .secondary : .primary)
                if let note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                        .help(note)
                }
            }
            Spacer(minLength: 4)
            if part.status.isRunning, !part.usesParentWording {
                ProgressView().controlSize(.mini)
            }
            VersionSwitcher(current: part.usesParentWording ? nil : part.shownVersionNumber,
                            count: part.versionCount,
                            isWriting: part.attemptStatus?.isRunning == true && part.shownVersionID != nil,
                            noneTitle: keepTitle,
                            select: { number in
                                part.usesParentWording = false
                                part.showVersion(number: number)
                            }) {
                Toggle(keepTitle, isOn: Binding(get: { part.usesParentWording },
                                                set: { if $0 { part.usesParentWording = true } }))
                Divider()
                ForEach(Array(part.versions.enumerated()), id: \.element.id) { index, version in
                    Toggle(VersionTitle.entry(number: index + 1, date: version.date, label: version.label),
                           isOn: Binding(get: { !part.usesParentWording && part.shownVersionID == version.id },
                                         set: { if $0 { part.usesParentWording = false; part.showVersion(version.id) } }))
                }
                if let status = part.attemptStatus {
                    Toggle("V\(part.versions.count + 1) · \(status.isRunning ? "Writing…" : "Failed")",
                           isOn: Binding(get: { !part.usesParentWording && part.shownVersionID == nil },
                                         set: { if $0 { part.usesParentWording = false; part.showVersion(nil) } }))
                }
            }
            Button(action: onRegenerate) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Rewrite this part again (adds a version)")
                .accessibilityLabel("Rewrite part \(number) again")
            Button(action: onRemove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless)
                .help("Drop this part’s rewrites and go back to the version’s own wording")
                .accessibilityLabel("Remove part \(number)")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(isFocused ? DiffPalette.refined.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onHover(perform: onHover)
    }

    private var keepTitle: String {
        versionNumber.map { "Keep V\($0) wording" } ?? "Keep this wording"
    }

    private var isFailed: Bool {
        if case .failed = part.status { return true }
        return false
    }

    private var note: String? {
        if part.usesParentWording { return "Using the paragraph version’s own words" }
        switch part.status {
        case .drafting: return part.isThinking ? "Thinking…" : "Writing…"
        case .auditing: return "Second pass…"
        case .failed(let message): return message
        default: return nil
        }
    }
}
