import Foundation

/// The ASS styling that FFmpeg's 3GPP text encoder (movtextenc.c, reading overrides through ass_split.c) would lose or
/// misread, rewritten into forms it keeps. Every cue converted to 3GPP text passes through here as an ASS event.
///
/// The encoder starts each new style record from the sample description's default style and changes only what the
/// override names, so after `{\i1}` in a cue of another style the text loses that style's colour, size and weight.
/// It also misreads several overrides:
/// - a colour written `\c&H..&`, which SubRip font colours become, is read as colour number 0 and dropped;
/// - `\alpha&H..&` is read as alpha number 0 and dropped;
/// - a reset without a value (`\c`, `\1c`, `\1a`, `\alpha`, `\fs`, `\fn`), which closing SubRip font tags become, is
///   read as white, fully transparent, size zero or the first font.
///
/// So every override block that changes the style is written with the complete style in force after it: bold, italic,
/// underline, primary colour and alpha, size and font, each in the form the encoder reads. The style in force is the
/// event's own, or the one a `\r` named, with the overrides since applied, as a renderer reads them.
///
/// A font named in an override is written as the default font unless the script header has a style that uses it,
/// since the encoder builds the sample description's font table from the header's styles. A style is added for each
/// such font (Header.addingFonts), so SubRip font faces and ASS font overrides keep their font.
enum ThreeGPPTextStyles {
    /// A style of the script header, as the encoder reads it.
    struct Style: Equatable {
        var name: String
        var font: String
        var size: Int
        /// &HAABBGGRR, where alpha 0 is opaque.
        var primary: UInt32
        var bold = false
        var italic = false
        var underline = false
    }

    /// The styles of an ASS script header, in order, and how its style lines are laid out.
    struct Header {
        let text: String
        let styles: [Style]
        /// The script's stated resolution, nil when it states none.
        let playResX: Int?
        let playResY: Int?
        /// The largest size, in script units, that the encoder can write (ThreeGPPTextStyles.largestSize). An override
        /// above it is written at it.
        var largestSize = Int.max

        init(_ text: String) {
            self.text = text
            var styles: [Style] = []
            var format: [String] = []
            var inStyles = false
            var inInfo = false
            var playResX: Int?
            var playResY: Int?
            for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.hasPrefix("[") {
                    inStyles = line.lowercased().hasSuffix("styles]")
                    inInfo = line.lowercased() == "[script info]"
                    continue
                }
                if inInfo, line.hasPrefix("PlayResX:") {
                    playResX = Self.integer(line.dropFirst("PlayResX:".count).trimmingCharacters(in: .whitespaces))
                } else if inInfo, line.hasPrefix("PlayResY:") {
                    playResY = Self.integer(line.dropFirst("PlayResY:".count).trimmingCharacters(in: .whitespaces))
                }
                guard inStyles else { continue }
                if line.hasPrefix("Format:") {
                    format = Self.values(line.dropFirst("Format:".count), count: Int.max)
                        .map { $0.lowercased() }
                } else if line.hasPrefix("Style:"), !format.isEmpty {
                    let fields = Self.values(line.dropFirst("Style:".count), count: format.count)
                    func field(_ name: String) -> String? {
                        format.firstIndex(of: name).flatMap { fields.indices.contains($0) ? fields[$0] : nil }
                    }
                    func flag(_ name: String) -> Bool { (field(name).flatMap(Self.integer) ?? 0) != 0 }
                    styles.append(Style(name: field("name") ?? "", font: field("fontname") ?? "",
                                        size: field("fontsize").flatMap(Self.integer) ?? 0,
                                        primary: field("primarycolour").flatMap(Self.colour) ?? 0x00FF_FFFF,
                                        bold: flag("bold"), italic: flag("italic"), underline: flag("underline")))
                }
            }
            self.styles = styles
            self.playResX = playResX.flatMap { $0 > 0 ? $0 : nil }
            self.playResY = playResY.flatMap { $0 > 0 ? $0 : nil }
        }

        /// The height that the script's sizes are measured against: its PlayResY, or as libass and VSFilter take it
        /// when the script states none, 288, or three quarters of a stated PlayResX (1024 for 1280).
        var scriptHeight: Int {
            if let playResY { return playResY }
            guard let playResX else { return 288 }
            return playResX == 1280 ? 1024 : playResX * 3 / 4
        }

