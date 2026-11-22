import Foundation

/// Compare Resolve's actual import with the timeline we sent. Resolve can silently
/// substitute a different timebase or raster even when its import API succeeds.
enum ResolveTimelineGeometry {
    static let reportFunction = #"""
    local function writeLayout(timeline)
        local report = assert(io.open(os.getenv("MPCUT_LAYOUT"), "w"))
        local rate = tostring(timeline:GetSetting("timelineFrameRate")):match("^([%d.]+)")
        local origin = timeline:GetStartFrame()
        assert(report:write(table.concat({rate, timeline:GetSetting("timelineResolutionWidth"),
               timeline:GetSetting("timelineResolutionHeight"), timeline:GetEndFrame() - origin}, "\t"), "\n"))
        for _,kind in ipairs({"video","audio"}) do
            for i=1,timeline:GetTrackCount(kind) do
                for _,item in ipairs(timeline:GetItemListInTrack(kind,i) or {}) do
                    local source = item:GetMediaPoolItem()
                    local group = source and source:GetClipProperty("Type") == "Multicam"
                    assert(report:write(table.concat({group and ("multicam-" .. kind) or kind,
                          item:GetStart(true) - origin,item:GetEnd(true) - origin}, "\t"), "\n"))
                end
            end
        end
        assert(report:close())
    end
    """#

    private struct Cut: Comparable {
        let kind: String
        let start: Double
        let end: Double

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.kind, lhs.start, lhs.end) < (rhs.kind, rhs.start, rhs.end)
        }
    }

    static func verify(xml: URL, report: URL, allowLoss: Bool) throws -> [String] {
        try verify(document: FCPInterchange.loadDocument(xml), report: report, allowLoss: allowLoss)
    }

    static func verify(document doc: XMLDocument, report: URL, allowLoss: Bool) throws -> [String] {
        let geometryError = CutError(code: "resolve_layout_failed", message: "Could not verify the Resolve timeline layout.")
        guard let sequence = try doc.nodes(forXPath: "/fcpxml/library/event/project/sequence").first as? XMLElement,
              let formatID = sequence.attribute(forName: "format")?.stringValue,
              let resources = try doc.nodes(forXPath: "/fcpxml/resources").first as? XMLElement,
              let format = resources.elements(forName: "format").first(where: { $0.attribute(forName: "id")?.stringValue == formatID }),
              let width = (format.attribute(forName: "width")?.stringValue).flatMap(Int.init),
              let height = (format.attribute(forName: "height")?.stringValue).flatMap(Int.init),
              let spine = sequence.elements(forName: "spine").first else { throw geometryError }
        func time(_ element: XMLElement, _ key: String) throws -> RationalTime {
            guard let value = element.attribute(forName: key)?.stringValue, value.last == "s" else { throw geometryError }
            return try RationalTime(parsing: String(value.dropLast()))
        }
        let frame = try time(format, "frameDuration")
        guard frame > .zero else { throw geometryError }
        let lines = try String(contentsOf: report, encoding: .utf8).split(whereSeparator: \.isNewline)
        let header = lines.first?.split(separator: "\t") ?? []
        guard header.count == 4, let rate = Double(header[0]), let actualWidth = Int(header[1]),
              let actualHeight = Int(header[2]), let duration = Double(header[3]) else { throw geometryError }
        // Resolve reports e.g. 29.97 for 30000/1001. Distinguish it from the integer rate.
        guard abs(rate - 1 / frame.seconds) <= 0.005,
              abs(duration - (try time(sequence, "duration")).seconds / frame.seconds) < 0.001 else {
            throw CutError(code: "resolve_timebase_changed",
                           message: "Resolve imported the timeline at \(rate) fps for \(duration) frames. Its requested frame duration is \(frame)s. Conform the source to a Resolve-supported frame rate before exporting.")
        }

        let actual = try lines.dropFirst().map { line -> Cut in
            let fields = line.split(separator: "\t")
            guard fields.count == 3, let start = Double(fields[1]), let end = Double(fields[2]) else { throw geometryError }
            return Cut(kind: String(fields[0]), start: start, end: end)
        }.sorted()
        var assets = [String: XMLElement]()
        for asset in resources.elements(forName: "asset") {
            if let id = asset.attribute(forName: "id")?.stringValue { assets[id] = asset }
        }
        var expected = [Cut]()
        for case let item as XMLElement in spine.children ?? [] {
            let position = try time(item, "offset")
            func append(_ kind: String, at start: RationalTime, length: RationalTime) throws {
                expected.append(Cut(kind: kind, start: start.seconds / frame.seconds,
                                    end: try start.adding(length).seconds / frame.seconds))
            }
            let length = try time(item, "duration")
            switch item.name {
            case "mc-clip":
                var kinds = Set<String>()
                for source in item.elements(forName: "mc-source") {
                    switch source.attribute(forName: "srcEnable")?.stringValue {
                    case "video": kinds.insert("multicam-video")
                    case "audio": kinds.insert("multicam-audio")
                    case "all": kinds.formUnion(["multicam-video", "multicam-audio"])
                    default: throw geometryError
                    }
                }
                for kind in kinds { try append(kind, at: position, length: length) }
            case "asset-clip":
                guard let ref = item.attribute(forName: "ref")?.stringValue, let asset = assets[ref] else { throw geometryError }
                if asset.attribute(forName: "hasVideo")?.stringValue == "1" { try append("video", at: position, length: length) }
                if asset.attribute(forName: "hasAudio")?.stringValue == "1" { try append("audio", at: position, length: length) }
            case "clip":
                let origin = try time(item, "start")
                for case let child as XMLElement in item.children ?? [] where child.name == "audio" || child.name == "video" {
                    let start = try position.adding(time(child, "offset").subtracting(origin))
                    try append(child.name!, at: start, length: time(child, "duration"))
                }
            default: throw geometryError
            }
        }
        let ordered = expected.sorted()
        guard actual.count == ordered.count, zip(actual, ordered).allSatisfy({ host, wanted in
            // Resolve can round an audio edit to the nearest timeline frame.
            let tolerance = wanted.kind == "audio" ? 0.50001 : 0.00001
            return host.kind == wanted.kind && abs(host.start - wanted.start) <= tolerance && abs(host.end - wanted.end) <= tolerance
        }) else {
            throw CutError(code: "resolve_layout_changed", message: "Resolve changed picture or audio clip boundaries, count, or multicam type while importing the timeline.")
        }
        var warnings = [String]()
        if zip(actual, ordered).contains(where: { host, wanted in
            abs(host.start - wanted.start) > 0.00001 || abs(host.end - wanted.end) > 0.00001
        }) {
            warnings.append("Resolve rounded an audio edit to the nearest timeline frame.")
        }
        if actualWidth != width || actualHeight != height {
            warnings.append("Resolve changed the timeline resolution from \(width)×\(height) to \(actualWidth)×\(actualHeight).")
        }
        if !allowLoss, !warnings.isEmpty {
            throw CutError(code: "conversion_loss", message: warnings.joined(separator: " "))
        }
        return warnings
    }
}
