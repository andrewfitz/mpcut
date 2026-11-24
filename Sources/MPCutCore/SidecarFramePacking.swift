import Foundation

/// A frame row is its flags, presentation time, decode time when that differs, duration
/// and size. In presentation order a time is normally the previous time plus the previous
/// duration, the duration repeats, and a reordered frame is decoded a whole number of
/// durations before it is shown. Such a row keeps only its flags and size. The three flag
/// bits a row never sets mark a field kept as its original bytes instead: the first row,
/// a discontinuity, a changing frame rate, or a spelling the prediction would not write.
/// Each kind of field has its own column, which lets the general compressor model the
/// periodic flags and the high size bytes apart from the unpredictable low ones.
enum SidecarFramePacking {
    private static let explicitTime: UInt8 = 0x80
    private static let explicitDuration: UInt8 = 0x40
    private static let explicitDecodeTime: UInt8 = 0x20
    private static let rowFlags: UInt8 = 0x1f
    // Flags, a two-byte time, a two-byte duration and a size.
    private static let minimumRowBytes = 6

    private static func lead(of decodeTime: RationalTime, before time: RationalTime, duration: RationalTime) -> Int64? {
        guard duration > .zero, let gap = try? time.subtracting(decodeTime) else { return nil }
        let count = (gap.seconds / duration.seconds).rounded()
        // Also false for a quotient that is not a number.
        guard count.magnitude <= 1_000_000 else { return nil }
        return Int64(count)
    }

    private static func decodeTime(_ time: RationalTime, lead: Int64, duration: RationalTime) -> RationalTime? {
        guard let offset = try? duration.multiplied(by: RationalTime(numerator: lead)) else { return nil }
        return try? time.subtracting(offset)
    }

