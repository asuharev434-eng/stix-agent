// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "STIXAgent",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.executable(name: "STIXAgent", targets: ["STIXAgent"])],
    dependencies: [
        .package(url: "https://github.com/apple-aiml-research/ml-stable-diffusion.git",
                 revision: "ea2805dc1945be20561c77e5f6d1d9a5a637cda2")
    ],
    targets: [
        .target(name: "RemoteChatCore", path: "Shared/RemoteChatCore"),
        .executableTarget(name: "STIXAgent",
                          dependencies: ["RemoteChatCore", .product(name: "StableDiffusion", package: "ml-stable-diffusion")],
                          resources: [.copy("Resources")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "STIXAgentTests", dependencies: ["STIXAgent", "RemoteChatCore"], resources: [.copy("Fixtures")])
    ]
)
