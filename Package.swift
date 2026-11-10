// swift-tools-version: 6.2
import PackageDescription

// Disk Survey — a modern disk-usage visualizer for macOS.
// Zero third-party dependencies; builds with only the Command Line Tools.
let package = Package(
    name: "DiskSurvey",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "DiskSurveyCore", targets: ["DiskSurveyCore"]),
        .library(name: "DiskSurveyScan", targets: ["DiskSurveyScan"]),
        .library(name: "DiskSurveyTreemap", targets: ["DiskSurveyTreemap"]),
        .library(name: "DiskSurveyMapView", targets: ["DiskSurveyMapView"]),
        // Executable product names must not collide case-insensitively.
        .executable(name: "disksurvey-cli", targets: ["disksurvey-cli"]),
        .executable(name: "DiskSurveyApp", targets: ["DiskSurveyApp"]),
    ],
    targets: [
        .target(name: "DiskSurveyCore"),
        .target(name: "DiskSurveyScan", dependencies: ["DiskSurveyCore"]),
        .target(name: "DiskSurveyTreemap", dependencies: ["DiskSurveyCore"]),
        .target(name: "DiskSurveyMapView", dependencies: ["DiskSurveyCore", "DiskSurveyTreemap"]),
        .executableTarget(name: "disksurvey-cli", dependencies: ["DiskSurveyCore", "DiskSurveyScan"]),
        .executableTarget(
            name: "DiskSurveyApp",
            dependencies: ["DiskSurveyCore", "DiskSurveyScan", "DiskSurveyTreemap", "DiskSurveyMapView"]
        ),
        .testTarget(name: "DiskSurveyCoreTests", dependencies: ["DiskSurveyCore"]),
        .testTarget(name: "DiskSurveyScanTests", dependencies: ["DiskSurveyScan", "DiskSurveyCore"]),
        .testTarget(name: "DiskSurveyTreemapTests", dependencies: ["DiskSurveyTreemap", "DiskSurveyCore"]),
        .testTarget(name: "DiskSurveyMapViewTests", dependencies: ["DiskSurveyMapView", "DiskSurveyTreemap", "DiskSurveyCore"]),
        .testTarget(name: "DiskSurveyCLITests", dependencies: ["disksurvey-cli", "DiskSurveyCore"]),
    ]
)
