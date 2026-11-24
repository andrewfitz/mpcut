import AppKit
import CoreText
import MPCutCore
import SwiftUI

/// Immutable input for a layout pass. A playback tick keeps the same instance.
final class TranscriptFlowSource: Sendable {
    let words: [TranscriptOccurrence]
    let speakers: [String: String]
    let tracks: [String: TranscriptTrack]
    let lane: (id: String, label: String)?
    let showsTakes: Bool

    init(words: [TranscriptOccurrence], speakers: [TranscriptSpeaker], tracks: [TranscriptTrack],
         lane: (String, String)?, showsTakes: Bool) {
        self.words = words
        self.speakers = Dictionary(speakers.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        self.tracks = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        self.lane = lane
        self.showsTakes = showsTakes
    }

    func heading(_ word: TranscriptOccurrence) -> String {
        let speaker = word.speakerID.flatMap { speakers[$0] ?? $0 } ?? "Unknown speaker"
        var parts = [timelineTime(word.range.from.seconds, milliseconds: true), speaker]
        if let label = word.laneLabel {
            parts.append(word.laneColorSlot == nil ? label : "● " + label)
            if let lane, lane.id != word.laneID, word.heardOnLaneIDs?.contains(lane.id) == true {
                parts.append(lane.label)
            }
        } else if tracks.count > 1, let id = word.trackID, let track = tracks[id] {
            if track.name != speaker { parts.append(track.name) }
            if let stream = track.streamIndex { parts.append("Stream \(stream)") }
        }
        if showsTakes, let take = word.assemblyIndex { parts.append("Take \(take + 1)") }
        if word.staleMatches { parts.append("Alignment out of date") }
        return parts.joined(separator: " · ") + "   "
    }
}

/// Character ranges are UTF-16, the clock used by Core Text. Only the reusable visible
/// rows keep shaped CTLines. Wrapping the whole document happens off the UI thread.
final class TranscriptFlowLayout: @unchecked Sendable {
    struct Line {
        let paragraph: Int
        let characters: NSRange
    }
    let source: TranscriptFlowSource
    let width: CGFloat
    fileprivate static let headingKey = NSAttributedString.Key("MPCutTranscriptHeading")
    fileprivate static let laneSlotKey = NSAttributedString.Key("MPCutTranscriptLaneSlot")
    let paragraphs: [NSAttributedString]
    let paragraphStarts: [Int]
    let ranges: [NSRange]
    let lines: [Line]

    init(source: TranscriptFlowSource, width: CGFloat) throws {
        self.source = source
        self.width = width
        let foreground = NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), foreground: true]
        let heading: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), Self.headingKey: true]
        var paragraphs: [NSAttributedString] = [], starts: [Int] = [], lines: [Line] = [], ranges: [NSRange] = []
        var text = "", headerLength = 0, base = 0, length = 0
        var laneSlot: Int?
        func wrap() throws {
            guard length > 0 else { return }
            let attributed = NSMutableAttributedString(string: text, attributes: body)
            attributed.addAttributes(heading, range: NSRange(location: 0, length: headerLength))
            if let laneSlot, let marker = text.utf16.firstIndex(of: 0x25CF) {
                let position = text.utf16.distance(from: text.utf16.startIndex, to: marker)
                attributed.addAttribute(Self.laneSlotKey, value: laneSlot, range: NSRange(location: position, length: 1))
            }
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            var offset = 0
            while offset < length {
                try Task.checkCancellation()
                let suggested = CTTypesetterSuggestLineBreak(typesetter, offset, Double(width))
                let count = suggested > 0 ? suggested : (text as NSString).rangeOfComposedCharacterSequence(at: offset).length
                lines.append(Line(paragraph: paragraphs.count, characters: NSRange(location: base + offset, length: count)))
                offset += count
            }
            paragraphs.append(attributed)
            starts.append(base)
            base += length
            text = ""
            length = 0
        }
        for (i, word) in source.words.enumerated() {
            if i.isMultiple(of: 128) { try Task.checkCancellation() }
            let previous = i > 0 ? source.words[i - 1] : nil
            let newTurn = previous.map {
                $0.speakerID != word.speakerID || $0.trackID != word.trackID || $0.laneID != word.laneID
                    || $0.clipID != word.clipID || $0.assemblyIndex != word.assemblyIndex
                    || $0.staleMatches != word.staleMatches || word.range.from.seconds - $0.range.to.seconds >= 2
            } ?? true
            if newTurn {
                try wrap()
                laneSlot = word.laneColorSlot
                text = source.heading(word)
                length = text.utf16.count
                headerLength = length
            } else {
                text.append(" ")
                length += 1
            }
            var token = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if word.partial { token += "✂" }
            if word.audibility == .inferred { token += "◌" }
            let count = token.utf16.count
            ranges.append(NSRange(location: base + length, length: count))
            text.append(token)
            length += count
        }
        try wrap()
        self.paragraphs = paragraphs
        paragraphStarts = starts
        self.lines = lines
        self.ranges = ranges
    }

    private func first(_ count: Int, where matches: (Int) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = low + (high - low) / 2
            if matches(mid) { high = mid } else { low = mid + 1 }
        }
        return low
    }

    func row(for word: Int) -> Int? {
        guard ranges.indices.contains(word) else { return nil }
        let i = first(lines.count) { NSMaxRange(lines[$0].characters) > ranges[word].location }
        return lines.indices.contains(i) ? i : nil
    }

    func words(in row: Int) -> Range<Int> {
        let span = lines[row].characters
        let start = first(ranges.count) { NSMaxRange(ranges[$0]) > span.location }
        var end = start
        while end < ranges.count, ranges[end].location < NSMaxRange(span) { end += 1 }
        return start..<end
    }

    func firstWord(atRow row: Int) -> Int? {
        guard lines.indices.contains(row), !ranges.isEmpty else { return nil }
        return min(words(in: row).lowerBound, ranges.count - 1)
    }

    func text(in row: Int) -> NSAttributedString {
        let line = lines[row]
        return paragraphs[line.paragraph].attributedSubstring(from: NSRange(
            location: line.characters.location - paragraphStarts[line.paragraph], length: line.characters.length))
    }
}

