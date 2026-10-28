import Foundation
import VoxPalmDevices
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

    static func load(from url: URL = fileURL) throws -> AppConfig {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return AppConfig()
        }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> AppConfig {
        let config = try JSONDecoder().decode(AppConfig.self, from: data)
        try config.validate()
        return config
    }

    /// 外部 JSON 也会进入定时器、录音缓冲区和 SwiftUI 列表，不能只检查它是否符合 Codable。
    func validate() throws {
        guard version == 1 else { throw ValidationError.unsupportedVersion(version) }
        for (name, value) in [("双击间隔", timing.doubleTapWindow), ("长按时长", timing.longPressThreshold)] {
            guard value.isFinite, value > 0, value < Double(Int64.max) / 1_000_000_000 else {
                throw ValidationError.invalidValue(name)
            }
        }
        for (name, value) in [("切回麦克风延迟", voice.restoreInputDelay), ("输入法发送延迟", voice.inputMethodSendDelay),
                              ("最短录音时长", voice.minimumSeconds)] {
            guard value.isFinite, (0...60).contains(value) else { throw ValidationError.invalidValue("\(name)（0–60 秒）") }
        }
        guard voice.warmSeconds.isFinite, (0...3).contains(voice.warmSeconds) else {
            throw ValidationError.invalidValue("预录时长（0–3 秒）")
        }
        guard Set(controlDeviceIDs).count == controlDeviceIDs.count, !controlDeviceIDs.contains("") else {
            throw ValidationError.invalidValue("控制设备列表")
        }
        var ids = Set<UUID>()
        var gestures: [ButtonID: Set<GestureKind>] = [:]
        for binding in keyMap.bindings {
            guard ids.insert(binding.id).inserted,
                  gestures[binding.button, default: []].insert(binding.gesture).inserted else {
                throw ValidationError.invalidValue("重复的按键映射")
            }
        }
        for layout in deviceLayouts.values {
            guard Set(layout.learned.map(\.button)).count == layout.learned.count else {
                throw ValidationError.invalidValue("重复的已学按键")
            }
        }
    }

    func save(to url: URL = fileURL) throws {
        try validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// 「导出设置」写出去的版本。这个文件常被发给别人看，设备标识去掉身份（`Redaction.maskDeviceIdentity`），
    /// 标识里带蓝牙地址的收音设备改回跟随系统默认输入；导入后由 `resolveDevicePlaceholders` 按型号认回。
    func sharable() -> AppConfig {
        var copy = self
        copy.controlDeviceIDs = []
        for id in controlDeviceIDs.map(Redaction.maskDeviceIdentity) where !copy.controlDeviceIDs.contains(id) {
            copy.controlDeviceIDs.append(id)
        }
        // 同型号的几台会落到同一个标识上，只留一份示意图设置：先留正在用的那台。
        copy.deviceLayouts = [:]
        let ordered = deviceLayouts.sorted { a, b in
            let (activeA, activeB) = (controlDeviceIDs.contains(a.key), controlDeviceIDs.contains(b.key))
            return activeA != activeB ? activeA : a.key < b.key
        }
        for (id, layout) in ordered {
            let masked = Redaction.maskDeviceIdentity(id)
            if copy.deviceLayouts[masked] == nil { copy.deviceLayouts[masked] = layout }
        }
        if let uid = voice.micUID, Redaction.maskDeviceIdentity(uid) != uid { copy.voice.micUID = nil }
        return copy
    }

    /// 导入的设置里去掉身份的设备标识，换回当前连着的同型号设备。恰好一台对得上才换，认不准的留着，等设备连上再认。
    /// 返回有没有改动。
    mutating func resolveDevicePlaceholders(connected: [String]) -> Bool {
        let before = self
        func match(_ masked: String, excluding taken: [String]) -> String? {
            let candidates = connected.filter { Redaction.identity(masked, matches: $0) && !taken.contains($0) }
            return candidates.count == 1 ? candidates[0] : nil
        }
        for (index, id) in controlDeviceIDs.enumerated() where id.contains(Redaction.identityPlaceholder) {
            if let found = match(id, excluding: controlDeviceIDs) { controlDeviceIDs[index] = found }
        }
        for (id, layout) in deviceLayouts where id.contains(Redaction.identityPlaceholder) {
            guard let found = match(id, excluding: []) else { continue }
            deviceLayouts[id] = nil
            // 本机已经有这台设备的示意图设置时以本机的为准
            if deviceLayouts[found] == nil { deviceLayouts[found] = layout }
        }
        return self != before
    }

    enum ValidationError: LocalizedError {
        case unsupportedVersion(Int)
        case invalidValue(String)

        var errorDescription: String? {
            switch self {
            case let .unsupportedVersion(version): return "设置文件版本 \(version) 不受当前掌声支持，请使用对应版本的 App。"
            case let .invalidValue(name): return "设置文件里的「\(name)」不合法，未应用这份设置。"
            }
        }
    }
}

/// 延迟保存与退出前落盘共用同一份待保存内容；读坏的原文件只在明确导入时备份、替换。
@MainActor
final class AppConfigStore {
    let url: URL
    let initialConfig: AppConfig
    private(set) var loadProblem: String?
    private(set) var hasPendingChanges = false
    var onSaveResult: ((String?) -> Void)?
    private var pending: AppConfig?
    private var saveWork: DispatchWorkItem?

    init(url: URL = AppConfig.fileURL) {
        self.url = url
        do {
            initialConfig = try AppConfig.load(from: url)
        } catch {
            initialConfig = AppConfig()
            loadProblem = "原设置文件读不出来，已保留在 \(url.path)。本次更改暂不保存，可先导出，再导入有效设置恢复保存。原因：\(error.localizedDescription)"
        }
    }

    func scheduleSave(_ config: AppConfig) {
        pending = config
        hasPendingChanges = true
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            do { try self?.flush() } catch { /* flush 已把失败交给界面，保留待保存内容供重试 */ }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func flush() throws {
        saveWork?.cancel()
        saveWork = nil
        guard let pending else { return }
        do {
            if let loadProblem { throw SaveError.protectedOriginal(loadProblem) }
            try pending.save(to: url)
            self.pending = nil
            hasPendingChanges = false
            onSaveResult?(nil)
        } catch {
            onSaveResult?(error.localizedDescription)
            throw error
        }
    }

    /// 导入先保存旧设置，再写新设置；写盘失败时不更改运行中的配置，也不丢掉延迟保存内容。
    @discardableResult
    func replace(with imported: AppConfig, previous: AppConfig) throws -> URL {
        try imported.validate()
        let backup = url.deletingLastPathComponent().appendingPathComponent("config-backup-\(UUID().uuidString).json")
        if loadProblem != nil {
            try FileManager.default.copyItem(at: url, to: backup)
            if hasPendingChanges {
                // 原文件读坏后用户仍可能编辑了临时设置，两份都保留。
                let unsaved = url.deletingLastPathComponent().appendingPathComponent("config-unsaved-\(UUID().uuidString).json")
                try previous.save(to: unsaved)
            }
        } else {
            try previous.save(to: backup)
        }
        try imported.save(to: url)
        saveWork?.cancel()
        saveWork = nil
        pending = nil
        hasPendingChanges = false
        loadProblem = nil
        onSaveResult?(nil)
        return backup
    }

    private enum SaveError: LocalizedError {
        case protectedOriginal(String)
        var errorDescription: String? {
            switch self { case let .protectedOriginal(message): return message }
        }
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
