// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AICredits",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AICredits", targets: ["AICreditsApp"])],
    targets: [
        .executableTarget(name: "AICreditsApp"),
        .testTarget(name: "AICreditsAppTests", dependencies: ["AICreditsApp"])
    ]
)
