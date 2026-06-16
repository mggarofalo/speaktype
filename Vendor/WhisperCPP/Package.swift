// swift-tools-version:5.9
import PackageDescription

// Local package wrapping the prebuilt whisper.cpp xcframework (Metal-enabled,
// from ggml-org/whisper.cpp releases). The xcframework binary is not committed —
// run scripts/fetch-whisper-xcframework.sh to populate ./whisper.xcframework.
let package = Package(
    name: "WhisperCPP",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WhisperCPP", targets: ["WhisperCPP"])
    ],
    targets: [
        .binaryTarget(name: "whisper", path: "whisper.xcframework"),
        .target(name: "WhisperCPP", dependencies: ["whisper"]),
    ]
)