        /// The header with a PlayResY, so the encoder scales its sizes to the picture: unchanged when it states one.
        func statingPlayResY() -> String {
            guard playResY == nil else { return text }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let info = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "[script info]" })
            else { return "[Script Info]\nPlayResY: \(scriptHeight)\n\n" + text }
            lines.insert("PlayResY: \(scriptHeight)" + (lines[info].hasSuffix("\r") ? "\r" : ""), at: info + 1)
            return lines.joined(separator: "\n")
        }

        /// The header with every style size above `largest` written at `largest`.
        func clampingSizes(_ largest: Int) -> String {
            guard styles.contains(where: { $0.size > largest }) else { return text }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var format: [String] = []
            var inStyles = false
            for (index, raw) in lines.enumerated() {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.hasPrefix("[") {
                    inStyles = line.lowercased().hasSuffix("styles]")
                    continue
                }
                guard inStyles else { continue }
                if line.hasPrefix("Format:") {
                    format = Self.values(line.dropFirst("Format:".count), count: Int.max).map { $0.lowercased() }
                } else if line.hasPrefix("Style:"), let sizeIndex = format.firstIndex(of: "fontsize") {
                    var fields = Self.values(line.dropFirst("Style:".count), count: format.count)
                    guard fields.indices.contains(sizeIndex), let size = Self.integer(fields[sizeIndex]), size > largest else { continue }
                    fields[sizeIndex] = String(largest)
                    lines[index] = "Style: " + fields.joined(separator: ",") + (raw.hasSuffix("\r") ? "\r" : "")
                }
            }
            return lines.joined(separator: "\n")
        }

        /// The style that a style name selects. An empty name is Default; a name without a style, the sample
        /// description's default, which is Default or else the first style.
        func style(_ name: String) -> Style? {
            let wanted = name.isEmpty ? "Default" : name
            return styles.first { $0.name == wanted } ?? styles.first { $0.name == "Default" } ?? styles.first
        }

        /// The header with one more style for each of `fonts` that no style uses, copied from the default style with
        /// its name and font replaced, so the encoder's font table holds every font the cues name. Fonts that a style
        /// line cannot hold (a comma, or longer than the font table's 255 bytes) are left out.
        func addingFonts(_ fonts: [String]) -> String {
            let used = Set(styles.map(\.font))
            let names = Set(styles.map(\.name))
            let missing = fonts.filter { !used.contains($0) && Self.canHold($0) }
            guard !missing.isEmpty, let base = style("") else { return text }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var format: [String] = []
            var inStyles = false
            var styleLines: [(fields: [String], ending: String)] = []
            var last: Int?
            for (index, raw) in lines.enumerated() {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.hasPrefix("[") {
                    inStyles = line.lowercased().hasSuffix("styles]")
                    continue
                }
                guard inStyles else { continue }
                if line.hasPrefix("Format:") {
                    format = Self.values(line.dropFirst("Format:".count), count: Int.max).map { $0.lowercased() }
                } else if line.hasPrefix("Style:"), !format.isEmpty {
                    last = index
                    styleLines.append((Self.values(line.dropFirst("Style:".count), count: format.count),
                                   raw.hasSuffix("\r") ? "\r" : ""))
                }
            }
            guard let last, let nameIndex = format.firstIndex(of: "name"), let fontIndex = format.firstIndex(of: "fontname"),
                  let template = styleLines.first(where: { $0.fields.count > max(nameIndex, fontIndex) && $0.fields[nameIndex] == base.name })
            else { return text }
            var added: [String] = []
            var number = 1
            for font in missing {
                while names.contains("MPCut Font \(number)") { number += 1 }
                var fields = template.fields
                fields[nameIndex] = "MPCut Font \(number)"
                fields[fontIndex] = font
                number += 1
                added.append("Style: " + fields.joined(separator: ",") + template.ending)
            }
            lines.insert(contentsOf: added, at: last + 1)
            return lines.joined(separator: "\n")
        }

        static func canHold(_ font: String) -> Bool {
            !font.isEmpty && !font.contains(",") && font.utf8.count <= 255
        }

        private static func values(_ text: Substring, count: Int) -> [String] {
            text.split(separator: ",", maxSplits: max(0, count - 1), omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }

        /// A leading integer, as sscanf("%d") reads it.
        private static func integer(_ text: String) -> Int? {
            var digits = ""
            for character in text {
                if character.isASCII && character.isNumber || (digits.isEmpty && (character == "-" || character == "+")) {
                    digits.append(character)
                } else {
                    break
                }
            }
            return Int(digits)
        }

        /// &H followed by up to eight hex digits, or a decimal number, as ass_split.c reads a colour.
        static func colour(_ text: String) -> UInt32? {
            if text.hasPrefix("&H") {
                let hex = text.dropFirst(2).prefix { $0.isHexDigit }.prefix(8)
                return UInt32(hex, radix: 16)
            }
            return integer(text).map { UInt32(truncatingIfNeeded: $0) }
        }
    }

    /// The largest size, in units of a script `scriptHeight` high, that the encoder writes for a picture
    /// `pictureHeight` high: it scales sizes by the picture height over the script's (FONTSIZE_SCALE, rounding) and
    /// writes the result in one byte, so a larger one would wrap around to a small size.
    static func largestSize(pictureHeight: Int, scriptHeight: Int) -> Int {
        let scale = pictureHeight > 0 && scriptHeight > 0 ? Double(pictureHeight) / Double(scriptHeight) : 1
        var size = Int(255.5 / scale)
        while size > 0 && Int(Double(size) * scale + 0.5) > 255 { size -= 1 }
        return max(size, 1)
    }

    /// The event line with its text rewritten as the type describes. The event's own style is the one in force at
    /// its start.
    static func normalized(_ event: String, header: Header) -> String {
        var fields = event.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 9 else { return event }
        fields[8] = normalizedText(fields[8], style: fields[2], header: header)
        return fields.joined(separator: ",")
    }

    /// The style in force at a point of a cue, as the encoder can write it.
    private struct State {
        var bold = false, italic = false, underline = false
        /// &HBBGGRR, and the ASS alpha, where 0 is opaque.
        var colour: UInt32 = 0xFF_FFFF
        var alpha: UInt32 = 0
        var size: Int?
        var font: String?
        /// The style that the event or the last \r selected.
        var base: Style?

        init(_ style: Style?) {
            base = style
            guard let style else { return }
            bold = style.bold
            italic = style.italic
            underline = style.underline
            colour = style.primary & 0xFF_FFFF
            alpha = style.primary >> 24
            size = style.size > 0 ? style.size : nil
            font = style.font.isEmpty ? nil : style.font
        }

        var tags: String {
            var result = "\\b\(bold ? 1 : 0)\\i\(italic ? 1 : 0)\\u\(underline ? 1 : 0)"
                + String(format: "\\1c&H%06X&\\1a&H%02X&", colour, alpha)
            if let size { result += "\\fs\(size)" }
            if let font { result += "\\fn\(font)" }
            return result
        }
    }

    /// The override block that starts a cue of `style` inside a joined event (TextCueMerge.joined). A reset (\r) does
    /// not clear bold, italic or underline in the encoder, so the complete style is stated.
    static func opening(_ style: String, header: Header) -> String {
        let tags = State(header.style(style)).tags
        return "{" + tags + tags + "}"
    }

    /// The text with every override block that changes the style written with the complete style after it, given
    /// the style of its event.
    static func normalizedText(_ text: String, style dialog: String, header: Header) -> String {
        var state = State(header.style(dialog))
        var result = ""
        var remainder = Substring(text)
        while let open = remainder.firstIndex(of: "{") {
            result += remainder[..<open]
            guard let close = remainder[open...].firstIndex(of: "}") else {
                remainder = remainder[open...]
                break
            }
            let block = remainder[remainder.index(after: open)..<close]
            remainder = remainder[remainder.index(after: close)...]
            // Style after the last character shows nothing, and a record the encoder starts at the very end of a cue
            // stays open into the next sample, so a block with only drawn-nothing text after it states no style.
            let last = visibleText(remainder).isEmpty
            let rewritten = rewrittenBlock(block, state: &state, dialog: dialog, header: header, stating: !last)
            // The encoder prints a block that does not start with a backslash, so one left empty is dropped.
            if !rewritten.isEmpty || block.isEmpty { result += "{" + rewritten + "}" }
        }
        return result + remainder
    }

    /// The text outside override blocks, with ASS line breaks counted as drawn.
    private static func visibleText(_ text: Substring) -> String {
        var result = ""
        var inBlock = false
        for character in text {
            if character == "{" && !inBlock {
                inBlock = true
            } else if character == "}" && inBlock {
                inBlock = false
            } else if !inBlock {
                result.append(character)
            }
        }
        return result
    }

    /// One override block: text before the first backslash (a comment) and the tags that do not set the style stay
    /// as they are, and the style tags are replaced by the complete style they leave in force, when `stating`.
    private static func rewrittenBlock(_ block: Substring, state: inout State, dialog: String, header: Header,
                                       stating: Bool) -> String {
        let parts = block.split(separator: "\\", omittingEmptySubsequences: false)
        var result = String(parts[0])
        var styled = false
        // Tags inside an animation such as \t(...) stay where they are.
        var depth = 0
        for part in parts.dropFirst() {
            if depth == 0, apply(String(part), to: &state, dialog: dialog, header: header) {
                styled = true
            } else {
                result += "\\" + part
                depth = max(0, depth + part.filter { $0 == "(" }.count - part.filter { $0 == ")" }.count)
            }
        }
        // The encoder skips a tag that matches the record in force, and starts the next record from the default style
        // at the first tag that does not. Written twice, every tag after the start lands in the new record too.
        return styled && stating ? result + state.tags + state.tags : result
    }

    /// Applies a style tag to the state, as ass_split.c reads it. False for a tag that does not set the style.
    private static func apply(_ tag: String, to state: inout State, dialog: String, header: Header) -> Bool {
        // A reset without a value returns to the style that the event or the last \r selected.
        let base = State(state.base)
        switch tag {
        case "b0", "b1": state.bold = tag == "b1"
        case "i0", "i1": state.italic = tag == "i1"
        case "u0", "u1": state.underline = tag == "u1"
        // 3GPP text has no strikethrough, but the encoder starts a style record for it from the default style.
        case "s0", "s1": break
        case "c", "1c": state.colour = base.colour
        case "alpha", "1a": state.alpha = base.alpha
        case "fs": state.size = base.size
        case "fn": state.font = base.font
        default:
            if tag.hasPrefix("r") {
                let name = String(tag.dropFirst())
                state = State(header.style(name.isEmpty ? dialog : name))
            } else if let value = hexValue(tag, after: ["c&H", "1c&H"]) {
                state.colour = value & 0xFF_FFFF
            } else if let value = hexValue(tag, after: ["alpha&H", "1a&H"]) {
                state.alpha = value & 0xFF
            } else if tag.hasPrefix("fs"), tag.count > 2, tag.dropFirst(2).allSatisfy({ $0.isASCII && $0.isNumber }),
                      let size = Int(tag.dropFirst(2)) {
                state.size = min(size, header.largestSize)
            } else if tag.hasPrefix("fn"), tag.count > 2 {
                state.font = String(tag.dropFirst(2))
            } else {
                return false
            }
        }
        return true
    }

    /// The hex value of a tag such as `1c&HFF&`, read as ass_split.c reads it: hex digits after the prefix, then `&`.
    private static func hexValue(_ tag: String, after prefixes: [String]) -> UInt32? {
        guard let prefix = prefixes.first(where: { tag.hasPrefix($0) }) else { return nil }
        let rest = tag.dropFirst(prefix.count)
        let digits = rest.prefix { $0.isHexDigit }
        guard !digits.isEmpty, rest.dropFirst(digits.count) == "&" else { return nil }
        return UInt32(digits.suffix(8), radix: 16)
    }

    /// The fonts that the events' `\fn` overrides name, in the order they first appear.
    static func fonts(_ events: [String]) -> [String] {
        var fonts: [String] = []
        for event in events {
            for block in event.split(separator: "{").dropFirst() {
                guard let close = block.firstIndex(of: "}") else { continue }
                for tag in block[..<close].split(separator: "\\").dropFirst() where tag.hasPrefix("fn") && tag.count > 2 {
                    let font = String(tag.dropFirst(2))
                    if !fonts.contains(font) { fonts.append(font) }
                }
            }
        }
        return fonts
    }
}
