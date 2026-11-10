import AppKit
import Observation
import DiskSurveyCore
import DiskSurveyMapView
import DiskSurveyScan
import DiskSurveyTreemap

/// Which size the app shows everywhere: space taken on disk, or the files' own length.
enum SizeMode: String, CaseIterable, Identifiable, Sendable {
    case allocated, logical
    var id: String { rawValue }
    var title: String { self == .allocated ? "On Disk" : "Logical" }
    var metric: TreemapLayoutOptions.SizeMetric { self == .allocated ? .allocated : .logical }
}

enum ColorModeSetting: String, CaseIterable, Identifiable, Sendable {
    case kind, age
    var id: String { rawValue }
    var title: String { self == .kind ? "Kind" : "Age" }
    var mapMode: TreemapColorMode { self == .kind ? .kind : .age }
}

enum MapStyleSetting: String, CaseIterable, Identifiable, Sendable {
    case adaptive, framed, grouped, cushion
    var id: String { rawValue }
    var title: String {
        switch self {
        case .adaptive: "Adaptive Frames"
        case .framed: "Top-Level Frames"
        case .grouped: "Grouped"
        case .cushion: "Classic Cushions"
        }
    }
    var mapStyle: TreemapMapStyle {
        switch self {
        case .adaptive: .adaptive
        case .framed: .framed
        case .grouped: .grouped
        case .cushion: .cushion
        }
    }

    /// The choice as Settings presents it: which folders get a frame with their name…
    var frames: FolderFrames {
        switch self {
        case .adaptive: .adaptive
        case .framed: .topLevels
        case .grouped, .cushion: .none
        }
    }
    /// …and, without frames, whether thin gutters still set folders apart.
    var hasGutters: Bool { self != .cushion }

    init(frames: FolderFrames, gutters: Bool) {
        switch frames {
        case .adaptive: self = .adaptive
        case .topLevels: self = .framed
        case .none: self = gutters ? .grouped : .cushion
        }
    }
}

/// Which folders are framed and named on the map.
enum FolderFrames: String, CaseIterable, Identifiable, Sendable {
    case adaptive, topLevels, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .adaptive: "Adaptive"
        case .topLevels: "Top levels only"
        case .none: "None"
        }
    }
}

/// How many folder levels below the folder shown the map subdivides.
enum MapDepth {
    /// The stored value for "down to the files".
    static let all = 0
    /// The deepest limit offered; beyond it "all" is the next step.
    static let deepest = 4
    static let choices = Array(1 ... deepest) + [all]

    static func title(_ depth: Int) -> String {
        switch depth {
        case all: "All Levels"
        case 1: "1 Level"
        default: "\(depth) Levels"
        }
    }

    /// One step towards fewer levels (`nil` at the lowest).
    static func less(than depth: Int) -> Int? {
        depth == all ? deepest : (depth > 1 ? depth - 1 : nil)
    }

    /// One step towards more levels (`nil` when everything is shown).
    static func more(than depth: Int) -> Int? {
        depth == all ? nil : (depth >= deepest ? all : depth + 1)
    }

    static func sanitized(_ depth: Int) -> Int { (1 ... deepest).contains(depth) ? depth : all }
}

/// Palette of the map, independent of the window's appearance.
enum MapPaletteSetting: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "Match Appearance"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// User settings, persisted in the user defaults. One observable object shared by every
/// window, so a change in Settings shows everywhere at once.
@MainActor @Observable
final class Preferences {
    static let shared = Preferences()

    /// The verification harness works on its own, freshly emptied domain so that it neither
    /// depends on nor disturbs the user's settings.
    @ObservationIgnored private let defaults: UserDefaults = {
        guard LaunchOptions.current.isHarness, let suite = UserDefaults(suiteName: "dev.disksurvey.app.harness") else { return .standard }
        suite.removePersistentDomain(forName: "dev.disksurvey.app.harness")
        return suite
    }()

