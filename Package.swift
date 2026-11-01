// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mnemosift",
    defaultLocalization: "ja",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MnemosiftCore",
            targets: ["MnemosiftCore"]
        ),
        .executable(
            name: "Mnemosift",
            targets: ["MnemosiftApp"]
        )
    ],
    targets: [
        .target(
            name: "MnemosiftCore",
            path: "Sources/MnemosiftCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Speech"),
                .linkedFramework("NaturalLanguage"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Accelerate")
            ]
        ),
        .executableTarget(
            name: "MnemosiftApp",
            dependencies: ["MnemosiftCore"],
            path: "Sources/MnemosiftApp",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/MnemosiftApp/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "MnemosiftTests",
            dependencies: ["MnemosiftCore"],
            path: "Tests/MnemosiftTests"
        )
    ]
)