    /// The row count and the lengths of the kept fields and decode leads, then one control
    /// byte per row, the kept fields, the leads, each size's low byte, and the rest of each size.
    static func pack(_ data: Data, cancelled: () -> Bool) throws -> Data? {
        let packed: Data? = try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var input = PackedReader(bytes)
            var controls: [UInt8] = []
            var kept: [UInt8] = []
            var sizeLow: [UInt8] = []
            var leads = PackedWriter()
            var sizeHigh = PackedWriter()
            var prediction = PackedWriter()
            var previous: (time: RationalTime, duration: RationalTime)?
            func matches(_ value: RationalTime?, _ range: Range<Int>) -> Bool {
                guard let value else { return false }
                prediction.bytes.removeAll(keepingCapacity: true)
                prediction.time(value)
                return bytes[range].elementsEqual(prediction.bytes)
            }
            do {
                while input.remaining > 0 {
                    if controls.count.isMultiple(of: 1024) { try checkSidecarCancellation(cancelled) }
                    let flags = try input.byte()
                    guard flags & ~rowFlags == 0, flags & 3 != 3 else { return nil }
                    var control = flags
                    let timeStart = input.position
                    let time = try input.time()
                    let decodeStart = input.position
                    var decoded: RationalTime?
                    if flags & 3 == 2 { decoded = try input.time() }
                    let durationStart = input.position
                    let duration = try input.time()
                    let durationEnd = input.position
                    let size = try input.unsigned()

                    let expected = previous.flatMap { try? $0.time.adding($0.duration) }
                    if !matches(expected, timeStart..<decodeStart) {
                        control |= explicitTime
                        kept.append(contentsOf: bytes[timeStart..<decodeStart])
                    }
                    if let decoded {
                        if let ahead = Self.lead(of: decoded, before: time, duration: duration),
                           matches(Self.decodeTime(time, lead: ahead, duration: duration), decodeStart..<durationStart) {
                            leads.signed(ahead)
                        } else {
                            control |= explicitDecodeTime
                            kept.append(contentsOf: bytes[decodeStart..<durationStart])
                        }
                    }
                    if !matches(previous?.duration, durationStart..<durationEnd) {
                        control |= explicitDuration
                        kept.append(contentsOf: bytes[durationStart..<durationEnd])
                    }
                    controls.append(control)
                    sizeLow.append(UInt8(truncatingIfNeeded: size))
                    sizeHigh.unsigned(size >> 8)
                    previous = (time, duration)
                }
            } catch is PackedCodingError {
                return nil
            }
            guard !controls.isEmpty else { return nil }
            var output = PackedWriter()
            output.unsigned(UInt64(controls.count))
            output.unsigned(UInt64(kept.count))
            output.unsigned(UInt64(leads.bytes.count))
            let size = output.bytes.count + 2 * controls.count + kept.count + leads.bytes.count + sizeHigh.bytes.count
            guard size < bytes.count else { return nil }
            output.bytes.reserveCapacity(size)
            output.bytes += controls
            output.bytes += kept
            output.bytes += leads.bytes
            output.bytes += sizeLow
            output.bytes += sizeHigh.bytes
            return Data(output.bytes)
        }
        // A size written with spare continuation bytes parses but would not be rebuilt.
        guard let packed, try unpack(packed, logicalSize: data.count, cancelled: cancelled) == data else { return nil }
        return packed
    }

    static func unpack(_ data: Data, logicalSize: Int, cancelled: () -> Bool) throws -> Data? {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            do {
                var header = PackedReader(bytes)
                let rows = try header.count(minimumBytes: 2)
                let keptCount = try header.count()
                let leadCount = try header.count()
                guard rows > 0, rows <= logicalSize / minimumRowBytes else { return nil }
                let controls = try header.slice(rows)
                var kept = PackedReader(try header.slice(keptCount))
                var leads = PackedReader(try header.slice(leadCount))
                let sizeLow = try header.slice(rows)
                var sizeHigh = PackedReader(try header.slice(header.remaining))
                var output = PackedWriter()
                output.bytes.reserveCapacity(min(logicalSize, 8 << 20))
                var previous: (time: RationalTime, duration: RationalTime)?
                for row in 0..<rows {
                    if row.isMultiple(of: 1024) { try checkSidecarCancellation(cancelled) }
                    let control = controls[row]
                    let reordered = control & 3 == 2
                    guard control & 3 != 3, reordered || control & explicitDecodeTime == 0 else { return nil }
                    output.bytes.append(control & rowFlags)
                    let time: RationalTime
                    if control & explicitTime != 0 {
                        let start = kept.position
                        time = try kept.time()
                        output.bytes.append(contentsOf: kept.bytes[start..<kept.position])
                    } else {
                        guard let previous, let next = try? previous.time.adding(previous.duration) else { return nil }
                        time = next
                        output.time(time)
                    }
                    if control & explicitDecodeTime != 0 {
                        let start = kept.position
                        _ = try kept.time()
                        output.bytes.append(contentsOf: kept.bytes[start..<kept.position])
                    }
                    // A predicted decode time counts in this row's duration, which follows it.
                    let duration: RationalTime
                    let durationStart = kept.position
                    if control & explicitDuration != 0 {
                        duration = try kept.time()
                    } else {
                        guard let previous else { return nil }
                        duration = previous.duration
                    }
                    if reordered, control & explicitDecodeTime == 0 {
                        let ahead = try leads.signed()
                        guard let decoded = Self.decodeTime(time, lead: ahead, duration: duration) else { return nil }
                        output.time(decoded)
                    }
                    if control & explicitDuration != 0 {
                        output.bytes.append(contentsOf: kept.bytes[durationStart..<kept.position])
                    } else {
                        output.time(duration)
                    }
                    let high = try sizeHigh.unsigned()
                    guard high <= UInt64.max >> 8 else { return nil }
                    output.unsigned(high << 8 | UInt64(sizeLow[row]))
                    guard output.bytes.count <= logicalSize else { return nil }
                    previous = (time, duration)
                }
                guard kept.remaining == 0, leads.remaining == 0, sizeHigh.remaining == 0,
                      output.bytes.count == logicalSize else { return nil }
                return Data(output.bytes)
            } catch is PackedCodingError {
                return nil
            }
        }
    }
}
