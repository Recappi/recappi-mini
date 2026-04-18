// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RecappiMini",
    platforms: [
        .macOS(.v26),
    ],
    targets: [
        .executableTarget(
            name: "RecappiMini",
            path: "RecappiMini",
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
                .linkedFramework("CoreMedia"),
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "RecappiMini/Info.plist"]),
            ]
        ),
    ]
)
