import Foundation

/// The locale-dependent bits of number formatting, captured once so that formatting itself is
/// pure string work: thread-safe, allocation-light and fast enough for table cells.
public struct NumberSymbols: Sendable, Hashable {
    public var decimalSeparator: String
    public var groupingSeparator: String
    /// "B" in most languages; French uses "o" (octet): "Ko", "Mo", "Go".
    public var byteSuffix: String
    public var bytesWord: (singular: String, plural: String) {
        byteSuffix == "o" ? ("octet", "octets") : ("byte", "bytes")
    }

    public init(decimalSeparator: String = ".", groupingSeparator: String = ",", byteSuffix: String = "B") {
        self.decimalSeparator = decimalSeparator
        self.groupingSeparator = groupingSeparator
        self.byteSuffix = byteSuffix
    }

    public init(locale: Locale) {
        decimalSeparator = locale.decimalSeparator ?? "."
        groupingSeparator = locale.groupingSeparator ?? ","
        byteSuffix = locale.language.languageCode?.identifier == "fr" ? "o" : "B"
    }

    /// Symbols of the user's locale, captured at first use.
    public static let current = NumberSymbols(locale: .autoupdatingCurrent)

    /// Fixed "1,234.5" symbols, independent of the user's settings (logs, tests, machine output).
    public static let posix = NumberSymbols()
}

/// Human-readable formatting of sizes, counts, percentages and dates.
public enum Format {
    private static let unitPrefixes = ["K", "M", "G", "T", "P", "E"]

    /// A byte count in decimal units, the way Finder shows sizes: "0 bytes", "812 bytes",
    /// "123 KB", "45.6 MB", "12.4 GB", "1.23 TB". About three significant digits.
    public static func bytes(_ count: UInt64, symbols: NumberSymbols = .current) -> String {
        if count < 1000 {
            let word = symbols.bytesWord
            return "\(count) \(count == 1 ? word.singular : word.plural)"
        }
        var unit = 0
        var value = Double(count) / 1000
        while value >= 1000, unit < unitPrefixes.count - 1 {
            value /= 1000
            unit += 1
        }
        var decimals = fractionDigits(value, unit: unit)
        var scaled = (value * pow10(decimals)).rounded()
        if scaled >= 1000 * pow10(decimals), unit < unitPrefixes.count - 1 {
            // Rounding carried us to "1000 MB": show "1 GB" instead.
            value /= 1000
            unit += 1
            decimals = fractionDigits(value, unit: unit)
            scaled = (value * pow10(decimals)).rounded()
        }
        return fixed(UInt64(scaled), decimals: decimals, symbols: symbols, group: false)
            + " " + unitPrefixes[unit] + symbols.byteSuffix
    }

    /// An exact byte count with grouping: "1,234,567 bytes".
    public static func exactBytes(_ count: UInt64, symbols: NumberSymbols = .current) -> String {
        let word = symbols.bytesWord
        return grouped(count, symbols: symbols) + " " + (count == 1 ? word.singular : word.plural)
    }

    /// An integer with grouping separators: "1,234,567".
    public static func count(_ value: Int, symbols: NumberSymbols = .current) -> String {
        value < 0 ? "-" + grouped(value.magnitude.asUInt64, symbols: symbols) : grouped(UInt64(value), symbols: symbols)
    }

    /// A short count: "950", "1.2K", "34K", "5.6M", "1.2B".
    public static func compactCount(_ value: Int, symbols: NumberSymbols = .current) -> String {
        let magnitude = value.magnitude.asUInt64
        guard magnitude >= 1000 else { return String(value) }
        let suffixes = ["K", "M", "B", "T"]
        var unit = 0
        var scaledValue = Double(magnitude) / 1000
        while scaledValue >= 1000, unit < suffixes.count - 1 {
            scaledValue /= 1000
            unit += 1
        }
        var decimals = scaledValue < 10 ? 1 : 0
        var scaled = (scaledValue * pow10(decimals)).rounded()
        if scaled >= 1000 * pow10(decimals), unit < suffixes.count - 1 {
            scaledValue /= 1000
            unit += 1
            decimals = 1
            scaled = (scaledValue * 10).rounded()
        }
        return (value < 0 ? "-" : "") + fixed(UInt64(scaled), decimals: decimals, symbols: symbols, group: false)
            + suffixes[unit]
    }

    /// "No items", "1 item", "1,234 items".
    public static func items(_ value: Int, symbols: NumberSymbols = .current) -> String {
        counted(value, singular: "item", plural: "items", symbols: symbols)
    }

    /// "No files", "1 file", "1,234 files".
    public static func files(_ value: Int, symbols: NumberSymbols = .current) -> String {
        counted(value, singular: "file", plural: "files", symbols: symbols)
    }

    /// "No <plural>", "1 <singular>", "1,234 <plural>".
    public static func counted(
        _ value: Int, singular: String, plural: String, symbols: NumberSymbols = .current
    ) -> String {
        switch value {
        case 0: "No \(plural)"
        case 1: "1 \(singular)"
        default: "\(count(value, symbols: symbols)) \(plural)"
        }
    }

