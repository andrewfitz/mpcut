import XCTest
@testable import MPCutCore

final class ThreeGPPTextStylesTests: XCTestCase {
    private let script = "[Script Info]\nScriptType: v4.00+\n\n[V4+ Styles]\n"
        + "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, "
        + "Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, "
        + "MarginV, Encoding\n"
        + "Style: Default,Arial,16,&Hffffff,&Hffffff,&H0,&H0,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,0\n"
        + "Style: Green,Arial,20,&H0000FF00,&H00FFFFFF,&H0,&H0,-1,0,0,0,100,100,0,0,1,1,0,2,10,10,10,0\n\n"
        + "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"

    /// The complete style as the rewrite writes it: twice, so every tag lands in the encoder's new style record.
    private func style(bold: Bool = false, italic: Bool = false, colour: String = "FFFFFF", alpha: String = "00",
                       size: Int = 16, font: String = "Arial") -> String {
        let tags = "\\b\(bold ? 1 : 0)\\i\(italic ? 1 : 0)\\u0\\1c&H\(colour)&\\1a&H\(alpha)&\\fs\(size)\\fn\(font)"
        return tags + tags
    }

    private func normalized(_ text: String, style name: String = "Default") -> String {
        ThreeGPPTextStyles.normalizedText(text, style: name, header: ThreeGPPTextStyles.Header(script))
    }

    func testTheHeaderStylesAreReadAsTheEncoderReadsThem() {
        let header = ThreeGPPTextStyles.Header(script)
        XCTAssertEqual(header.styles.map(\.name), ["Default", "Green"])
        XCTAssertEqual(header.styles[1], ThreeGPPTextStyles.Style(name: "Green", font: "Arial", size: 20, primary: 0x0000_FF00,
                                                                  bold: true))
        XCTAssertEqual(header.style("")?.name, "Default")
        // A style the header lacks is the sample description's default.
        XCTAssertEqual(header.style("Missing")?.name, "Default")
    }

    func testSubRipFontColoursAndSizesAreWrittenAsTheEncoderReadsThem() {
        // The SubRip decoder writes <font color> as \c and its end as a bare \c; <font size> ends with a bare \fs.
        XCTAssertEqual(normalized("a {\\c&HFF&}Red{\\c} b"),
                       "a {\(style(colour: "0000FF"))}Red{\(style())} b")
        XCTAssertEqual(normalized("a {\\fs30}Big{\\fs} b"), "a {\(style(size: 30))}Big{\(style())} b")
        XCTAssertEqual(normalized("a {\\fnCourier}Mono{\\fn} b"), "a {\(style(font: "Courier"))}Mono{\(style())} b")
    }

    func testAnOverrideKeepsTheRestOfItsCuesStyle() {
        // The encoder starts each record from the default style; the complete style keeps Green's weight and colour.
        XCTAssertEqual(normalized("a {\\fs30}Big{\\fs} b", style: "Green"),
                       "a {\(style(bold: true, colour: "00FF00", size: 30))}Big{\(style(bold: true, colour: "00FF00", size: 20))} b")
        // A reset without a value returns to the style the last \r named.
        XCTAssertEqual(normalized("{\\rGreen\\c&HFF&}x{\\c}y"),
                       "{\(style(bold: true, colour: "0000FF", size: 20))}x{\(style(bold: true, colour: "00FF00", size: 20))}y")
    }

    func testAlphaAndStrikethroughAndOtherTags() {
        XCTAssertEqual(normalized("{\\alpha&H80&}Half{\\alpha} b"), "{\(style(alpha: "80"))}Half{\(style())} b")
        // Style after the last character shows nothing, so a closing block there states none: a record the encoder
        // started at the very end would stay open into the next sample.
        XCTAssertEqual(normalized("{\\i1}a{\\i0\\an8}", style: "Green"), "{\(style(bold: true, italic: true, colour: "00FF00", size: 20))}a{\\an8}")
        // The encoder would print an empty block, so one left empty is dropped; an empty block of the source stays.
        XCTAssertEqual(normalized("{\\u1}three{\\u0}"), "{\(style().replacingOccurrences(of: "\\u0", with: "\\u1"))}three")
        XCTAssertEqual(normalized("a{}b"), "a{}b")
        // 3GPP text has no strikethrough; the style around it is kept.
        XCTAssertEqual(normalized("{\\i1}a{\\s1}b"), "{\(style(italic: true))}a{\(style(italic: true))}b")
        // Tags that do not set the style stay in place, as do tags inside an animation and the block's comment.
        XCTAssertEqual(normalized("{note\\an8\\pos(1,2)\\i1}a{\\t(\\c&HFF&)}b"),
                       "{note\\an8\\pos(1,2)\(style(italic: true))}a{\\t(\\c&HFF&)}b")
        // A colour without its closing & is not read by the encoder, so it stays as it is.
        XCTAssertEqual(normalized("{\\c&HFF}a"), "{\\c&HFF}a")
        XCTAssertEqual(normalized("no overrides"), "no overrides")
    }

