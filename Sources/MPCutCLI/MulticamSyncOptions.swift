import MPCutCore

struct MulticamSyncOptions {
    struct Replacement {
        let path: String
        let stream: Int
        let referenceStream: Int?
        let seed: RationalTime?
        let program: Bool
    }

    let project: String
    let sourceID: String?
    let referenceSourceID: String?
    let metadataOnly: Bool
    let replacement: Replacement?

    init(_ options: [String]) throws {
        let usage = "Use multicam sync suggest --project FILE [--source-id ID] [--reference-source-id ID] [--metadata-only]."
        var values: [String: String] = [:]
        var flags = Set<String>()
        var iterator = options.makeIterator()
        while let option = iterator.next() {
            guard flags.insert(option).inserted else { throw CLIError("invalid_arguments", "Duplicate " + option) }
            if ["--metadata-only", "--program", "--json"].contains(option) { continue }
            guard ["--project", "--source-id", "--reference-source-id", "--reference-stream", "--replacement",
                   "--replacement-stream", "--seed"].contains(option),
                  let value = iterator.next(), !value.isEmpty, !value.hasPrefix("--") else {
                throw CLIError("invalid_arguments", usage)
            }
            values[option] = value
        }
        guard let project = values["--project"] else { throw CLIError("invalid_arguments", usage) }
        self.project = project
        sourceID = values["--source-id"]
        referenceSourceID = values["--reference-source-id"]
        metadataOnly = flags.contains("--metadata-only")
        if let path = values["--replacement"] {
            let program = flags.contains("--program")
            let reference = values["--reference-stream"].flatMap(Int.init)
            guard sourceID == nil, referenceSourceID != nil,
                  (reference.map { $0 >= 0 } ?? (program && values["--reference-stream"] == nil)),
                  let stream = values["--replacement-stream"].flatMap(Int.init), stream >= 0 else {
                throw CLIError("invalid_arguments", "Supply --reference-source-id and --replacement-stream. Track replacement sync also requires --reference-stream.")
            }
            replacement = try .init(path: path, stream: stream, referenceStream: reference,
                                    seed: values["--seed"].map { try RationalTime(parsing: $0) }, program: program)
        } else {
            guard values["--reference-stream"] == nil, values["--replacement-stream"] == nil,
                  values["--seed"] == nil, !flags.contains("--program") else {
                throw CLIError("invalid_arguments", "Replacement sync options require --replacement.")
            }
            replacement = nil
        }
    }
}