struct TranscriptFlowSelection: Equatable {
    let positions: ClosedRange<Int>
    let track: String?
}

struct TranscriptFlowScroll: Equatable {
    let word: Int
    var atTop = false
    let id = UUID()
}

@MainActor
final class TranscriptFlowViewport {
    weak var view: TranscriptFlowScrollView?
    var lastTopWord: Int?
}

struct TranscriptFlowReader: NSViewRepresentable {
    let source: TranscriptFlowSource
    let viewport: TranscriptFlowViewport
    let active: [Int]
    let selection: TranscriptFlowSelection?
    let scroll: TranscriptFlowScroll?
    let choose: (TranscriptOccurrence, Bool, Bool) -> Void
    let inspect: () -> Void
    let describe: (TranscriptOccurrence) -> String

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TranscriptFlowScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 380, height: 360))
    }

    func makeNSView(context: Context) -> TranscriptFlowScrollView {
        let view = TranscriptFlowScrollView()
        viewport.view = view
        view.viewport = viewport
        return view
    }

    func updateNSView(_ view: TranscriptFlowScrollView, context: Context) {
        view.choose = choose
        view.inspect = inspect
        view.describe = describe
        view.update(source: source, active: active, selection: selection, scroll: scroll)
    }

    static func dismantleNSView(_ view: TranscriptFlowScrollView, coordinator: ()) {
        view.rememberTopWord()
        view.cancel()
    }
}

