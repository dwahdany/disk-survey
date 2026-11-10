import Foundation
import DiskSurveyCore

// MARK: - Output sink

/// Buffered writer over a file descriptor.
///
/// Not `print`: a report can be millions of lines (exports), and a reader that goes away
/// (`disksurvey … | head`) must end the program quietly instead of killing it with SIGPIPE or
/// spraying errors. SIGPIPE is ignored at startup, so the closed pipe shows up here as EPIPE.
final class Output {
    let fd: Int32
    private var buffer: [UInt8] = []
    private(set) var bytesWritten: UInt64 = 0
    /// Set when a write failed for a reason other than a closed pipe (disk full, …).
    private(set) var failure: Int32 = 0

    init(fd: Int32) {
        self.fd = fd
        buffer.reserveCapacity(1 << 16)
    }

    func write(_ text: String) {
        buffer.append(contentsOf: text.utf8)
        if buffer.count >= 1 << 16 { flush() }
    }

    func write(byte: UInt8) {
        buffer.append(byte)
    }

    func write(bytes: some Sequence<UInt8>) {
        buffer.append(contentsOf: bytes)
        if buffer.count >= 1 << 16 { flush() }
    }

    func line(_ text: String = "") {
        write(text)
        buffer.append(0x0A)
    }

    func flush() {
        guard !buffer.isEmpty else { return }
        defer { buffer.removeAll(keepingCapacity: true) }
        guard failure == 0 else { return }
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 {
                    offset += n
                    bytesWritten += UInt64(n)
                } else if errno == EINTR || errno == EAGAIN {
                    continue
                } else if errno == EPIPE {
                    // The reader has seen enough. That is success, not an error.
                    exit(0)
                } else {
                    failure = errno
                    return
                }
            }
        }
    }
}

// MARK: - Terminal properties

enum Terminal {
    static func isTTY(_ fd: Int32) -> Bool { isatty(fd) == 1 }

    /// Width of the terminal on `fd`, or nil when it is not a terminal (then nothing is truncated).
    static func columns(_ fd: Int32) -> Int? {
        guard isTTY(fd) else { return nil }
        var size = winsize()
        // TIOCGWINSZ is a function-like macro that Swift cannot import; this is its Darwin value.
        if ioctl(fd, 0x4008_7468, &size) == 0, size.ws_col > 0 { return Int(size.ws_col) }
        if let env = ProcessInfo.processInfo.environment["COLUMNS"], let value = Int(env), value > 0 { return value }
        return 80
    }
}

// MARK: - Styling

/// How text is decorated: colours on or off, 24-bit or 256-colour, Unicode or ASCII drawing.
struct Style: Sendable {
    var color: Bool
    var trueColor: Bool
    var unicode: Bool
    var scheme: PaletteScheme

    init(mode: ColorMode, ascii: Bool, fd: Int32) {
        let env = ProcessInfo.processInfo.environment
        switch mode {
        case .always: color = true
        case .never: color = false
        case .auto:
            // https://no-color.org: any non-empty value turns colour off.
            let noColor = !(env["NO_COLOR"] ?? "").isEmpty
            let forced = !(env["CLICOLOR_FORCE"] ?? "").isEmpty && env["CLICOLOR_FORCE"] != "0"
            color = !noColor && env["TERM"] != "dumb" && (Terminal.isTTY(fd) || forced)
        }
        let colorTerm = env["COLORTERM"] ?? ""
        trueColor = colorTerm == "truecolor" || colorTerm == "24bit"
        unicode = !ascii
        // COLORFGBG ("15;0") is the only hint terminals give about their background; without it
        // assume dark, where the brighter palette also stays readable on mid-grey.
        scheme = .dark
        if let background = env["COLORFGBG"]?.split(separator: ";").last.flatMap({ Int($0) }),
            background == 7 || background == 15
        {
            scheme = .light
        }
    }

    func paint(_ text: String, _ rgb: RGB?, bold: Bool = false) -> String {
        guard color, !text.isEmpty else { return text }
        var codes: [String] = []
        if bold { codes.append("1") }
        if let rgb {
            let (r, g, b) = legible(rgb).bytes
            if trueColor {
                codes.append("38;2;\(r);\(g);\(b)")
            } else {
                // The 6×6×6 colour cube every 256-colour terminal has.
                func level(_ v: UInt8) -> Int { (Int(v) * 5 + 127) / 255 }
                codes.append("38;5;\(16 + 36 * level(r) + 6 * level(g) + level(b))")
            }
        }
        guard !codes.isEmpty else { return text }
        return "\u{1B}[\(codes.joined(separator: ";"))m\(text)\u{1B}[0m"
    }

