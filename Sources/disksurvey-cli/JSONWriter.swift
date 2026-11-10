import Foundation

/// A streaming JSON writer.
///
/// Hand-written rather than `JSONEncoder` for two reasons: the key order is exactly the order of
/// the calls (stable, diff-friendly output), and an export of millions of nodes streams straight
/// to the file instead of materializing an object graph first.
final class JSONWriter {
    private let out: Output
    private let pretty: Bool
    /// Number of values written so far in each open container.
    private var counts: [Int] = []
    private var afterKey = false
    private var pendingBreak = false

    init(_ out: Output, pretty: Bool) {
        self.out = out
        self.pretty = pretty
    }

    // MARK: Structure

    func beginObject() {
        beforeValue()
        out.write(byte: UInt8(ascii: "{"))
        counts.append(0)
    }

    func endObject() { end(UInt8(ascii: "}")) }

    func beginArray() {
        beforeValue()
        out.write(byte: UInt8(ascii: "["))
        counts.append(0)
    }

    func endArray() { end(UInt8(ascii: "]")) }

    func key(_ name: String) {
        beforeValue()
        writeString(name)
        out.write(pretty ? ": " : ":")
        afterKey = true
    }

    /// Ends the document with a newline.
    func finish() {
        out.write(byte: 0x0A)
    }

    /// Compact mode only: start the next value (or closing bracket) on a new line, which keeps
    /// huge exports greppable and diffable.
    func lineBreak() {
        pendingBreak = !pretty
    }

    // MARK: Values

    func value(_ string: String) {
        beforeValue()
        writeString(string)
    }

    func value(_ number: UInt64) {
        beforeValue()
        out.write(String(number))
    }

    func value(_ number: Int) {
        beforeValue()
        out.write(String(number))
    }

    func value(_ flag: Bool) {
        beforeValue()
        out.write(flag ? "true" : "false")
    }

    /// Fixed three decimals: enough for seconds and fractions, and no exponent notation.
    func value(_ number: Double) {
        beforeValue()
        out.write(number.isFinite ? String(format: "%.3f", number) : "null")
    }

    func null() {
        beforeValue()
        out.write("null")
    }

    func field(_ name: String, _ v: String) { key(name); value(v) }
    func field(_ name: String, _ v: UInt64) { key(name); value(v) }
    func field(_ name: String, _ v: Int) { key(name); value(v) }
    func field(_ name: String, _ v: Bool) { key(name); value(v) }
    func field(_ name: String, _ v: Double) { key(name); value(v) }

    func field(_ name: String, strings: [String]) {
        key(name)
        // Short lists stay on one line even in pretty mode.
        out.write(byte: UInt8(ascii: "["))
        for (i, s) in strings.enumerated() {
            if i > 0 { out.write(pretty ? ", " : ",") }
            writeString(s)
        }
        out.write(byte: UInt8(ascii: "]"))
        afterKey = false
    }

    // MARK: Internals

    private func beforeValue() {
        if afterKey {
            afterKey = false
            pendingBreak = false
            return
        }
        guard !counts.isEmpty else { return }
        if counts[counts.count - 1] > 0 { out.write(byte: UInt8(ascii: ",")) }
        counts[counts.count - 1] += 1
        if pendingBreak {
            pendingBreak = false
            out.write(byte: 0x0A)
        }
        newline()
    }

    private func end(_ bracket: UInt8) {
        let hadValues = counts.removeLast() > 0
        if hadValues { newline() }
        if pendingBreak {
            pendingBreak = false
            out.write(byte: 0x0A)
        }
        out.write(byte: bracket)
    }

    private func newline() {
        guard pretty else { return }
        out.write(byte: 0x0A)
        for _ in 0..<counts.count { out.write("  ") }
    }

    private static let hex = Array("0123456789abcdef".utf8)

    private func writeString(_ string: String) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(string.utf8.count + 2)
        bytes.append(UInt8(ascii: "\""))
        for byte in string.utf8 {
            switch byte {
            case UInt8(ascii: "\""): bytes.append(contentsOf: [0x5C, 0x22])
            case UInt8(ascii: "\\"): bytes.append(contentsOf: [0x5C, 0x5C])
            case 0x0A: bytes.append(contentsOf: [0x5C, UInt8(ascii: "n")])
            case 0x0D: bytes.append(contentsOf: [0x5C, UInt8(ascii: "r")])
            case 0x09: bytes.append(contentsOf: [0x5C, UInt8(ascii: "t")])
            case 0..<0x20, 0x7F:
                bytes.append(contentsOf: [0x5C, UInt8(ascii: "u"), 0x30, 0x30])
                bytes.append(Self.hex[Int(byte >> 4)])
                bytes.append(Self.hex[Int(byte & 0xF)])
            default: bytes.append(byte)
            }
        }
        bytes.append(UInt8(ascii: "\""))
        out.write(bytes: bytes)
    }
}