@MainActor
final class TranscriptFlowScrollView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var layoutResult: TranscriptFlowLayout?
    private(set) var active: [Int] = []
    private(set) var selection: TranscriptFlowSelection?
    private let table = NSTableView()
    private var source: TranscriptFlowSource?
    private var requestedWidth: CGFloat = 0
    private var worker: Task<Void, Never>?
    private var request: TranscriptFlowScroll?
    private var appliedRequest: UUID?
    weak var viewport: TranscriptFlowViewport?
    var choose: ((TranscriptOccurrence, Bool, Bool) -> Void)?
    var inspect: (() -> Void)?
    var describe: ((TranscriptOccurrence) -> String)?
    private static let inset: CGFloat = 12

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = false
        table.wantsLayer = true
        table.style = .plain
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.rowHeight = 23
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.usesAutomaticRowHeights = false
        let column = NSTableColumn(identifier: .init("text"))
        column.resizingMask = .autoresizingMask
        column.minWidth = 1
        table.addTableColumn(column)
        table.delegate = self
        table.dataSource = self
        documentView = table
        setAccessibilityIdentifier("transcript.dialogue")
        table.setAccessibilityLabel("Transcript")
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(rememberTopWord), name: NSView.boundsDidChangeNotification, object: contentView)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        scheduleLayout()
    }

    func cancel() { worker?.cancel() }

    func update(source: TranscriptFlowSource, active: [Int], selection: TranscriptFlowSelection?, scroll: TranscriptFlowScroll?) {
        let changed = self.source !== source
        self.source = source
        self.request = scroll
        let oldActive = self.active
        let selectionChanged = self.selection != selection
        self.active = active
        self.selection = selection
        if changed { requestedWidth = 0 }
        scheduleLayout()
        if !changed, layoutResult?.source === source {
            if selectionChanged {
                table.enumerateAvailableRowViews { row, _ in
                    (row.view(atColumn: 0) as? NSView)?.needsDisplay = true
                }
            } else if oldActive != active, let layoutResult {
                let changedWords = Set(oldActive).symmetricDifference(active)
                for word in changedWords {
                    guard let first = layoutResult.row(for: word) else { continue }
                    var row = first
                    while row < layoutResult.lines.count,
                          layoutResult.lines[row].characters.location < NSMaxRange(layoutResult.ranges[word]) {
                        table.view(atColumn: 0, row: row, makeIfNecessary: false)?.needsDisplay = true
                        row += 1
                    }
                }
            }
            applyScroll()
        }
    }

    private func scheduleLayout() {
        guard let source, contentSize.width > 2 * Self.inset else { return }
        let width = floor(contentSize.width - 2 * Self.inset)
        guard width != requestedWidth else { return }
        requestedWidth = width
        worker?.cancel()
        worker = Task { [weak self] in
            let task = Task.detached(priority: .userInitiated) { try TranscriptFlowLayout(source: source, width: width) }
            let result = await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
            guard !Task.isCancelled, let self, self.source === source, requestedWidth == width,
                  case let .success(layout) = result else { return }
            let anchor = layoutResult?.source === source ? topWord : nil
            layoutResult = layout
            table.tableColumns.first?.width = contentSize.width
            table.reloadData()
            table.layoutSubtreeIfNeeded()
            if let anchor { reveal(anchor, atTop: true) }
            applyScroll()
            rememberTopWord()
        }
    }

    var topWord: Int? {
        guard let layoutResult else { return nil }
        return layoutResult.firstWord(atRow: max(0, table.row(at: NSPoint(x: table.bounds.midX, y: contentView.bounds.minY + 1))))
    }

    @objc func rememberTopWord() {
        if let topWord { viewport?.lastTopWord = topWord }
    }

    private func applyScroll() {
        guard let request, request.id != appliedRequest, layoutResult?.source === source else { return }
        appliedRequest = request.id
        reveal(request.word, atTop: request.atTop)
    }

    func reveal(_ position: Int, atTop: Bool) {
        guard let row = layoutResult?.row(for: position) else { return }
        if atTop {
            let rect = table.rect(ofRow: row)
            contentView.scroll(to: contentView.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: rect.minY), size: contentSize)).origin)
            reflectScrolledClipView(contentView)
        } else { table.scrollRowToVisible(row) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { layoutResult?.lines.count ?? 0 }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let layoutResult else { return nil }
        let id = NSUserInterfaceItemIdentifier("transcript.line")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? TranscriptFlowLine ?? TranscriptFlowLine()
        cell.identifier = id
        cell.configure(owner: self, layout: layoutResult, row: row, inset: Self.inset)
        return cell
    }

    func pick(_ index: Int, extending: Bool, seek: Bool) {
        guard let layoutResult, layoutResult.source === source, layoutResult.source.words.indices.contains(index) else { return }
        choose?(layoutResult.source.words[index], extending, seek)
    }

    func word(at event: NSEvent) -> Int? {
        let point = table.convert(event.locationInWindow, from: nil)
        let row = table.row(at: point)
        guard row >= 0, let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? TranscriptFlowLine else { return nil }
        return cell.word(at: cell.convert(event.locationInWindow, from: nil))
    }
}

@MainActor
private final class TranscriptFlowLine: NSView, NSViewToolTipOwner {
    private weak var owner: TranscriptFlowScrollView?
    private weak var layoutResult: TranscriptFlowLayout?
    private var row = 0
    private var inset: CGFloat = 0
    private var line: CTLine?
    private var contextWord: Int?
    private var tip: NSView.ToolTipTag?
    private var mouseWord: Int?
    private var extended = false

    func configure(owner: TranscriptFlowScrollView, layout: TranscriptFlowLayout, row: Int, inset: CGFloat) {
        TranscriptPaneProbe.lineConfigurations += 1
        self.owner = owner
        layoutResult = layout
        self.row = row
        self.inset = inset
        let text = layout.text(in: row)
        shape(text)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(text.string)
        needsDisplay = true
    }