    func testTheEventsOwnStyleIsInForceAtItsStart() {
        XCTAssertEqual(ThreeGPPTextStyles.normalized("3,0,Green,,0,0,0,,a, {\\i1}b", header: ThreeGPPTextStyles.Header(script)),
                       "3,0,Green,,0,0,0,,a, {\(style(bold: true, italic: true, colour: "00FF00", size: 20))}b")
    }

    func testJoinedCuesOpenWithTheirCompleteStyle() {
        // A reset leaves bold, italic and underline set in the encoder, so a later cue states its whole style.
        let header = ThreeGPPTextStyles.Header(script)
        let events = ["0,0,Default,,0,0,0,,{\\i1}One", "0,0,Green,,0,0,0,,Two"].map { ThreeGPPTextStyles.normalized($0, header: header) }
        XCTAssertEqual(TextCueMerge.joined(events, readOrder: 4) { ThreeGPPTextStyles.opening($0, header: header) },
                       "4,0,Default,,0,0,0,,{\(style(italic: true))}One\\N{\(style(bold: true, colour: "00FF00", size: 20))}Two")
    }

    func testSizesAreScaledToThePictureAndHeldInOneByte() {
        // The encoder scales by picture height over PlayResY and writes one byte: 68 at 288 lines is 255 at 1080.
        XCTAssertEqual(ThreeGPPTextStyles.largestSize(pictureHeight: 1080, scriptHeight: 288), 68)
        XCTAssertEqual(ThreeGPPTextStyles.largestSize(pictureHeight: 288, scriptHeight: 288), 255)
        XCTAssertEqual(ThreeGPPTextStyles.largestSize(pictureHeight: 0, scriptHeight: 288), 255)
        // A script without PlayResY is measured as libass measures it, and states it so the encoder scales.
        let bare = ThreeGPPTextStyles.Header(script)
        XCTAssertNil(bare.playResY)
        XCTAssertEqual(bare.scriptHeight, 288)
        XCTAssertEqual(ThreeGPPTextStyles.Header("[Script Info]\nPlayResX: 1280\n").scriptHeight, 1024)
        XCTAssertEqual(ThreeGPPTextStyles.Header("[Script Info]\nPlayResX: 640\n").scriptHeight, 480)
        let stated = bare.statingPlayResY()
        XCTAssertTrue(stated.hasPrefix("[Script Info]\nPlayResY: 288\nScriptType: v4.00+\n"), stated)
        XCTAssertEqual(ThreeGPPTextStyles.Header(stated).statingPlayResY(), stated)
        XCTAssertEqual(ThreeGPPTextStyles.Header("Style: x\n").statingPlayResY(), "[Script Info]\nPlayResY: 288\n\nStyle: x\n")
        // Style sizes and overrides above the largest are written at it.
        var clamped = ThreeGPPTextStyles.Header(bare.clampingSizes(18))
        XCTAssertEqual(clamped.styles.map(\.size), [16, 18])
        XCTAssertTrue(clamped.text.contains("Style: Green,Arial,18,&H0000FF00,"), clamped.text)
        clamped.largestSize = 18
        XCTAssertEqual(ThreeGPPTextStyles.normalizedText("{\\fs40}a", style: "Default", header: clamped), "{\(style(size: 18))}a")
    }

    func testFontsTheCuesNameAreAddedToTheHeader() {
        let events = [ThreeGPPTextStyles.normalized("0,0,Default,,0,0,0,,{\\fnCourier}a{\\fnComic, Sans}b",
                                                    header: ThreeGPPTextStyles.Header(script))]
        XCTAssertEqual(ThreeGPPTextStyles.fonts(events), ["Courier", "Comic, Sans"])
        let header = ThreeGPPTextStyles.Header(script).addingFonts(ThreeGPPTextStyles.fonts(events))
        // A font name with a comma cannot be written in a style line.
        XCTAssertTrue(header.contains("Style: Green,Arial,20,&H0000FF00,&H00FFFFFF,&H0,&H0,-1,0,0,0,100,100,0,0,1,1,0,2,10,10,10,0\n"
            + "Style: MPCut Font 1,Courier,16,&Hffffff,&Hffffff,&H0,&H0,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,0\n\n[Events]"),
                      header)
        XCTAssertEqual(ThreeGPPTextStyles.Header(header).styles.map(\.font), ["Arial", "Arial", "Courier"])
        XCTAssertEqual(ThreeGPPTextStyles.Header(script).addingFonts(["Arial"]), script)
    }
}
