// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tsuyaku",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "1.1.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.2"),
    ],
    targets: [
        .executableTarget(
            name: "Tsuyaku",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Tsuyaku"
        ),
        .executableTarget(
            name: "TsuyakuCLI",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/TsuyakuCLI"
        ),
    ]
)
