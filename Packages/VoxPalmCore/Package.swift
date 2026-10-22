// swift-tools-version: 6.0
// 掌声 VoxPalm 的核心库：设备读取、按键动作引擎、语音会话。App 和设备探针共用。
import PackageDescription

// whisper.cpp（MIT）官方预编译的 xcframework：老系统没有系统转写时用它。版本 v1.9.5：
// 官方的版本号发布不带附件，同一个提交的预编译包挂在构建号 b5454 下。
// 升级时构建号、校验和（GitHub 发布页附件的 sha256）、THIRD-PARTY-NOTICES.md 里的版本一起改。
let whisperBuild = "b5454"
let whisperChecksum = "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"

let package = Package(
    name: "VoxPalmCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VoxPalmDevices", targets: ["VoxPalmDevices"]),
        .library(name: "VoxPalmEngine", targets: ["VoxPalmEngine"]),
        .library(name: "VoxPalmVoice", targets: ["VoxPalmVoice"]),
    ],
    targets: [
        .target(
            name: "VoxPalmDevices",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AppKit"),
                .linkedFramework("MediaPlayer"),
                .linkedFramework("Accelerate"),
            ]
        ),
        .target(name: "VoxPalmEngine", dependencies: ["VoxPalmDevices"]),
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/\(whisperBuild)/whisper-\(whisperBuild)-xcframework.zip",
            checksum: whisperChecksum
        ),
        .target(
            name: "VoxPalmVoice",
            dependencies: ["VoxPalmDevices", "VoxPalmEngine", "whisper"],
            linkerSettings: [.linkedFramework("Speech"), .linkedFramework("AVFoundation")]
        ),
        .testTarget(name: "VoxPalmDevicesTests", dependencies: ["VoxPalmDevices"]),
        .testTarget(name: "VoxPalmEngineTests", dependencies: ["VoxPalmEngine"]),
        .testTarget(name: "VoxPalmVoiceTests", dependencies: ["VoxPalmVoice"]),
    ],
    swiftLanguageModes: [.v5]
)
