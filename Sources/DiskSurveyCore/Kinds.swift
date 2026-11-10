import Foundation

/// Broad file categories used for colouring and for the kinds legend.
public enum KindCategory: UInt8, CaseIterable, Sendable, Hashable, Codable {
    case video
    case audio
    case image
    case document
    case archive
    case code
    case application
    case system
    case data
    case buildArtifact
    case diskImage
    case font
    case other

    /// Human-readable, plural name for legends ("Videos", "Disk Images", …).
    public var displayName: String {
        switch self {
        case .video: "Videos"
        case .audio: "Audio"
        case .image: "Images"
        case .document: "Documents"
        case .archive: "Archives"
        case .code: "Source Code"
        case .application: "Applications"
        case .system: "System"
        case .data: "Data"
        case .buildArtifact: "Build Artifacts"
        case .diskImage: "Disk Images"
        case .font: "Fonts"
        case .other: "Other"
        }
    }

    /// Human-readable name of **one** item of the category ("Video", "Disk Image", …), for
    /// describing a single file: "Image (.png)". Unclassified files are just a "File".
    public var singularName: String {
        switch self {
        case .video: "Video"
        case .audio: "Audio"
        case .image: "Image"
        case .document: "Document"
        case .archive: "Archive"
        case .code: "Source Code"
        case .application: "Application"
        case .system: "System File"
        case .data: "Data File"
        case .buildArtifact: "Build Artifact"
        case .diskImage: "Disk Image"
        case .font: "Font"
        case .other: "File"
        }
    }

    /// An SF Symbol name that suits the category (plain string; Core has no AppKit dependency).
    public var symbolName: String {
        switch self {
        case .video: "film"
        case .audio: "music.note"
        case .image: "photo"
        case .document: "doc.text"
        case .archive: "archivebox"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .application: "app.badge"
        case .system: "gearshape"
        case .data: "cylinder.split.1x2"
        case .buildArtifact: "hammer"
        case .diskImage: "externaldrive"
        case .font: "textformat"
        case .other: "doc"
        }
    }
}

/// Extension → category classification and the list of package (bundle) extensions.
public enum FileKinds {
    /// The category of a file extension (without dot, any case). Unknown extensions are `.other`.
    /// ``FileKind/unixExecutableExtension`` (the pseudo-kind of extensionless executables) is
    /// `.application`.
    public static func category(forExtension ext: String) -> KindCategory {
        if let found = table[ext] { return found }
        return table[ext.lowercased()] ?? .other
    }

    /// Whether a directory with this extension is presented by Finder as a single file.
    public static func isPackageExtension(_ ext: String) -> Bool {
        packageExtensions.contains(ext) || packageExtensions.contains(ext.lowercased())
    }

    /// The extension of a file name the way the tree interns it: lowercase, at most 16 ASCII
    /// letters/digits/`_`/`-`, not digits only; `""` if there is none.
    public static func normalizedExtension(ofName name: String) -> String {
        var name = name
        return name.withUTF8 { bytes in
            guard let base = bytes.baseAddress, let key = ExtKey(name: base, length: bytes.count) else { return "" }
            return key.string
        }
    }

    /// Lowercase extensions of directories that are packages.
    public static let packageExtensions: Set<String> = Set(
        """
        app appex framework bundle plugin kext xpc prefpane saver qlgenerator mdimporter component \
        vst vst3 driver dext action workflow wdgt scptd docset dsym xcarchive xcresult xcodeproj \
        xcworkspace playground playgroundbook xcdatamodeld storyboardc nib mlmodelc mlpackage \
        photoslibrary photolibrary migratedphotolibrary aplibrary imovielibrary fcpbundle tvlibrary \
        musiclibrary theater band logicx rtfd pages numbers key sparsebundle vmwarevm pvm utm \
        pkg mpkg download lrdata ofocus dtbase2 savedstate
        """.split(separator: " ").map(String.init))

    private static let table: [String: KindCategory] = {
        var table: [String: KindCategory] = [:]
        for (category, list) in categoryLists {
            for ext in list.split(separator: " ") { table[String(ext)] = category }
        }
        table[FileKind.unixExecutableExtension] = .application
        return table
    }()