    private func shape(_ text: NSAttributedString) {
        let drawing = NSMutableAttributedString(attributedString: text)
        let foreground = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let full = NSRange(location: 0, length: text.length)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            text.enumerateAttribute(TranscriptFlowLayout.headingKey, in: full) { value, range, _ in
                if value != nil {
                    drawing.removeAttribute(NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String), range: range)
                    drawing.addAttribute(foreground, value: NSColor.secondaryLabelColor.cgColor, range: range)
                }
            }
            text.enumerateAttribute(TranscriptFlowLayout.laneSlotKey, in: full) { value, range, _ in
                if let slot = value as? Int {
                    drawing.addAttribute(foreground, value: NSColor(MulticamLaneChip.color(for: slot)).cgColor, range: range)
                }
            }
        }
        line = CTLineCreateWithAttributedString(drawing)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let layoutResult { shape(layoutResult.text(in: row)); needsDisplay = true }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let tip { removeToolTip(tip) }
        tip = bounds.isEmpty ? nil : addToolTip(bounds, owner: self, userData: nil)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
                    userData: UnsafeMutableRawPointer?) -> String {
        guard let i = word(at: point), let layoutResult else { return "" }
        return owner?.describe?(layoutResult.source.words[i]) ?? ""
    }

    private final class WordButton: NSAccessibilityElement {
        var press: (() -> Void)?
        override func accessibilityPerformPress() -> Bool { press?(); return press != nil }
    }

    override func accessibilityChildren() -> [Any]? {
        guard let layoutResult else { return [] }
        return layoutResult.words(in: row).map { i in
            let word = layoutResult.source.words[i]
            let button = WordButton()
            button.setAccessibilityElement(true)
            button.setAccessibilityParent(self)
            button.setAccessibilityRole(.button)
            button.setAccessibilityLabel(word.text)
            button.setAccessibilityIdentifier("transcript.word." + word.id)
            button.setAccessibilityHelp(owner?.describe?(word))
            let selected = owner?.selection
            button.setAccessibilitySelected(selected?.positions.contains(i) == true &&
                (selected?.track == nil || selected?.track == word.trackID))
            button.setAccessibilityFrameInParentSpace(rect(for: i))
            button.press = { [weak owner] in
                guard owner?.layoutResult === layoutResult else { return }
                owner?.pick(i, extending: false, seek: true)
            }
            return button
        }
    }

    private func rect(for word: Int) -> CGRect {
        guard let layoutResult, let line else { return .zero }
        let span = layoutResult.lines[row].characters
        let range = NSIntersectionRange(span, layoutResult.ranges[word])
        let a = CTLineGetOffsetForStringIndex(line, range.location - span.location, nil)
        let b = CTLineGetOffsetForStringIndex(line, NSMaxRange(range) - span.location, nil)
        return CGRect(x: inset + min(a, b), y: 2, width: abs(b - a), height: bounds.height - 4)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let line, let layoutResult, let owner else { return }
        for i in layoutResult.words(in: row) {
            let active = owner.active.contains(i)
            let selected = owner.selection.map {
                $0.positions.contains(i) && ($0.track == nil || $0.track == layoutResult.source.words[i].trackID)
            } ?? false
            guard active || selected else { continue }
            NSColor.controlAccentColor.withAlphaComponent(active ? 0.38 : 0.22).setFill()
            NSBezierPath(roundedRect: rect(for: i).insetBy(dx: -1, dy: 0), xRadius: 3, yRadius: 3).fill()
        }
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.setFillColor(NSColor.labelColor.cgColor)
        ctx.textPosition = .init(x: inset, y: 6)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    func word(at point: NSPoint) -> Int? {
        guard let line, let layoutResult else { return nil }
        let x = point.x - inset
        guard x >= 0, x < CTLineGetTypographicBounds(line, nil, nil, nil) else { return nil }
        return layoutResult.words(in: row).first { rect(for: $0).contains(point) }
    }

    override func mouseDown(with event: NSEvent) {
        mouseWord = word(at: convert(event.locationInWindow, from: nil))
        extended = event.modifierFlags.contains(.shift)
        if let mouseWord { owner?.pick(mouseWord, extending: extended, seek: false) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mouseWord != nil else { return }
        extended = true
        autoscroll(with: event)
        if let i = owner?.word(at: event) { owner?.pick(i, extending: true, seek: false) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseWord = nil }
        if let mouseWord, owner?.word(at: event) == mouseWord {
            owner?.pick(mouseWord, extending: extended, seek: true)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let i = word(at: convert(event.locationInWindow, from: nil)) else { return nil }
        contextWord = i
        let menu = NSMenu()
        for (title, action) in [("Seek to Word", #selector(seek)), ("Extend Selection to Word", #selector(extendSelection)),
                                ("Inspect Word Evidence", #selector(inspectWord))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        return menu
    }

    @objc private func seek() { if let contextWord { owner?.pick(contextWord, extending: false, seek: true) } }
    @objc private func extendSelection() { if let contextWord { owner?.pick(contextWord, extending: true, seek: true) } }
    @objc private func inspectWord() {
        if let contextWord { owner?.pick(contextWord, extending: false, seek: false); owner?.inspect?() }
    }
}
