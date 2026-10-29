import VoxPalmEngine
#if VOXPALM_PRIVATE
import VoxPalmDJI
import VoxPalmMarks
#if VOXPALM_EXPERIMENTAL_AUDIO
import VoxPalmAudioExtension
#endif
#endif

/// 闭源模块的接入点。开源版编译时这些模块不存在，这里全部返回空，App 照样完整可用。
enum PrivateModules {
    /// 启动时调一次：官方版登记第三方品牌标志（开源版示意图用普通字体印品牌名）。
    static func setUp() {
        #if VOXPALM_PRIVATE
        ThirdPartyMarks.register()
        #endif
    }

    static func controlSources() -> [ControlSource] {
        #if VOXPALM_PRIVATE
        var sources = DJIModule.controlSources()
        #if VOXPALM_EXPERIMENTAL_AUDIO
        sources += AudioExtensionModule.controlSources()
        #endif
        return sources
        #else
        return []
        #endif
    }

    /// 闭源模块认识的型号（示意图、短名字）：没连上时也在选设备列表里灰着列出来，告诉用户还支持什么。
    static func knownModels() -> [(diagram: DeviceDiagram, shortName: String)] {
        #if VOXPALM_PRIVATE
        return DJIModule.knownModels()
        #else
        return []
        #endif
    }

    /// 闭源模块认识的收音设备（按设备名认）：收音列表和面板里画它的样子、用短名字。
    static func micModel(named name: String) -> (diagram: DeviceDiagram, shortName: String)? {
        #if VOXPALM_PRIVATE
        return DJIModule.micModel(forAudioDeviceNamed: name)
        #else
        return nil
        #endif
    }

    /// 闭源模块自带的设备示意图（调试渲染用）。
    static func previewDiagrams() -> [DeviceDiagram] {
        #if VOXPALM_PRIVATE
        return DJIModule.previewDiagrams()
        #else
        return []
        #endif
    }

    static var buildFlavor: String {
        #if VOXPALM_PRIVATE
        return "官方版（含 DJI 适配）"
        #else
        return "开源版"
        #endif
    }
}
