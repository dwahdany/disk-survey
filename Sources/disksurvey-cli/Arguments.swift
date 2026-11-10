import Foundation
import DiskSurveyCore

/// A mistake on the command line (exit status 2).
struct UsageError: Error {
    var message: String
    init(_ message: String) { self.message = message }
}

/// Something that went wrong while doing the work (exit status 1).
struct RuntimeError: Error {
    var message: String
    init(_ message: String) { self.message = message }
}

enum Command: String, CaseIterable {
    case scan, top, kinds, volumes, find, export, help

    /// Commands that read a directory tree.
    static let scanning: Set<Command> = [.scan, .top, .kinds, .find, .export]
}

enum ColorMode { case auto, always, never }
enum ExportFormat: String, CaseIterable { case json, csv, ncdu }

/// Everything the command line can say. One flat struct: the commands share most options.
struct Options {
    var command: Command = .scan
    var positionals: [String] = []

    var depth: Int?
    /// `-n`, `--limit`, and scan's `--top`: how many entries to list. nil = the command's default;
    /// an explicit 0 means "all" and is stored as `Int.max`, so every command treats it alike.
    var limit: Int?
    var minSize: UInt64?
    var maxSize: UInt64?
    var logical = false
    var json = false
    var color: ColorMode = .auto
    var ascii = false
    var threads = 0
    var crossMounts = false
    var excludes: [String] = []
    var noProgress = false
    var showIssues = false
    var packages = false
    var kinds: [String] = []
    var categories: [KindCategory] = []
    /// Epoch seconds: only entries modified before / after this moment.
    var modifiedBefore: Int64?
    var modifiedAfter: Int64?
    var scope: SearchQuery.Scope = .all
    var format: ExportFormat?
    var output: String?
    var all = false
    var help = false
    var version = false
}

enum ArgumentParser {
    private struct Spec: Sendable {
        let names: [String]
        let takesValue: Bool
        /// Commands the option applies to; nil = every command.
        let commands: Set<Command>?
        let apply: @Sendable (inout Options, String) throws -> Void

        init(
            _ names: String..., value: Bool = false, on commands: Set<Command>? = nil,
            _ apply: @escaping @Sendable (inout Options, String) throws -> Void
        ) {
            self.names = names
            self.takesValue = value
            self.commands = commands
            self.apply = apply
        }
    }

    private static let specs: [Spec] = [
        Spec("--depth", "-d", value: true, on: [.scan]) { o, v in o.depth = try integer(v, "--depth", 0...1000) },
        // Three spellings of one option, kept apart only so that an error names the one that was typed.
        Spec("--top", value: true, on: [.scan]) { o, v in o.limit = try limit(v, "--top") },
        Spec("--limit", value: true, on: [.scan, .top, .kinds, .find]) { o, v in o.limit = try limit(v, "--limit") },
        Spec("-n", value: true, on: [.scan, .top, .kinds, .find]) { o, v in o.limit = try limit(v, "-n") },
        Spec("--min-size", value: true, on: [.scan, .find]) { o, v in o.minSize = try size(v, "--min-size") },
        Spec("--max-size", value: true, on: [.find]) { o, v in o.maxSize = try size(v, "--max-size") },
        Spec("--logical", on: [.scan, .kinds]) { o, _ in o.logical = true },
        Spec("--json", on: [.scan, .top, .kinds, .volumes, .find]) { o, _ in o.json = true },
        Spec("--no-color") { o, _ in o.color = .never },
        Spec("--color") { o, _ in o.color = .always },
        Spec("--ascii") { o, _ in o.ascii = true },
        Spec("--threads", value: true, on: Command.scanning) { o, v in o.threads = try integer(v, "--threads", 0...64) },
        Spec("--cross-mounts", on: Command.scanning) { o, _ in o.crossMounts = true },
        Spec("--exclude", value: true, on: Command.scanning) { o, v in o.excludes.append(v) },
        Spec("--no-progress", on: Command.scanning) { o, _ in o.noProgress = true },
        Spec("--issues", on: Command.scanning) { o, _ in o.showIssues = true },
        Spec("--packages", on: [.scan, .top]) { o, _ in o.packages = true },
        Spec("--kind", value: true, on: [.find]) { o, v in
            for part in v.split(separator: ",") {
                let ext = part.trimmingCharacters(in: .whitespaces).lowercased()
                // Extensionless executables form a kind of their own, which has no extension to name.
                if ext == "unix-executable" || ext == FileKind.unixExecutableExtension {
                    o.kinds.append(FileKind.unixExecutableExtension)
                } else {
                    o.kinds.append(ext.hasPrefix(".") ? String(ext.dropFirst()) : ext)
                }
            }
        },
        Spec("--category", value: true, on: [.find]) { o, v in
            for part in v.split(separator: ",") { o.categories.append(try category(String(part))) }
        },
        Spec("--older-than", value: true, on: [.find]) { o, v in o.modifiedBefore = try moment(v, "--older-than") },
        Spec("--newer-than", value: true, on: [.find]) { o, v in o.modifiedAfter = try moment(v, "--newer-than") },
        Spec("--files", on: [.find]) { o, _ in o.scope = .files },
        Spec("--dirs", on: [.find]) { o, _ in o.scope = .directories },
        Spec("--format", "-f", value: true, on: [.export]) { o, v in
            guard let format = ExportFormat(rawValue: v.lowercased()) else {
                throw UsageError("unknown export format '\(v)' (expected json, csv or ncdu)")
            }
            o.format = format
        },
        Spec("--output", "-o", value: true, on: [.export]) { o, v in o.output = v },
        Spec("--all", "-a", on: [.volumes]) { o, _ in o.all = true },
        Spec("--help", "-h") { o, _ in o.help = true },
        Spec("--version", "-V") { o, _ in o.version = true },
    ]

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var used: [(name: String, spec: Spec)] = []
        var commandChosen = false
        var onlyPositionals = false
        var index = 0

