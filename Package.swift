// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RecappiMini",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "RecappiMini", targets: ["RecappiMini"]),
        .executable(name: "recappi", targets: ["RecappiCLI"]),
        .library(name: "RecappiCloudCore", targets: ["RecappiCloudCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.8.1"),
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", exact: "9.13.0"),
    ],
    targets: [
        .target(
            name: "RecappiCloudCore",
            dependencies: [],
            path: "Sources/RecappiCloudCore",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
            ]
        ),
        .executableTarget(
            name: "RecappiCLI",
            dependencies: ["RecappiCloudCore"],
            path: "Sources/RecappiCLI"
        ),
        .executableTarget(
            name: "RecappiMini",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Sentry", package: "sentry-cocoa"),
            ],
            path: "RecappiMini",
            exclude: ["Info.plist", "RecappiMini.entitlements", "Resources"],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AuthenticationServices"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Security"),
                .linkedLibrary("sqlite3"),
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "RecappiMini/Info.plist"]),
            ]
        ),
        .testTarget(
            name: "RecappiMiniCoreTests",
            dependencies: ["RecappiMini", "RecappiCloudCore"],
            path: "Tests/RecappiMiniCoreTests"
        ),
    ]
)
