// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RecappiMini",
    platforms: [
        .macOS(.v26),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.8.1"),
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", exact: "9.13.0"),
    ],
    targets: [
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
        .executableTarget(
            name: "RecappiMiniSidecar",
            path: "RecappiMiniSidecar",
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "RecappiMiniSidecar/Info.plist"]),
            ]
        ),
        .testTarget(
            name: "RecappiMiniCoreTests",
            dependencies: ["RecappiMini"],
            path: "Tests/RecappiMiniCoreTests"
        ),
    ]
)
