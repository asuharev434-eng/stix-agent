// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "STIXMLXRunner",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "stix-mlx-runner", targets: ["stix-mlx-runner"])],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", revision: "48114eedf3c3d4a682a6b1d644cc5af5c2945d10"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.0")
    ],
    targets: [
        .executableTarget(name: "stix-mlx-runner", dependencies: [
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXVLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
            .product(name: "HuggingFace", package: "swift-huggingface"),
            .product(name: "Tokenizers", package: "swift-transformers")
        ])
    ]
)