    var sizeMode: SizeMode { didSet { defaults.set(sizeMode.rawValue, forKey: "sizeMode") } }
    var colorMode: ColorModeSetting { didSet { defaults.set(colorMode.rawValue, forKey: "colorMode") } }
    var mapStyle: MapStyleSetting { didSet { defaults.set(mapStyle.rawValue, forKey: "mapStyle") } }
    /// Folder levels the map subdivides below the folder shown; `MapDepth.all` for all of them.
    var mapDepth: Int { didSet { defaults.set(mapDepth, forKey: "mapDepth") } }
    var mapPalette: MapPaletteSetting { didSet { defaults.set(mapPalette.rawValue, forKey: "mapPalette") } }
    var showsLabels: Bool { didSet { defaults.set(showsLabels, forKey: "showsLabels") } }
    var showsTileBorders: Bool { didSet { defaults.set(showsTileBorders, forKey: "showsTileBorders") } }
    var cushionStrength: Double { didSet { defaults.set(cushionStrength, forKey: "cushionStrength") } }
    var packagesAsItems: Bool { didSet { defaults.set(packagesAsItems, forKey: "packagesAsItems") } }
    var confirmTrash: Bool { didSet { defaults.set(confirmTrash, forKey: "confirmTrash") } }
    var showHiddenSpace: Bool { didSet { defaults.set(showHiddenSpace, forKey: "showHiddenSpace") } }
    var crossMountPoints: Bool { didSet { defaults.set(crossMountPoints, forKey: "crossMountPoints") } }
    var excludedPaths: [String] { didSet { defaults.set(excludedPaths, forKey: "excludedPaths") } }
    /// 0 = automatic.
    var threadCount: Int { didSet { defaults.set(threadCount, forKey: "threadCount") } }
    var showsInspector: Bool { didSet { defaults.set(showsInspector, forKey: "showsInspector") } }
    var showsOutline: Bool { didSet { defaults.set(showsOutline, forKey: "showsOutline") } }
    var fullDiskAccessCardDismissed: Bool {
        didSet { defaults.set(fullDiskAccessCardDismissed, forKey: "fdaCardDismissed") }
    }

    private init() {
        defaults.register(defaults: [
            "showsLabels": true, "showsTileBorders": true, "cushionStrength": 1.0, "confirmTrash": true,
            "showHiddenSpace": true, "showsInspector": true, "showsOutline": true,
        ])
        sizeMode = SizeMode(rawValue: defaults.string(forKey: "sizeMode") ?? "") ?? .allocated
        colorMode = ColorModeSetting(rawValue: defaults.string(forKey: "colorMode") ?? "") ?? .kind
        mapStyle = MapStyleSetting(rawValue: defaults.string(forKey: "mapStyle") ?? "") ?? .adaptive
        mapDepth = MapDepth.sanitized(defaults.integer(forKey: "mapDepth"))
        mapPalette = MapPaletteSetting(rawValue: defaults.string(forKey: "mapPalette") ?? "") ?? .system
        showsLabels = defaults.bool(forKey: "showsLabels")
        showsTileBorders = defaults.bool(forKey: "showsTileBorders")
        cushionStrength = defaults.double(forKey: "cushionStrength")
        packagesAsItems = defaults.bool(forKey: "packagesAsItems")
        confirmTrash = defaults.bool(forKey: "confirmTrash")
        showHiddenSpace = defaults.bool(forKey: "showHiddenSpace")
        crossMountPoints = defaults.bool(forKey: "crossMountPoints")
        excludedPaths = defaults.stringArray(forKey: "excludedPaths") ?? []
        threadCount = defaults.integer(forKey: "threadCount")
        showsInspector = defaults.bool(forKey: "showsInspector")
        showsOutline = defaults.bool(forKey: "showsOutline")
        fullDiskAccessCardDismissed = defaults.bool(forKey: "fdaCardDismissed")
    }

    var scanOptions: ScanOptions {
        var options = ScanOptions()
        options.crossMountPoints = crossMountPoints
        options.excludedPaths = excludedPaths
        options.threadCount = max(0, threadCount)
        return options
    }
}

/// A finished scan remembered for the start screen.
struct RecentScan: Codable, Hashable, Identifiable, Sendable {
    var path: String
    var size: UInt64
    var fileCount: Int
    var date: Date
    var id: String { path }
    var name: String { path == "/" ? "Startup Disk" : (path as NSString).lastPathComponent }
}

