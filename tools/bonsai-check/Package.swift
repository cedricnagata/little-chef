// swift-tools-version: 6.0
//
// Loads each Bonsai 2 model the way the app does — the same mlx-swift-lm fork, the same
// Hugging Face loader, the app's own tool definitions (symlinked in Sources/bonsai-check/App) —
// and reports whether it answers, calls tools and returns JSON, how fast, and how much memory it
// holds. macOS on Apple Silicon only: MLX needs Metal, which the Simulator doesn't give it.
//
//   swift run -c release bonsai-check                 # every model
//   swift run -c release bonsai-check prism-ml/Ternary-Bonsai-2-4B-mlx-2bit
//
// Keep the package pins below equal to the app's (project.pbxproj / Package.resolved).

import PackageDescription

let package = Package(
    name: "BonsaiCheck",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.33.0"),
        .package(url: "https://github.com/cedricnagata/mlx-swift-lm", revision: "7a5ff87473419be495faf3c57bfb95fe587c9897"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.13.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.5"),
    ],
    targets: [
        .executableTarget(
            name: "bonsai-check",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
