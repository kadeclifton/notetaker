import Foundation

/// Finds top-level values in the JSONC settings file by walking it (strings, comments and nesting
/// all understood), so a menu or settings window can change one value and leave every comment and
/// the rest of the layout alone.
enum ConfigText {
    /// The range of the value of top-level `key` (a string, number, bool, array or object).
    static func topLevelValue(_ key: String, in text: String) -> Range<String.Index>? {
        let chars = Array(text.unicodeScalars)
        var i = 0
        var depth = 0
        var expectingKey = false
        func index(_ offset: Int) -> String.Index {
            text.unicodeScalars.index(text.unicodeScalars.startIndex, offsetBy: offset)
        }
        while i < chars.count {
            let c = chars[i]
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "/" {
                while i < chars.count && chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count && !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            if c == "\"" {
                let start = i
                i = skipString(chars, from: i)
                if depth == 1 && expectingKey {
                    let name = String(String.UnicodeScalarView(chars[(start + 1)..<(i - 1)]))
                    var j = skipSpace(chars, from: i)
                    if j < chars.count, chars[j] == ":" {
                        j = skipSpace(chars, from: j + 1)
                        if name == key {
                            let end = skipValue(chars, from: j)
                            return index(j)..<index(end)
                        }
                        i = skipValue(chars, from: j)
                        expectingKey = false
                        continue
                    }
                }
                continue
            }
            switch c {
            case "{", "[":
                depth += 1
                if depth == 1 { expectingKey = true }
            case "}", "]":
                depth -= 1
            case ",":
                if depth == 1 { expectingKey = true }
            default:
                break
            }
            i += 1
        }
        return nil
    }

    /// Where a new top-level key can go: just before the closing brace of the outer object.
    static func closingBrace(in text: String) -> String.Index? {
        text.lastIndex(of: "}")
    }

    private static func skipString(_ chars: [Unicode.Scalar], from start: Int) -> Int {
        var i = start + 1
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            if chars[i] == "\"" { return i + 1 }
            i += 1
        }
        return i
    }

    private static func skipSpace(_ chars: [Unicode.Scalar], from start: Int) -> Int {
        var i = start
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\t" || c == "\n" || c == "\r" { i += 1; continue }
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "/" {
                while i < chars.count && chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count && !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            return i
        }
        return i
    }

    /// The end of the value starting at `start` (exclusive).
    private static func skipValue(_ chars: [Unicode.Scalar], from start: Int) -> Int {
        guard start < chars.count else { return start }
        if chars[start] == "\"" { return skipString(chars, from: start) }
        if chars[start] == "{" || chars[start] == "[" {
            var depth = 0
            var i = start
            while i < chars.count {
                let c = chars[i]
                if c == "\"" { i = skipString(chars, from: i); continue }
                if c == "/" && i + 1 < chars.count && chars[i + 1] == "/" {
                    while i < chars.count && chars[i] != "\n" { i += 1 }
                    continue
                }
                if c == "/" && i + 1 < chars.count && chars[i + 1] == "*" {
                    i += 2
                    while i + 1 < chars.count && !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                    i += 2
                    continue
                }
                if c == "{" || c == "[" { depth += 1 }
                if c == "}" || c == "]" {
                    depth -= 1
                    if depth == 0 { return i + 1 }
                }
                i += 1
            }
            return i
        }
        var i = start
        while i < chars.count, !",}] \t\r\n/".unicodeScalars.contains(chars[i]) { i += 1 }
        return i
    }
}

extension ConfigFileEdit {
    /// Sets top-level `key` to `json` (any JSON value), keeping comments and layout; adds the key
    /// if it is missing. Nil if the result would not parse or `verify` rejects it.
    public static func settingTopLevel(_ key: String, json: String, in text: String,
                                       verify: (Config) -> Bool) -> String? {
        var candidates: [String] = []
        if let range = ConfigText.topLevelValue(key, in: text) {
            candidates.append(text.replacingCharacters(in: range, with: json))
        } else if let close = ConfigText.closingBrace(in: text) {
            let addition = "\"\(key)\": \(json)\n"
            candidates.append(text.replacingCharacters(in: close..<close, with: ",\n  " + addition))
            candidates.append(text.replacingCharacters(in: close..<close, with: "  " + addition))
        }
        return candidates.first { (try? Config.parse($0)).map(verify) ?? false }
    }

    public static func setTopLevel(_ key: String, json: String, in file: URL, verify: (Config) -> Bool) throws -> Bool {
        let text = try String(contentsOf: file, encoding: .utf8)
        guard let updated = settingTopLevel(key, json: json, in: text, verify: verify) else { return false }
        try Data(updated.utf8).write(to: file, options: .atomic)
        return true
    }

    /// A JSON literal for any Encodable value, on one line.
    public static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }
}