    /// The classification table as written. Each extension may appear in one list only (a later
    /// list would silently overwrite an earlier one); a unit test checks that.
    static let categoryLists: [(KindCategory, String)] = [
            (
                .video,
                """
                mp4 m4v mov mkv avi wmv flv webm mpg mpeg m2ts mts 3gp vob ogv rm rmvb divx mxf braw r3d \
                imovielibrary fcpbundle tvlibrary theater
                """
            ),
            (
                .audio,
                """
                mp3 m4a aac flac wav aiff aif ogg oga opus wma alac caf mid midi m4b m4r amr ape \
                band logicx musiclibrary
                """
            ),
            (
                .image,
                """
                jpg jpeg png gif heic heif tiff tif bmp webp raw cr2 cr3 nef arw dng orf rw2 raf psd psb ai \
                eps svg ico icns jp2 avif xcf sketch fig exr hdr tga kra \
                photoslibrary photolibrary migratedphotolibrary aplibrary lrdata
                """
            ),
            (
                .document,
                """
                pdf doc docx xls xlsx ppt pptx pages numbers key txt rtf rtfd md markdown odt ods odp epub \
                mobi azw3 tex djvu xps one msg eml emlx ics vcf indd ofocus dtbase2
                """
            ),
            (
                .archive,
                """
                zip gz tgz bz2 tbz xz txz zst 7z rar tar lz lz4 lzma cab cpio z jar war xip pkg mpkg deb \
                rpm aar download
                """
            ),
            (
                .code,
                """
                swift c h cpp cc cxx hpp hh m mm js mjs cjs jsx ts tsx py rb go rs java kt kts scala cs php \
                pl pm sh bash zsh fish lua r jl dart ex exs erl hs ml clj lisp el vim sql html htm css scss \
                sass less xml json yaml yml toml ini cfg conf gradle cmake mk proto graphql vue svelte asm \
                s f90 pas ipynb xib storyboard entitlements xcconfig pbxproj tf nix patch diff \
                xcodeproj xcworkspace playground playgroundbook xcdatamodeld scptd docset
                """
            ),
            (
                .application,
                """
                app exe msi dll ipa apk appex xpc bundle plugin kext framework dylib so prefpane saver \
                command action workflow wdgt component vst vst3 appimage driver dext qlgenerator mdimporter \
                asar node
                """
            ),
            (
                .system,
                """
                plist log cache tmp temp bak swp sys crash ips diag tracev3 strings nib storyboardc car \
                mobileconfig keychain keychain-db pem crt cer der p12 lock pid binarycookies savedstate \
                localized dyld scap sefw im4p efires
                """
            ),
            (
                .data,
                """
                db sqlite sqlite3 sqlite-wal sqlite-shm db-wal db-shm sqlitedb realm mdb accdb csv tsv \
                parquet arrow feather avro orc h5 hdf5 npy npz mat pkl pickle pb onnx safetensors gguf ggml \
                ckpt pt pth bin tflite mlmodel mlmodelc mlpackage weights index idx dat data store \
                storedata ldb wal dump bson ndjson jsonl rdb pak metallib dic sdict trx
                """
            ),
            (
                .buildArtifact,
                """
                o a obj lib class pyc pyo pch gch dsym swiftmodule swiftdoc swiftinterface swiftsourceinfo \
                swiftdeps d dia hmap xcbuilddata rlib rmeta ilk pdb pcm tbd map elc beam hi dex wasm \
                tsbuildinfo xcarchive xcresult
                """
            ),
            (
                .diskImage,
                """
                dmg iso img sparseimage sparsebundle vmdk vdi vhd vhdx qcow2 qcow hdd vmem toast cdr wim \
                vmwarevm pvm utm
                """
            ),
            (.font, "ttf otf ttc woff woff2 eot dfont pfb pfm fon suit"),
        ]
}

extension FileTree {
    /// A short description of what one node is, for an info pane or tooltip: "Folder", "Volume",
    /// "Symbolic link", "Application (.app)", "Image package (.photoslibrary)", "Image (.png)",
    /// "Unix executable", or just "File" when nothing is known about it.
    public func kindDescription(of id: NodeID) -> String {
        let flags = flags(of: id)
        if flags.contains(.mountPoint) { return "Volume" }
        if flags.contains(.symlink) { return "Symbolic link" }
        let kind = fileKind(of: id)
        if flags.contains(.package) {
            return kind.category == .application
                ? "Application (\(kind.displayName))"
                : "\(kind.category.singularName) package (\(kind.displayName))"
        }
        if flags.contains(.directory) { return "Folder" }
        return kind.singularDescription
    }
}

extension FileKind {
    /// Describes one file of this kind: "Image (.png)", "File (.xyz)" for an unknown extension,
    /// "Unix executable", or "File" when there is no extension.
    public var singularDescription: String {
        if isUnixExecutable { return "Unix executable" }
        if ext.isEmpty { return category.singularName }
        return "\(category.singularName) (\(displayName))"
    }
}

