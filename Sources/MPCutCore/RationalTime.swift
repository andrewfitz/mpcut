import Foundation

public struct RationalTime: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let numerator: Int64
    public let denominator: Int64

    public init(numerator: Int64, denominator: Int64 = 1) {
        precondition(denominator > 0, "Time denominator must be positive")
        let divisor = Int64(Self.gcd(numerator.magnitude, UInt64(denominator)))
        self.numerator = numerator / divisor
        self.denominator = denominator / divisor
    }

    // Arithmetic and parsing can prove coprimality before constructing the result.
    private init(reducedNumerator: Int64, denominator: Int64) {
        self.numerator = reducedNumerator
        self.denominator = denominator
    }

    public static let zero = Self(numerator: 0)
    public var seconds: Double { Double(numerator) / Double(denominator) }
    public var description: String {
        denominator == 1 ? String(numerator) : "\(numerator)/\(denominator)"
    }

    public init(parsing input: String) throws {
        var invalid: CutError { CutError(code: "invalid_time", message: "Invalid timestamp ‘\(input)’") }
        let negative = input.first == "-"
        let unsigned = negative || input.first == "+" ? input.dropFirst() : input[...]
        guard !unsigned.isEmpty else { throw invalid }
        func digits(_ value: Substring) -> UInt64? {
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return UInt64(value)
        }
        let ratio = unsigned.split(separator: "/", omittingEmptySubsequences: false)
        if ratio.count == 2, let top = digits(ratio[0]), let bottom = digits(ratio[1]), bottom > 0 {
            guard let result = Self.reduced((0, top), denominator: bottom, negative: negative) else {
                throw invalid
            }
            self = result
            return
        }
        guard ratio.count == 1 else { throw invalid }
        let clock = unsigned.split(separator: ":", omittingEmptySubsequences: false)
        guard clock.count <= 3, let last = clock.last, !last.isEmpty else { throw invalid }
        let decimal = last.split(separator: ".", omittingEmptySubsequences: false)
        guard decimal.count <= 2 else { throw invalid }
        let wholePart = decimal[0].isEmpty && decimal.count == 2 && clock.count == 1 ? 0 : digits(decimal[0])
        guard var whole = wholePart else { throw invalid }
        if clock.count >= 2 {
            guard let minutes = digits(clock[clock.count - 2]), whole < 60 else { throw invalid }
            let (minuteSeconds, minutesOverflow) = minutes.multipliedReportingOverflow(by: 60)
            let (total, sumOverflow) = minuteSeconds.addingReportingOverflow(whole)
            guard !minutesOverflow, !sumOverflow else { throw invalid }
            whole = total
            if clock.count == 3 {
                guard let hours = digits(clock[0]), minutes < 60 else { throw invalid }
                let (hourSeconds, hoursOverflow) = hours.multipliedReportingOverflow(by: 3_600)
                let (total, sumOverflow) = hourSeconds.addingReportingOverflow(whole)
                guard !hoursOverflow, !sumOverflow else { throw invalid }
                whole = total
            }
        }
        var scale: UInt64 = 1
        var fraction: UInt64 = 0
        if decimal.count == 2 {
            guard !decimal[1].isEmpty, decimal[1].utf8.allSatisfy({ (48...57).contains($0) }) else {
                throw invalid
            }
            for digit in decimal[1].utf8.reversed() {
                // Moving the decimal point preserves coprimality with the current denominator.
                // Only factors of ten can cancel from the new denominator.
                let digitPart = UInt64(digit - 48).multipliedFullWidth(by: scale)
                let (low, carry) = digitPart.low.addingReportingOverflow(fraction)
                let combined = (high: digitPart.high + (carry ? 1 : 0), low: low)
                let divisor = Self.gcd(Self.remainder(combined, dividingBy: 10), 10)
                let (denominator, overflow) = scale.multipliedReportingOverflow(by: 10 / divisor)
                guard !overflow, denominator <= UInt64(Int64.max) else { throw invalid }
                fraction = divisor.dividingFullWidth(combined).quotient
                scale = denominator
            }
        }
        let scaled = whole.multipliedFullWidth(by: scale)
        let (low, carry) = scaled.low.addingReportingOverflow(fraction)
        let combined = (high: scaled.high + (carry ? 1 : 0), low: low)
        guard let result = Self.reduced(combined, denominator: scale, negative: negative) else {
            throw invalid
        }
        self = result
    }

    private enum CodingKeys: String, CodingKey { case numerator, denominator }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let numerator = try values.decode(Int64.self, forKey: .numerator)
        let denominator = try values.decode(Int64.self, forKey: .denominator)
        guard denominator > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .denominator, in: values, debugDescription: "Expected positive denominator")
        }
        self.init(numerator: numerator, denominator: denominator)
    }

    public static func < (left: Self, right: Self) -> Bool {
        let lhs = left.numerator.multipliedFullWidth(by: right.denominator)
        let rhs = right.numerator.multipliedFullWidth(by: left.denominator)
        return lhs.high == rhs.high ? lhs.low < rhs.low : lhs.high < rhs.high
    }

    public static func + (left: Self, right: Self) -> Self {
        try! left.adding(right)
    }

    public static func - (left: Self, right: Self) -> Self {
        try! left.subtracting(right)
    }

    public static func * (left: Self, right: Self) -> Self {
        try! left.multiplied(by: right)
    }

    public func adding(_ other: Self) throws -> Self {
        if numerator == 0 { return other }
        return try combining(other, subtract: false)
    }

    public func subtracting(_ other: Self) throws -> Self {
        try combining(other, subtract: true)
    }

    public func multiplied(by other: Self) throws -> Self {
        let crossLeft = Int64(Self.gcd(numerator.magnitude, UInt64(other.denominator)))
        let crossRight = Int64(Self.gcd(other.numerator.magnitude, UInt64(denominator)))
        let (top, numeratorOverflow) = (numerator / crossLeft).multipliedReportingOverflow(by: other.numerator / crossRight)
        let (bottom, denominatorOverflow) = (denominator / crossRight).multipliedReportingOverflow(by: other.denominator / crossLeft)
        guard !numeratorOverflow, !denominatorOverflow else { throw Self.overflow }
        return Self(reducedNumerator: top, denominator: bottom)
    }

    private func combining(_ other: Self, subtract: Bool) throws -> Self {
        if other.numerator == 0 { return self }
        if denominator == other.denominator {
            let (top, overflow) = subtract ? numerator.subtractingReportingOverflow(other.numerator)
                                           : numerator.addingReportingOverflow(other.numerator)
            if !overflow { return Self(numerator: top, denominator: denominator) }
            // A wide sum can still fit after reducing the shared denominator.
        }
        let common = Self.gcd(UInt64(denominator), UInt64(other.denominator))
        let leftScale = other.denominator / Int64(common)
        let rightScale = denominator / Int64(common)
        let left = numerator.multipliedFullWidth(by: leftScale)
        let right = other.numerator.multipliedFullWidth(by: rightScale)
        let sum: (high: Int64, low: UInt64)
        if subtract {
            sum = Self.difference(left, right)
        } else {
            let (low, carry) = left.low.addingReportingOverflow(right.low)
            sum = (left.high &+ right.high &+ (carry ? 1 : 0), low)
        }
        let magnitude = Self.magnitude(sum)
        // Reduced inputs leave only factors of the original shared denominator available for cancellation.
        let divisor = Self.gcd(Self.remainder(magnitude, dividingBy: common), common)
        let (bottom, overflow) = (denominator / Int64(divisor)).multipliedReportingOverflow(by: leftScale)
        guard !overflow, let top = Self.quotient(magnitude, dividingBy: divisor, negative: sum.high < 0) else {
            throw Self.overflow
        }
        return Self(reducedNumerator: top, denominator: bottom)
    }

    func isCloserToEarlier(_ earlier: Self, than later: Self) -> Bool {
        if self <= earlier { return true }
        if self >= later { return false }

        let before = Self.magnitude(Self.difference(
            numerator.multipliedFullWidth(by: earlier.denominator),
            earlier.numerator.multipliedFullWidth(by: denominator)))
        let after = Self.magnitude(Self.difference(
            later.numerator.multipliedFullWidth(by: denominator),
            numerator.multipliedFullWidth(by: later.denominator)))
        // The request denominator cancels when comparing the two distances.
        return Self.product(before, UInt64(later.denominator)) <= Self.product(after, UInt64(earlier.denominator))
    }

    /// Floor the fraction of a positive duration to a whole percent on the source clock.
    func wholePercent(of duration: Self) -> Int {
        guard self > .zero, duration > .zero else { return 0 }
        guard self < duration else { return 100 }
        let elapsed = UInt64(numerator).multipliedFullWidth(by: UInt64(duration.denominator))
        let total = UInt64(duration.numerator).multipliedFullWidth(by: UInt64(denominator))
        if elapsed.high == 0, total.high == 0, elapsed.low <= UInt64.max / 100 {
            return Int(elapsed.low * 100 / total.low)
        }
        let scaled = Self.product(elapsed, 100)
        var lower = 0
        var upper = 99
        while lower < upper {
            let candidate = (lower + upper + 1) / 2
            if Self.product(total, UInt64(candidate)) <= scaled {
                lower = candidate
            } else {
                upper = candidate - 1
            }
        }
        return lower
    }

    package func roundedToSamples(_ sampleRate: Int) throws -> Int64 {
        let scaled = numerator.multipliedFullWidth(by: Int64(sampleRate))
        let magnitude = Self.magnitude(scaled)
        let divisor = UInt64(denominator)
        guard magnitude.high < divisor else { throw Self.overflow }
        let (whole, remainder) = magnitude.high == 0
            ? magnitude.low.quotientAndRemainder(dividingBy: divisor)
            : divisor.dividingFullWidth(magnitude)
        let (rounded, overflow) = whole.addingReportingOverflow(remainder >= divisor - remainder ? 1 : 0)
        guard !overflow, let result = Self.signed(rounded, negative: scaled.high < 0) else { throw Self.overflow }
        return result
    }

    private typealias WideMagnitude = (high: UInt64, low: UInt64)

    private static var overflow: CutError {
        CutError(code: "time_overflow", message: "Timeline time exceeds the supported rational range")
    }

    private static func reduced(_ top: WideMagnitude, denominator: UInt64, negative: Bool) -> Self? {
        let divisor = gcd(remainder(top, dividingBy: denominator), denominator)
        guard let numerator = quotient(top, dividingBy: divisor, negative: negative),
              let bottom = Int64(exactly: denominator / divisor) else { return nil }
        return Self(reducedNumerator: numerator, denominator: bottom)
    }

    private static func remainder(_ value: WideMagnitude, dividingBy divisor: UInt64) -> UInt64 {
        if value.high == 0 { return value.low % divisor }
        return divisor.dividingFullWidth((value.high % divisor, value.low)).remainder
    }

    private static func quotient(_ value: WideMagnitude, dividingBy divisor: UInt64, negative: Bool) -> Int64? {
        if value.high == 0 { return signed(value.low / divisor, negative: negative) }
        guard value.high < divisor else { return nil }
        return signed(divisor.dividingFullWidth(value).quotient, negative: negative)
    }

    private static func signed(_ magnitude: UInt64, negative: Bool) -> Int64? {
        if negative, magnitude == Int64.min.magnitude { return .min }
        guard let value = Int64(exactly: magnitude) else { return nil }
        return negative ? -value : value
    }

    private static func difference(_ left: (high: Int64, low: UInt64),
                                   _ right: (high: Int64, low: UInt64)) -> (high: Int64, low: UInt64) {
        let (low, borrow) = left.low.subtractingReportingOverflow(right.low)
        return (left.high &- right.high &- (borrow ? 1 : 0), low)
    }

    private static func magnitude(_ value: (high: Int64, low: UInt64)) -> WideMagnitude {
        let absolute = value.high < 0 ? difference((0, 0), value) : value
        return (UInt64(bitPattern: absolute.high), absolute.low)
    }

    private static func product(_ value: WideMagnitude, _ scale: UInt64) -> (UInt64, UInt64, UInt64) {
        let upper = value.high.multipliedFullWidth(by: scale)
        let lower = value.low.multipliedFullWidth(by: scale)
        let (middle, carry) = upper.low.addingReportingOverflow(lower.high)
        return (upper.high + (carry ? 1 : 0), middle, lower.low)
    }

    private static func gcd(_ first: UInt64, _ second: UInt64) -> UInt64 {
        var (left, right) = (first, second)
        while right != 0 { (left, right) = (right, left % right) }
        return left
    }
}
