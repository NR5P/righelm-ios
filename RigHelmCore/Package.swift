// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RigHelmCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RigHelmCore", targets: ["RigHelmCore"]),
    ],
    targets: [
        .target(name: "RigHelmCore"),
        // Command-line check against a real RigHelm server (never transmits).
        .executableTarget(name: "rhcheck", dependencies: ["RigHelmCore"]),
        .testTarget(name: "RigHelmCoreTests", dependencies: ["RigHelmCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
