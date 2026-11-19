// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PranaBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PranaBar", targets: ["PranaBar"]),
        .library(name: "PranaKit", targets: ["PranaKit"]),
    ],
    targets: [
        // Foundation-only client and models for the Prana local HTTP API.
        .target(name: "PranaKit"),

        // SwiftUI menu bar app.
        .executableTarget(
            name: "PranaBar",
            dependencies: ["PranaKit"],
            linkerSettings: [
                // Embed Info.plist so `swift run` gets ATS local networking and LSUIElement.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Support/Info.plist",
                ]),
            ]
        ),

        .testTarget(name: "PranaKitTests", dependencies: ["PranaKit"]),
    ]
)
