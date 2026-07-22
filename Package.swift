// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AtlasMapped",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "AtlasMapped", targets: ["AtlasMapped"])
    ],
    targets: [
        .executableTarget(
            name: "AtlasMapped",
            path: "Atlas/Sources"
        ),
        .testTarget(
            name: "AtlasMappedTests",
            dependencies: ["AtlasMapped"],
            path: "Atlas/Tests"
        )
    ]
)
