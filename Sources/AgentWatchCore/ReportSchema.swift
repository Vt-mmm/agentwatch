import Foundation

/// Evaluates the closed subset used by our bundled schema. Unknown schema
/// features are rejected rather than silently treated as validated.
public enum ReportSchema {
    public static func validateSnapshot(_ data: Data) throws { try validate(data, schemaName: "daily-report-v1.schema") }
    public static func validateNarrative(_ data: Data) throws { try validate(data, schemaName: "report-narrative-v1.schema") }
    public static func validatePolicy(_ data: Data) throws { try validate(data, schemaName: "report-team-policy-v1.schema") }
    private static func validate(_ data: Data, schemaName: String) throws {
        guard data.count < 50_000_000,
              let url = Bundle.module.url(forResource: schemaName, withExtension: "json"),
              let schema = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw ReportValidationError.invalid("Không đọc được schema báo cáo.")
        }
        try check(JSONSerialization.jsonObject(with: data), schema: schema, root: schema, path: "$")
    }
    private static func check(_ value: Any, schema: [String: Any], root: [String: Any], path: String) throws {
        let supported: Set<String> = ["$schema", "$id", "$defs", "$ref", "title", "description", "type", "additionalProperties", "properties", "required", "items", "enum", "const", "minimum", "pattern", "format"]
        guard Set(schema.keys).isSubset(of: supported) else { throw invalid(path) }
        if let reference = schema["$ref"] as? String {
            guard reference.hasPrefix("#/$defs/"), let definitions = root["$defs"] as? [String: [String: Any]],
                  let resolved = definitions[String(reference.dropFirst(8))] else { throw invalid(path) }
            try check(value, schema: resolved, root: root, path: path); return
        }
        if let constant = schema["const"] as? String, value as? String != constant { throw invalid(path) }
        if let constant = schema["const"] as? Int, UsageIdentity.count(value, required: true) != constant { throw invalid(path) }
        if let values = schema["enum"] as? [String], !values.contains(value as? String ?? "") { throw invalid(path) }
        switch schema["type"] as? String {
        case "object":
            guard let object = value as? [String: Any], let properties = schema["properties"] as? [String: [String: Any]],
                  schema["additionalProperties"] as? Bool == false, Set(object.keys).isSubset(of: Set(properties.keys)),
                  Set(schema["required"] as? [String] ?? []).isSubset(of: Set(object.keys)) else { throw invalid(path) }
            for (key, child) in object { try check(child, schema: properties[key]!, root: root, path: path + "." + key) }
        case "array":
            guard let values = value as? [Any], let item = schema["items"] as? [String: Any] else { throw invalid(path) }
            for (index, child) in values.enumerated() { try check(child, schema: item, root: root, path: "\(path)[\(index)]") }
        case "string":
            guard let text = value as? String else { throw invalid(path) }
            if let pattern = schema["pattern"] as? String, text.range(of: pattern, options: .regularExpression) == nil { throw invalid(path) }
            if let format = schema["format"] as? String, format != "date-time" || PiTaskJournal.parseDate(text) == nil { throw invalid(path) }
        case "integer", "number":
            guard !UsageIdentity.isBoolean(value), let number = value as? NSNumber, number.doubleValue.isFinite else { throw invalid(path) }
            if schema["type"] as? String == "integer", number.doubleValue.rounded() != number.doubleValue { throw invalid(path) }
            if let minimum = schema["minimum"] as? Double, number.doubleValue < minimum { throw invalid(path) }
        case "boolean": guard UsageIdentity.isBoolean(value) else { throw invalid(path) }
        case nil: break // const-only schema
        default: throw invalid(path)
        }
    }
    private static func invalid(_ path: String) -> ReportValidationError { .invalid("Dữ liệu không đúng schema tại \(path).") }
}
