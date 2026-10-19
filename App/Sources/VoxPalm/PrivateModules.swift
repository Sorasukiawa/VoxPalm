import VoxPalmEngine
#if VOXPALM_PRIVATE
import VoxPalmDJI
#endif

/// 闭源模块的接入点。开源版编译时这些模块不存在，这里全部返回空，App 照样完整可用。
enum PrivateModules {
    static func controlSources() -> [ControlSource] {
        #if VOXPALM_PRIVATE
        return DJIModule.controlSources()
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
