import Foundation
import Testing
@testable import DiskSurveyCore

@Suite struct KindTests {
    @Test func classification() {
        #expect(FileKinds.category(forExtension: "mp4") == .video)
        #expect(FileKinds.category(forExtension: "MKV") == .video)
        #expect(FileKinds.category(forExtension: "flac") == .audio)
        #expect(FileKinds.category(forExtension: "heic") == .image)
        #expect(FileKinds.category(forExtension: "pdf") == .document)
        #expect(FileKinds.category(forExtension: "zip") == .archive)
        #expect(FileKinds.category(forExtension: "swift") == .code)
        #expect(FileKinds.category(forExtension: "app") == .application)
        #expect(FileKinds.category(forExtension: "plist") == .system)
        #expect(FileKinds.category(forExtension: "sqlite") == .data)
        #expect(FileKinds.category(forExtension: "o") == .buildArtifact)
        #expect(FileKinds.category(forExtension: "dmg") == .diskImage)
        #expect(FileKinds.category(forExtension: "ttf") == .font)
        #expect(FileKinds.category(forExtension: "") == .other)
        #expect(FileKinds.category(forExtension: "qqqq") == .other)
        #expect(FileKinds.isPackageExtension("app") && FileKinds.isPackageExtension("PhotosLibrary"))
        #expect(!FileKinds.isPackageExtension("txt") && !FileKinds.isPackageExtension(""))
        #expect(FileKind(ext: "mov").category == .video)
        #expect(FileKind(ext: "").displayName == "No Extension")
        for category in KindCategory.allCases {
            #expect(!category.displayName.isEmpty && !category.symbolName.isEmpty)
        }
        #expect(Set(KindCategory.allCases.map(\.displayName)).count == KindCategory.allCases.count)
    }

