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

    init() {}

    /// 缺的字段用默认值，旧版本的配置文件也能读。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        controlDeviceIDs = try c.decodeIfPresent([String].self, forKey: .controlDeviceIDs) ?? []
        keyMap = try c.decodeIfPresent(KeyMap.self, forKey: .keyMap) ?? KeyMap()
        timing = try c.decodeIfPresent(GestureTiming.self, forKey: .timing) ?? GestureTiming()
        voice = try c.decodeIfPresent(VoiceSession.Settings.self, forKey: .voice) ?? VoiceSession.Settings()
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
