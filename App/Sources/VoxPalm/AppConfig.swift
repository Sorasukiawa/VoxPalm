import Foundation
import VoxPalmEngine
import VoxPalmVoice

/// 全部用户设置，存成一个 JSON：~/Library/Application Support/VoxPalm/config.json。导入导出也用这个格式。
struct AppConfig: Codable, Equatable {
    var version = 1
    var controlDeviceIDs: [String] = []
    var keyMap = KeyMap()
    var timing = GestureTiming()
    var voice = VoiceSession.Settings()
    /// 每台控制设备的示意图：选的外形、示意图上的键对应学到的哪个键
    var deviceLayouts: [String: DeviceLayout] = [:]
    /// 第一次打开的引导走完了没有
    var onboardingDone = false
    /// 按键时在屏幕下方弹一张小卡片：设备图上点亮刚按的键，写清楚做了什么
    var showKeyFlash = true

    init() {}

    /// 缺的字段用默认值，旧版本的配置文件也能读。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        controlDeviceIDs = try c.decodeIfPresent([String].self, forKey: .controlDeviceIDs) ?? []
        keyMap = try c.decodeIfPresent(KeyMap.self, forKey: .keyMap) ?? KeyMap()
        timing = try c.decodeIfPresent(GestureTiming.self, forKey: .timing) ?? GestureTiming()
        voice = try c.decodeIfPresent(VoiceSession.Settings.self, forKey: .voice) ?? VoiceSession.Settings()
        deviceLayouts = try c.decodeIfPresent([String: DeviceLayout].self, forKey: .deviceLayouts) ?? [:]
        onboardingDone = try c.decodeIfPresent(Bool.self, forKey: .onboardingDone) ?? false
        showKeyFlash = try c.decodeIfPresent(Bool.self, forKey: .showKeyFlash) ?? true
    }

    static var fileURL: URL {
        // 调试用：VOXPALM_CONFIG 指向别的配置文件，不碰真正的设置。
        if let path = ProcessInfo.processInfo.environment["VOXPALM_CONFIG"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VoxPalm/config.json")
    }

    static func load(from url: URL = fileURL) -> AppConfig {
        guard let data = try? Data(contentsOf: url), let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return AppConfig()
        }
        return config
    }

    func save(to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// 一台控制设备在示意图上的样子。
struct DeviceLayout: Codable, Equatable {
    /// 用户选的外形（示意图 id）；nil = 自动（适配模块给的或者按设备说明猜的）
    var diagramID: String?
    /// 示意图上的键（spot id）→ 学到的键
    var spotButtons: [String: ButtonID] = [:]
    /// 外形是「通用按键」时，学到的键按顺序排
    var learned: [LearnedButton] = []
}

struct LearnedButton: Codable, Equatable {
    var button: ButtonID
    var label: String
}
