import Foundation

private extension XMLElement {
    @discardableResult func add(_ name: String, _ text: String? = nil) -> XMLElement {
        let element = XMLElement(name: name)
        if let text { element.stringValue = text }
        addChild(element)
        return element
    }
    func value(_ field: String) -> String? { elements(forName: field).first?.stringValue }
    func addRate(_ fps: RationalTime) throws {
        guard fps > .zero, fps.seconds <= 1000 else { throw PremiereTimeline.issue("Invalid Premiere frame rate \(fps).") }
        let nominal = Int64(fps.seconds.rounded())
        let ntsc = fps != RationalTime(numerator: nominal)
        guard nominal >= 1, !ntsc || fps == RationalTime(numerator: nominal * 1000, denominator: 1001) else {
            throw PremiereTimeline.issue("Premiere sequence XML cannot represent the frame rate \(fps).")
        }
        let rate = add("rate")
        rate.add("timebase", String(nominal))
        rate.add("ntsc", ntsc ? "TRUE" : "FALSE")
    }
}

/// Legacy sequence XML is the private interchange Premiere itself can read and write.
enum PremiereTimeline {
    private struct Edit {
        let file: URL
        let range: MulticamRange
        let position: RationalTime
        let video: Bool
        let audio: Bool
        let audioOrdinal: Int?
        var angle: String? = nil
    }

