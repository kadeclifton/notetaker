import Foundation

/// Reads `KEY=value` files. Supports `export`, quotes, `#` comments, and blank lines.
public enum DotEnv {
    public static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'",
               let close = value.dropFirst().firstIndex(of: quote) {
                value = String(value[value.index(after: value.startIndex)..<close])
            } else if let hash = value.range(of: " #") {
                value = value[..<hash.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            result[key] = value
        }
        return result
    }

    /// The `.env` file merged over the process environment; the file wins.
    public static func load(from url: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var merged = environment
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            merged.merge(parse(text)) { _, file in file }
        }
        return merged
    }
}
