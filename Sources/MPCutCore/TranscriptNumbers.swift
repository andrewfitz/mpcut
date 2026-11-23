import Foundation

/// The number functions of ICU, the Unicode library every macOS installs. Foundation's
/// `NumberFormatter` reaches only its default cardinal rules. The library itself carries, for
/// each language, every way of saying a number: ordinals in each gender and case, years,
/// "two hundred and five", and the names of units and currencies. Apple ships the library and
/// not the headers for these calls, so they are looked up when first needed. If one is ever
/// missing, numbers are matched as written.
struct ICUNumbers: @unchecked Sendable {
    typealias Status = UnsafeMutablePointer<Int32>
    typealias Units = UnsafeMutablePointer<UInt16>?
    typealias Open = @convention(c) (Int32, UnsafePointer<UInt16>?, Int32, UnsafePointer<CChar>?, UnsafeMutableRawPointer?, Status) -> OpaquePointer?
    typealias Close = @convention(c) (OpaquePointer?) -> Void
    typealias GetText = @convention(c) (OpaquePointer?, Int32, Units, Int32, Status) -> Int32
    typealias SetText = @convention(c) (OpaquePointer?, Int32, UnsafePointer<UInt16>?, Int32, Status) -> Void
    typealias SetAttribute = @convention(c) (OpaquePointer?, Int32, Int32) -> Void
    typealias Format = @convention(c) (OpaquePointer?, Double, Units, Int32, UnsafeMutableRawPointer?, Status) -> Int32
    typealias Parse = @convention(c) (OpaquePointer?, UnsafePointer<UInt16>?, Int32, UnsafeMutablePointer<Int32>?, Status) -> Double
    typealias OpenSkeleton = @convention(c) (UnsafePointer<UInt16>?, Int32, UnsafePointer<CChar>?, Status) -> OpaquePointer?
    typealias OpenResult = @convention(c) (Status) -> OpaquePointer?
    typealias FormatSkeleton = @convention(c) (OpaquePointer?, Double, OpaquePointer?, Status) -> Void
    typealias ResultText = @convention(c) (OpaquePointer?, Units, Int32, Status) -> Int32

    static let spellOut: Int32 = 5
    static let ordinal: Int32 = 6
    static let defaultRuleSet: Int32 = 6
    static let publicRuleSets: Int32 = 7
    static let lenientParse: Int32 = 19

    static let shared = ICUNumbers()

    let open: Open
    let close: Close
    let getText: GetText
    let setText: SetText
    let setAttribute: SetAttribute
    let format: Format
    let parse: Parse
    let openSkeleton: OpenSkeleton
    let closeSkeleton: Close
    let openResult: OpenResult
    let closeResult: Close
    let formatSkeleton: FormatSkeleton
    let resultText: ResultText

