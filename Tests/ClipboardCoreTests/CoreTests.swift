import Testing
import Foundation
@testable import ClipboardCore

private func tempStore() throws -> HistoryStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cm-test-\(UUID().uuidString)")
    return try HistoryStore(directory: dir)
}

@Suite struct ClassifierTests {
    @Test func detectsKinds() {
        #expect(ContentClassifier.classify("https://github.com/anthropics") == .link)
        #expect(ContentClassifier.classify("www.example.com/path") == .link)
        #expect(ContentClassifier.classify("someone@example.com") == .email)
        #expect(ContentClassifier.classify(#"{"a": 1, "b": [1,2]}"#) == .json)
        #expect(ContentClassifier.classify("name,age\nBob,3\nAnn,4") == .csv)
        #expect(ContentClassifier.classify("a\tb\n1\t2\n3\t4") == .csv)
        #expect(ContentClassifier.classify("def add(a, b):\n    return a + b\n") == .code)
        #expect(ContentClassifier.classify("SELECT id, name FROM users WHERE id = 1") == .code)
        #expect(ContentClassifier.classify("# Title\n\n- one\n- two\n\nSee [link](http://x.y)") == .markdown)
        #expect(ContentClassifier.classify("Remember to buy milk and eggs tomorrow morning.") == .text)
    }
    @Test func domain() { #expect(ContentClassifier.domain(of: "https://docs.github.com/x") == "docs.github.com") }
}

@Suite struct SensitiveTests {
    @Test func flagsSecrets() {
        #expect(SensitiveDetector.detect("AKIAIOSFODNN7EXAMPLE") != nil)
        #expect(SensitiveDetector.detect("ghp_abcdefghijklmnopqrstuvwxyz0123456789") != nil)
        #expect(SensitiveDetector.detect("-----BEGIN RSA PRIVATE KEY-----\nabc") != nil)
        #expect(SensitiveDetector.detect("password = hunter22hunter") != nil)
        #expect(SensitiveDetector.detect("4111 1111 1111 1111") != nil)
        #expect(SensitiveDetector.detect("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijk") != nil)
    }
    @Test func ignoresOrdinaryText() {
        #expect(SensitiveDetector.detect("Let's meet at 5pm to discuss the password policy") == nil)
        #expect(SensitiveDetector.detect("https://github.com/anthropics/claude-code") == nil)
        #expect(SensitiveDetector.detect("def add(a, b):\n    return a + b") == nil)
        #expect(SensitiveDetector.detect("1234 5678") == nil)
    }
}

@Suite struct TransformTests {
    @Test func jsonRoundTripKeepsOrder() throws {
        let src = #"{"z":1,"a":[1,2,{"k":"v, \"q\""}],"e":{},"s":"x:y"}"#
        let pretty = try #require(Transforms.formatJSON(src))
        #expect(pretty.contains("\n  \"z\": 1,\n  \"a\": ["))
        #expect(pretty.contains("\"e\": {}"))
        #expect(Transforms.minifyJSON(pretty) == src)
        #expect(Transforms.formatJSON("{nope") == nil)
    }
    @Test func sql() {
        let out = Transforms.formatSQL("select a, b from t left join u on t.id=u.id where x = 1 and y in (select 1, 2) order by a")
        #expect(out == "SELECT\n  a,\n  b\nFROM t\nLEFT JOIN u\n  ON t.id = u.id\nWHERE x = 1\n  AND y IN (SELECT 1, 2)\nORDER BY a")
    }
    @Test func whitespace() {
        #expect(Transforms.cleanWhitespace("  a   b  \n\n\n\n    c    d\t \n") == "a b\n\n    c d")
    }
}

@Suite struct StoreTests {
    @Test func saveSearchDedupe() throws {
        let s = try tempStore()
        let code = "def f(x):\n    return x * 2\n"
        let a = try s.save(NewClip(kind: .code, text: code, sourceApp: "Xcode"))
        let b = try s.save(NewClip(kind: .code, text: code))
        #expect(a.id == b.id && a.isNew && !b.isNew)
        _ = try s.save(NewClip(kind: .link, text: "https://github.com/a/b"))
        #expect(s.count() == 2)
        #expect(s.fetch(search: "github.com").count == 1)
        #expect(s.fetch(search: "return x").first?.id == a.id)
        #expect(s.fetch(search: "xcode").count == 1)          // source app is searchable
        #expect(s.fetch(search: "100%").isEmpty)                // wildcards are escaped
        #expect(s.fetch(filter: .links).count == 1 && s.fetch(filter: .code).count == 1)
        #expect(s.payload(id: a.id)?.text == code)             // exact indentation preserved
    }
    @Test func pinFavoriteTagsAndRetention() throws {
        let s = try tempStore()
        let old = Date().addingTimeInterval(-40 * 86400)
        let p = try s.save(NewClip(kind: .text, text: "keep me"), now: old)
        let q = try s.save(NewClip(kind: .text, text: "drop me"), now: old)
        s.setPinned(p.id, true); s.setFavorite(q.id, true); s.setTags(q.id, ["sql", " work "])
        #expect(s.entry(id: q.id)?.tags == ["sql", "work"])
        #expect(s.fetch(filter: .pinned).map(\.id) == [p.id])
        #expect(s.fetch(search: "work").count == 1)
        #expect(s.purge(olderThanDays: 30, maxEntries: 0) == 1)
        #expect(s.entry(id: p.id) != nil && s.entry(id: q.id) == nil)
    }
    @Test func imagesAndPersistence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cm-test-\(UUID().uuidString)")
        var s: HistoryStore? = try HistoryStore(directory: dir)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let r = try #require(try s?.save(NewClip(kind: .image, imagePNG: png, imageWidth: 10, imageHeight: 5)))
        s = nil
        let again = try HistoryStore(directory: dir)               // reopened: history persists
        let e = try #require(again.entry(id: r.id))
        #expect(e.kind == .image && e.imageWidth == 10)
        #expect(try Data(contentsOf: try #require(again.payload(id: r.id)?.imageURL)) == png)
        again.delete(ids: [r.id])
        #expect(try FileManager.default.contentsOfDirectory(atPath: again.imagesDirectory.path).isEmpty)
    }
    @Test func clearKeepsPinned() throws {
        let s = try tempStore()
        let a = try s.save(NewClip(kind: .text, text: "a")); _ = try s.save(NewClip(kind: .text, text: "b"))
        s.setPinned(a.id, true)
        s.clear(keepPinned: true)
        #expect(s.count() == 1)
        s.clear(keepPinned: false)
        #expect(s.count() == 0)
    }
    @Test func manyEntriesSearchIsFast() throws {
        let s = try tempStore()
        for i in 0..<5000 { _ = try s.save(NewClip(kind: .text, text: "entry number \(i) lorem ipsum dolor sit amet \(i * 7)")) }
        let t = Date()
        let r = s.fetch(search: "number 4999")
        #expect(r.count == 1)
        #expect(Date().timeIntervalSince(t) < 0.5)
        #expect(s.fetch(limit: 100, offset: 100).count == 100)
    }
}