    /// The kind palette is made for treemap tiles, where dark and pale tiles are both fine. As
    /// text on a terminal background the extremes vanish, so pull them towards the readable range.
    func legible(_ rgb: RGB) -> RGB {
        var result = rgb
        func luminance(_ c: RGB) -> Double { 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }
        for _ in 0..<8 {
            if scheme == .dark, luminance(result) < 0.42 {
                result = result.mixed(with: RGB(r: 1, g: 1, b: 1), 0.18)
            } else if scheme == .light, luminance(result) > 0.5 {
                result = result.mixed(with: RGB(r: 0, g: 0, b: 0), 0.18)
            } else {
                break
            }
        }
        return result
    }

    /// Folders: the blue that `ls` users expect, not the treemap's neutral folder grey.
    var folderColor: RGB { scheme == .dark ? RGB(r: 0.45, g: 0.68, b: 1.0) : RGB(r: 0.13, g: 0.36, b: 0.78) }

    func sgr(_ text: String, _ code: String) -> String {
        guard color, !text.isEmpty else { return text }
        return "\u{1B}[\(code)m\(text)\u{1B}[0m"
    }

    func bold(_ text: String) -> String { sgr(text, "1") }
    func dim(_ text: String) -> String { sgr(text, "2") }
    func warning(_ text: String) -> String { sgr(text, "1;33") }
    func error(_ text: String) -> String { sgr(text, "1;31") }

    var ellipsis: String { unicode ? "…" : "..." }
    var separator: String { unicode ? " · " : " | " }

    /// A horizontal bar exactly `width` cells wide, filled to `fraction` with eighth-cell precision.
    func bar(_ fraction: Double, width: Int, track: Bool = false) -> (filled: String, rest: String) {
        guard width > 0 else { return ("", "") }
        let clamped = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        if !unicode {
            var cells = Int((clamped * Double(width)).rounded())
            if clamped > 0, cells == 0 { cells = 1 }
            return (String(repeating: "#", count: cells), String(repeating: track ? "-" : " ", count: width - cells))
        }
        var eighths = Int((clamped * Double(width) * 8).rounded())
        // Anything non-zero stays visible.
        if clamped > 0, eighths == 0 { eighths = 1 }
        let full = eighths / 8
        let partial = eighths % 8
        var filled = String(repeating: "█", count: full)
        if partial > 0 { filled.append(["▏", "▎", "▍", "▌", "▋", "▊", "▉"][partial - 1]) }
        let used = full + (partial > 0 ? 1 : 0)
        return (filled, String(repeating: track ? "░" : " ", count: width - used))
    }
}

// MARK: - Text measurement

enum Text {
    /// Terminal cells a string occupies. Good enough for file names: combining marks take no
    /// room, CJK and emoji take two cells. (`wcwidth` depends on the C locale, which a command
    /// line tool does not control, so the table is ours.)
    static func width(_ text: String) -> Int {
        var total = 0
        for character in text { total += width(character) }
        return total
    }

    static func width(_ character: Character) -> Int {
        var width = 0
        for scalar in character.unicodeScalars {
            let v = scalar.value
            if v < 0x7F {
                if v >= 0x20, width == 0 { width = 1 }
                continue
            }
            if v == 0xFE0F {  // emoji presentation selector
                width = 2
                continue
            }
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .enclosingMark, .format, .control: continue
            default: break
            }
            if width == 0 { width = isWide(v) || scalar.properties.isEmojiPresentation ? 2 : 1 }
        }
        return width
    }

    private static func isWide(_ v: UInt32) -> Bool {
        switch v {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
            0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
            0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    /// File names are attacker-controlled bytes: a name containing escape sequences or newlines
    /// must not be able to repaint the terminal or fake extra report lines.
    static func sanitized(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }) else {
            return text
        }
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            result.append(scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) ? "?" : scalar)
        }
        return String(result)
    }

    enum Cut { case end, middle }

    /// Shortens `text` to at most `width` cells, marking the cut with an ellipsis.
    static func truncated(_ text: String, to width: Int, cut: Cut = .end, ellipsis: String = "…") -> String {
        guard Text.width(text) > width else { return text }
        let mark = Text.width(ellipsis)
        guard width > mark else { return String(ellipsis.prefix(max(width, 0))) }
        let budget = width - mark
        let characters = Array(text)

        func take(_ source: some Sequence<Character>, _ limit: Int) -> [Character] {
            var used = 0
            var kept: [Character] = []
            for character in source {
                let w = Text.width(character)
                if used + w > limit { break }
                used += w
                kept.append(character)
            }
            return kept
        }

        switch cut {
        case .end:
            return String(take(characters, budget)) + ellipsis
        case .middle:
            // Keep more of the tail: for a path, the file name is the interesting end.
            let headBudget = budget / 3
            let head = take(characters, headBudget)
            let tail = take(characters.reversed(), budget - headBudget).reversed()
            return String(head) + ellipsis + String(tail)
        }
    }

    static func padded(_ text: String, to width: Int, right: Bool = false) -> String {
        let gap = width - Text.width(text)
        guard gap > 0 else { return text }
        let spaces = String(repeating: " ", count: gap)
        return right ? spaces + text : text + spaces
    }
}
