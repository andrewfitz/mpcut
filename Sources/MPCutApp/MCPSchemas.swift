import Foundation
import MPCutCore

/// Read the same descriptors the bundled stdio server advertises.
struct MCPSchemas {
    typealias Object = [String: Any]
    struct WireInteger {
        let exact: Int?
    }
    typealias WireIntegers = [[JSONInputLocation]: WireInteger]
    static let projectDataPath: [JSONInputLocation] = [.key("arguments"), .key("project_data")]
    static let loaded = Result { try MCPSchemas() }
    let inputs: [String: Object]

    static func encodeResult(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(value)
    }

    init() throws {
        let directory: URL
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("MCPTools", isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.path) {
            directory = bundled
        } else if Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier == "com.mpcut.desktop" {
            throw MCPFailure("schema_unavailable", "Install the complete MPCut application bundle.")
        } else if let resources = Bundle.module.resourceURL {
            directory = resources.appendingPathComponent("MCPResources", isDirectory: true)
        } else {
            throw MCPFailure("schema_unavailable", "Missing MPCut development resources.")
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var inputs = [String: Object]()
        for url in files where url.pathExtension == "json" {
            guard let descriptors = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [Object] else {
                throw MCPFailure("schema_unavailable", "Invalid tool catalog at \(url.lastPathComponent).")
            }
            for descriptor in descriptors {
                guard let name = descriptor["name"] as? String, let schema = descriptor["inputSchema"] as? Object,
                      inputs.updateValue(schema, forKey: name) == nil else {
                    throw MCPFailure("schema_unavailable", "Invalid or duplicate tool definition.")
                }
            }
        }
        guard inputs["project_editor_state_read"] != nil else { throw MCPFailure("schema_unavailable", "Missing MPCut tool definitions.") }
        self.inputs = inputs
    }

    func validate(tool: String, arguments: Object, wireIntegers: WireIntegers = [:]) throws -> Object {
        guard let schema = inputs[tool] else { throw MCPFailure("unsupported_tool", "Unknown MPCut tool \(tool).") }
        guard var validated = try Self.check(arguments, schema: schema, tool: tool,
                                             path: [.key("arguments")], wireIntegers: wireIntegers) as? Object else {
            throw MCPFailure("schema_unavailable", "The tool must have an object input schema.")
        }
        // The CLI owns the inline .cut document schema. Preserve exact integers
        // here before the file job serializes that otherwise opaque object again.
        if let project = validated["project_data"], wireIntegers.keys.contains(where: { $0.starts(with: Self.projectDataPath) }) {
            validated["project_data"] = Self.restoreProjectIntegers(project, path: Self.projectDataPath, wireIntegers: wireIntegers)
        }
        return validated
    }

    private static func restoreProjectIntegers(_ value: Any, path: [JSONInputLocation], wireIntegers: WireIntegers) -> Any {
        if let exact = wireIntegers[path]?.exact { return exact }
        if var object = value as? Object {
            for (key, child) in object {
                object[key] = restoreProjectIntegers(child, path: path + [.key(key)], wireIntegers: wireIntegers)
            }
            return object
        }
        if let array = value as? [Any] {
            return array.enumerated().map { index, child in
                restoreProjectIntegers(child, path: path + [.index(index)], wireIntegers: wireIntegers)
            }
        }
        return value
    }

    private static func check(_ input: Any, schema: Object, tool: String, path: [JSONInputLocation],
                              wireIntegers: WireIntegers) throws -> Any {
        func reject(_ reason: String) -> MCPFailure {
            let location = path.dropFirst().reduce(into: tool) { name, part in
                switch part {
                case let .key(key): name += "." + key
                case let .index(index): name += "[\(index)]"
                }
            }
            return MCPFailure("invalid_arguments", "\(location): \(reason)")
        }
        if let types = schema["type"] as? [String] {
            var variant = schema
            for type in types {
                variant["type"] = type
                if let validated = try? check(input, schema: variant, tool: tool, path: path, wireIntegers: wireIntegers) {
                    return validated
                }
            }
            throw reject("Expected a supported value of type " + types.joined(separator: " or ") + ".")
        }
        var value = input
        if let choices = schema["enum"] as? [Any], !choices.contains(where: { matches(value, $0) }) {
            throw reject("Expected one of " + choices.map { String(describing: $0) }.joined(separator: ", ") + ".")
        }
        if let variants = schema["oneOf"] as? [Object] {
            let matches = variants.compactMap { try? check(value, schema: $0, tool: tool, path: path, wireIntegers: wireIntegers) }
            guard matches.count == 1 else { throw reject("The value must match one supported variant.") }
            value = matches[0]
        }
        for constraint in schema["allOf"] as? [Object] ?? [] {
            value = try check(value, schema: constraint, tool: tool, path: path, wireIntegers: wireIntegers)
        }
        if let excluded = schema["not"] as? Object,
           (try? check(value, schema: excluded, tool: tool, path: path, wireIntegers: wireIntegers)) != nil {
            throw reject("This field combination is unsupported.")
        }
        if let condition = schema["if"] as? Object, let consequent = schema["then"] as? Object,
           (try? check(value, schema: condition, tool: tool, path: path, wireIntegers: wireIntegers)) != nil {
            value = try check(value, schema: consequent, tool: tool, path: path, wireIntegers: wireIntegers)
        }
        if let constant = schema["const"], !matches(value, constant) { throw reject("Expected \(constant).") }
        let objectContract = schema["required"] != nil || schema["properties"] != nil
        switch schema["type"] as? String ?? (objectContract ? "object" : "") {
        case "object":
            guard var object = value as? Object else { throw reject("Expected an object.") }
            let properties = schema["properties"] as? [String: Object] ?? [:]
            for required in schema["required"] as? [String] ?? [] where object[required] == nil {
                throw reject("Missing \(required).")
            }
            for (key, child) in object {
                if let field = properties[key] {
                    object[key] = try check(child, schema: field, tool: tool, path: path + [.key(key)], wireIntegers: wireIntegers)
                } else if schema["additionalProperties"] as? Bool == false {
                    throw reject("Unexpected field \(key).")
                } else if let field = schema["additionalProperties"] as? Object {
                    object[key] = try check(child, schema: field, tool: tool, path: path + [.key(key)], wireIntegers: wireIntegers)
                }
            }
            return object
        case "array":
            guard let array = value as? [Any], array.count >= (schema["minItems"] as? Int ?? 0),
                  array.count <= (schema["maxItems"] as? Int ?? Int.max) else { throw reject("Invalid array or item count.") }
            if let items = schema["items"] as? Object {
                return try array.enumerated().map { index, entry in
                    try check(entry, schema: items, tool: tool, path: path + [.index(index)], wireIntegers: wireIntegers)
                }
            }
        case "string":
            guard let text = value as? String else { throw reject("Expected a string.") }
            if schema["minLength"] != nil || schema["maxLength"] != nil {
                let count = text.unicodeScalars.count
                guard count >= (schema["minLength"] as? Int ?? 0), count <= (schema["maxLength"] as? Int ?? Int.max)
                else { throw reject("Invalid string length.") }
            }
            if schema["format"] as? String == "uuid", UUID(uuidString: text) == nil { throw reject("Expected a UUID.") }
            if let pattern = schema["pattern"] as? String, text.range(of: pattern, options: .regularExpression) == nil {
                throw reject("Invalid format.")
            }
        case "integer":
            let exact: Int?
            if let wire = wireIntegers[path] { exact = wire.exact }
            else { exact = mcpInteger(value) }
            guard let number = exact, number >= (schema["minimum"] as? Int ?? Int.min),
                  number <= (schema["maximum"] as? Int ?? Int.max) else {
                throw reject("Expected an integer in the supported range.")
            }
            if let step = schema["multipleOf"] as? Int, step > 0, !number.isMultiple(of: step) {
                throw reject("Expected a multiple of \(step).")
            }
            return number
        case "number":
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= (schema["minimum"] as? Double ?? -.infinity),
                  number.doubleValue <= (schema["maximum"] as? Double ?? .infinity) else {
                throw reject("Expected a number in the supported range.")
            }
        case "null":
            guard value is NSNull else { throw reject("Expected null.") }
        case "boolean":
            guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else {
                throw reject("Expected true or false.")
            }
        default: break
        }
        return value
    }

    private static func matches(_ value: Any, _ allowed: Any) -> Bool {
        if let text = allowed as? String { return (value as? String)?.unicodeScalars.elementsEqual(text.unicodeScalars) == true }
        if let number = allowed as? NSNumber, let candidate = value as? NSNumber {
            let boolean = CFBooleanGetTypeID()
            return (CFGetTypeID(number) == boolean) == (CFGetTypeID(candidate) == boolean)
                && number.compare(candidate) == .orderedSame
        }
        return allowed is NSNull && value is NSNull
    }
}
