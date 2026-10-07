// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Caton",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Caton", targets: ["Caton"]),
    ],
    dependencies: [
        .package(url: "https://github.com/shergin/baton.git", .upToNextMinor(from: "0.8.0")),
    ],
    targets: [
        .target(
            name: "CatonCore",
            path: "Sources/CatonCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Caton",
            dependencies: [
                "CatonCore",
                .product(name: "Baton", package: "baton"),
                .product(name: "BatonInspector", package: "baton"),
            ],
            path: "Sources/Caton",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)],
            plugins: [.plugin(name: "BatonPlugin", package: "baton")]
        ),
        .testTarget(
            name: "CatonTests",
            dependencies: ["Caton", "CatonCore", .product(name: "BatonTesting", package: "baton")],
            path: "Tests/CatonTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CatonCoreTests",
            dependencies: ["CatonCore"],
            path: "Tests/CatonCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
