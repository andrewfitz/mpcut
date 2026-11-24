import Foundation

/// IDs for the records MPCut adds to a project.
///
/// A project needs each ID to be a nonblank string that is unique within its list. A UUID spends
/// 36 characters on that. Random text does not compress, so in a long edit the IDs outweigh the
/// clips and switches they name. Twelve symbols of five bits each carry 60 random bits in a third
/// of the space.
///
/// Two of n IDs in one list agree with probability about n(n − 1)/2 ÷ 2⁶⁰, or n² ÷ 2⁶¹. That is
/// one project in 6 × 10¹¹ at 2,000 clips, one in 2 × 10⁸ at 100,000 records and one in 2 × 10⁶
/// at a million. Project validation rejects a repeated ID, so a collision cannot save two records
/// under one name.
public enum ProjectIdentifier {
    public static let length = 12

    /// Lowercase letters and digits survive case-insensitive file systems, JSON and shell words
    /// unquoted, and an ID never begins with a hyphen. Leaving out i, l, o and u keeps 32 symbols
    /// with none that reads as 1, 0 or v.
    static let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz".utf8)

    public static func make() -> String {
        var generator = SystemRandomNumberGenerator()
        return make(using: &generator)
    }

    /// A new ID that differs from every ID already in the list it joins.
    public static func make<Existing: Sequence>(avoiding existing: Existing) -> String where Existing.Element == String {
        var generator = SystemRandomNumberGenerator()
        return make(avoiding: existing, using: &generator)
    }

    /// The ID for a record that is known in memory by a random UUID. The same UUID always yields
    /// the same ID, so every copy of the record names it alike without carrying the string.
    public static func make(from uuid: UUID) -> String {
        // Byte 6 holds the version and byte 8 the variant. The bytes read here are entirely random.
        let bytes = uuid.uuid
        let random = [bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.9, bytes.10]
        return encode(random.reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
    }

    static func make<Generator: RandomNumberGenerator>(using generator: inout Generator) -> String {
        encode(generator.next())
    }

    static func make<Existing: Sequence, Generator: RandomNumberGenerator>(
        avoiding existing: Existing, using generator: inout Generator
    ) -> String where Existing.Element == String {
        let taken = Set(existing)
        while true {
            let candidate = make(using: &generator)
            if !taken.contains(candidate) { return candidate }
        }
    }

    /// Five-bit groups of the low 60 bits index the alphabet directly, so every symbol is equally likely.
    private static func encode(_ bits: UInt64) -> String {
        String(decoding: (0..<length).map { alphabet[Int(bits >> UInt64(5 * $0) & 31)] }, as: UTF8.self)
    }
}
