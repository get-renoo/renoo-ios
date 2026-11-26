import Foundation

/// A minimal JSON Schema (draft 2020-12) validator for the event schema tests. No third-party
/// dependencies, so it covers only the keywords the event schema uses. Any other keyword is an
/// error, never ignored: a schema change can't make the tests pass silently.
///
/// Limits: `$ref` resolves local JSON pointers only (`#/$defs/name`); `additionalProperties`
/// takes a boolean or a schema; `format` supports `date-time`.
struct JSONSchemaValidator {
    struct UnsupportedKeyword: Error, CustomStringConvertible {
        let keyword: String
        let path: String
        var description: String { "unsupported JSON Schema keyword '\(keyword)' at \(path)" }
    }

    /// Annotations: they never change the result.
    static let annotations: Set<String> = ["$schema", "$id", "$comment", "title", "description"]
    /// Keywords this validator evaluates.
    static let supported: Set<String> = [
        "$defs", "$ref", "type", "enum", "const", "properties", "required", "additionalProperties",
        "items", "contains", "uniqueItems", "minimum", "minLength", "pattern", "format",
        "allOf", "anyOf", "not", "if", "then",
    ]

    let root: [String: Any]

    init(schemaData: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: schemaData) as? [String: Any] else {
            throw UnsupportedKeyword(keyword: "(root is not an object)", path: "#")
        }
        self.root = root
        try Self.checkKeywords(root, path: "#")
    }

    /// The errors for `instance` (parsed with `JSONSerialization`); empty when it is valid.
    func validate(_ instance: Any) throws -> [String] {
        var errors: [String] = []
        try validate(instance, against: root, at: "$", errors: &errors)
        return errors
    }

    // MARK: Keyword check

    /// Fails on any keyword outside `supported` and `annotations`, in every subschema.
    private static func checkKeywords(_ schema: Any, path: String) throws {
        if schema is Bool { return }
        guard let schema = schema as? [String: Any] else {
            throw UnsupportedKeyword(keyword: "(schema is not an object or boolean)", path: path)
        }
        for (key, value) in schema {
            let here = "\(path)/\(key)"
            if annotations.contains(key) { continue }
            guard supported.contains(key) else { throw UnsupportedKeyword(keyword: key, path: path) }
            switch key {
            case "$defs", "properties":
                guard let map = value as? [String: Any] else { throw UnsupportedKeyword(keyword: key, path: path) }
                for (name, sub) in map { try checkKeywords(sub, path: "\(here)/\(name)") }
            case "allOf", "anyOf":
                guard let list = value as? [Any] else { throw UnsupportedKeyword(keyword: key, path: path) }
                for (index, sub) in list.enumerated() { try checkKeywords(sub, path: "\(here)/\(index)") }
            case "items", "contains", "not", "if", "then", "additionalProperties":
                try checkKeywords(value, path: here)
            case "$ref":
                guard let ref = value as? String, ref.hasPrefix("#/") else { throw UnsupportedKeyword(keyword: "$ref (non-local)", path: path) }
            case "format":
                guard value as? String == "date-time" else { throw UnsupportedKeyword(keyword: "format \(value)", path: path) }
            default:
                break
            }
        }
    }

    // MARK: Validation

    private func validate(_ instance: Any, against schema: Any, at path: String, errors: inout [String]) throws {
        if let flag = schema as? Bool {
            if !flag { errors.append("\(path): not allowed") }
            return
        }
        guard let schema = schema as? [String: Any] else { return }

        if let ref = schema["$ref"] as? String {
            try validate(instance, against: resolve(ref), at: path, errors: &errors)
        }
        if let type = schema["type"] {
            let types = (type as? [String]) ?? [(type as? String) ?? ""]
            if !types.contains(where: { Self.matches(instance, type: $0) }) {
                errors.append("\(path): expected type \(types), got \(Self.render(instance))")
            }
        }
        if let options = schema["enum"] as? [Any], !options.contains(where: { Self.equal($0, instance) }) {
            errors.append("\(path): \(Self.render(instance)) not in enum \(Self.render(options))")
        }
        if let constant = schema["const"], !Self.equal(constant, instance) {
            errors.append("\(path): \(Self.render(instance)) is not const \(Self.render(constant))")
        }
        if let object = instance as? [String: Any] {
            let properties = schema["properties"] as? [String: Any] ?? [:]
            for (key, sub) in properties {
                if let value = object[key] { try validate(value, against: sub, at: "\(path).\(key)", errors: &errors) }
            }
            for key in schema["required"] as? [String] ?? [] where object[key] == nil {
                errors.append("\(path): missing required '\(key)'")
            }
            if let additional = schema["additionalProperties"] {
                for (key, value) in object where properties[key] == nil {
                    try validate(value, against: additional, at: "\(path).\(key)", errors: &errors)
                }
            }
        }
        if let array = instance as? [Any] {
            if let items = schema["items"] {
                for (index, item) in array.enumerated() {
                    try validate(item, against: items, at: "\(path)[\(index)]", errors: &errors)
                }
            }
            if let contains = schema["contains"] {
                let any = try array.contains { try isValid($0, against: contains, at: path) }
                if !any { errors.append("\(path): no item matches 'contains'") }
            }
            if schema["uniqueItems"] as? Bool == true {
                for i in array.indices {
                    for j in array.indices where j > i && Self.equal(array[i], array[j]) {
                        errors.append("\(path): duplicate items at \(i) and \(j)")
                    }
                }
            }
        }
        if let minimum = schema["minimum"] as? NSNumber, let number = Self.number(instance), number.doubleValue < minimum.doubleValue {
            errors.append("\(path): \(number) < minimum \(minimum)")
        }
        if let string = instance as? String {
            if let minLength = schema["minLength"] as? Int, string.count < minLength {
                errors.append("\(path): shorter than \(minLength)")
            }
            if let pattern = schema["pattern"] as? String {
                let regex = try NSRegularExpression(pattern: pattern)
                if regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) == nil {
                    errors.append("\(path): '\(string)' doesn't match \(pattern)")
                }
            }
            if schema["format"] as? String == "date-time", !Self.isDateTime(string) {
                errors.append("\(path): '\(string)' is not a valid date-time")
            }
        }
        for sub in schema["allOf"] as? [Any] ?? [] {
            try validate(instance, against: sub, at: path, errors: &errors)
        }
        if let anyOf = schema["anyOf"] as? [Any] {
            let any = try anyOf.contains { try isValid(instance, against: $0, at: path) }
            if !any { errors.append("\(path): matches no 'anyOf' option: \(Self.render(instance))") }
        }
        if let not = schema["not"], try isValid(instance, against: not, at: path) {
            errors.append("\(path): matches 'not' \(Self.render(not))")
        }
        if let condition = schema["if"], try isValid(instance, against: condition, at: path), let then = schema["then"] {
            try validate(instance, against: then, at: path, errors: &errors)
        }
    }

    private func isValid(_ instance: Any, against schema: Any, at path: String) throws -> Bool {
        var errors: [String] = []
        try validate(instance, against: schema, at: path, errors: &errors)
        return errors.isEmpty
    }

    private func resolve(_ ref: String) throws -> Any {
        var node: Any = root
        for token in ref.dropFirst(2).split(separator: "/") {
            guard let next = (node as? [String: Any])?[String(token)] else {
                throw UnsupportedKeyword(keyword: "$ref \(ref) (unresolved)", path: ref)
            }
            node = next
        }
        return node
    }

    // MARK: JSON values

    private static func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func number(_ value: Any) -> NSNumber? {
        guard let number = value as? NSNumber, !isBool(number) else { return nil }
        return number
    }

    private static func matches(_ value: Any, type: String) -> Bool {
        switch type {
        case "null": return value is NSNull
        case "boolean": return isBool(value)
        case "integer":
            guard let number = number(value) else { return false }
            return number.doubleValue.rounded() == number.doubleValue
        case "number": return number(value) != nil
        case "string": return value is String
        case "array": return value is [Any]
        case "object": return value is [String: Any]
        default: return false
        }
    }

    /// JSON equality: a boolean never equals a number.
    private static func equal(_ a: Any, _ b: Any) -> Bool {
        switch (a, b) {
        case (is NSNull, is NSNull): return true
        case let (a as String, b as String): return a == b
        case let (a as [Any], b as [Any]): return a.count == b.count && zip(a, b).allSatisfy { equal($0, $1) }
        case let (a as [String: Any], b as [String: Any]):
            return a.count == b.count && a.allSatisfy { key, value in b[key].map { equal(value, $0) } ?? false }
        case let (a as NSNumber, b as NSNumber):
            return isBool(a) == isBool(b) && a == b
        default: return false
        }
    }

    /// RFC 3339 date-time that is a real date (rejects `2026-02-30T…`).
    private static func isDateTime(_ string: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: string) else { return false }
        // The formatter rolls invalid days over; formatting back must give the same calendar date.
        return formatter.string(from: date).prefix(10) == string.prefix(10)
    }

    private static func render(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) {
            return String(decoding: data, as: UTF8.self)
        }
        return "\(value)"
    }
}
