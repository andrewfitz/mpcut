@testable import MPCutCore
import XCTest

final class TranscriptNumberSearchTests: XCTestCase {
    private func index(_ texts: [String], language: String? = "en") throws -> TranscriptIndex {
        let words = texts.enumerated().map { offset, text in
            TranscriptWord(id: "w\(offset)", text: text, start: .init(numerator: Int64(offset)),
                           end: .init(numerator: Int64(offset) + 1), candidateTrackIDs: ["mic"])
        }
        let provenance = language.map {
            TranscriptProvenance(source: "test", model: nil, device: nil, language: $0,
                                 duration: .init(numerator: Int64(texts.count)), metadata: .object([:]))
        }
        return try TranscriptIndex(document: .init(clock: .presentation, tracks: [.init(id: "mic", name: "mic")],
                                                   words: words, provenance: provenance))
    }

    private func found(_ query: String, in index: TranscriptIndex) -> [[String]] {
        index.search(query, space: .source).items.map { $0.words.map(\.text) }
    }

    func testPreparedSearchPreservesMatchOrderContextAndPagination() throws {
        let transcript = try index(["We", "saw", "200", "hours", "on", "a", "range", "finder", "and",
                                    "we", "saw", "two", "hundred", "hours", "on", "a", "range", "finder"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for query in ["we saw", "200 hours", "a rangefinder", "absent", "!"] {
            for filter in [TranscriptFilter(trackID: "mic"), TranscriptFilter(trackID: "other")] {
                let search = try transcript.prepareSearch(query, space: .source, filter: filter)
                for offset in [0, 1, 2, 10] {
                    let expected = transcript.search(query, space: .source, filter: filter, offset: offset, limit: 1)
                    XCTAssertEqual(try encoder.encode(search.page(offset: offset, limit: 1)),
                                   try encoder.encode(expected), "\(query), offset \(offset)")
                }
            }
        }
    }

    func testANumberIsFoundWrittenAsWordsOrAsDigits() throws {
        let spoken = try index(["Around", "two", "hundred", "hours", "spread", "over", "three", "or", "four", "months."])
        let written = try index(["Around", "200", "hours", "over", "3", "or", "4", "months."])
        XCTAssertEqual(found("200 hours", in: spoken), [["two", "hundred", "hours"]])
        XCTAssertEqual(found("two hundred hours", in: written), [["200", "hours"]])
        XCTAssertEqual(found("three or four months", in: written), [["3", "or", "4", "months."]])
        XCTAssertEqual(found("3 or 4 months", in: spoken), [["three", "or", "four", "months."]])
        // A plain phrase search still finds what it found before.
        XCTAssertEqual(found("two hundred", in: spoken), [["two", "hundred"]])
        XCTAssertEqual(found("two", in: spoken), [["two"]])
        XCTAssertEqual(found("hundred", in: spoken), [["hundred"]])
        XCTAssertEqual(found("hours spread", in: spoken), [["hours", "spread"]])
        // 200 is not 2, and not 100.
        XCTAssertEqual(found("two", in: written), [])
        XCTAssertEqual(found("100", in: spoken), [])
        XCTAssertEqual(found("2", in: spoken), [])
    }

    func testGroupedDecimalYearAndClockFormsReadAsTheirValue() throws {
        let written = try index(["It", "cost", "1,500", "dollars", "in", "1999", "at", "3:30", "about", "3.5", "percent"])
        XCTAssertEqual(found("fifteen hundred", in: written), [["1,500"]])
        XCTAssertEqual(found("one thousand five hundred dollars", in: written), [["1,500", "dollars"]])
        XCTAssertEqual(found("1500", in: written), [["1,500"]])
        XCTAssertEqual(found("in nineteen ninety nine", in: written), [["in", "1999"]])
        XCTAssertEqual(found("three thirty", in: written), [["3:30"]])
        XCTAssertEqual(found("three point five percent", in: written), [["3.5", "percent"]])

        let spoken = try index(["In", "twenty", "twenty", "four", "we", "sold", "two", "hundred", "and", "five",
                                "units", "by", "nineteen", "oh", "five"])
        XCTAssertEqual(found("in 2024", in: spoken), [["In", "twenty", "twenty", "four"]])
        XCTAssertEqual(found("205 units", in: spoken), [["two", "hundred", "and", "five", "units"]])
        XCTAssertEqual(found("1905", in: spoken), [["nineteen", "oh", "five"]])
        // "two hundred and five" is 205 and nothing else.
        XCTAssertEqual(found("200", in: spoken), [])
        XCTAssertEqual(found("5", in: spoken), [])
    }

    func testAnOrdinalIsNotItsCardinal() throws {
        let transcript = try index(["My", "1st", "guitar", "took", "two", "weeks", "and", "the", "second", "took",
                               "twenty", "one"])
        XCTAssertEqual(found("first guitar", in: transcript), [["1st", "guitar"]])
        XCTAssertEqual(found("2nd", in: transcript), [["second"]])
        XCTAssertEqual(found("second", in: transcript), [["second"]])
        XCTAssertEqual(found("2", in: transcript), [["two"]])
        XCTAssertEqual(found("21", in: transcript), [["twenty", "one"]])
        XCTAssertEqual(found("twenty first", in: transcript), [])
        XCTAssertEqual(found("1", in: transcript), [])
    }

    func testANumberBeforeTheWordSecondIsStillThatNumber() throws {
        let transcript = try index(["Cut", "a", "thirty", "second", "clip", "with", "a", "10", "second", "delay",
                                    "on", "the", "twenty", "first"])
        XCTAssertEqual(found("30 second clip", in: transcript), [["thirty", "second", "clip"]])
        XCTAssertEqual(found("ten second delay", in: transcript), [["10", "second", "delay"]])
        XCTAssertEqual(found("thirty second clip", in: transcript), [["thirty", "second", "clip"]])
        XCTAssertEqual(found("the 21st", in: transcript), [["the", "twenty", "first"]])
        XCTAssertEqual(found("21", in: transcript), [])
    }

    func testSignsMultipliersAndABareHundred() throws {
        let transcript = try index(["Between", "$4,000", "and", "$6", "million,", "or", "50%", "of", "a", "hundred", "people"])
        XCTAssertEqual(found("four thousand dollars", in: transcript), [["$4,000"]])
        XCTAssertEqual(found("six million dollars", in: transcript), [["$6", "million,"]])
        XCTAssertEqual(found("6,000,000", in: transcript), [["$6", "million,"]])
        XCTAssertEqual(found("fifty percent of", in: transcript), [["50%", "of"]])
        XCTAssertEqual(found("100 people", in: transcript), [["hundred", "people"]])
        XCTAssertEqual(found("$4,000", in: transcript), [["$4,000"]])
        XCTAssertEqual(found("4,000 dollars and", in: transcript), [["$4,000", "and"]])
        // Recognizers put a leading space on each word and can split a grouped figure in two.
        let split = try index([" between", " 4", " and", " 6,", " 000", " dollars,", " in", " 2024,", " 100", " people"])
        XCTAssertEqual(found("four and six thousand dollars", in: split), [[" 4", " and", " 6,", " 000", " dollars,"]])
        XCTAssertEqual(found("6000", in: split), [[" 6,", " 000"]])
        XCTAssertEqual(found("one hundred people", in: split), [[" 100", " people"]])
        XCTAssertEqual(found("2024", in: split), [[" 2024,"]])
    }

    func testDigitsSaidOneAtATimeAndAListOfNumbers() throws {
        let transcript = try index(["Call", "nine", "one", "one", "now.", "I", "counted", "one,", "two,", "three",
                               "between", "four", "and", "six", "thousand"])
        XCTAssertEqual(found("911", in: transcript), [["nine", "one", "one"]])
        // A comma ends a number, and "four and six thousand" is two numbers.
        XCTAssertEqual(found("12", in: transcript), [])
        XCTAssertEqual(found("123", in: transcript), [])
        XCTAssertEqual(found("6000", in: transcript), [["six", "thousand"]])
        XCTAssertEqual(found("between 4 and 6,000", in: transcript), [["between", "four", "and", "six", "thousand"]])
    }

    func testWordsWithDigitsThatAreNotNumbersSearchAsBefore() throws {
        let transcript = try index(["An", "MP3", "player", "and", "a", "4K", "screen", "in", "the", "garage"])
        XCTAssertEqual(found("mp3 player", in: transcript), [["MP3", "player"]])
        XCTAssertEqual(found("4k screen", in: transcript), [["4K", "screen"]])
        XCTAssertEqual(found("four", in: transcript), [])
        XCTAssertEqual(found("the garage", in: transcript), [["the", "garage"]])
    }

    func testEveryLanguageReadsItsOwnNumberWords() throws {
        let german = try index(["Etwa", "zweihundert", "Stunden", "und", "einundzwanzig", "Tage", "am", "einundzwanzigsten",
                                "Mai", "neunzehnhundertfünf,", "die", "erste", "und", "5", "Millionen"], language: "de")
        XCTAssertEqual(found("200 Stunden", in: german), [["zweihundert", "Stunden"]])
        XCTAssertEqual(found("21 Tage", in: german), [["einundzwanzig", "Tage"]])
        XCTAssertEqual(found("21. Mai", in: german), [["einundzwanzigsten", "Mai"]])
        XCTAssertEqual(found("1905", in: german), [["neunzehnhundertfünf,"]])
        XCTAssertEqual(found("die 1.", in: german), [["die", "erste"]])
        XCTAssertEqual(found("fünf Millionen", in: german), [["5", "Millionen"]])
        XCTAssertEqual(found("5000000", in: german), [["5", "Millionen"]])

        let spanish = try index(["Unas", "doscientas", "horas", "en", "dos", "mil", "cinco,", "el", "vigésimo", "primero",
                                 "y", "la", "primera", "vez,", "$5", "y", "200", "días"], language: "es")
        XCTAssertEqual(found("200 horas", in: spanish), [["doscientas", "horas"]])
        XCTAssertEqual(found("doscientos días", in: spanish), [["200", "días"]])
        XCTAssertEqual(found("2005", in: spanish), [["dos", "mil", "cinco,"]])
        XCTAssertEqual(found("el 21.º", in: spanish), [["el", "vigésimo", "primero"]])
        XCTAssertEqual(found("cinco dólares", in: spanish), [["$5"]])
        XCTAssertEqual(found("cinco pesos y", in: spanish), [["$5", "y"]])

        let french = try index(["Environ", "deux", "cents", "heures,", "quatre-vingt-dix", "jours,", "le", "premier",
                                "et", "5", "%", "du", "total"], language: "fr")
        XCTAssertEqual(found("200 heures", in: french), [["deux", "cents", "heures,"]])
        XCTAssertEqual(found("90 jours", in: french), [["quatre-vingt-dix", "jours,"]])
        XCTAssertEqual(found("le 1er", in: french), [["le", "premier"]])
        XCTAssertEqual(found("cinq pour cent du total", in: french), [["5", "du", "total"]])

        let russian = try index(["Около", "двести", "пять", "часов,", "двадцать", "первый", "день", "и", "пять", "миллионов"],
                                language: "ru")
        XCTAssertEqual(found("205 часов", in: russian), [["двести", "пять", "часов,"]])
        XCTAssertEqual(found("5000000", in: russian), [["пять", "миллионов"]])
        XCTAssertEqual(found("205", in: russian).count, 1)

        let japanese = try index(["二百", "時間", "と", "二千三百四十五", "円", "第二"], language: "ja")
        XCTAssertEqual(found("200 時間", in: japanese), [["二百", "時間"]])
        XCTAssertEqual(found("2345", in: japanese), [["二千三百四十五"]])
    }

    func testAnUndeclaredLanguageIsReadFromTheWords() throws {
        let words = ["Wir", "haben", "lange", "über", "das", "Projekt", "gesprochen", "und", "dann", "beschlossen,", "noch",
                     "einmal", "von", "vorne", "anzufangen,", "weil", "die", "ersten", "Aufnahmen", "nicht", "gut", "genug",
                     "waren.", "Das", "hat", "etwa", "zweihundert", "Stunden", "gedauert,", "verteilt", "auf", "drei", "oder",
                     "vier", "Monate", "im", "Jahr", "neunzehnhundertneunundneunzig."]
        for language in [nil, "auto"] {
            let transcript = try index(words, language: language)
            XCTAssertEqual(found("200 Stunden", in: transcript), [["zweihundert", "Stunden"]])
            XCTAssertEqual(found("1999", in: transcript), [["neunzehnhundertneunundneunzig."]])
            XCTAssertEqual(found("3 oder 4 Monate", in: transcript), [["drei", "oder", "vier", "Monate"]])
        }
    }

    func testEveryPlaceIsListedOnceInTranscriptOrder() throws {
        let transcript = try index(["200", "hours", "then", "two", "hundred", "hours", "then", "200", "hours"])
        XCTAssertEqual(found("two hundred hours", in: transcript),
                       [["200", "hours"], ["two", "hundred", "hours"], ["200", "hours"]])
        let page = transcript.search("200 hours", space: .source, offset: 1, limit: 1)
        XCTAssertEqual(page.total, 3)
        XCTAssertEqual(page.items.map { $0.words.map(\.wordID) }, [["w3", "w4", "w5"]])
        XCTAssertEqual(page.items.first?.before.map(\.text), ["200", "hours", "then"])
        XCTAssertEqual(page.items.first?.after.map(\.text), ["then", "200", "hours"])
    }
}