    private init?() {
        guard let library = dlopen("/usr/lib/libicucore.dylib", RTLD_LAZY) else { return nil }
        func find<T>(_ name: String) -> T? {
            dlsym(library, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let open: Open = find("unum_open"), let close: Close = find("unum_close"),
              let getText: GetText = find("unum_getTextAttribute"), let setText: SetText = find("unum_setTextAttribute"),
              let setAttribute: SetAttribute = find("unum_setAttribute"), let format: Format = find("unum_formatDouble"),
              let parse: Parse = find("unum_parseDouble"),
              let openSkeleton: OpenSkeleton = find("unumf_openForSkeletonAndLocale"), let closeSkeleton: Close = find("unumf_close"),
              let openResult: OpenResult = find("unumf_openResult"), let closeResult: Close = find("unumf_closeResult"),
              let formatSkeleton: FormatSkeleton = find("unumf_formatDouble"),
              let resultText: ResultText = find("unumf_resultToString") else { return nil }
        self.open = open
        self.close = close
        self.getText = getText
        self.setText = setText
        self.setAttribute = setAttribute
        self.format = format
        self.parse = parse
        self.openSkeleton = openSkeleton
        self.closeSkeleton = closeSkeleton
        self.openResult = openResult
        self.closeResult = closeResult
        self.formatSkeleton = formatSkeleton
        self.resultText = resultText
    }

    static func text(_ fill: (Units, Int32, Status) -> Int32) -> String {
        var buffer = [UInt16](repeating: 0, count: 192)
        var status: Int32 = 0
        var length = fill(&buffer, Int32(buffer.count), &status)
        if Int(length) > buffer.count {
            buffer = [UInt16](repeating: 0, count: Int(length) + 1)
            status = 0
            length = fill(&buffer, Int32(buffer.count), &status)
        }
        return status > 0 ? "" : String(utf16CodeUnits: buffer, count: Int(max(0, length)))
    }

    /// A number written by a unit or currency pattern, such as "5 percent" or "5.00 US dollars".
    func written(_ value: Double, skeleton: String, locale: String) -> String {
        var status: Int32 = 0
        let units = Array(skeleton.utf16)
        guard let formatter = openSkeleton(units, Int32(units.count), locale, &status), status <= 0 else { return "" }
        defer { closeSkeleton(formatter) }
        guard let result = openResult(&status), status <= 0 else { return "" }
        defer { closeResult(result) }
        formatSkeleton(formatter, value, result, &status)
        guard status <= 0 else { return "" }
        return Self.text { resultText(result, $0, $1, $2) }
    }
}

/// Reads the numbers in a run of transcript words, so a search for "200" finds "two hundred"
/// and the reverse. A recognizer writes the same number as digits on one recording and as words
/// on another, and a person typing a search picks either.
///
/// Nothing here knows a language. The words that can say a number, what a phrase of them is
/// worth, whether it is an ordinal, and what a sign such as "$" or "%" is called all come from
/// ICU's rules for the transcript's language.
final class TranscriptNumberReader: @unchecked Sendable {
    struct Word {
        let text: String
        let tokens: [String]
    }

    /// One number. `key` is equal for every way of writing the same value. An ordinal has its
    /// own key, so "second" is "2nd" and never "two".
    struct Run: Equatable {
        let words: Range<Int>
        let key: String
        var symbol: Character?
        /// Other numbers the same words can be read as. "thirty second" is the 32nd, and in
        /// "a thirty second clip" it is 30. "three thirty" is 330, and it is 3 and 30.
        var parts: [Part] = []
    }

    struct Part: Equatable {
        let words: Range<Int>
        let key: String
    }

    private struct RuleSet {
        let name: String
        let ordinal: Bool
    }

    private struct Reading {
        let value: Double
        let ordinal: Bool
    }

    private struct Literal {
        var value: Decimal
        var ordinal = false
        var symbol: Character?
        /// "21." is the 21st in German and can also end a sentence on a plain 21.
        var alsoCardinal = false
    }

    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var readers: [String: TranscriptNumberReader?] = [:]
    }

    private static let registry = Registry()

    /// The reader for a language, built once for the process. Nil when the system library
    /// cannot read number words.
    static func shared(language: String) -> TranscriptNumberReader? {
        let identifier = language.replacingOccurrences(of: "-", with: "_")
        registry.lock.lock()
        defer { registry.lock.unlock() }
        if let known = registry.readers[identifier] { return known }
        let reader = ICUNumbers.shared.flatMap { TranscriptNumberReader(locale: identifier, icu: $0) }
        registry.readers[identifier] = .some(reader)
        return reader
    }

    private static let cacheLimit = 16_384
    private static let longestRun = 12

    private let icu: ICUNumbers
    private let locale: String
    private let lock = NSLock()
    private let parser: OpaquePointer
    private let speller: OpaquePointer
    private let ruleSets: [RuleSet]
    private let ordinalDigits: OpaquePointer?
    private let ordinalDigitSets: [String]
    private let decimal: NumberFormatter
    private let grouping: Character?
    /// Each part of a spoken number, by its search token, as the rules spell it.
    private let morphemes: [String: String]
    private let longestMorpheme: Int
    private let one: String
    /// The rule set that says a plain count.
    private let base: String?
    private var spelledSet: String?
    private var ordinalDigitSet: String?
    private var spellings: [String: String?] = [:]
    private var parses: [String: (value: Double, consumed: Int)?] = [:]
    private var readings: [String: Reading?] = [:]
    private var literals: [String: Literal?] = [:]
    private var stretches: [String: [Run]] = [:]
    private var signNames: [Character: Set<[String]>]?

    private init?(locale: String, icu: ICUNumbers) {
        var status: Int32 = 0
        guard let parser = icu.open(ICUNumbers.spellOut, nil, 0, locale, nil, &status), status <= 0,
              let speller = icu.open(ICUNumbers.spellOut, nil, 0, locale, nil, &status), status <= 0 else { return nil }
        // Strict parsing reads "twenty one" as 2001. Lenient parsing reads what people say.
        icu.setAttribute(parser, ICUNumbers.lenientParse, 1)
        self.icu = icu
        self.locale = locale
        self.parser = parser
        self.speller = speller
        func sets(_ formatter: OpaquePointer) -> [String] {
            ICUNumbers.text { icu.getText(formatter, ICUNumbers.publicRuleSets, $0, $1, $2) }
                .split(separator: ";").map(String.init)
        }
        ruleSets = sets(speller).map { .init(name: $0, ordinal: $0.contains("ordinal")) }
        ordinalDigits = icu.open(ICUNumbers.ordinal, nil, 0, locale, nil, &status)
        ordinalDigitSets = ordinalDigits.map(sets) ?? []
        let decimal = NumberFormatter()
        decimal.locale = Locale(identifier: locale)
        decimal.numberStyle = .decimal
        decimal.generatesDecimalNumbers = true
        self.decimal = decimal
        grouping = decimal.groupingSeparator.count == 1 ? decimal.groupingSeparator.first : nil

        func choose(_ set: String) {
            let units = Array(set.utf16)
            var status: Int32 = 0
            icu.setText(speller, ICUNumbers.defaultRuleSet, units, Int32(units.count), &status)
        }
        func spell(_ value: Double) -> String {
            ICUNumbers.text { icu.format(speller, value, $0, $1, nil, $2) }
        }
        // Every word a number is built from appears in one of these values.
        var sample = (0...100).map(Double.init) + stride(from: 200.0, through: 900, by: 100)
        for scale in [1e3, 1e6, 1e9, 1e12] { sample += [scale, 2 * scale, 5 * scale] }
        sample += [1100, 1905, 1999, 2005]
        var morphemes: [String: String] = [:]
        for set in ruleSets {
            choose(set.name)
            for value in sample + (set.ordinal ? [] : [0.5, 1.5]) {
                for part in Self.parts(spell(value)) where !part.isEmpty {
                    let token = TranscriptIndex.tokens(part).joined()
                    if !token.isEmpty, morphemes[token] == nil { morphemes[token] = part }
                }
            }
        }
        guard !morphemes.isEmpty else { return nil }
        self.morphemes = morphemes
        longestMorpheme = morphemes.keys.map(\.count).max() ?? 0
        base = ruleSets.first { !$0.ordinal && !$0.name.contains("year") }?.name
        if let base {
            choose(base)
            one = spell(1)
            spelledSet = base
        } else {
            one = ""
        }
    }

    deinit {
        icu.close(parser)
        icu.close(speller)
        icu.close(ordinalDigits)
    }

    /// The parts of a spelled number. The rules join them with spaces, hyphens and, in
    /// languages that write a number as one word, soft hyphens.
    private static func parts(_ spelled: String) -> [String] {
        spelled.split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" }.map(String.init)
    }

    private static func squashed(_ text: String) -> String {
        TranscriptIndex.tokens(text.replacingOccurrences(of: "\u{00AD}", with: "")).joined()
    }

    private static func key(_ value: Decimal, ordinal: Bool) -> String {
        var input = value
        var output = Decimal()
        NSDecimalRound(&output, &input, 6, .plain)
        return "\(output)" + (ordinal ? "#" : "")
    }

    private static func lastCharacter(_ text: String) -> Character? {
        text.last { !$0.isWhitespace }
    }

    /// Whether a word closes a clause, in any script. A number does not run on past it.
    private static func endsClause(_ text: String) -> Bool {
        guard let last = lastCharacter(text) else { return false }
        return last.isPunctuation && !isSign(last)
    }

    private static func isSign(_ character: Character) -> Bool {
        character.isCurrencySymbol || character == "%" || character == "٪" || character == "‰" || character == "％"
    }

    /// A decimal digit of any script. 二 and ⅚ have a value and are not digits.
    private static func isDigit(_ character: Character) -> Bool {
        character.unicodeScalars.count == 1 && character.unicodeScalars.first?.properties.generalCategory == .decimalNumber
    }

    /// Digits of any script as ASCII digits.
    private static func plain(_ text: some StringProtocol) -> String {
        String(text.map { isDigit($0) ? Character(String($0.wholeNumberValue ?? 0)) : $0 })
    }

    // MARK: Spelled numbers

    private func spell(_ value: Double, _ set: String) -> String {
        if spelledSet != set {
            let units = Array(set.utf16)
            var status: Int32 = 0
            icu.setText(speller, ICUNumbers.defaultRuleSet, units, Int32(units.count), &status)
            spelledSet = set
        }
        return ICUNumbers.text { icu.format(speller, value, $0, $1, nil, $2) }
    }

    /// A search token as the rules spell it, when it is made only of parts of numbers.
    /// "einundzwanzigste" is "ein", "und" and "zwanzigste".
    private func spelling(_ token: String) -> String? {
        if let known = spellings[token] { return known }
        var result: String?
        if let whole = morphemes[token] {
            result = whole
        } else if token.count <= 64 {
            let characters = Array(token)
            var best = [String?](repeating: nil, count: characters.count + 1)
            best[0] = ""
            for end in 1...max(1, characters.count) where end <= characters.count {
                for start in stride(from: end - 1, through: max(0, end - longestMorpheme), by: -1) {
                    guard let head = best[start], let part = morphemes[String(characters[start..<end])] else { continue }
                    best[end] = head + part
                    break
                }
            }
            result = characters.isEmpty ? nil : best[characters.count]
        }
        if spellings.count < Self.cacheLimit { spellings[token] = .some(result) }
        return result
    }

    private func spelling(_ word: Word) -> String? {
        guard !word.tokens.isEmpty else { return nil }
        var parts: [String] = []
        for token in word.tokens {
            guard let part = spelling(token) else { return nil }
            parts.append(part)
        }
        return parts.joined(separator: " ")
    }

    /// The number a text begins with, and how much of the text says it.
    private func parse(_ text: String) -> (value: Double, consumed: Int)? {
        if let known = parses[text] { return known }
        let units = Array(text.utf16)
        var status: Int32 = 0
        var position: Int32 = 0
        let value = icu.parse(parser, units, Int32(units.count), &position, &status)
        let result: (value: Double, consumed: Int)? = status <= 0 && position > 0 && value.isFinite ? (value, Int(position)) : nil
        if parses.count < Self.cacheLimit { parses[text] = .some(result) }
        return result
    }

    /// The value of a phrase that is exactly one number as the rules would say it. Lenient
    /// parsing also accepts "nine one" as 901, which nobody means, so a reading counts only
    /// when one of the language's own rule sets spells that value the same way.
    private func reading(_ text: String) -> Reading? {
        if let known = readings[text] { return known }
        var result: Reading?
        if let (value, consumed) = parse(text), consumed >= text.utf16.count, value >= 0 {
            let said = Self.squashed(text)
            if let set = ruleSets.first(where: { Self.squashed(spell(value, $0.name)) == said }) {
                result = .init(value: value, ordinal: set.ordinal)
            }
        }
        if readings.count < Self.cacheLimit { readings[text] = .some(result) }
        return result
    }

    // MARK: Numbers in words

    /// The numbers in `words`, in order.
    func runs(in words: [Word]) -> [Run] {
        lock.lock()
        defer { lock.unlock() }
        var result: [Run] = []
        var stretch: [(position: Int, spelling: String)] = []
        func flush() {
            if !stretch.isEmpty { result += read(stretch) }
            stretch.removeAll(keepingCapacity: true)
        }
        var position = 0
        while position < words.count {
            let word = words[position]
            if word.text.contains(where: Self.isDigit) {
                flush()
                if let run = literal(at: position, in: words) {
                    result.append(run)
                    position = run.words.upperBound
                    continue
                }
            } else if let spelled = spelling(word) {
                stretch.append((position, spelled))
                if Self.endsClause(word.text) { flush() }
            } else {
                flush()
            }
            position += 1
        }
        flush()
        return result
    }

    /// The numbers in a stretch of number words. A transcript says the same figures many times,
    /// so each distinct stretch is read once and placed wherever it is said again.
    private func read(_ stretch: [(position: Int, spelling: String)]) -> [Run] {
        guard let origin = stretch.first?.position else { return [] }
        let said = stretch.map(\.spelling).joined(separator: "\u{1F}")
        let runs: [Run]
        if let known = stretches[said] {
            runs = known
        } else {
            runs = read(stretch.map { ($0.position - origin, $0.spelling) }, from: 0)
            if stretches.count < Self.cacheLimit { stretches[said] = runs }
        }
        guard origin != 0 else { return runs }
        return runs.map { run in
            Run(words: (run.words.lowerBound + origin)..<(run.words.upperBound + origin), key: run.key, symbol: run.symbol,
                parts: run.parts.map { .init(words: ($0.words.lowerBound + origin)..<($0.words.upperBound + origin), key: $0.key) })
        }
    }

    private func read(_ stretch: [(position: Int, spelling: String)], from _: Int) -> [Run] {
        var found: [(run: Run, reading: Reading)] = []
        var start = 0
        while start < stretch.count {
            let limit = min(stretch.count, start + Self.longestRun)
            guard let (run, reading) = number(in: stretch, from: start, to: limit) else {
                start += 1
                continue
            }
            found.append((run, reading))
            start += run.words.count
        }
        // Numbers said side by side without a pause are one figure read in pieces:
        // "three thirty" is 3:30, "seven forty seven" is 747, "nine one one" is 911.
        var result: [Run] = []
        var group: [(run: Run, reading: Reading)] = []
        func close() {
            if group.count > 1 {
                let digits = group.map { String(Int($0.reading.value)) }.joined()
                if let value = Decimal(string: digits), let first = group.first, let last = group.last {
                    result.append(.init(words: first.run.words.lowerBound..<last.run.words.upperBound,
                                        key: Self.key(value, ordinal: false), symbol: nil,
                                        parts: group.map { .init(words: $0.run.words, key: $0.run.key) }))
                }
            } else {
                result += group.map(\.run)
            }
            group.removeAll(keepingCapacity: true)
        }
        for item in found {
            let small = !item.reading.ordinal && item.reading.value < 100 && item.reading.value == item.reading.value.rounded()
            if let last = group.last, !small || last.run.words.upperBound != item.run.words.lowerBound { close() }
            if small { group.append(item) } else { result.append(item.run) }
        }
        close()
        return result
    }

    /// The longest number that starts at a word of a stretch.
    private func number(in stretch: [(position: Int, spelling: String)], from start: Int, to limit: Int) -> (Run, Reading)? {
        let spellings = stretch[start..<limit].map(\.spelling)
        func words(_ count: Int) -> Range<Int> {
            stretch[start].position..<(stretch[start + count - 1].position + 1)
        }
        func longest(prefix: String) -> (Int, Reading)? {
            let lead = prefix.isEmpty ? "" : prefix + " "
            guard let (_, consumed) = parse(lead + spellings.joined(separator: " ")) else { return nil }
            var count = 0
            var length = lead.utf16.count
            for (offset, spelled) in spellings.enumerated() {
                length += spelled.utf16.count + (offset > 0 ? 1 : 0)
                if length > consumed { break }
                count = offset + 1
            }
            while count > 0 {
                if let reading = reading(lead + spellings[..<count].joined(separator: " ")) { return (count, reading) }
                count -= 1
            }
            return nil
        }
        // "a hundred" leaves its one unsaid.
        guard let (count, reading) = longest(prefix: "") ?? (one.isEmpty ? nil : longest(prefix: one)) else { return nil }
        var run = Run(words: words(count), key: Self.key(Decimal(reading.value), ordinal: reading.ordinal), symbol: nil)
        if reading.ordinal, count > 1, let head = self.reading(spellings[..<(count - 1)].joined(separator: " ")), !head.ordinal {
            run.parts = [.init(words: words(count - 1), key: Self.key(Decimal(head.value), ordinal: false))]
        }
        return (run, reading)
    }

    // MARK: Numbers in digits

    /// A number written in digits, with what follows it when that is part of the figure.
    private func literal(at position: Int, in words: [Word]) -> Run? {
        guard let written = literal(words[position].text) else { return nil }
        var (value, symbol) = (written.value, written.symbol)
        var end = position + 1
        guard !written.ordinal else {
            let plain = written.alsoCardinal ? [Part(words: position..<end, key: Self.key(value, ordinal: false))] : []
            return .init(words: position..<end, key: Self.key(value, ordinal: true), symbol: symbol, parts: plain)
        }
        // A recognizer can write "6,000" as the two words "6," and "000".
        if value < 1000, let grouping {
            while end < words.count, Self.lastCharacter(words[end - 1].text) == grouping {
                let group = words[end].text.filter { $0.isLetter || $0.isNumber }
                guard group.count == 3, group.allSatisfy(Self.isDigit), let thousand = Decimal(string: Self.plain(group)) else { break }
                value = value * 1000 + thousand
                symbol = symbol ?? words[end].text.first(where: Self.isSign)
                end += 1
            }
        }
        // "5 million": the words after a figure can multiply it. The rules read the figure
        // spelled out with those words, and what they add is the multiplier.
        if !Self.endsClause(words[end - 1].text), end < words.count, let next = spelling(words[end]), let base {
            let whole = NSDecimalNumber(decimal: value).doubleValue
            let figure = whole == whole.rounded() && whole > 0 && whole < 1000 ? whole : 2
            if let reading = reading(spell(figure, base) + " " + next), !reading.ordinal,
               reading.value >= figure * 100, (reading.value / figure) == (reading.value / figure).rounded() {
                value *= Decimal(reading.value / figure)
                end += 1
            }
        }
        return .init(words: position..<end, key: Self.key(value, ordinal: false), symbol: symbol)
    }

    /// The value of a word written in digits: "1,500", "3.5", "$200", "50%", "21st", "3:30".
    private func literal(_ text: String) -> Literal? {
        if let known = literals[text] { return known }
        let symbol = text.first(where: Self.isSign)
        let opening = text.drop { !$0.isLetter && !$0.isNumber }
        let core = String(opening.reversed().drop { !$0.isLetter && !$0.isNumber }.reversed())
        // The figure with the one mark that follows it, for languages that write "21." for 21st.
        let marked = String(opening.prefix(core.count + 1)).trimmingCharacters(in: .whitespaces)
        var result: Literal?
        let clock = core.split(separator: ":", omittingEmptySubsequences: false)
        let digits = core.prefix(while: Self.isDigit)
        func ordinal(_ written: String) -> Bool {
            guard !digits.isEmpty, digits.count < written.count, let whole = Double(Self.plain(digits)), let ordinalDigits else { return false }
            let written = Self.plain(written.lowercased())
            for set in ordinalDigitSets {
                if ordinalDigitSet != set {
                    let units = Array(set.utf16)
                    var status: Int32 = 0
                    icu.setText(ordinalDigits, ICUNumbers.defaultRuleSet, units, Int32(units.count), &status)
                    ordinalDigitSet = set
                }
                if Self.plain(ICUNumbers.text({ icu.format(ordinalDigits, whole, $0, $1, nil, $2) }).lowercased()) == written { return true }
            }
            return false
        }
        if clock.count == 2 || clock.count == 3, clock.allSatisfy({ !$0.isEmpty && $0.allSatisfy(Self.isDigit) }) {
            // A clock time is said as its figures side by side.
            result = Decimal(string: Self.plain(clock.joined())).map { .init(value: $0, symbol: symbol) }
        } else if let number = decimal.number(from: core) {
            result = .init(value: number.decimalValue, symbol: symbol)
            if digits.count == core.count, marked != core, ordinal(marked) {
                result?.ordinal = true
                result?.alsoCardinal = true
            }
        } else if ordinal(core), let whole = Decimal(string: Self.plain(digits)) {
            // "21st", "1er", "3.º": the figure with the ending the language gives an ordinal.
            result = .init(value: whole, ordinal: true, symbol: symbol)
        }
        if literals.count < Self.cacheLimit { literals[text] = .some(result) }
        return result
    }

    // MARK: Signs

    /// How many of the words after a number say the sign it is written with: "dollars" for
    /// "$", "pour cent" for "%", in the transcript's language. The words must open or close a
    /// name the language has for that sign, so "pesos" counts and the "y" of "Trinidad y
    /// Tobago" does not.
    func said(_ symbol: Character, by words: ArraySlice<Word>) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if signNames == nil {
            var names: [Character: Set<[String]>] = [:]
            func add(_ sign: Character, _ skeleton: String) {
                for amount in [1.0, 2, 5] {
                    let written = icu.written(amount, skeleton: skeleton + " unit-width-full-name", locale: locale)
                    let name = TranscriptIndex.tokens(written.filter { !Self.isDigit($0) })
                    if !name.isEmpty { names[Self.folded(sign), default: []].insert(name) }
                }
            }
            for sign in icu.written(1, skeleton: "percent", locale: locale) where Self.isSign(sign) { add(sign, "percent") }
            for sign in icu.written(1, skeleton: "permille", locale: locale) where Self.isSign(sign) { add(sign, "permille") }
            for code in Locale.commonISOCurrencyCodes {
                let signs = icu.written(1, skeleton: "currency/\(code) unit-width-narrow", locale: locale).filter(\.isCurrencySymbol)
                if signs.count == 1, let sign = signs.first { add(sign, "currency/\(code)") }
            }
            signNames = names
        }
        guard let names = signNames?[Self.folded(symbol)] else { return 0 }
        var spoken: [String] = []
        for word in words.prefix(4) {
            guard word.tokens.count == 1 else { break }
            spoken.append(word.tokens[0])
        }
        while !spoken.isEmpty {
            if names.contains(where: { $0.starts(with: spoken) || $0.reversed().starts(with: spoken.reversed()) }) {
                return spoken.count
            }
            spoken.removeLast()
        }
        return 0
    }

    /// A sign without its full-width form, so "￥" is "¥".
    private static func folded(_ sign: Character) -> Character {
        String(sign).folding(options: .widthInsensitive, locale: nil).first ?? sign
    }
}
