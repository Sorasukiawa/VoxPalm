// swift-tools-version: 6.0
// 掌声 VoxPalm 菜单栏 App。打包成 .app 用 scripts/build-app.sh。
//
// 开源版只依赖 Packages/VoxPalmCore，完整可用。官方版本编译时设环境变量
// VOXPALM_PRIVATE_DIR 指向私有仓库，会额外链接 DJI 适配、第三方品牌标志（以后还有 Pro 包），并定义编译条件 VOXPALM_PRIVATE。
// 不用 canImport 判断：编译目录里残留的旧模块会让它误判。
import Foundation
import PackageDescription

var dependencies: [Package.Dependency] = [.package(path: "../Packages/VoxPalmCore")]
var swiftSettings: [SwiftSetting] = []
var appDependencies: [Target.Dependency] = [
    .product(name: "VoxPalmDevices", package: "VoxPalmCore"),
    .product(name: "VoxPalmEngine", package: "VoxPalmCore"),
    .product(name: "VoxPalmVoice", package: "VoxPalmCore"),
]

if let privateDir = ProcessInfo.processInfo.environment["VOXPALM_PRIVATE_DIR"], !privateDir.isEmpty {
    dependencies.append(.package(path: "\(privateDir)/dji"))
    dependencies.append(.package(path: "\(privateDir)/marks"))
    appDependencies.append(.product(name: "VoxPalmDJI", package: "dji"))
    appDependencies.append(.product(name: "VoxPalmMarks", package: "marks"))
    swiftSettings.append(.define("VOXPALM_PRIVATE"))
}

let package = Package(
    name: "VoxPalmApp",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "VoxPalm", targets: ["VoxPalm"])],
    dependencies: dependencies,
    targets: [
        .executableTarget(
            name: "VoxPalm",
            dependencies: appDependencies,
            swiftSettings: swiftSettings,
            // 打包时 whisper.cpp 的框架放在 VoxPalm.app/Contents/Frameworks（scripts/build-app.sh）
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ],
    swiftLanguageModes: [.v5]
)
