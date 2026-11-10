import Foundation
import Testing
import DiskSurveyCore
@testable import disksurvey_cli

@Suite struct ArgumentParserTests {
    @Test func sizesAreDecimalUnlessMarkedBinary() throws {
        #expect(try ArgumentParser.size("4096", "--min-size") == 4096)
        #expect(try ArgumentParser.size("500K", "--min-size") == 500_000)
        #expect(try ArgumentParser.size("10MB", "--min-size") == 10_000_000)
        #expect(try ArgumentParser.size("1.5G", "--min-size") == 1_500_000_000)
        #expect(try ArgumentParser.size("1,5g", "--min-size") == 1_500_000_000)
        #expect(try ArgumentParser.size("2GiB", "--min-size") == 2_147_483_648)
        #expect(throws: UsageError.self) { try ArgumentParser.size("lots", "--min-size") }
        #expect(throws: UsageError.self) { try ArgumentParser.size("5 parsecs", "--min-size") }
    }

    @Test func agesCountBackFromNowAndDatesAreAbsolute() throws {
        let now: Int64 = 1_800_000_000
        #expect(try ArgumentParser.moment("12h", "--older-than", now: now) == now - 12 * 3600)
        #expect(try ArgumentParser.moment("30d", "--older-than", now: now) == now - 30 * 86400)
        #expect(try ArgumentParser.moment("2w", "--older-than", now: now) == now - 14 * 86400)
        #expect(try ArgumentParser.moment("1y", "--older-than", now: now) == now - 365 * 86400)
        let date = try ArgumentParser.moment("2025-01-31", "--older-than", now: now)
        var parts = DateComponents()
        (parts.year, parts.month, parts.day) = (2025, 1, 31)
        #expect(date == Int64(Calendar.current.date(from: parts)!.timeIntervalSince1970))
        #expect(throws: UsageError.self) { try ArgumentParser.moment("soon", "--older-than", now: now) }
    }

    @Test func commandsOptionsAndPositionals() throws {
        let scan = try ArgumentParser.parse(["/tmp", "-d", "3", "--top=5", "--min-size", "1M", "--json"])
        #expect(scan.command == .scan)
        #expect(scan.positionals == ["/tmp"])
        #expect(scan.depth == 3)
        #expect(scan.limit == 5)
        #expect(scan.minSize == 1_000_000)
        #expect(scan.json)

        let find = try ArgumentParser.parse(["find", "/tmp", "cache", "--kind", "mp4,MOV", "--category", "video", "--files", "-n25"])
        #expect(find.command == .find)
        #expect(find.positionals == ["/tmp", "cache"])
        #expect(find.kinds == ["mp4", "mov"])
        #expect(find.categories == [.video])
        #expect(find.scope == .files)
        #expect(find.limit == 25)

        let export = try ArgumentParser.parse(["export", "-f", "ncdu", "-o", "out.json", "--exclude", "/a", "--exclude", "/b", "--", "-odd-name"])
        #expect(export.command == .export)
        #expect(export.format == .ncdu)
        #expect(export.output == "out.json")
        #expect(export.excludes == ["/a", "/b"])
        #expect(export.positionals == ["-odd-name"])
    }

    @Test func mistakesAreUsageErrors() {
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["--no-such-option"]) }
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["scan", "--depth"]) }
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["scan", "--depth", "deep"]) }
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["export", "-f", "xml"]) }
        // An option that belongs to another command is rejected rather than silently ignored.
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["volumes", "--depth", "2"]) }
    }
}

@Suite struct TextTests {
    @Test func widthCountsTerminalCells() {
        #expect(Text.width("report.pdf") == 10)
        #expect(Text.width("日本語") == 6)
        #expect(Text.width("e\u{301}") == 1)          // combining acute accent
        #expect(Text.width("📦") == 2)
        #expect(Text.width("") == 0)
    }