    static func write(_ project: CutProject, relativeTo location: URL, to xml: URL,
                      name: String, allowLoss: Bool, flattenMulticam: Bool = false) throws -> [String] {
        let conversion = try ProjectConverter.prepareForInterchange(project, for: "Adobe Premiere Pro", allowLoss: allowLoss)
        var edits: [Edit] = []
        var warnings = Set(conversion.warnings)
        var media: [URL: MediaInfo] = [:]
        var nativeGroup: MulticamProject?
        var programDuration: RationalTime?
        var referenceVideo: StreamInfo?
        let engine = CutEngine(useSidecar: false)
        func inspect(_ url: URL) throws -> MediaInfo {
            if let found = media[url] { return found }
            var attributes = stat()
            guard stat(url.path, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG else {
                throw issue("Relink the source to a regular media file: \(url.path)")
            }
            let result = try engine.inspectSummary(url)
            media[url] = result
            return result
        }
        func loss(_ message: String) throws {
            guard allowLoss else { throw CutError(code: "premiere_conversion_loss", message: message + " Use --allow-loss to continue.") }
            warnings.insert(message)
        }
        switch conversion.project {
        case .stillSequence:
            throw issue("Premiere timeline XML has no verified mapping for MPCut stills.")
        case .sequence(let clips):
            try InterchangeMediaPreflight.require(clips.map(\.file), relativeTo: location)
            var position = RationalTime.zero
            for clip in clips {
                let file = try CutProject.checkedMediaURL(clip.file, relativeTo: location)
                if clip.originalFile != nil || !clip.replacementNames.isEmpty || clip.audioTrack != nil {
                    try loss("Premiere uses all tracks in the current replacement media. MPCut replacement history, preview preference and track labels are omitted.")
                }
                edits.append(Edit(file: file, range: .init(from: clip.from, to: clip.to), position: position,
                                  video: true, audio: true, audioOrdinal: nil))
                position = try position.adding(clip.to.subtracting(clip.from))
            }
        case .multicam(let group):
            let plan = try group.plan()
            programDuration = plan.duration
            let sources = Dictionary(uniqueKeysWithValues: group.sources.map { ($0.id, $0) })
            let permitsNative = !flattenMulticam && (2...4).contains(group.pictureSources.count)
                && group.angles.allSatisfy { $0.offset == .zero && $0.coverage == nil && $0.additionalRecordings.isEmpty }
            let selectedIDs = Set(plan.intervals.compactMap(\.pictureSourceID))
                .union(plan.intervals.compactMap { $0.audio?.source })
            let required = permitsNative ? selectedIDs.union(group.pictureSources.map(\.id)) : selectedIDs
            try InterchangeMediaPreflight.require(required.compactMap { sources[$0]?.file }, relativeTo: location)
            let cameras = try permitsNative ? group.pictureSources.map {
                try inspect(CutProject.checkedMediaURL($0.file, relativeTo: location))
            } : []
            guard cameras.allSatisfy(\.hasVideo) else { throw issue("Each multicam camera must link to a video recording.") }
            if let index = group.pictureSources.firstIndex(where: { $0.id == group.referenceAngle }),
               cameras.indices.contains(index) {
                referenceVideo = cameras[index].videoStream
            }
            let fps = cameras.first?.videoStream?.frameRate
            let native = permitsNative && cameras.allSatisfy {
                $0.videoStream != nil && $0.videoStream?.frameRate == fps
                    && $0.multicamSourceOffset == .zero && $0.duration >= group.range.to
            }
            if native {
                nativeGroup = group
                warnings.insert("Premiere has editable native camera angles and separate microphone tracks. To import these edits back into MPCut, flatten a copy in Premiere first.")
            } else {
                try loss("Premiere receives the selected camera and microphone edits as separate timeline clips. Alternate angles and the multicam group are omitted.")
            }
            func append(_ interval: MulticamInterval, sourceID: String, stream: Int?) throws {
                guard let source = sources[sourceID] else { throw issue("Missing multicam source \(sourceID).") }
                let url = try CutProject.checkedMediaURL(source.file, relativeTo: location)
                let info = try inspect(url)
                if stream == nil && !info.hasVideo {
                    throw issue("Each selected multicam camera must link to a video recording: \(url.path)")
                }
                let audio = info.streams.filter { $0.kind == "audio" }
                let ordinal = stream.flatMap { id in audio.firstIndex { $0.index == id } }
                if stream != nil && ordinal == nil { throw issue("Missing selected microphone stream in \(url.path).") }
                let offset = try source.offset.adding(info.multicamSourceOffset)
                let range = try MulticamRange(from: interval.group.from.subtracting(offset), to: interval.group.to.subtracting(offset))
                let selected = ordinal.map { audio[$0] } ?? info.videoStream
                if let selected {
                    let end = try selected.duration > .zero ? selected.start.adding(selected.duration) : info.duration
                    guard selected.start <= range.from, range.to <= end else {
                        throw issue("Source \(source.id) stream \(selected.index) does not cover the edit at \(range.from)–\(range.to).")
                    }
                }
                edits.append(Edit(file: url, range: range,
                                  position: interval.output.from, video: stream == nil,
                                  audio: stream != nil, audioOrdinal: ordinal,
                                  angle: stream == nil ? sourceID : nil))
            }
            for interval in plan.intervals {
                if let source = interval.pictureSourceID { try append(interval, sourceID: source, stream: nil) }
                if let selection = interval.audio { try append(interval, sourceID: selection.source, stream: selection.stream) }
            }
        }
        for file in Set(edits.map(\.file)) { _ = try inspect(file) }
        let video = edits.lazy.filter(\.video).compactMap { media[$0.file]?.videoStream }.first ?? referenceVideo
        let fps = video?.frameRate ?? RationalTime(numerator: 30)
        // A Premiere sequence needs a picture format. With no picture to follow, say which one it was given.
        if video == nil { warnings.insert("No clip has picture, so the sequence uses 30 fps and 1920 × 1080.") }
        func frame(_ time: RationalTime, at rate: RationalTime) throws -> Int64 {
            let exact = try time.multiplied(by: rate)
            if exact.denominator != 1 { try loss("Premiere rounds subframe edits to the nearest frame.") }
            return try exact.roundedToSamples(1)
        }
        let root = XMLElement(name: "xmeml")
        root.setAttributesWith(["version": "4"])
        let sequence = root.add("sequence")
        sequence.add("name", name)
        try sequence.addRate(fps)
        let tracks = sequence.add("media")
        let picture = tracks.add("video")
        let format = picture.add("format").add("samplecharacteristics")
        try format.addRate(fps)
        format.add("width", String(video?.displayWidth ?? 1920))
        format.add("height", String(video?.displayHeight ?? 1080))
        format.add("pixelaspectratio", "square")
        format.add("fielddominance", "none")
        let v1 = picture.add("track")
        let sound = tracks.add("audio")
        var videoClipCount = 0
        var audioTracks: [(node: XMLElement, clipCount: Int)] = []
        var end = try programDuration.map { try frame($0, at: fps) } ?? 0
        var next = 1
        var fileIDs: [URL: String] = [:]
        for edit in edits {
            guard let info = media[edit.file], edit.range.from >= .zero,
                  edit.audioOrdinal != nil || edit.range.to <= info.duration else {
                throw issue("Edit lies outside source coverage at \(edit.file.path).")
            }
            let sourceRate = info.videoStream?.frameRate ?? fps
            let start = try frame(edit.position, at: fps)
            let stop = try frame(edit.position.adding(edit.range.to.subtracting(edit.range.from)), at: fps)
            // Premiere reads clipitem in/out on the sequence grid even when its linked file has a different rate.
            let lower = try frame(edit.range.from, at: fps)
            let desiredUpper = try frame(edit.range.to, at: fps)
            guard start < stop else { throw issue("A Premiere cut is shorter than one timeline frame.") }
            let (upper, overflow) = lower.addingReportingOverflow(stop - start)
            let assetDuration = max(info.duration, edit.range.to)
            let timelineFrames = try assetDuration.multiplied(by: fps).roundedToSamples(1)
            guard !overflow, upper <= timelineFrames else { throw issue("Frame rounding would extend the clip past the source: \(edit.file.path)") }
            if upper != desiredUpper { try loss("Premiere adjusts a source out-point to preserve the rounded timeline duration.") }
            end = max(end, stop)
            let streams = info.streams.filter { $0.kind == "audio" }
            if let ordinal = edit.audioOrdinal, !streams.indices.contains(ordinal) {
                throw issue("Audio track \(ordinal) does not exist in \(edit.file.path).")
            }
            func item(on track: XMLElement, sourceChannel: Int? = nil) throws -> XMLElement {
                let item = track.add("clipitem")
                item.setAttributesWith(["id": "clipitem-\(next)"])
                next += 1
                item.add("name", edit.file.lastPathComponent)
                item.add("enabled", "TRUE")
                try item.addRate(fps)
                item.add("duration", String(timelineFrames))
                for (key, value) in [("start", start), ("end", stop), ("in", lower), ("out", upper)] {
                    item.add(key, String(value))
                }
                let file = item.add("file")
                let existing = fileIDs[edit.file]
                let id = existing ?? "file-\(fileIDs.count + 1)"
                file.setAttributesWith(["id": id])
                if existing == nil {
                    fileIDs[edit.file] = id
                    file.add("name", edit.file.lastPathComponent)
                    file.add("pathurl", edit.file.absoluteURL.absoluteString)
                    try file.addRate(sourceRate)
                    file.add("duration", String(try assetDuration.multiplied(by: sourceRate).roundedToSamples(1)))
                    let av = file.add("media")
                    if let video = info.videoStream {
                        let samples = av.add("video").add("samplecharacteristics")
                        try samples.addRate(sourceRate)
                        samples.add("width", String(video.width))
                        samples.add("height", String(video.height))
                    }
                    for stream in streams {
                        let audio = av.add("audio")
                        audio.add("channelcount", String(stream.channels))
                        audio.add("samplecharacteristics").add("samplerate", String(stream.sampleRate))
                    }
                }
                if let sourceChannel {
                    let source = item.add("sourcetrack")
                    source.add("mediatype", "audio")
                    source.add("trackindex", String(sourceChannel))
                }
                return item
            }
            var linked: [(XMLElement, String, Int, Int)] = []
            if edit.video && info.hasVideo {
                videoClipCount += 1
                if let group = nativeGroup {
                    let input = v1.add("clipitem")
                    let angleID = next
                    input.setAttributesWith(["id": "clipitem-\(next)"])
                    next += 1
                    input.add("name", name)
                    try input.addRate(fps)
                    input.add("duration", String(try group.range.to.multiplied(by: fps).roundedToSamples(1)))
                    for (key, value) in [("start", start), ("end", stop), ("in", lower), ("out", upper)] {
                        input.add(key, String(value))
                    }
                    try addNativeAngles(to: input, group: group, selected: edit.angle, occurrence: angleID,
                                        name: name, fps: fps, location: location, media: media)
                } else {
                    linked.append((try item(on: v1), "video", 1, videoClipCount))
                }
            }
            if edit.audio {
                var channel = 0, destination = 0
                for (ordinal, stream) in streams.enumerated() {
                    for _ in 0..<stream.channels {
                        channel += 1
                        guard edit.audioOrdinal == nil || edit.audioOrdinal == ordinal else { continue }
                        guard destination < 32 else { throw issue("Premiere exchange supports up to 32 audio channels per clip.") }
                        if destination == audioTracks.count { audioTracks.append((sound.add("track"), 0)) }
                        audioTracks[destination].clipCount += 1
                        let track = audioTracks[destination]
                        linked.append((try item(on: track.node, sourceChannel: channel), "audio", destination + 1, track.clipCount))
                        destination += 1
                    }
                }
            }
            for (item, _, _, _) in linked {
                for (target, kind, index, clipIndex) in linked {
                    let link = item.add("link")
                    link.add("linkclipref", target.attribute(forName: "id")?.stringValue)
                    link.add("mediatype", kind)
                    link.add("trackindex", String(index))
                    link.add("clipindex", String(clipIndex))
                }
            }
        }
        sequence.add("duration", String(end))
        try XMLDocument(rootElement: root).xmlData.write(to: xml, options: .atomic)
        return warnings.sorted()
    }

    private static func addNativeAngles(to input: XMLElement, group: MulticamProject, selected: String?,
                                        occurrence: Int, name: String, fps: RationalTime, location: URL,
                                        media: [URL: MediaInfo]) throws {
        let multi = input.add("multiclip")
        multi.setAttributesWith(["id": "multiclip-\(occurrence)"])
        multi.add("name", name + " Cameras")
        multi.add("collapsed", "FALSE")
        multi.add("synctype", "1")
        // Premiere deduplicates these equivalent groups and applies each occurrence's active angle.
        for (index, camera) in group.angles.enumerated() {
            let url = try CutProject.checkedMediaURL(camera.file, relativeTo: location)
            guard let info = media[url], let video = info.videoStream else { throw issue("Missing native camera.") }
            let active = camera.id == selected
            let angle = multi.add("angle")
            angle.add("activevideoangle", active ? "TRUE" : "FALSE")
            angle.add("activeaudioangle", "FALSE")
            let clip = angle.add("clip")
            clip.setAttributesWith(["id": "camera-\(occurrence)-\(index)"])
            let title = camera.name ?? url.lastPathComponent
            let length = String(try info.duration.multiplied(by: fps).roundedToSamples(1))
            clip.add("name", title)
            try clip.addRate(fps)
            clip.add("duration", length)
            clip.add("in", "0")
            clip.add("out", length)
            clip.add("defaultangle", String(index + 1))
            let source = clip.add("media").add("video").add("track").add("clipitem")
            source.add("name", title)
            try source.addRate(fps)
            source.add("duration", length)
            source.add("start", "0")
            source.add("end", length)
            source.add("in", "0")
            source.add("out", length)
            source.add("mediadelay", "0")
            let file = source.add("file")
            file.setAttributesWith(["id": "camera-file-\(occurrence)-\(index)"])
            file.add("name", url.lastPathComponent)
            file.add("pathurl", url.absoluteURL.absoluteString)
            try file.addRate(fps)
            file.add("duration", length)
            let characteristics = file.add("media").add("video").add("samplecharacteristics")
            try characteristics.addRate(fps)
            characteristics.add("width", String(video.width))
            characteristics.add("height", String(video.height))
        }
    }

    static func issue(_ text: String) -> CutError { CutError(code: "premiere_timeline", message: text) }

    static func nativeAngles(in xml: URL) throws -> [Int] {
        let document = try XMLDocument(contentsOf: xml, options: [.nodeLoadExternalEntitiesNever])
        return try document.nodes(forXPath: "/xmeml/sequence/media/video/track/clipitem/multiclip").map { node in
            guard let angles = (node as? XMLElement)?.elements(forName: "angle"),
                  let index = angles.firstIndex(where: { $0.value("activevideoangle") == "TRUE" }) else {
                throw issue("Missing active native camera angle.")
            }
            return index + 1
        }
    }
}

extension PremiereTimeline {
    private struct Item: Equatable {
        let file: String
        let start: RationalTime
        let end: RationalTime
        let sourceIn: RationalTime
        let sourceOut: RationalTime
        let channel: Int
    }

