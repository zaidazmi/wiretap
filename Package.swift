// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Wiretap",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Wiretap", targets: ["Wiretap"])
    ],
    targets: [
        .executableTarget(
            name: "Wiretap",
            path: "Sources/Wiretap",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                // Embed Info.plist into the bare executable so permission-gated
                // APIs (Audio Capture, microphone) can prompt even when the
                // binary runs outside the packaged .app bundle.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Wiretap/Resources/WiretapInfo.plist"
                ])
            ]
        ),
        .testTarget(
            name: "WiretapTests",
            dependencies: ["Wiretap"]
        )
    ]
)
