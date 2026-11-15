import Foundation

public enum SensitiveDetector {
    private static let patterns: [(String, String)] = [
        ("private key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        ("AWS access key", #"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#),
        ("GitHub token", #"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}\b|\bgithub_pat_[A-Za-z0-9_]{40,}\b"#),
        ("API key", #"\bsk-[A-Za-z0-9_\-]{20,}\b|\b[sr]k_(live|test)_[A-Za-z0-9]{16,}\b"#),
        ("Slack token", #"\bxox[abprs]-[A-Za-z0-9\-]{10,}\b"#),
        ("Google API key", #"\bAIza[0-9A-Za-z_\-]{35}\b"#),
        ("JSON web token", #"\beyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b"#),
        ("bearer token", #"(?i)\bbearer\s+[A-Za-z0-9_\-\.=]{20,}"#),
        ("credential assignment", #"(?i)\b(password|passwd|pwd|secret|api[_\-]?key|access[_\-]?token|auth[_\-]?token|client[_\-]?secret)\b["']?\s*[:=]\s*["']?[^\s"']{6,}"#),
    ]
    private static let compiled: [(String, NSRegularExpression)] = patterns.compactMap { name, p in
        (try? NSRegularExpression(pattern: p)).map { (name, $0) }
    }

    /// Returns a short human-readable reason when the text looks like a secret.
    public static func detect(_ text: String) -> String? {
        guard !text.isEmpty, text.utf8.count < 200_000 else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for (name, re) in compiled where re.firstMatch(in: text, range: range) != nil { return name }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isCardNumber(t) { return "card number" }
        if looksLikeSecretToken(t) { return "high-entropy token" }
        return nil
    }

    static func isCardNumber(_ t: String) -> Bool {
        let digits = t.filter { $0.isNumber }
        guard (13...19).contains(digits.count), t.allSatisfy({ $0.isNumber || $0 == " " || $0 == "-" }) else { return false }
        var sum = 0, alt = false
        for ch in digits.reversed() {
            var d = Int(String(ch))!
            if alt { d *= 2; if d > 9 { d -= 9 } }
            sum += d; alt.toggle()
        }
        return sum % 10 == 0
    }

    static func looksLikeSecretToken(_ t: String) -> Bool {
        guard (24...200).contains(t.count), !t.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "." || $0 == ":" }) else { return false }
        let hasUpper = t.contains { $0.isUppercase }, hasLower = t.contains { $0.isLowercase }, hasDigit = t.contains { $0.isNumber }
        guard hasUpper && hasLower && hasDigit else { return false }
        var freq: [Character: Int] = [:]
        t.forEach { freq[$0, default: 0] += 1 }
        let n = Double(t.count)
        let entropy = -freq.values.reduce(0.0) { $0 + (Double($1) / n) * log2(Double($1) / n) }
        return entropy > 4.0
    }
}
