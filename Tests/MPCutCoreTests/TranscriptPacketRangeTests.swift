import Foundation
@testable import MPCutCore
import XCTest

final class TranscriptPacketRangeTests: XCTestCase {
    private struct Generator {
        var state: UInt64

        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    private func time(_ numerator: Int64, _ denominator: Int64 = 1) -> RationalTime {
        .init(numerator: numerator, denominator: denominator)
    }

    /// Integer sums on a shared clock must give the ranges rational arithmetic gives, for
    /// holes, overlaps, priming, trailing padding, coarse container clocks and shifted sources.
    func testSharedClockRangesEqualRationalArithmetic() throws {
        var generator = Generator(state: 17)
        var shared = 0
        for round in 0..<400 {
            let rate = Int64([8_000, 16_000, 44_100, 48_000][generator.next(4)])
            let clockDenominator = [rate, 1_000, 90_000, 600, rate * 4][generator.next(5)]
            let packetClock = time(1, clockDenominator)
            let coarse = packetClock > time(1, rate)
            let tolerance = coarse ? try packetClock.adding(time(1, rate * 2)) : .zero
            let frame = Int64([960, 1_024, 1_152, 441][generator.next(4)])
            let step = max(1, frame * clockDenominator / rate)
            var cursor = Int64(generator.next(2_000)) - 500
            var packets: [AudioPacket] = []
            for index in 0..<(1 + generator.next(120)) {
                switch generator.next(12) {
                case 0: cursor += Int64(generator.next(5_000))
                case 1: cursor -= Int64(generator.next(Int(step) + 1))
                case 2: cursor += 1
                default: break
                }
                let skip = index == 0 && generator.next(2) == 0 ? generator.next(2_500) : generator.next(15) == 0 ? generator.next(700) : 0
                let discard = generator.next(14) == 0 ? generator.next(900) : 0
                let decoded = generator.next(5) == 0 ? 0 : Int(frame) + (generator.next(9) == 0 ? generator.next(40) - 20 : 0)
                let duration = generator.next(10) == 0 ? time(frame, rate) : time(step, clockDenominator)
                packets.append(AudioPacket(time: time(cursor, clockDenominator), dts: nil, duration: duration,
                                           skipSamples: skip, discardSamples: discard, decodedSamples: decoded))
                cursor += step
            }
            let offset = [RationalTime.zero, time(1, 3), time(5, 2), time(-7, 25), time(36_000), time(1, rate)][generator.next(6)]
            let low = try packets[0].time.adding(offset).adding(time(Int64(generator.next(4_000)) - 1_000, [1_000, rate, 3][generator.next(3)]))
            let high = try low.adding(time(Int64(generator.next(60_000)), [1_000, rate, 7][generator.next(3)]))
            let envelope = MulticamRange(from: low, to: high)
            let skipsFirst = generator.next(4) == 0
            let exact = try TranscriptPacketRanges.exactly(packets, skipsFirst: skipsFirst, sampleClock: false, rate: rate,
                                                           tolerance: tolerance, offset: offset, envelope: envelope)
            if let quick = TranscriptPacketRanges.onSharedClock(packets, skipsFirst: skipsFirst, rate: rate, tolerance: tolerance,
                                                                packetClock: packetClock, offset: offset, envelope: envelope) {
                shared += 1
                XCTAssertEqual(quick, exact, "round \(round)")
            }
            XCTAssertEqual(try TranscriptPacketRanges.ranges(packets, skipsFirst: skipsFirst, sampleClock: false, rate: rate,
                                                             tolerance: tolerance, packetClock: packetClock, offset: offset,
                                                             envelope: envelope), exact, "round \(round)")
        }
        XCTAssertGreaterThan(shared, 350)
    }

    func testTimesOffTheSharedClockOrPastItsRangeUseRationalArithmetic() throws {
        func packet(_ at: RationalTime) -> AudioPacket {
            .init(time: at, dts: nil, duration: time(1_024, 48_000), skipSamples: 0, discardSamples: 0, decodedSamples: 1_024)
        }
        let envelope = MulticamRange(from: .zero, to: time(10))
        func quick(_ packets: [AudioPacket], offset: RationalTime = .zero, envelope: MulticamRange) -> [MulticamRange]? {
            TranscriptPacketRanges.onSharedClock(packets, skipsFirst: false, rate: 48_000, tolerance: .zero,
                                                 packetClock: time(1, 48_000), offset: offset, envelope: envelope)
        }
        XCTAssertEqual(quick([packet(.zero), packet(time(1_024, 48_000))], envelope: envelope),
                       [MulticamRange(from: .zero, to: time(2_048, 48_000))])
        // A seventh of a second is not a whole number of 48 kHz samples.
        XCTAssertNil(quick([packet(.zero), packet(time(1, 7))], envelope: envelope))
        // A time near the end of the integer range does not fit once scaled to the clock.
        XCTAssertNil(quick([packet(time(Int64.max / 2))], envelope: envelope))
        XCTAssertNil(quick([packet(.zero)], offset: time(Int64.max / 3), envelope: envelope))
        let unusual = [packet(.zero), packet(time(1, 7))]
        XCTAssertEqual(try TranscriptPacketRanges.ranges(unusual, skipsFirst: false, sampleClock: false, rate: 48_000,
                                                         tolerance: .zero, packetClock: time(1, 48_000), offset: .zero,
                                                         envelope: envelope),
                       [MulticamRange(from: .zero, to: time(1_024, 48_000)),
                        MulticamRange(from: time(1, 7), to: try time(1, 7).adding(time(1_024, 48_000)))])
    }
}
