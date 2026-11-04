// swift-tools-version: 6.0
import PackageDescription

// 共享协议的编译下限；手机版的实际最低系统和硬件兼容性另行验收。
let package = Package(
    name: "VoxPalmLink",
    platforms: [.macOS(.v14), .iOS(.v16), .watchOS(.v9)],
    products: [.library(name: "VoxPalmLink", targets: ["VoxPalmLink"]),
               .library(name: "VoxPalmLinkNetwork", targets: ["VoxPalmLinkNetwork"])],
    targets: [
        .target(name: "VoxPalmLink"),
        .target(name: "VoxPalmLinkNetwork", dependencies: ["VoxPalmLink"]),
        .testTarget(name: "VoxPalmLinkTests", dependencies: ["VoxPalmLink"]),
        .testTarget(name: "VoxPalmLinkNetworkTests", dependencies: ["VoxPalmLinkNetwork"]),
    ]
)