// MARK: - Colours

/// A plain sRGB colour with components in 0…1 (no AppKit/SwiftUI dependency).
public struct RGB: Sendable, Hashable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Components as 0…255 bytes.
    public var bytes: (r: UInt8, g: UInt8, b: UInt8) {
        (UInt8((r * 255).rounded()), UInt8((g * 255).rounded()), UInt8((b * 255).rounded()))
    }

    /// "#RRGGBB".
    public var hex: String {
        let (r, g, b) = bytes
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Linear interpolation towards `other` (`t` in 0…1), in sRGB space.
    public func mixed(with other: RGB, _ t: Double) -> RGB {
        RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }

    /// A colour from OKLCH (perceptual lightness 0…1, chroma ≈ 0…0.37, hue in degrees).
    /// Chroma is reduced as needed to stay inside the sRGB gamut, preserving lightness and hue.
    public static func oklch(l: Double, c: Double, h: Double) -> RGB {
        var chroma = max(0, c)
        let lightness = min(1, max(0, l))
        while true {
            let (r, g, b) = oklchToSRGB(lightness, chroma, h)
            let inGamut = r >= -0.0005 && r <= 1.0005 && g >= -0.0005 && g <= 1.0005 && b >= -0.0005 && b <= 1.0005
            if inGamut || chroma < 0.002 {
                return RGB(r: min(1, max(0, r)), g: min(1, max(0, g)), b: min(1, max(0, b)))
            }
            chroma *= 0.96
        }
    }

    private static func oklchToSRGB(_ l: Double, _ c: Double, _ h: Double) -> (Double, Double, Double) {
        let radians = h * .pi / 180
        let a = c * cos(radians)
        let b = c * sin(radians)
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let l3 = l_ * l_ * l_
        let m3 = m_ * m_ * m_
        let s3 = s_ * s_ * s_
        let lr = 4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3
        let lg = -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3
        let lb = -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3
        func gamma(_ x: Double) -> Double {
            x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        }
        return (gamma(lr), gamma(lg), gamma(lb))
    }
}

/// Light or dark appearance for palette lookups. (Named to avoid clashing with SwiftUI's `ColorScheme`.)
public enum PaletteScheme: Sendable, Hashable, CaseIterable {
    case light, dark
}

/// Colours for file kinds.
///
/// Every category has a base colour chosen in OKLCH so that categories differ in lightness as
/// well as hue — neighbours remain distinguishable with the common colour-vision deficiencies.
/// Each extension gets a small, stable variation of its category's colour (so `.mp4` and `.mkv`
/// look related but not identical). All results are deterministic across runs and machines.
public enum KindPalette {
    private static func base(_ category: KindCategory) -> (l: Double, c: Double, h: Double) {
        switch category {
        case .video: (0.60, 0.19, 305)
        case .audio: (0.72, 0.15, 350)
        case .image: (0.74, 0.17, 148)
        case .document: (0.64, 0.15, 255)
        case .archive: (0.80, 0.15, 82)
        case .code: (0.74, 0.11, 198)
        case .application: (0.64, 0.19, 28)
        case .system: (0.58, 0.035, 262)
        case .data: (0.82, 0.10, 222)
        case .buildArtifact: (0.55, 0.08, 55)
        case .diskImage: (0.50, 0.13, 332)
        case .font: (0.58, 0.10, 172)
        case .other: (0.68, 0.0, 0)
        }
    }

    /// The base colour of a category.
    public static func color(for category: KindCategory, scheme: PaletteScheme = .light) -> RGB {
        let (l, c, h) = base(category)
        return render(l: l, c: c, h: h, scheme: scheme)
    }

    /// The colour of an extension: its category's colour with a stable per-extension variation.
    public static func color(
        forExtension ext: String, category: KindCategory? = nil, scheme: PaletteScheme = .light
    ) -> RGB {
        let category = category ?? FileKinds.category(forExtension: ext)
        var (l, c, h) = base(category)
        guard !ext.isEmpty else { return render(l: l, c: c, h: h, scheme: scheme) }
        let hash = fnv1a(ext)
        // Three independent-ish fractions in 0…1 from the hash.
        let u1 = Double(hash & 0xFFFF) / 65535
        let u2 = Double((hash >> 16) & 0xFFFF) / 65535
        let u3 = Double((hash >> 32) & 0xFFFF) / 65535
        if category == .other {
            // Unknown types stay neutral: grey with a hint of tint and varying lightness.
            l += (u2 - 0.5) * 0.16
            c = 0.012 + u3 * 0.02
            h = u1 * 360
        } else {
            h += (u1 - 0.5) * 30
            l += (u2 - 0.5) * 0.10
            c *= 0.88 + u3 * 0.24
        }
        return render(l: l, c: c, h: h, scheme: scheme)
    }

