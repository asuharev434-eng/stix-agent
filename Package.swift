// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "STIXAgent",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "STIXAgent", targets: ["STIXAgent"])],
    targets: [
        .executableTarget(name: "STIXAgent", resources: [.copy("Resources")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "STIXAgentTests", dependencies: ["STIXAgent"])
    ]
)
