import Foundation

public enum ContentClassifier {
    private static let urlRegex = try! NSRegularExpression(pattern: #"^(https?|ftp|file|mailto):[^\s]+$|^www\.[^\s]+\.[a-z]{2,}[^\s]*$"#, options: [.caseInsensitive])
    private static let emailRegex = try! NSRegularExpression(pattern: #"^[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}$"#, options: [.caseInsensitive])

    private static func matches(_ r: NSRegularExpression, _ s: String) -> Bool {
        r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    public static func classify(_ text: String) -> ContentKind {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .text }
        let isSingleLine = !t.contains("\n")
        if isSingleLine && t.count < 2048 {
            if matches(urlRegex, t) { return .link }
            if matches(emailRegex, t) { return .email }
        }
        if isJSON(t) { return .json }
        if isTable(t) { return .csv }
        let code = codeScore(t), md = markdownScore(t)
        if md >= 3 && md > code { return .markdown }
        if code >= 3 { return .code }
        if md >= 2 { return .markdown }
        return .text
    }

    public static func isJSON(_ t: String) -> Bool {
        guard let f = t.first, f == "{" || f == "[", let l = t.last, l == "}" || l == "]" else { return false }
        guard t.utf8.count < 20_000_000 else { return true }
        return (try? JSONSerialization.jsonObject(with: Data(t.utf8), options: [])) != nil
    }

    static func isTable(_ t: String) -> Bool {
        let lines = t.split(separator: "\n", omittingEmptySubsequences: true).prefix(50)
        guard lines.count >= 2 else { return false }
        for d in [Character("\t"), Character(","), Character(";"), Character("|")] {
            let counts = lines.map { $0.filter { $0 == d }.count }
            if let first = counts.first, first >= 1, counts.allSatisfy({ $0 == first }) {
                // Commas alone also fit ordinary two-line sentences; demand short-ish cells.
                if d == "," || d == ";" {
                    if lines.contains(where: { $0.count > 400 }) { return false }
                    if first < 2 && lines.count < 3 { return false }
                }
                return true
            }
        }
        return false
    }

    static func codeScore(_ t: String) -> Int {
        let lines = t.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return 0 }
        var score = 0
        let sample = lines.prefix(200)
        var indented = 0, endings = 0
        for l in sample {
            if l.hasPrefix("    ") || l.hasPrefix("\t") { indented += 1 }
            if let c = l.last, "{};)".contains(c) { endings += 1 }
        }
        if indented * 4 >= sample.count && sample.count > 1 { score += 2 }
        if endings * 3 >= sample.count { score += 2 }
        let patterns = [
            #"(?m)^\s*(def|class|func|fn|function|import|from|package|using|public|private|protected|struct|enum|interface|impl|const|let|var|return|if|for|while|elif|else|switch|case|try|catch|async|await)\b.*[\{\(:;]\s*$"#,
            #"(?mi)^\s*(select\s.+\sfrom|insert\s+into|update\s+\w+\s+set|delete\s+from|create\s+table|alter\s+table|with\s+\w+\s+as)\b"#,
            #"=>|->|::|\+\+|--\s|&&|\|\||!==?|===?|\bnull\b|\bnil\b|\bNone\b"#,
            #"#include\s*<|^\s*#!/|\$\(|</?[a-z][a-z0-9]*[^>]*>"#,
            #"(?m)^\s*(//|#|/\*|\*)\s"#,
            #"\w+\([^)]*\)\s*[\{:]?"#,
            #"\b\w+\s*=\s*[^=\s].*;\s*$"#,
        ]
        for (i, p) in patterns.enumerated() {
            if let re = try? NSRegularExpression(pattern: p, options: []),
               re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil {
                score += (i <= 1) ? 3 : 1
            }
        }
        // Prose usually has long sentences without brackets.
        let symbols = t.filter { "{}[]();=<>_$".contains($0) }.count
        if Double(symbols) / Double(max(t.count, 1)) > 0.04 { score += 1 }
        return score
    }

    static func markdownScore(_ t: String) -> Int {
        var score = 0
        let patterns = [
            #"(?m)^#{1,6}\s+\S"#, #"(?m)^\s*[-*+]\s+\S"#, #"(?m)^\s*\d+\.\s+\S"#,
            #"\[[^\]]+\]\([^)]+\)"#, #"\*\*[^*\n]+\*\*"#, #"(?m)^```"#, #"(?m)^>\s+\S"#, #"`[^`\n]+`"#,
        ]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p),
               re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil { score += 1 }
        }
        if t.range(of: #"(?m)^#{1,6}\s+\S"#, options: .regularExpression) != nil { score += 1 }
        return score
    }

    /// Helpful extra info for links.
    public static func domain(of text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = t.lowercased().hasPrefix("www.") ? "https://" + t : t
        return URL(string: candidate)?.host
    }
}