    public static func color(for kind: FileKind, scheme: PaletteScheme = .light) -> RGB {
        color(forExtension: kind.ext, category: kind.category, scheme: scheme)
    }

    /// Colours for a whole kind table, indexed by `KindID` — what a rasterizer wants.
    public static func colors(for kinds: [FileKind], scheme: PaletteScheme = .light) -> [RGB] {
        kinds.map { color(for: $0, scheme: scheme) }
    }

    /// Neutral colour for directories drawn as cells (collapsed folders, folder frames).
    public static func folderColor(scheme: PaletteScheme = .light) -> RGB {
        switch scheme {
        case .light: RGB.oklch(l: 0.80, c: 0.03, h: 250)
        case .dark: RGB.oklch(l: 0.42, c: 0.03, h: 250)
        }
    }

    private static func render(l: Double, c: Double, h: Double, scheme: PaletteScheme) -> RGB {
        switch scheme {
        case .light: RGB.oklch(l: l, c: c, h: h)
        // On dark backgrounds slightly deeper tiles keep the cushion highlights from glaring.
        case .dark: RGB.oklch(l: l * 0.93, c: c * 0.96, h: h)
        }
    }

    private static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        // Final avalanche so short, similar extensions spread out well.
        hash ^= hash >> 33
        hash = hash &* 0xFF51_AFD7_ED55_8CCD
        hash ^= hash >> 33
        return hash
    }
}

extension FileTree {
    /// Colours for this tree's kind table, indexed by `KindID`.
    public func kindColors(scheme: PaletteScheme = .light) -> [RGB] {
        KindPalette.colors(for: kinds, scheme: scheme)
    }
}

// MARK: - Age

/// Coarse age classes for "colour by age".
public enum AgeBucket: Int, CaseIterable, Sendable, Hashable {
    case day, week, month, quarter, year, twoYears, older, unknown

    /// Upper bound of the bucket in seconds (exclusive); `nil` for the open-ended ones.
    public var upperBound: Int64? {
        switch self {
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        case .quarter: 91 * 86_400
        case .year: 365 * 86_400
        case .twoYears: 730 * 86_400
        case .older, .unknown: nil
        }
    }

    public var displayName: String {
        switch self {
        case .day: "Today"
        case .week: "This Week"
        case .month: "This Month"
        case .quarter: "Last 3 Months"
        case .year: "This Year"
        case .twoYears: "Last 2 Years"
        case .older: "Older"
        case .unknown: "Unknown"
        }
    }

    /// The bucket for a modification time (`0` = unknown) relative to `now`, both seconds since 1970.
    public init(modified: Int64, now: Int64) {
        guard modified > 0 else {
            self = .unknown
            return
        }
        let age = max(0, now - modified)
        self = AgeBucket.allCases.first { bucket in
            bucket.upperBound.map { age < $0 } ?? false
        } ?? .older
    }
}

/// A sequential warm → cool ramp for ages: recent files glow orange, old ones recede into blue.
/// Lightness falls monotonically, so the ramp also reads in greyscale and for colour-blind users.
public enum AgePalette {
    public static func color(for bucket: AgeBucket, scheme: PaletteScheme = .light) -> RGB {
        let darken = scheme == .dark ? 0.93 : 1.0
        if bucket == .unknown { return RGB.oklch(l: 0.62 * darken, c: 0, h: 0) }
        let t = Double(bucket.rawValue) / Double(AgeBucket.older.rawValue)
        // Hue travels the short way from orange (55°) through magenta to blue (255°).
        let hue = (55 - t * 160).truncatingRemainder(dividingBy: 360)
        return RGB.oklch(l: (0.80 - 0.34 * t) * darken, c: 0.16 - 0.04 * t, h: hue < 0 ? hue + 360 : hue)
    }

    public static func color(modified: Int64, now: Int64, scheme: PaletteScheme = .light) -> RGB {
        color(for: AgeBucket(modified: modified, now: now), scheme: scheme)
    }

    /// Colours for all buckets, indexed by `AgeBucket.rawValue`.
    public static func colors(scheme: PaletteScheme = .light) -> [RGB] {
        AgeBucket.allCases.map { color(for: $0, scheme: scheme) }
    }
}
