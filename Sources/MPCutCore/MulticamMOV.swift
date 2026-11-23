import Foundation

enum MulticamMOV {
    static func combine(picture: URL, sound: URL, output: URL, progress: (Double) throws -> Void) throws {
        try combine(picture: Optional(picture), sounds: [sound], output: output, progress: progress)
    }

    static func combine(picture: URL?, sounds: [URL], output: URL, progress: (Double) throws -> Void) throws {
        var lanes: [Lane] = []
        defer { for lane in lanes { try? lane.file.close() } }
        for url in [picture].compactMap({ $0 }) + sounds {
            lanes.append(try Lane(url))
        }
        guard let first = lanes.first else { throw invalidMovie }
        let prefix = try first.read(first.fileType.offset, Int(first.fileType.size))
        let dataStart = UInt64(prefix.count + 16)
        var mediaEnd = dataStart
        var starts: [UInt64] = []
        for lane in lanes {
            starts.append(mediaEnd)
            let (end, overflow) = mediaEnd.addingReportingOverflow(lane.media.contentSize)
            guard !overflow, end <= UInt64(Int64.max) else { throw invalidMovie }
            mediaEnd = end
        }
        let mediaSize = mediaEnd - UInt64(prefix.count)
        let movie = try merge(lanes: lanes, starts: starts, audioAlternatesFrom: sounds.count > 1 ? (picture == nil ? 0 : 1) : nil)

        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CutError(code: "write_failed", message: "Could not create the staged multicam movie.")
        }
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }
        try writer.write(contentsOf: prefix)
        var header = Data()
        header.appendInteger(UInt32(1))
        header.append(contentsOf: "mdat".utf8)
        header.appendInteger(mediaSize)
        try writer.write(contentsOf: header)
        var copied: UInt64 = 0
        for lane in lanes {
            try lane.file.seek(toOffset: lane.media.contentOffset)
            var remaining = lane.media.contentSize
            while remaining > 0 {
                let count = Int(min(remaining, 1 << 20))
                guard let data = try lane.file.read(upToCount: count), data.count == count else { throw invalidMovie }
                try writer.write(contentsOf: data)
                remaining -= UInt64(count)
                copied += UInt64(count)
                try progress(Double(copied) / Double(mediaSize))
            }
        }
        try writer.write(contentsOf: movie)
        try writer.close()
    }

    // The helper writes unfragmented picture-only media with the movie atom last.
    // Keep every payload and chunk offset intact while replacing the media clock.
    static func retimeStill(_ url: URL, schedule: StillSampleSchedule, timescale: Int64) throws {
        let lane = try Lane(url)
        defer { try? lane.file.close() }
        guard lane.movieBox.offset >= lane.media.offset + lane.media.size,
              lane.movieBox.offset + lane.movieBox.size == (try lane.file.seekToEnd()),
              schedule.fits(timescale: timescale) else { throw invalidMovie }
        let ticks = UInt64(try schedule.duration.roundedToSamples(Int(timescale)))
        var timeTable = Data(repeating: 0, count: 4)
        timeTable.appendInteger(UInt32(schedule.runs.count))
        for run in schedule.runs {
            timeTable.appendInteger(UInt32(run.count))
            timeTable.appendInteger(UInt32(try run.duration.roundedToSamples(Int(timescale))))
        }

        func patch(_ data: Data, at path: [String]) throws -> Data {
            let parts = try children(of: data)
            if let required = ["moov": "trak", "trak": "mdia", "mdia": "minf", "minf": "stbl", "stbl": "stts"][path[path.count - 1]] {
                _ = try only(required, in: parts)
            }
            var result = Data()
            for part in parts {
                var payload = part.data
                let location = path + [part.type]
                switch location {
                case ["moov", "trak"], ["moov", "trak", "mdia"], ["moov", "trak", "mdia", "minf"],
                     ["moov", "trak", "mdia", "minf", "stbl"]:
                    payload = try patch(payload, at: location)
                case ["moov", "mvhd"], ["moov", "trak", "mdia", "mdhd"]:
                    let clock = try movieClock(payload)
                    guard clock.rate == timescale else { throw invalidMovie }
                    try setDuration(&payload, after: clock.durationField, wide: clock.wide, value: ticks)
                case ["moov", "trak", "tkhd"]:
                    let wide = try isWide(payload)
                    try setDuration(&payload, after: wide ? 28 : 20, wide: wide, value: ticks)
                case ["moov", "trak", "mdia", "minf", "stbl", "stts"]:
                    guard payload.count == 16, try payload.integer(UInt32.self, at: 4) == 1,
                          try payload.integer(UInt32.self, at: 8) == schedule.count else { throw invalidMovie }
                    payload = timeTable
                case ["moov", "trak", "edts"], ["moov", "trak", "mdia", "minf", "stbl", "ctts"]:
                    throw invalidMovie
                default:
                    break
                }
                result.append(try box(part.type, payload))
            }
            return result
        }

        let movie = try box("moov", patch(lane.movie, at: ["moov"]))
        let writer = try FileHandle(forWritingTo: url)
        defer { try? writer.close() }
        try writer.seek(toOffset: lane.movieBox.offset)
        try writer.write(contentsOf: movie)
        try writer.truncate(atOffset: lane.movieBox.offset + UInt64(movie.count))
        try writer.close()
    }

    private static var invalidMovie: CutError {
        CutError(code: "write_failed", message: "The staged video or audio movie has an unsupported track or media layout.")
    }

    private static func merge(lanes: [Lane], starts: [UInt64], audioAlternatesFrom: Int?) throws -> Data {
        let parts = try lanes.map { try children(of: $0.movie) }
        let headers = try parts.map { try only("mvhd", in: $0) }
        let clocks = try headers.map { try movieClock($0.data) }
        func commonClock(_ rates: [UInt32]) -> UInt32? {
            var scale: UInt64 = 1
            for rate in rates {
                scale = scale / gcd(scale, UInt64(rate)) * UInt64(rate)
                guard scale <= Int32.max else { return nil }
            }
            return UInt32(scale)
        }
        let rate: UInt32
        if let fullClock = commonClock(clocks.map(\.rate)) {
            rate = fullClock
        } else {
            // Only durations in track headers and edit lists use the movie clock.
            // Their reduced denominators may fit even when the original clocks do not.
            let reduced = try zip(parts, clocks).map { entries, clock in
                try requiredClock(for: entries, movieRate: clock.rate)
            }
            guard let exactClock = commonClock(reduced) else {
                throw incompatibleClocks
            }
            rate = exactClock
        }
        var duration: UInt64 = 0
        var nextID: UInt32 = 1
        var tracks = Data()
        for index in lanes.indices {
            let entries = parts[index].filter { $0.type == "trak" }
            guard !entries.isEmpty else { throw invalidMovie }
            let enabledInAlternateGroup: Bool?
            if let first = audioAlternatesFrom, index >= first {
                guard entries.count == 1 else { throw invalidMovie }
                enabledInAlternateGroup = index == first
            } else {
                enabledInAlternateGroup = nil
            }
            var ids: [UInt32: UInt32] = [:]
            for entry in entries {
                let trackHeader = try only("tkhd", in: children(of: entry.data))
                let id = try trackHeader.data.integer(UInt32.self, at: isWide(trackHeader.data) ? 20 : 12)
                guard ids.updateValue(nextID, forKey: id) == nil, nextID < UInt32.max else { throw invalidMovie }
                nextID += 1
            }
            for entry in entries {
                let track = try relocate(entry.data, lane: lanes[index], destination: starts[index],
                                         ids: ids, from: clocks[index].rate, to: rate, enabledInAlternateGroup: enabledInAlternateGroup)
                duration = max(duration, track.duration)
                tracks.append(try box("trak", track.data))
            }
        }
        var header = headers[0].data
        let clock = clocks[0]
        header.setInteger(rate, at: clock.durationField - 4)
        try setDuration(&header, after: clock.durationField, wide: clock.wide, value: duration)
        guard header.count >= 4 else { throw invalidMovie }
        header.setInteger(nextID, at: header.count - 4)
        var payload = try box("mvhd", header)
        payload.append(tracks)
        for element in parts[0] where ["udta", "meta"].contains(element.type) {
            payload.append(try box(element.type, element.data))
        }
        return try box("moov", payload)
    }

    private static func requiredClock(for entries: [Child], movieRate: UInt32) throws -> UInt32 {
        var divisor = UInt64(movieRate)
        for entry in entries where entry.type == "trak" {
            let track = try children(of: entry.data)
            let header = try only("tkhd", in: track).data
            let wide = try isWide(header)
            divisor = gcd(divisor, try readDuration(header, at: wide ? 28 : 20, wide: wide))
            for edits in track where edits.type == "edts" {
                let list = try only("elst", in: children(of: edits.data)).data
                let table = try editTable(list)
                for index in 0..<table.count {
                    let duration = try readDuration(list, at: 8 + index * table.stride, wide: table.wide)
                    divisor = gcd(divisor, duration)
                }
            }
        }
        return movieRate / UInt32(divisor)
    }

    private static func gcd(_ first: UInt64, _ second: UInt64) -> UInt64 {
        var a = first
        var b = second
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }

    private static func editTable(_ data: Data) throws -> (wide: Bool, width: Int, stride: Int, count: Int) {
        let wide = try isWide(data)
        let width = wide ? 8 : 4
        let stride = 2 * width + 4
        let count = Int(try data.integer(UInt32.self, at: 4))
        guard count == (data.count - 8) / stride, (data.count - 8).isMultiple(of: stride) else { throw invalidMovie }
        return (wide, width, stride, count)
    }

    private static func relocate(_ track: Data, lane: Lane, destination: UInt64, ids: [UInt32: UInt32],
                                 from oldRate: UInt32, to newRate: UInt32, enabledInAlternateGroup: Bool?) throws -> (data: Data, duration: UInt64) {
        var duration: UInt64?
        func transform(_ type: String, data: Data) throws -> Data {
            switch type {
            case "tkhd":
                let wide = try isWide(data)
                let idField = wide ? 20 : 12
                let durationField = idField + 8
                let converted = try rescale(readDuration(data, at: durationField, wide: wide), from: oldRate, to: newRate)
                var patched = data
                let oldID = try data.integer(UInt32.self, at: idField)
                guard let id = ids[oldID] else { throw invalidMovie }
                patched.setInteger(id, at: idField)
                if let enabledInAlternateGroup {
                    let alternateGroupField = wide ? 46 : 34
                    guard patched.count >= alternateGroupField + 2 else { throw invalidMovie }
                    patched.setInteger(UInt16(1), at: alternateGroupField)
                    if enabledInAlternateGroup { patched[3] |= 1 }
                    else { patched[3] &= ~UInt8(1) }
                }
                try setDuration(&patched, after: durationField, wide: wide, value: converted)
                duration = converted
                return try box(type, patched)
            case "tref":
                var references = Data()
                for reference in try children(of: data) {
                    guard reference.data.count.isMultiple(of: 4) else { throw invalidMovie }
                    var body = Data()
                    for offset in stride(from: 0, to: reference.data.count, by: 4) {
                        let oldID = try reference.data.integer(UInt32.self, at: offset)
                        guard let id = ids[oldID] else { throw invalidMovie }
                        body.appendInteger(id)
                    }
                    references.append(try box(reference.type, body))
                }
                return try box(type, references)
            case "mdia", "minf", "stbl", "edts":
                var rebuilt = Data()
                for child in try children(of: data) {
                    rebuilt.append(try transform(child.type, data: child.data))
                }
                return try box(type, rebuilt)
            case "elst" where oldRate != newRate:
                let (wide, width, stride, count) = try editTable(data)
                var edited = Data(data.prefix(8))
                edited[0] = 1
                for index in 0..<count {
                    let position = 8 + index * stride
                    let length = try rescale(readDuration(data, at: position, wide: wide), from: oldRate, to: newRate)
                    edited.appendInteger(length)
                    let media = try readDuration(data, at: position + width, wide: wide)
                    let signed = wide ? media : UInt64(bitPattern: Int64(Int32(bitPattern: UInt32(media))))
                    edited.appendInteger(signed)
                    edited.appendInteger(try data.integer(UInt32.self, at: position + 2 * width))
                }
                return try box(type, edited)
            case "stco", "co64":
                let width = type == "stco" ? 4 : 8
                let entries = Int(try data.integer(UInt32.self, at: 4))
                guard entries == (data.count - 8) / width, (data.count - 8).isMultiple(of: width) else { throw invalidMovie }
                let needsWideOffsets = width == 8 || destination + lane.media.contentSize > UInt32.max
                var offsets = Data(data.prefix(8))
                offsets.reserveCapacity(8 + entries * (needsWideOffsets ? 8 : 4))
                for index in 0..<entries {
                    let original = try readDuration(data, at: 8 + index * width, wide: width == 8)
                    guard original >= lane.media.contentOffset,
                          original - lane.media.contentOffset < lane.media.contentSize else { throw invalidMovie }
                    let adjusted = destination + (original - lane.media.contentOffset)
                    if needsWideOffsets { offsets.appendInteger(adjusted) }
                    else { offsets.appendInteger(UInt32(adjusted)) }
                }
                return try box(needsWideOffsets ? "co64" : "stco", offsets)
            default:
                return try box(type, data)
            }
        }

        var content = Data()
        for child in try children(of: track) {
            content.append(try transform(child.type, data: child.data))
        }
        guard let duration else { throw invalidMovie }
        return (content, duration)
    }

    private static func movieClock(_ data: Data) throws -> (rate: UInt32, durationField: Int, wide: Bool) {
        let wide = try isWide(data)
        let scaleField = wide ? 20 : 12
        let rate = try data.integer(UInt32.self, at: scaleField)
        guard rate > 0 else { throw invalidMovie }
        return (rate, scaleField + 4, wide)
    }

    private static func rescale(_ number: UInt64, from: UInt32, to: UInt32) throws -> UInt64 {
        if from == to { return number }
        let product = number.multipliedFullWidth(by: UInt64(to))
        guard product.high < UInt64(from) else { throw invalidMovie }
        let (quotient, remainder) = UInt64(from).dividingFullWidth(product)
        guard remainder == 0 else { throw incompatibleClocks }
        return quotient
    }

    private static var incompatibleClocks: CutError {
        CutError(code: "unsupported_container", message: "The staged picture and sound use incompatible MOV presentation clocks.")
    }

    private static func isWide(_ data: Data) throws -> Bool {
        guard let version = data.first, version <= 1 else { throw invalidMovie }
        return version == 1
    }

    private static func readDuration(_ data: Data, at index: Int, wide: Bool) throws -> UInt64 {
        if wide { return try data.integer(UInt64.self, at: index) }
        return UInt64(try data.integer(UInt32.self, at: index))
    }

    private static func setDuration(_ data: inout Data, after index: Int, wide: Bool, value: UInt64) throws {
        if wide {
            guard data.count >= index + 8 else { throw invalidMovie }
            data.setInteger(value, at: index)
        } else if let narrow = UInt32(exactly: value) {
            guard data.count >= index + 4 else { throw invalidMovie }
            data.setInteger(narrow, at: index)
        } else {
            // Version 1 widens creation and modification timestamps along with duration.
            var upgraded = Data(data.prefix(4))
            upgraded[0] = 1
            upgraded.appendInteger(UInt64(try data.integer(UInt32.self, at: 4)))
            upgraded.appendInteger(UInt64(try data.integer(UInt32.self, at: 8)))
            upgraded.append(data[12..<index])
            upgraded.appendInteger(value)
            upgraded.append(data.dropFirst(index + 4))
            data = upgraded
        }
    }

    private struct FileBox {
        let type: String
        let offset: UInt64
        let size: UInt64
        let header: UInt64
        var contentOffset: UInt64 { offset + header }
        var contentSize: UInt64 { size - header }
    }

    private struct Child {
        let type: String
        let data: Data
    }

    private static func only(_ type: String, in children: [Child]) throws -> Child {
        let matches = children.filter { $0.type == type }
        guard matches.count == 1, let value = matches.first else { throw invalidMovie }
        return value
    }

    private static func children(of data: Data) throws -> [Child] {
        var children: [Child] = []
        var cursor = 0
        while cursor < data.count {
            let end = min(cursor + 16, data.count)
            let entry = try parse(Data(data[cursor..<end]), offset: UInt64(cursor), limit: UInt64(data.count))
            children.append(Child(type: entry.type, data: Data(data[Int(entry.contentOffset)..<Int(entry.offset + entry.size)])))
            cursor += Int(entry.size)
        }
        return children
    }

    private static func box(_ type: String, _ data: Data) throws -> Data {
        guard let size = UInt32(exactly: data.count + 8) else { throw invalidMovie }
        var value = Data()
        value.reserveCapacity(Int(size))
        value.appendInteger(size)
        value.append(contentsOf: type.utf8)
        value.append(data)
        return value
    }

    private static func parse(_ bytes: Data, offset: UInt64, limit: UInt64) throws -> FileBox {
        let narrow = try bytes.integer(UInt32.self, at: 0)
        guard bytes.count >= 8 else { throw invalidMovie }
        let name = String(decoding: bytes[4..<8], as: Unicode.ASCII.self)
        let header: UInt64 = narrow == 1 ? 16 : 8
        let size = narrow == 1 ? try bytes.integer(UInt64.self, at: 8) : narrow == 0 ? limit - offset : UInt64(narrow)
        guard size >= header, size <= limit - offset, name.utf8.count == 4 else { throw invalidMovie }
        return FileBox(type: name, offset: offset, size: size, header: header)
    }

    private struct Lane {
        let file: FileHandle
        let fileType: FileBox
        let media: FileBox
        let movie: Data
        let movieBox: FileBox

        init(_ url: URL) throws {
            let handle = try FileHandle(forReadingFrom: url)
            let length = try handle.seekToEnd()
            var offset: UInt64 = 0
            var boxes: [String: FileBox] = [:]
            while offset < length {
                try handle.seek(toOffset: offset)
                let count = Int(min(16, length - offset))
                guard let data = try handle.read(upToCount: count), data.count == count else { throw invalidMovie }
                let entry = try parse(data, offset: offset, limit: length)
                switch entry.type {
                case "ftyp", "moov", "mdat":
                    guard boxes.updateValue(entry, forKey: entry.type) == nil else { throw invalidMovie }
                case "wide", "free", "skip": break
                default: throw invalidMovie
                }
                offset += entry.size
            }
            guard let fileType = boxes["ftyp"], fileType.size <= 4096,
                  let media = boxes["mdat"], media.contentSize > 0,
                  let movie = boxes["moov"], movie.contentSize <= UInt32.max else { throw invalidMovie }
            file = handle
            self.fileType = fileType
            self.media = media
            movieBox = movie
            try handle.seek(toOffset: movie.contentOffset)
            guard let content = try handle.read(upToCount: Int(movie.contentSize)), content.count == Int(movie.contentSize) else {
                throw invalidMovie
            }
            self.movie = content
        }

        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            try file.seek(toOffset: offset)
            guard let value = try file.read(upToCount: count), value.count == count else { throw invalidMovie }
            return value
        }
    }
}

private extension Data {
    func integer<T: FixedWidthInteger>(_ type: T.Type, at index: Int) throws -> T {
        guard index >= 0, index <= count - MemoryLayout<T>.size else {
            throw CutError(code: "write_failed", message: "The staged movie contains a truncated atom.")
        }
        return withUnsafeBytes { T(bigEndian: $0.loadUnaligned(fromByteOffset: index, as: type)) }
    }

    mutating func setInteger<T: FixedWidthInteger>(_ value: T, at index: Int) {
        var encoded = value.bigEndian
        Swift.withUnsafeBytes(of: &encoded) { replaceSubrange(index..<(index + $0.count), with: $0) }
    }

    mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        var encoded = value.bigEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }
}
