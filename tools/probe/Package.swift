// swift-tools-version: 6.0
// 设备探针 VoxPalm Probe：实测遥控器、无线麦等设备的按键和收音能力，导出 JSON 和 Markdown 报告。
import PackageDescription

let package = Package(
    name: "VoxPalmProbe",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "voxpalm-probe", targets: ["voxpalm-probe"]),
    ],
    dependencies: [
        .package(path: "../../Packages/VoxPalmCore"),
    ],
    targets: [
        .target(
            name: "ProbeKit",
            dependencies: [.product(name: "VoxPalmDevices", package: "VoxPalmCore")]
        ),
        .executableTarget(
            name: "voxpalm-probe",
            dependencies: ["ProbeKit"],
            exclude: ["Info.plist"],
            linkerSettings: [
                // 命令行程序没有 App 包，把 Info.plist 嵌进可执行文件，系统才认得它的标识和麦克风用途说明。
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                              "-Xlinker", "\(Context.packageDirectory)/Sources/voxpalm-probe/Info.plist"]),
            ]
        ),
        .testTarget(name: "ProbeKitTests", dependencies: ["ProbeKit"]),
    ],
    swiftLanguageModes: [.v5]
)
