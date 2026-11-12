// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TunerCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "TunerCore", targets: ["TunerCore"]),
    ],
    targets: [
        .target(name: "TunerCore"),
        .testTarget(name: "TunerCoreTests", dependencies: ["TunerCore"]),
    ]
)
