// swift-tools-version: 6.0
// 掌声 VoxPalm 的核心库：设备读取、按键动作引擎、语音会话。App 和设备探针共用。
import PackageDescription

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
        .target(
            name: "VoxPalmVoice",
            dependencies: ["VoxPalmDevices", "VoxPalmEngine"],
            linkerSettings: [.linkedFramework("Speech"), .linkedFramework("AVFoundation")]
        ),
        .testTarget(name: "VoxPalmDevicesTests", dependencies: ["VoxPalmDevices"]),
        .testTarget(name: "VoxPalmEngineTests", dependencies: ["VoxPalmEngine"]),
        .testTarget(name: "VoxPalmVoiceTests", dependencies: ["VoxPalmVoice"]),
    ],
    swiftLanguageModes: [.v5]
)
