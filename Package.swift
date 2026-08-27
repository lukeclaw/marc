// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "marc",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "marc", targets: ["Marc"]),
        .executable(name: "marc-checks", targets: ["MarcChecks"])
    ],
    targets: [
        .target(
            name: "MarcCore",
            path: "Sources/MarcCore"
        ),
        .executableTarget(
            name: "Marc",
            dependencies: ["MarcCore"],
            path: "Sources/Marc"
        ),
        .executableTarget(
            name: "MarcChecks",
            dependencies: ["MarcCore"],
            path: "Sources/MarcChecks"
        )
    ]
)