    /// A fraction (0…1) as a percentage with one decimal: "0%", "<0.1%", "12.3%", "100%".
    public static func percent(_ fraction: Double, symbols: NumberSymbols = .current) -> String {
        guard fraction.isFinite, fraction > 0 else { return "0%" }
        let tenths = (fraction * 1000).rounded()
        if tenths < 1 { return "<0\(symbols.decimalSeparator)1%" }
        if tenths >= 1000 && fraction <= 1.0005 { return "100%" }
        return fixed(UInt64(min(tenths, 1e15)), decimals: 1, symbols: symbols, group: true, trimZeros: false) + "%"
    }

    /// `part / whole` as a percentage; "0%" when `whole` is zero.
    public static func percent(_ part: UInt64, of whole: UInt64, symbols: NumberSymbols = .current) -> String {
        whole == 0 ? "0%" : percent(Double(part) / Double(whole), symbols: symbols)
    }

    /// A timestamp relative to now: "Just now", "5 minutes ago", "Yesterday", "3 weeks ago",
    /// "2 years ago". Unknown (0) timestamps give "—"; future ones the absolute date.
    public static func relativeDate(_ epochSeconds: Int64, now: Int64 = Int64(Date().timeIntervalSince1970)) -> String {
        guard epochSeconds > 0 else { return "—" }
        let delta = now - epochSeconds
        if delta < -60 { return date(epochSeconds) }
        func ago(_ n: Int64, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s") ago" }
        let minute: Int64 = 60, hour: Int64 = 3600, day: Int64 = 86_400
        switch delta {
        case ..<minute: return "Just now"
        case ..<hour: return ago(delta / minute, "minute")
        case ..<day: return ago(delta / hour, "hour")
        case ..<(2 * day): return "Yesterday"
        case ..<(7 * day): return ago(delta / day, "day")
        case ..<(30 * day): return ago(delta / (7 * day), "week")
        case ..<(365 * day): return ago(delta / (30 * day), "month")
        default: return ago(delta / (365 * day), "year")
        }
    }

    /// An absolute date in the user's locale ("9 Nov 2026"); "—" for unknown (0) timestamps.
    public static func date(_ epochSeconds: Int64, includingTime: Bool = false) -> String {
        guard epochSeconds > 0 else { return "—" }
        return Date(timeIntervalSince1970: TimeInterval(epochSeconds))
            .formatted(date: .abbreviated, time: includingTime ? .shortened : .omitted)
    }

    /// A short duration: "0.42 s", "3.2 s", "45 s", "2 min 5 s", "1 h 12 min".
    public static func duration(_ seconds: Double, symbols: NumberSymbols = .current) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        if seconds < 0.995 {
            return fixed(UInt64((seconds * 100).rounded()), decimals: 2, symbols: symbols, group: false, trimZeros: false)
                + " s"
        }
        // One decimal up to "9.9 s". Decided after rounding, so 9.95…9.99 become "10 s" below
        // rather than "10.0 s".
        let tenths = (seconds * 10).rounded()
        if tenths < 100 {
            return fixed(UInt64(tenths), decimals: 1, symbols: symbols, group: false, trimZeros: false) + " s"
        }
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole) s" }
        if whole < 3600 {
            return whole % 60 == 0 ? "\(whole / 60) min" : "\(whole / 60) min \(whole % 60) s"
        }
        let minutes = (whole % 3600) / 60
        return minutes == 0 ? "\(whole / 3600) h" : "\(whole / 3600) h \(minutes) min"
    }

    // MARK: - Internals

    /// Finder-like precision: whole kilobytes; above that about three significant digits.
    private static func fractionDigits(_ value: Double, unit: Int) -> Int {
        if unit == 0 { return 0 }
        return value < 10 ? 2 : value < 100 ? 1 : 0
    }

    private static func pow10(_ n: Int) -> Double {
        n == 0 ? 1 : n == 1 ? 10 : 100
    }

    /// Renders `scaled / 10^decimals` with the locale's separators.
    private static func fixed(
        _ scaled: UInt64, decimals: Int, symbols: NumberSymbols, group: Bool, trimZeros: Bool = true
    ) -> String {
        let divisor = UInt64(pow10(decimals))
        let whole = scaled / divisor
        var result = group ? grouped(whole, symbols: symbols) : String(whole)
        guard decimals > 0 else { return result }
        var fraction = String(scaled % divisor)
        while fraction.count < decimals { fraction = "0" + fraction }
        if trimZeros {
            while fraction.hasSuffix("0") { fraction.removeLast() }
        }
        if !fraction.isEmpty { result += symbols.decimalSeparator + fraction }
        return result
    }

    private static func grouped(_ value: UInt64, symbols: NumberSymbols) -> String {
        let digits = String(value)
        guard digits.count > 3, !symbols.groupingSeparator.isEmpty else { return digits }
        var result = ""
        result.reserveCapacity(digits.count + digits.count / 3 * symbols.groupingSeparator.utf8.count)
        let lead = digits.count % 3
        for (i, ch) in digits.enumerated() {
            if i != 0, (i - lead) % 3 == 0 { result += symbols.groupingSeparator }
            result.append(ch)
        }
        return result
    }
}

extension UInt {
    fileprivate var asUInt64: UInt64 { UInt64(self) }
}