    private enum AudioBoundary {
        case begin(track: Int, item: Item)
        case end(track: Int)
    }

    static func read(_ xml: URL, allowLoss: Bool) throws -> (CutProject, [String]) {
        let imported = try readDocument(xml, allowLoss: allowLoss)
        return (imported.project, imported.warnings)
    }

    static func readDocument(_ xml: URL, allowLoss: Bool) throws
        -> (project: CutProject, warnings: [String], mediaSnapshot: ProjectMediaSnapshot) {
        let data: Data
        do { data = try ProjectFile.readBytes(from: xml) }
        catch { throw issue(error.localizedDescription) }
        guard data.count <= (64 << 20) else { throw issue("Premiere sequence description exceeds the interchange size limit.") }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0"), !text.contains("<!ENTITY"),
              !text.contains("<!DOCTYPE") || text.range(of: #"<!DOCTYPE(?!\s+xmeml\s*>)"#, options: .regularExpression) == nil else {
            throw issue("Expected UTF-8 Premiere sequence XML without entity declarations or external DTDs.")
        }
        let document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        guard let root = document.rootElement(), root.name == "xmeml",
              root.elements(forName: "sequence").count == 1, let sequence = root.elements(forName: "sequence").first,
              let media = sequence.elements(forName: "media").first else { throw issue("Expected one Premiere sequence.") }
        var warnings = Set<String>()
        func loss(_ text: String) throws {
            guard allowLoss else { throw CutError(code: "conversion_loss", message: text) }
            warnings.insert(text)
        }
        func rate(_ node: XMLElement, fallback: RationalTime? = nil) throws -> RationalTime {
            guard let rate = node.elements(forName: "rate").first else {
                if let fallback { return fallback }
                throw issue("Missing Premiere sequence frame rate.")
            }
            guard let base = Int64(rate.value("timebase") ?? ""), (1...1000).contains(base) else {
                throw issue("Invalid Premiere frame rate.")
            }
            return rate.value("ntsc")?.uppercased() == "TRUE"
                ? RationalTime(numerator: base * 1000, denominator: 1001) : RationalTime(numerator: base)
        }
        let sequenceRate = try rate(sequence)
        var files: [String: String] = [:]
        for case let file as XMLElement in try sequence.nodes(forXPath: ".//file[pathurl]") {
            guard let id = file.attribute(forName: "id")?.stringValue,
                  let raw = file.value("pathurl"), let url = URL(string: raw), url.isFileURL,
                  ["", "localhost"].contains(url.host?.lowercased() ?? ""), url.user == nil, url.password == nil, url.port == nil,
                  url.path.hasPrefix("/"), url.query == nil, url.fragment == nil,
                  !raw.lowercased().contains("%00"), ProjectFile.validMediaPath(url.path) else { throw issue("Premiere media must reference a local file.") }
            let path = "/" + url.path.drop(while: { $0 == "/" })
            guard files[id] == nil || files[id] == path else { throw issue("Conflicting Premiere source paths for file ID \(id).") }
            files[id] = path
        }
        if !(try sequence.nodes(forXPath: ".//marker | .//filter | .//transitionitem | .//generatoritem").isEmpty) {
            try loss("Premiere markers, effects, graphics, transitions and clip motion are omitted.")
        }
        func tracks(_ type: String) throws -> [[Item]] {
            let tracks = media.elements(forName: type).first?.elements(forName: "track") ?? []
            return try tracks.compactMap { track in
                let children = track.elements(forName: "clipitem")
                if children.isEmpty { return nil }
                if track.value("enabled")?.uppercased() == "FALSE" {
                    try loss("Disabled Premiere tracks are omitted.")
                    return nil
                }
                var result: [Item] = []
                for item in children {
                    if item.value("enabled")?.uppercased() == "FALSE" {
                        try loss("Disabled Premiere clips are omitted.")
                        continue
                    }
                    guard let fileID = item.elements(forName: "file").first?.attribute(forName: "id")?.stringValue,
                          let file = files[fileID] else {
                        throw issue("A nested sequence, multicam source or unlinked clip has no direct source file. Flatten that clip in Premiere first.")
                    }
                    if try !item.nodes(forXPath: "./filter/effect/effectid").allSatisfy({ $0.stringValue?.lowercased() != "timeremap" }) {
                        throw issue("A Premiere clip uses time remapping. Render or remove the speed change before importing.")
                    }
                    let fps = try rate(item, fallback: sequenceRate)
                    func frame(_ key: String, at rate: RationalTime) throws -> RationalTime {
                        guard let n = Int64(item.value(key) ?? ""), n >= 0 else {
                            throw issue("Premiere clip \(file) contains an unsupported transition boundary or invalid \(key).")
                        }
                        return try RationalTime(numerator: n).multiplied(by: .init(numerator: rate.denominator, denominator: rate.numerator))
                    }
                    func source(_ key: String, ticks: String) throws -> RationalTime {
                        if let count = Int64(item.value(ticks) ?? ""), count >= 0 { return RationalTime(numerator: count, denominator: 254_016_000_000) }
                        return try frame(key, at: fps)
                    }
                    let sourceTrack = item.elements(forName: "sourcetrack").first
                    guard let channel = Int(sourceTrack?.value("trackindex") ?? "1"), channel > 0 else {
                        throw issue("Invalid source track on Premiere clip \(file).")
                    }
                    let edit = try Item(file: file, start: frame("start", at: sequenceRate), end: frame("end", at: sequenceRate),
                                        sourceIn: source("in", ticks: "pproTicksIn"), sourceOut: source("out", ticks: "pproTicksOut"),
                                        channel: channel)
                    guard edit.start < edit.end, edit.sourceIn < edit.sourceOut,
                          try edit.end.subtracting(edit.start) == edit.sourceOut.subtracting(edit.sourceIn) else {
                        throw issue("Premiere clip \(file) has a retime or mismatched source and timeline durations.")
                    }
                    result.append(edit)
                }
                return result.isEmpty ? nil : result.sorted { $0.start < $1.start }
            }
        }
        let pictures = try tracks("video"), sounds = try tracks("audio")
        let pictureItems = pictures.flatMap { $0 }.sorted { $0.start < $1.start }
        guard zip(pictureItems, pictureItems.dropFirst()).allSatisfy({ $0.end <= $1.start }) else {
            throw issue("Overlapping Premiere picture clips require flattening before import.")
        }
        if pictures.count > 1 {
            try loss("Combined cuts from separate Premiere picture tracks into one MPCut timeline.")
        }
        for track in sounds {
            guard zip(track, track.dropFirst()).allSatisfy({ $0.end <= $1.start }) else {
                throw issue("Overlapping clips on a single Premiere audio track cannot be represented.")
            }
        }
        let audio = sounds.flatMap { $0 }
        let engine = CutEngine(useSidecar: false)
        var metadata: [String: MediaInfo] = [:]
        func imported(_ project: CutProject) -> (CutProject, [String], ProjectMediaSnapshot) {
            let entries = metadata.keys.sorted().compactMap { path in
                metadata[path].map { ProjectMediaSnapshot.Entry(path: path, media: $0) }
            }
            return (project, warnings.sorted(), ProjectMediaSnapshot(entries: entries))
        }
        func inspect(_ path: String) throws -> MediaInfo {
            if let media = metadata[path] { return media }
            let url = URL(fileURLWithPath: path)
            var attributes = stat()
            guard stat(path, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG else {
                throw issue("Relink the source in Premiere before importing: \(path).")
            }
            let media = try engine.inspectSummary(url)
            metadata[path] = media
            return media
        }
        func sameEdit(_ a: Item, _ b: Item) -> Bool {
            a.file == b.file && a.start == b.start && a.end == b.end && a.sourceIn == b.sourceIn && a.sourceOut == b.sourceOut
        }
        var last = max(pictureItems.last?.end ?? .zero, audio.lazy.map(\.end).max() ?? .zero)
        if let value = sequence.value("duration") {
            guard let declared = Int64(value), declared >= 0 else { throw issue("Invalid Premiere sequence duration.") }
            let duration = try RationalTime(numerator: declared).multiplied(by: .init(numerator: sequenceRate.denominator, denominator: sequenceRate.numerator))
            guard duration >= last else { throw issue("A Premiere clip extends past the declared sequence duration.") }
            last = duration
        }
        for item in pictureItems {
            let info = try inspect(item.file)
            guard info.hasVideo else { throw issue("The Premiere picture source has no video: \(item.file)") }
            guard item.sourceOut <= info.duration else { throw issue("The Premiere source trim exceeds the duration of \(item.file).") }
        }
        // Audio-only recordings between picture clips can form ordinary sequence items.
        let audioOnly = try (sounds.first ?? []).filter { item in
            let index = pictureItems.lowerBound { $0.end > item.start }
            guard index == pictureItems.count || pictureItems[index].start >= item.end else { return false }
            return try !inspect(item.file).hasVideo
        }
        let sequenceItems = (pictureItems + audioOnly).sorted { $0.start < $1.start }
        let contiguous = (sequenceItems.first?.start ?? .zero) == .zero && (sequenceItems.last?.end ?? .zero) == last
            && zip(sequenceItems, sequenceItems.dropFirst()).allSatisfy { $0.end == $1.start }
        let starts = Dictionary(grouping: audio, by: \.start)
        var matched = 0
        let simple = try contiguous && sequenceItems.allSatisfy { item in
            let matches = starts[item.start] ?? []
            let info = try inspect(item.file)
            guard item.sourceOut <= info.duration else { throw issue("The Premiere source trim exceeds the duration of \(item.file).") }
            let channels = info.streams.filter { $0.kind == "audio" }.reduce(0) { $0 + $1.channels }
            matched += matches.count
            guard matches.count == channels, matches.allSatisfy({ sameEdit(item, $0) }),
                  Set(matches.map(\.channel)) == Set((0..<channels).map { $0 + 1 }) else { return false }
            if matches.map(\.channel) != matches.map(\.channel).sorted() {
                try loss("MPCut restores the original audio channel order for \(item.file).")
            }
            return true
        } && matched == audio.count
        if simple {
            let clips = sequenceItems.enumerated().map { i, item in
                CutSequenceClip(id: "clip-\(i + 1)", file: item.file, from: item.sourceIn, to: item.sourceOut)
            }
            let project = CutProject.sequence(clips)
            try project.validate()
            return imported(project)
        }
        guard !pictures.isEmpty, last > .zero else { throw issue("Independent audio tracks over an audio-only interval cannot be represented in MPCut.") }
        let pictureHasGaps = pictureItems.first?.start != .zero || pictureItems.last?.end != last
            || zip(pictureItems, pictureItems.dropFirst()).contains { $0.end != $1.start }
        // Represent independently positioned picture and microphones with MPCut's synchronized source offsets.
        var angles: [MulticamSource] = [], microphones: [MulticamSource] = [], switches: [MulticamSwitch] = []
        var identifiers: [String: [RationalTime: String]] = [:]
        func id(_ item: Item, video: Bool) throws -> String {
            let prefix = video ? "camera" : "microphone"
            let offset = try item.start.subtracting(item.sourceIn).subtracting(inspect(item.file).multicamSourceOffset)
            let key = prefix + item.file
            if let result = identifiers[key]?[offset] { return result }
            let id = "\(prefix)-\((video ? angles.count : microphones.count) + 1)"
            identifiers[key, default: [:]][offset] = id
            let source = MulticamSource(id: id, file: item.file, offset: offset)
            if video { angles.append(source) } else { microphones.append(source) }
            return id
        }
        if pictureHasGaps {
            let recordings = try pictureItems.enumerated().map { index, item in
                let offset = try item.start.subtracting(item.sourceIn).subtracting(inspect(item.file).multicamSourceOffset)
                return MulticamSource(id: "camera-\(index + 1)", file: item.file, offset: offset,
                                      coverage: .init(from: item.start, to: item.end))
            }
            angles = [recordings[0]]
            angles[0].additionalRecordings = Array(recordings.dropFirst())
        }
        var boundaries: [RationalTime: [AudioBoundary]] = [:]
        for (track, items) in sounds.enumerated() {
            for item in items {
                // Ordered clips put an ending before a new beginning at the same time on a track.
                boundaries[item.start, default: []].append(.begin(track: track, item: item))
                boundaries[item.end, default: []].append(.end(track: track))
            }
        }
        let times = Set(pictureItems.lazy.map(\.start)).union(boundaries.keys).union([.zero]).sorted()
        var pictureIndex = 0
        var activeTracks: [Int: Item] = [:]
        for start in times where start < last {
            let camera: String
            if pictureHasGaps {
                camera = angles[0].id
            } else {
                while pictureItems[pictureIndex].end <= start { pictureIndex += 1 }
                camera = try id(pictureItems[pictureIndex], video: true)
            }
            if let events = boundaries[start] {
                for event in events {
                    switch event {
                    case let .begin(track, item): activeTracks[track] = item
                    case let .end(track): activeTracks.removeValue(forKey: track)
                    }
                }
            }
            let active = activeTracks.keys.sorted().map { activeTracks[$0]! }
            var selection: MulticamAudioSelection?
            if let first = active.first {
                let sourceOffset = try first.sourceIn.subtracting(first.start)
                guard active.allSatisfy({ $0.file == first.file && (try? $0.sourceIn.subtracting($0.start)) == sourceOffset }) else {
                    throw issue("Premiere mixes overlapping microphones. Export stems or simplify the audio mix before importing.")
                }
                if active.map(\.channel) != active.map(\.channel).sorted() {
                    try loss("MPCut restores the original audio channel order for \(first.file).")
                }
                let channels = Set(active.map(\.channel))
                guard channels.count == active.count else { throw issue("Overlapping Premiere tracks duplicate audio channels. Mix them down before import.") }
                var offset = 0
                let info = try inspect(first.file)
                let stream = info.streams.first { stream in
                    guard stream.kind == "audio" else { return false }
                    defer { offset += stream.channels }
                    return channels == Set((0..<stream.channels).map { offset + $0 + 1 })
                }
                guard let stream else { throw issue("Premiere selected partial channels or mixed streams that cannot be represented by a microphone selection.") }
                let end = try stream.duration > .zero ? stream.start.adding(stream.duration) : info.duration
                guard active.allSatisfy({ stream.start <= $0.sourceIn && $0.sourceOut <= end }) else {
                    throw issue("The Premiere audio trim exceeds the selected stream in \(first.file).")
                }
                selection = try .init(source: id(first, video: false), stream: stream.index)
            }
            switches.append(.init(at: start, angle: camera, audio: selection))
        }
        guard let reference = angles.first else { throw issue("Missing Premiere reference picture.") }
        let group = MulticamProject(referenceAngle: reference.id, range: .init(from: .zero, to: last),
                                    angles: angles, audioSources: microphones, audio: .none, switches: switches)
        try group.validate()
        return imported(.multicam(group))
    }
}
