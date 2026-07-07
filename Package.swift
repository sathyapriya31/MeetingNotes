// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeetingNotes",
    platforms: [
        .macOS("14.4")
    ],
    products: [
        .executable(name: "MeetingNotes", targets: ["MeetingNotes"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.7.2"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.4.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.0.0"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.1.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "0.1.24")
    ],
    targets: [
        .executableTarget(
            name: "MeetingNotes",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Transformers", package: "swift-transformers")
            ],
            path: "Sources/MeetingNotes"
        )
    ]
)
