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
            ]
        ),
        .testTarget(
            name: "WiretapTests",
            dependencies: ["Wiretap"]
        )
    ]
)