/// Hidden launch arguments: the self-verification harness and `DiskSurvey <path>`.
struct LaunchOptions: Sendable {
    var scanPath: String?
    var snapshotPath: String?
    var snapshotDelay: Double = 0.8
    var appearance: String?
    var windowSize: CGSize?
    var inspector: String?
    var search: String?
    var selectPath: String?
    var zoomPath: String?
    var colorMode: String?
    var style: String?
    /// Detail level of the map: a number of folder levels, or "all".
    var depth: Int?
    /// Show the hover outline and tooltip for the item at this path.
    var hoverPath: String?
    var syntheticNodes: Int?
    var showSettings: String?
    var showTrashSheet = false
    var dumpMenu = false
    var measureStalls = false
    var showOutline: Bool?
    /// Take the snapshot this many seconds into the scan instead of after it.
    var duringScan: Double?
    /// Trash, undo and rescan against a throwaway folder (which must be named `disksurvey-action-test`).
    var exerciseActions = false
    /// Stop the scan after this many seconds (exercises cancellation).
    var cancelAfter: Double?
    /// Run the app target's regression checks (see `SelfTest`) and exit.
    var selfTest = false
    /// Create the throwaway folder for `--exercise-actions` in the temporary directory (inside
    /// the container when sandboxed) and scan it, instead of a folder named on the command line.
    var actionFixture = false
    /// Print what the process can reach (sandbox, home, grants, Full Disk Access) and exit.
    var sandboxReport = false
    /// Forget the grants stored by earlier harness runs before doing anything else.
    var forgetGrants = false

    var isHarness: Bool {
        snapshotPath != nil || measureStalls || dumpMenu || exerciseActions || selfTest || actionFixture || sandboxReport || forgetGrants
    }

    static let current = LaunchOptions(arguments: Array(CommandLine.arguments.dropFirst()))

    init(arguments: [String]) {
        var index = 0
        func value() -> String? {
            guard index + 1 < arguments.count else { return nil }
            index += 1
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--scan": scanPath = value()
            case "--snapshot": snapshotPath = value()
            case "--snapshot-delay": snapshotDelay = value().flatMap(Double.init) ?? snapshotDelay
            case "--appearance": appearance = value()
            case "--window-size":
                if let parts = value()?.lowercased().split(separator: "x"), parts.count == 2,
                    let width = Double(parts[0]), let height = Double(parts[1])
                {
                    windowSize = CGSize(width: width, height: height)
                }
            case "--inspector": inspector = value()
            case "--search": search = value()
            case "--select": selectPath = value()
            case "--zoom": zoomPath = value()
            case "--color": colorMode = value()
            case "--style": style = value()
            case "--depth": depth = value().map { MapDepth.sanitized(Int($0) ?? MapDepth.all) }
            case "--hover": hoverPath = value()
            case "--synthetic": syntheticNodes = value().flatMap(Int.init)
            case "--settings": showSettings = value()
            case "--trash-sheet": showTrashSheet = true
            case "--dump-menu": dumpMenu = true
            case "--measure-stalls": measureStalls = true
            case "--outline": showOutline = value() != "off"
            case "--exercise-actions": exerciseActions = true
            case "--cancel-after": cancelAfter = value().flatMap(Double.init)
            case "--during-scan": duringScan = value().flatMap(Double.init)
            case "--self-test": selfTest = true
            case "--action-fixture": actionFixture = true
            case "--sandbox-report": sandboxReport = true
            case "--forget-grants": forgetGrants = true
            default:
                // `DiskSurvey <path>`; AppKit's own `-Key value` options are skipped in pairs.
                if argument.hasPrefix("-") {
                    if !argument.hasPrefix("--") { index += 1 }
                } else if scanPath == nil {
                    scanPath = argument
                }
            }
            index += 1
        }
        if let path = scanPath {
            // `~` is the real home folder, also in the sandbox (where Foundation expands it to
            // the app's container).
            scanPath = URL(fileURLWithPath: AppSandbox.expandingTilde(path)).standardizedFileURL.path
        }
    }
}