    @Test func truncationRespectsCellWidth() {
        #expect(Text.truncated("short", to: 10) == "short")
        #expect(Text.truncated("a-rather-long-file-name.txt", to: 10) == "a-rather-…")
        let middle = Text.truncated("Library/Caches/Homebrew/downloads/archive.tar.gz", to: 24, cut: .middle)
        #expect(Text.width(middle) == 24)
        #expect(middle.hasSuffix("archive.tar.gz"))
        #expect(middle.contains("…"))
        // A wide character that does not fit is dropped, never split.
        #expect(Text.width(Text.truncated("日本語のファイル", to: 6)) <= 6)
        #expect(Text.truncated("anything", to: 1) == "…")
    }

    @Test func hostileNamesCannotDriveTheTerminal() {
        #expect(Text.sanitized("plain name.txt") == "plain name.txt")
        #expect(Text.sanitized("evil\u{1B}[2J\nname") == "evil?[2J?name")
        #expect(Text.sanitized("tab\there\u{7F}") == "tab?here?")
    }

    @Test func paddingAlignsByCells() {
        #expect(Text.padded("ab", to: 5) == "ab   ")
        #expect(Text.padded("ab", to: 5, right: true) == "   ab")
        #expect(Text.padded("日本", to: 5) == "日本 ")
        #expect(Text.padded("toolong", to: 3) == "toolong")
    }
}

@Suite struct JSONWriterTests {
    /// Runs `body` against a writer whose output goes to a pipe, and returns what was written.
    private func capture(pretty: Bool = false, _ body: (JSONWriter) -> Void) throws -> String {
        let pipe = Pipe()
        let output = Output(fd: pipe.fileHandleForWriting.fileDescriptor)
        let writer = JSONWriter(output, pretty: pretty)
        body(writer)
        writer.finish()
        output.flush()
        try pipe.fileHandleForWriting.close()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    @Test func producesValidJSONWithStableKeyOrder() throws {
        let text = try capture { json in
            json.beginObject()
            json.field("name", "a \"quoted\" \\ name\n\twith control \u{1} bytes and ünïcödé 📦")
            json.field("size", UInt64.max)
            json.field("count", -3)
            json.field("ok", true)
            json.field("ratio", 0.5)
            json.field("tags", strings: ["x", "y"])
            json.key("nothing"); json.null()
            json.key("children"); json.beginArray()
            json.beginObject(); json.field("n", 1); json.endObject()
            json.endArray()
            json.endObject()
        }
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(parsed["name"] as? String == "a \"quoted\" \\ name\n\twith control \u{1} bytes and ünïcödé 📦")
        #expect((parsed["size"] as? NSNumber)?.uint64Value == UInt64.max)
        #expect(parsed["count"] as? Int == -3)
        #expect(parsed["ok"] as? Bool == true)
        #expect(parsed["tags"] as? [String] == ["x", "y"])
        #expect(parsed["nothing"] is NSNull)
        #expect((parsed["children"] as? [[String: Any]])?.count == 1)
        let order = ["\"name\"", "\"size\"", "\"count\"", "\"ok\"", "\"ratio\"", "\"tags\"", "\"nothing\"", "\"children\""]
        let positions = order.compactMap { text.range(of: $0)?.lowerBound }
        #expect(positions.count == order.count && positions == positions.sorted())
    }

    @Test func prettyAndCompactOutputParseToTheSameValue() throws {
        func write(_ json: JSONWriter) {
            json.beginObject()
            json.key("list"); json.beginArray(); json.value(1); json.value("two"); json.endArray()
            json.endObject()
        }
        let compact = try capture(pretty: false, write)
        let pretty = try capture(pretty: true, write)
        let a = try JSONSerialization.jsonObject(with: Data(compact.utf8)) as? NSDictionary
        let b = try JSONSerialization.jsonObject(with: Data(pretty.utf8)) as? NSDictionary
        #expect(a != nil && a == b)
    }
}