        func nextValue(for name: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw UsageError("option \(name) needs a value") }
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            defer { index += 1 }

            if onlyPositionals || argument == "-" || !argument.hasPrefix("-") {
                // The first bare word names the command if it is one; a directory that happens to
                // be called "top" can still be scanned as `disksurvey scan top` or `disksurvey ./top`.
                if !commandChosen, !onlyPositionals, options.positionals.isEmpty,
                    let command = Command(rawValue: argument)
                {
                    options.command = command
                    commandChosen = true
                } else {
                    options.positionals.append(argument)
                }
                continue
            }
            if argument == "--" {
                onlyPositionals = true
                continue
            }

            var name = argument
            var inlineValue: String?
            if argument.hasPrefix("--") {
                if let equals = argument.firstIndex(of: "=") {
                    name = String(argument[..<equals])
                    inlineValue = String(argument[argument.index(after: equals)...])
                }
            } else if argument.count > 2 {
                // "-n25": a short option with its value attached.
                name = String(argument.prefix(2))
                inlineValue = String(argument.dropFirst(2))
            }

            guard let spec = specs.first(where: { $0.names.contains(name) }) else {
                var message = "unknown option '\(name)'"
                if let guess = closestOption(to: name) { message += " (did you mean \(guess)?)" }
                throw UsageError(message)
            }
            var value = ""
            if spec.takesValue {
                value = try inlineValue ?? nextValue(for: name)
            } else if inlineValue != nil {
                throw UsageError("option \(name) does not take a value")
            }
            try spec.apply(&options, value)
            used.append((name, spec))
        }

        if options.help || options.version || options.command == .help { return options }

        for (name, spec) in used {
            if let commands = spec.commands, !commands.contains(options.command) {
                let names = Command.allCases.filter { commands.contains($0) }.map(\.rawValue).joined(separator: ", ")
                throw UsageError("option \(name) does not apply to '\(options.command.rawValue)' (it belongs to: \(names))")
            }
        }
        try validatePositionals(options)
        return options
    }

    private static func validatePositionals(_ options: Options) throws {
        let count = options.positionals.count
        switch options.command {
        case .volumes:
            if count > 0 { throw UsageError("'volumes' takes no arguments") }
        case .find:
            if count == 0 { throw UsageError("usage: disksurvey find <path> <query> [filters]") }
            if count > 2 { throw UsageError("'find' takes a path and one query (quote a query that contains spaces)") }
        case .scan, .top, .kinds, .export:
            if count > 1 {
                throw UsageError(
                    "'\(options.command.rawValue)' takes a single path, got \(count): "
                        + options.positionals.joined(separator: " "))
            }
        case .help:
            break
        }
        // An empty path would otherwise resolve to the working directory: `disksurvey "$unset"` must
        // not quietly scan (or export) a different tree. Only the path is checked — find's query
        // (the second positional) may be empty when a filter is given.
        if Command.scanning.contains(options.command), options.positionals.first == "" {
            throw UsageError("empty path argument (an unset shell variable?); use '.' for the current directory")
        }
        if options.excludes.contains("") {
            throw UsageError("--exclude expects a path, got an empty string")
        }
        if options.command == .export, options.format == nil {
            throw UsageError("'export' needs --format json|csv|ncdu")
        }
        if let min = options.minSize, let max = options.maxSize, min > max {
            throw UsageError("--min-size is larger than --max-size")
        }
    }

    // MARK: - Value parsers

    private static func integer(_ text: String, _ name: String, _ range: ClosedRange<Int>) throws -> Int {
        guard let value = Int(text), range.contains(value) else {
            throw UsageError("\(name) expects a whole number from \(range.lowerBound) to \(range.upperBound), got '\(text)'")
        }
        return value
    }

    /// The value of `-n` / `--limit` / `--top`. 0 means "all" for every command.
    private static func limit(_ text: String, _ name: String) throws -> Int {
        let value = try integer(text, name, 0...10_000_000)
        return value == 0 ? Int.max : value
    }

    /// "4096", "500k", "10MB", "1.5G", "2GiB". Plain prefixes are decimal — the same units the
    /// output uses — and the "i" forms are binary.
    static func size(_ text: String, _ name: String) throws -> UInt64 {
        let lower = text.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: ".")
        let digits = lower.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
        let unit = lower.dropFirst(digits.count)
        let multipliers: [String: Double] = [
            "": 1, "b": 1,
            "k": 1e3, "kb": 1e3, "m": 1e6, "mb": 1e6, "g": 1e9, "gb": 1e9, "t": 1e12, "tb": 1e12, "p": 1e15, "pb": 1e15,
            "ki": 1024, "kib": 1024, "mi": 1_048_576, "mib": 1_048_576, "gi": 1_073_741_824, "gib": 1_073_741_824,
            "ti": 1_099_511_627_776, "tib": 1_099_511_627_776,
        ]
        guard let number = Double(digits), let multiplier = multipliers[String(unit)], number.isFinite,
            number * multiplier < 9e18
        else {
            throw UsageError("\(name) expects a size such as 500K, 10MB, 1.5G or 2GiB, got '\(text)'")
        }
        return UInt64((number * multiplier).rounded())
    }

    /// An age ("12h", "30d", "2w", "6m", "1y") counted back from now, or a calendar date
    /// ("2025-01-31", local midnight).
    static func moment(_ text: String, _ name: String, now: Int64 = Int64(Date().timeIntervalSince1970)) throws -> Int64 {
        let lower = text.lowercased()
        var broken = tm()
        if let end = strptime(lower, "%Y-%m-%d", &broken), end.pointee == 0 {
            broken.tm_isdst = -1
            let stamp = mktime(&broken)
            if stamp >= 0 { return Int64(stamp) }
        }
        let digits = lower.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
        let seconds: [String: Double] = [
            "h": 3600, "d": 86400, "w": 7 * 86400, "m": 30 * 86400, "mo": 30 * 86400, "y": 365 * 86400,
        ]
        guard let number = Double(digits), let unit = seconds[String(lower.dropFirst(digits.count))],
            number.isFinite, number * unit < 1e11
        else {
            throw UsageError(
                "\(name) expects an age such as 12h, 30d, 2w, 6m, 1y or a date such as 2025-01-31, got '\(text)'")
        }
        return now - Int64(number * unit)
    }

    static func categoryName(_ category: KindCategory) -> String { String(describing: category) }

    private static func category(_ text: String) throws -> KindCategory {
        let wanted = text.trimmingCharacters(in: .whitespaces).lowercased()
        for category in KindCategory.allCases {
            let names = [categoryName(category).lowercased(), category.displayName.lowercased()]
            if names.contains(wanted) || names.contains(where: { $0 == wanted + "s" || $0 + "s" == wanted }) {
                return category
            }
        }
        let valid = KindCategory.allCases.map(categoryName).joined(separator: ", ")
        throw UsageError("unknown category '\(text)' (expected one of: \(valid))")
    }

    // MARK: - Suggestions

    private static func closestOption(to name: String) -> String? {
        let candidates = specs.flatMap(\.names).filter { $0.hasPrefix("--") }
        let scored = candidates.map { ($0, editDistance(Array(name), Array($0))) }
        guard let best = scored.min(by: { $0.1 < $1.1 }), best.1 <= 3 else { return nil }
        return best.0
    }

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var row = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var previous = row[0]
            row[0] = i + 1
            for (j, cb) in b.enumerated() {
                let substitution = previous + (ca == cb ? 0 : 1)
                previous = row[j + 1]
                row[j + 1] = min(substitution, row[j] + 1, row[j + 1] + 1)
            }
        }
        return row[b.count]
    }
}
