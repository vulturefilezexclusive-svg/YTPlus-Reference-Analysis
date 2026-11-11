// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TrapTubeStemKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "TrapTubeStemKit", type: .dynamic, targets: ["TrapTubeStemKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/SplitFireAI/demucs-swift.git", exact: "0.1.0")
    ],
    targets: [
        .target(
            name: "TrapTubeStemKit",
            dependencies: [.product(name: "Demucs", package: "demucs-swift")]
        )
    ],
    swiftLanguageModes: [.v5]
)