    @Test func bundlePayloadAndFirmwareExtensions() {
        for ext in ["asar", "node"] { #expect(FileKinds.category(forExtension: ext) == .application, "\(ext)") }
        for ext in ["pak", "metallib", "dic", "sdict", "trx"] { #expect(FileKinds.category(forExtension: ext) == .data, "\(ext)") }
        for ext in ["scap", "sefw", "im4p", "efires", "nib"] { #expect(FileKinds.category(forExtension: ext) == .system, "\(ext)") }
        #expect(FileKinds.category(forExtension: "ASAR") == .application)
        // A later list would silently overwrite an earlier one, so every extension is listed once.
        var seen: [String: KindCategory] = [:]
        for (category, list) in FileKinds.categoryLists {
            for ext in list.split(separator: " ").map(String.init) {
                #expect(seen[ext] == nil, "\(ext) is in \(String(describing: seen[ext])) and \(category)")
                seen[ext] = category
                #expect(ext == ext.lowercased() && FileKinds.category(forExtension: ext) == category)
            }
        }
    }

    @Test func singularNamesAndUnixExecutableKind() {
        for category in KindCategory.allCases { #expect(!category.singularName.isEmpty) }
        #expect(KindCategory.application.singularName == "Application")
        #expect(KindCategory.image.singularName == "Image")
        #expect(KindCategory.other.singularName == "File")
        // The legend names stay plural.
        #expect(KindCategory.application.displayName == "Applications" && KindCategory.other.displayName == "Other")

        let exec = FileKind(ext: FileKind.unixExecutableExtension)
        #expect(exec.isUnixExecutable && exec.category == .application)
        #expect(exec.displayName == "Unix Executable")
        #expect(exec.singularDescription == "Unix executable")
        #expect(!FileKind(ext: "").isUnixExecutable && !FileKind(ext: "exe").isUnixExecutable)
        #expect(FileKinds.category(forExtension: FileKind.unixExecutableExtension) == .application)
        #expect(!FileKinds.isPackageExtension(FileKind.unixExecutableExtension))
        // No file name can produce the reserved extension.
        #expect(FileKinds.normalizedExtension(ofName: "a.unix executable") == "")
        #expect(FileKinds.normalizedExtension(ofName: "tool") == "")
        #expect(ExtKey.unixExecutable.string == FileKind.unixExecutableExtension)
        // Coloured as an application, not as neutral grey.
        #expect(KindPalette.color(for: exec) != KindPalette.color(for: .other))

        #expect(FileKind(ext: "png").singularDescription == "Image (.png)")
        #expect(FileKind(ext: "swift").singularDescription == "Source Code (.swift)")
        #expect(FileKind(ext: "xyz").singularDescription == "File (.xyz)")
        #expect(FileKind(ext: "").singularDescription == "File")
    }

    @Test func paletteIsStableDistinctAndInGamut() {
        for scheme in PaletteScheme.allCases {
            let colors = KindCategory.allCases.map { KindPalette.color(for: $0, scheme: scheme) }
            #expect(Set(colors.map(\.hex)).count == colors.count)
            for color in colors {
                #expect((0 ... 1).contains(color.r) && (0 ... 1).contains(color.g) && (0 ... 1).contains(color.b))
            }
            // Categories stay apart from each other (rough sRGB distance).
            for (i, a) in colors.enumerated() {
                for b in colors[(i + 1)...] {
                    let d = ((a.r - b.r) * (a.r - b.r) + (a.g - b.g) * (a.g - b.g) + (a.b - b.b) * (a.b - b.b)).squareRoot()
                    #expect(d > 0.08)
                }
            }
        }
        // Deterministic.
        #expect(KindPalette.color(forExtension: "mp4") == KindPalette.color(forExtension: "mp4"))
        // Related but distinguishable within a category; light and dark differ.
        let mp4 = KindPalette.color(forExtension: "mp4")
        let mkv = KindPalette.color(forExtension: "mkv")
        let base = KindPalette.color(for: .video)
        #expect(mp4 != mkv)
        func distance(_ a: RGB, _ b: RGB) -> Double {
            ((a.r - b.r) * (a.r - b.r) + (a.g - b.g) * (a.g - b.g) + (a.b - b.b) * (a.b - b.b)).squareRoot()
        }
        #expect(distance(mp4, base) < 0.25 && distance(mkv, base) < 0.25)
        #expect(distance(mp4, KindPalette.color(for: .image)) > distance(mp4, base))
        #expect(KindPalette.color(forExtension: "mp4", scheme: .dark) != mp4)
        #expect(KindPalette.color(forExtension: "") == KindPalette.color(for: .other))
        #expect(KindPalette.folderColor(scheme: .light) != KindPalette.folderColor(scheme: .dark))

        let tree = demoTree()
        let table = tree.kindColors(scheme: .dark)
        #expect(table.count == tree.kinds.count)
        #expect(table[Int(tree.kindID(forExtension: "mp4")!)] == KindPalette.color(forExtension: "mp4", scheme: .dark))
    }

    @Test func rgbHelpers() {
        #expect(RGB(r: 1, g: 0, b: 0.5).hex == "#FF0080")
        #expect(RGB(r: 0, g: 0, b: 0).mixed(with: RGB(r: 1, g: 1, b: 1), 0.5) == RGB(r: 0.5, g: 0.5, b: 0.5))
        let white = RGB.oklch(l: 1, c: 0, h: 0)
        #expect(abs(white.r - 1) < 0.01 && abs(white.g - 1) < 0.01 && abs(white.b - 1) < 0.01)
        let black = RGB.oklch(l: 0, c: 0, h: 0)
        #expect(black.r < 0.01 && black.g < 0.01 && black.b < 0.01)
        // sRGB red is roughly oklch(0.628 0.258 29.2).
        let red = RGB.oklch(l: 0.628, c: 0.258, h: 29.23)
        #expect(red.r > 0.95 && red.g < 0.2 && red.b < 0.2)
        // L = 0.6 without chroma is mid grey: 0.6^3 = 0.216 linear = 0.502 sRGB.
        let grey = RGB.oklch(l: 0.6, c: 0, h: 0)
        #expect(abs(grey.r - 0.502) < 0.005 && abs(grey.g - 0.502) < 0.005 && abs(grey.b - 0.502) < 0.005)
        // sRGB blue is oklch(0.452 0.313 264.05).
        let blue = RGB.oklch(l: 0.452, c: 0.313, h: 264.05)
        #expect(blue.b > 0.95 && blue.r < 0.2 && blue.g < 0.2)
        // Out-of-gamut chroma is reduced, not clipped to garbage.
        let vivid = RGB.oklch(l: 0.7, c: 0.9, h: 150)
        #expect(vivid.g > vivid.r && vivid.g > vivid.b)
    }

    @Test func ageBuckets() {
        let now: Int64 = 1_800_000_000
        #expect(AgeBucket(modified: now - 3600, now: now) == .day)
        #expect(AgeBucket(modified: now - 3 * 86_400, now: now) == .week)
        #expect(AgeBucket(modified: now - 20 * 86_400, now: now) == .month)
        #expect(AgeBucket(modified: now - 60 * 86_400, now: now) == .quarter)
        #expect(AgeBucket(modified: now - 200 * 86_400, now: now) == .year)
        #expect(AgeBucket(modified: now - 500 * 86_400, now: now) == .twoYears)
        #expect(AgeBucket(modified: now - 3000 * 86_400, now: now) == .older)
        #expect(AgeBucket(modified: 0, now: now) == .unknown)
        #expect(AgeBucket(modified: now + 500, now: now) == .day)
        let colors = AgePalette.colors()
        #expect(colors.count == AgeBucket.allCases.count)
        #expect(Set(colors.map(\.hex)).count == colors.count)
        // The ramp gets darker with age.
        func luma(_ c: RGB) -> Double { 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }
        let ramp = AgeBucket.allCases.filter { $0 != .unknown }.map { luma(AgePalette.color(for: $0)) }
        #expect(ramp == ramp.sorted(by: >))
        #expect(AgePalette.color(modified: now - 10, now: now) == AgePalette.color(for: .day))
    }
}

@Suite struct FormatTests {
    let en = NumberSymbols(locale: Locale(identifier: "en_US"))
    let de = NumberSymbols(locale: Locale(identifier: "de_DE"))
    let fr = NumberSymbols(locale: Locale(identifier: "fr_FR"))

    @Test func bytes() {
        #expect(Format.bytes(0, symbols: en) == "0 bytes")
        #expect(Format.bytes(1, symbols: en) == "1 byte")
        #expect(Format.bytes(999, symbols: en) == "999 bytes")
        #expect(Format.bytes(1000, symbols: en) == "1 KB")
        #expect(Format.bytes(1499, symbols: en) == "1 KB")
        #expect(Format.bytes(123_456, symbols: en) == "123 KB")
        #expect(Format.bytes(999_499, symbols: en) == "999 KB")
        #expect(Format.bytes(999_500, symbols: en) == "1 MB")
        #expect(Format.bytes(1_000_000, symbols: en) == "1 MB")
        #expect(Format.bytes(1_230_000, symbols: en) == "1.23 MB")
        #expect(Format.bytes(45_600_000, symbols: en) == "45.6 MB")
        #expect(Format.bytes(456_700_000, symbols: en) == "457 MB")
        #expect(Format.bytes(999_950_000, symbols: en) == "1 GB")
        #expect(Format.bytes(1_500_000_000, symbols: en) == "1.5 GB")
        #expect(Format.bytes(12_400_000_000, symbols: en) == "12.4 GB")
        #expect(Format.bytes(9_999_000_000, symbols: en) == "10 GB")
        #expect(Format.bytes(2_000_000_000_000, symbols: en) == "2 TB")
        #expect(Format.bytes(1_234_000_000_000_000, symbols: en) == "1.23 PB")
        #expect(Format.bytes(.max, symbols: en) == "18.4 EB")
        #expect(Format.bytes(12_400_000_000, symbols: de) == "12,4 GB")
        #expect(Format.bytes(12_400_000_000, symbols: fr) == "12,4 Go")
        #expect(Format.bytes(12, symbols: fr) == "12 octets")
        #expect(Format.exactBytes(1_234_567, symbols: en) == "1,234,567 bytes")
        #expect(Format.exactBytes(1_234_567, symbols: de) == "1.234.567 bytes")
        #expect(Format.exactBytes(1, symbols: en) == "1 byte")
        #expect(!Format.bytes(5_000_000).isEmpty)  // default symbols work
    }

    @Test func counts() {
        #expect(Format.count(0, symbols: en) == "0")
        #expect(Format.count(999, symbols: en) == "999")
        #expect(Format.count(1000, symbols: en) == "1,000")
        #expect(Format.count(1_234_567, symbols: en) == "1,234,567")
        #expect(Format.count(12_345, symbols: de) == "12.345")
        #expect(Format.count(-1_234_567, symbols: en) == "-1,234,567")
        #expect(Format.count(100_000, symbols: .posix) == "100,000")
        #expect(Format.compactCount(950, symbols: en) == "950")
        #expect(Format.compactCount(1200, symbols: en) == "1.2K")
        #expect(Format.compactCount(34_400, symbols: en) == "34K")
        #expect(Format.compactCount(999_950, symbols: en) == "1M")
        #expect(Format.compactCount(5_600_000, symbols: en) == "5.6M")
        #expect(Format.compactCount(5_600_000, symbols: de) == "5,6M")
        #expect(Format.compactCount(2_000_000_000, symbols: en) == "2B")
        #expect(Format.items(0, symbols: en) == "No items")
        #expect(Format.items(1, symbols: en) == "1 item")
        #expect(Format.items(12_345, symbols: en) == "12,345 items")
        #expect(Format.files(2, symbols: en) == "2 files")
        #expect(Format.counted(1, singular: "folder", plural: "folders", symbols: en) == "1 folder")
    }

    @Test func percent() {
        #expect(Format.percent(0, symbols: en) == "0%")
        #expect(Format.percent(0.00004, symbols: en) == "<0.1%")
        #expect(Format.percent(0.001, symbols: en) == "0.1%")
        #expect(Format.percent(0.1234, symbols: en) == "12.3%")
        #expect(Format.percent(0.5, symbols: en) == "50.0%")
        #expect(Format.percent(0.9996, symbols: en) == "100%")
        #expect(Format.percent(1, symbols: en) == "100%")
        #expect(Format.percent(0.1234, symbols: de) == "12,3%")
        #expect(Format.percent(0.00004, symbols: de) == "<0,1%")
        #expect(Format.percent(.nan, symbols: en) == "0%")
        #expect(Format.percent(-0.5, symbols: en) == "0%")
        #expect(Format.percent(1, of: 3, symbols: en) == "33.3%")
        #expect(Format.percent(1, of: 0, symbols: en) == "0%")
    }

    @Test func datesAndDurations() {
        let now: Int64 = 1_800_000_000
        #expect(Format.relativeDate(0, now: now) == "—")
        #expect(Format.relativeDate(now - 5, now: now) == "Just now")
        #expect(Format.relativeDate(now + 30, now: now) == "Just now")
        #expect(Format.relativeDate(now - 60, now: now) == "1 minute ago")
        #expect(Format.relativeDate(now - 59 * 60, now: now) == "59 minutes ago")
        #expect(Format.relativeDate(now - 3 * 3600, now: now) == "3 hours ago")
        #expect(Format.relativeDate(now - 30 * 3600, now: now) == "Yesterday")
        #expect(Format.relativeDate(now - 4 * 86_400, now: now) == "4 days ago")
        #expect(Format.relativeDate(now - 15 * 86_400, now: now) == "2 weeks ago")
        #expect(Format.relativeDate(now - 100 * 86_400, now: now) == "3 months ago")
        #expect(Format.relativeDate(now - 800 * 86_400, now: now) == "2 years ago")
        #expect(Format.relativeDate(now + 86_400, now: now) == Format.date(now + 86_400))
        #expect(Format.date(0) == "—")
        #expect(Format.date(now).contains("2027"))
        #expect(Format.date(now, includingTime: true).count > Format.date(now).count)

        #expect(Format.duration(0.4235, symbols: en) == "0.42 s")
        #expect(Format.duration(3.21, symbols: en) == "3.2 s")
        #expect(Format.duration(3.21, symbols: de) == "3,2 s")
        #expect(Format.duration(45.4, symbols: en) == "45 s")
        #expect(Format.duration(125, symbols: en) == "2 min 5 s")
        #expect(Format.duration(120, symbols: en) == "2 min")
        #expect(Format.duration(4320, symbols: en) == "1 h 12 min")
        #expect(Format.duration(-1, symbols: en) == "—")
        // Boundaries of the formats: never "10.0 s".
        #expect(Format.duration(0.994, symbols: en) == "0.99 s")
        #expect(Format.duration(0.995, symbols: en) == "1.0 s")
        #expect(Format.duration(9.94, symbols: en) == "9.9 s")
        #expect(Format.duration(9.949, symbols: en) == "9.9 s")
        #expect(Format.duration(9.95, symbols: en) == "10 s")
        #expect(Format.duration(9.96, symbols: en) == "10 s")
        #expect(Format.duration(9.994, symbols: en) == "10 s")
        #expect(Format.duration(9.995, symbols: en) == "10 s")
        #expect(Format.duration(10.0, symbols: en) == "10 s")
        #expect(Format.duration(10.4, symbols: en) == "10 s")
        for step in 0 ... 12_000 {
            let text = Format.duration(Double(step) / 1000, symbols: en)
            #expect(text != "10.0 s" && text != "1.00 s", "\(step) ms")
        }
    }

    @Test func formattingIsThreadSafe() {
        let en = self.en
        DispatchQueue.concurrentPerform(iterations: 8) { t in
            for i in 0 ..< 2000 {
                let n = UInt64(i * 7919 + t) * 1_000_003
                precondition(!Format.bytes(n, symbols: en).isEmpty)
                precondition(!Format.bytes(n).isEmpty)
            }
        }
    }
}
