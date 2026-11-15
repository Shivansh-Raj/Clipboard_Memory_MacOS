import Foundation

/// Text transformations. Each returns a *new* string; the original entry is never modified.
public enum Transforms {
    // MARK: JSON (order-preserving)

    public static func formatJSON(_ text: String, indent: String = "  ") -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (try? JSONSerialization.jsonObject(with: Data(t.utf8), options: [.fragmentsAllowed])) != nil else { return nil }
        var out = "", depth = 0, inString = false, escaped = false
        let chars = Array(t)
        var i = 0
        func newline() { out += "\n" + String(repeating: indent, count: depth) }
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else {
                switch c {
                case "\"": inString = true; out.append(c)
                case "{", "[":
                    // Keep empty containers compact.
                    var j = i + 1
                    while j < chars.count, chars[j].isWhitespace { j += 1 }
                    if j < chars.count, (c == "{" && chars[j] == "}") || (c == "[" && chars[j] == "]") {
                        out.append(c); out.append(chars[j]); i = j
                    } else { out.append(c); depth += 1; newline() }
                case "}", "]": depth -= 1; newline(); out.append(c)
                case ",": out.append(c); newline()
                case ":": out += ": "
                case " ", "\n", "\t", "\r": break
                default: out.append(c)
                }
            }
            i += 1
        }
        return out
    }

    public static func minifyJSON(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (try? JSONSerialization.jsonObject(with: Data(t.utf8), options: [.fragmentsAllowed])) != nil else { return nil }
        var out = "", inString = false, escaped = false
        for c in t {
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" { inString = true; out.append(c) }
            else if !c.isWhitespace { out.append(c) }
        }
        return out
    }

    // MARK: Simple text transforms

    public static func uppercased(_ t: String) -> String { t.uppercased() }
    public static func lowercased(_ t: String) -> String { t.lowercased() }

    /// Trims line ends, collapses repeated inner spaces and runs of blank lines. Indentation is preserved.
    public static func cleanWhitespace(_ text: String) -> String {
        var lines: [String] = []
        var blank = false
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            var line = raw
            while let l = line.last, l == " " || l == "\t" { line.removeLast() }
            if line.isEmpty {
                if blank { continue }
                blank = true
            } else { blank = false }
            let indentEnd = line.firstIndex(where: { $0 != " " && $0 != "\t" }) ?? line.startIndex
            let indent = line[..<indentEnd]
            let rest = line[indentEnd...].replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            lines.append(indent + rest)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: SQL

    private static let majorClauses: Set<String> = ["SELECT", "FROM", "WHERE", "GROUP BY", "ORDER BY", "HAVING", "LIMIT", "OFFSET",
        "UNION", "UNION ALL", "INSERT INTO", "VALUES", "UPDATE", "SET", "DELETE FROM", "RETURNING", "WITH", "EXCEPT", "INTERSECT"]
    private static let joinWords: Set<String> = ["JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "OUTER", "NATURAL"]
    private static let keywords: Set<String> = majorClauses.union(joinWords).union(["AND", "OR", "ON", "AS", "IN", "NOT", "NULL", "IS", "LIKE",
        "BETWEEN", "DISTINCT", "BY", "ASC", "DESC", "CASE", "WHEN", "THEN", "ELSE", "END", "EXISTS", "ALL", "INTO", "USING", "COUNT", "SUM", "AVG", "MIN", "MAX"])

    public static func formatSQL(_ text: String) -> String {
        // Tokenise, preserving strings, quoted identifiers and comments.
        var tokens: [String] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c == "'" || c == "\"" || c == "`" {
                var j = i + 1
                while j < chars.count {
                    if chars[j] == c { if j + 1 < chars.count, chars[j + 1] == c { j += 2; continue }; break }
                    j += 1
                }
                tokens.append(String(chars[i..<min(j + 1, chars.count)])); i = j + 1
            } else if c == "-", i + 1 < chars.count, chars[i + 1] == "-" {
                var j = i; while j < chars.count, chars[j] != "\n" { j += 1 }
                tokens.append(String(chars[i..<j]) + "\u{0}"); i = j
            } else if c.isLetter || c.isNumber || c == "_" || c == "." || c == "@" || c == "$" || c == ":" {
                var j = i; while j < chars.count, chars[j].isLetter || chars[j].isNumber || "_.@$:*".contains(chars[j]) { j += 1 }
                if j == i { j = i + 1 }
                tokens.append(String(chars[i..<j])); i = j
            } else if "<>=!".contains(c) {
                var j = i + 1; while j < chars.count, "<>=".contains(chars[j]) { j += 1 }
                tokens.append(String(chars[i..<j])); i = j
            } else { tokens.append(String(c)); i += 1 }
        }

        var out = "", depth = 0, clause = ""
        var lineStart = true
        func emit(_ s: String, space: Bool = true) {
            if !lineStart && space && !out.hasSuffix("(") && !out.hasSuffix("\n") { out += " " }
            out += s; lineStart = false
        }
        func newline(_ indent: Int) { out += "\n" + String(repeating: "  ", count: indent); lineStart = true }
        var idx = 0
        while idx < tokens.count {
            let tok = tokens[idx]
            let up = tok.uppercased()
            if tok.hasSuffix("\u{0}") { emit(String(tok.dropLast())); newline(0); idx += 1; continue }
            if tok == "(" { depth += 1; emit("("); idx += 1; continue }
            if tok == ")" { depth = max(0, depth - 1); out += ")"; lineStart = false; idx += 1; continue }
            if tok == ";" { out += ";"; newline(0); clause = ""; idx += 1; continue }
            if tok == "," {
                out += ","
                if depth == 0 && ["SELECT", "SET", "GROUP BY", "ORDER BY"].contains(clause) { newline(1) }
                idx += 1; continue
            }
            if tok == "." || tok == "*" { emit(tok); idx += 1; continue }
            // Multi-word clauses.
            var word = up
            var consumed = 1
            if idx + 1 < tokens.count {
                let two = up + " " + tokens[idx + 1].uppercased()
                if ["GROUP BY", "ORDER BY", "INSERT INTO", "DELETE FROM", "UNION ALL"].contains(two) { word = two; consumed = 2 }
            }
            if depth == 0, majorClauses.contains(word) {
                if !out.isEmpty && !out.hasSuffix("\n") && !lineStart { newline(0) }
                emit(word); clause = word; idx += consumed
                if word == "SELECT" || word == "SET" {
                    if word == "SELECT", idx < tokens.count, tokens[idx].uppercased() == "DISTINCT" { emit("DISTINCT"); idx += 1 }
                    newline(1)
                }
                continue
            }
            if depth == 0, joinWords.contains(up) {
                // Gather "LEFT OUTER JOIN" as one line.
                var parts = [up]; var k = idx + 1
                while parts.last != "JOIN", k < tokens.count, joinWords.contains(tokens[k].uppercased()) { parts.append(tokens[k].uppercased()); k += 1 }
                if !out.hasSuffix("\n") { newline(0) }
                emit(parts.joined(separator: " ")); clause = "JOIN"; idx = k; continue
            }
            if depth == 0, (up == "AND" || up == "OR"), clause == "WHERE" || clause == "JOIN" || clause == "HAVING" {
                newline(1); emit(up); idx += 1; continue
            }
            if depth == 0, up == "ON" { newline(1); emit(up); idx += 1; continue }
            emit(keywords.contains(up) ? up : tok); idx += 1
        }
        // Put the first item of SELECT/SET lists on its own indented line for readability.
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
