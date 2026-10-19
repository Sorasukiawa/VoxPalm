import AVFoundation
import CoreAudio
import Foundation
import VoxPalmDevices
import VoxPalmEngine

/// 语音会话：按住说话 / 按一下开始结束。两种出字方式：
/// - 内置转写：直接从选中的收音设备录音（不改系统默认输入），说完转成文字贴到光标处。
/// - 外部输入法：临时把系统默认输入切到选中的收音设备，模拟输入法的语音键，结束后切回。
public final class VoiceSession: VoiceActionHandler {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case builtIn
        case inputMethod

        public var title: String {
            switch self {
            case .builtIn: return "内置转写"
            case .inputMethod: return "外部输入法"
            }
        }
    }

    public enum State: Equatable, Sendable {
        case idle
        /// 按下了按住说话的键，已经开麦预录，还没确认是长按
        case armed
        case listening
        case transcribing
    }

    public struct Settings: Codable, Equatable, Sendable {
        public var mode: Mode = .builtIn
        /// 收音设备的 UID；nil = 跟随系统默认输入
        public var micUID: String?
        public var localeID = "zh-CN"
        public var transcriber: TranscriberChoice = .automatic
        public var whisper = WhisperCLITranscriber.Configuration()
        public var inputMethodKey = InputMethodKey()
        /// 外部输入法模式下，松手后等多久再把系统默认输入切回去（输入法可能还在收尾）
        public var restoreInputDelay: Double = 1.5
        /// 一直开着麦克风、保留最近一段声音：蓝牙麦开麦要半秒以上时用，代价是麦克风指示灯常亮
        public var keepMicWarm = false
        public var warmSeconds: Double = 1.0
        public var textMethod: TextInserter.Method = .paste
        /// 短于这个时长的录音当成误触，不转写
        public var minimumSeconds: Double = 0.3

        public init() {}

        /// 缺的字段用默认值：以后加了新设置，旧的配置文件也能读。
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Settings()
            mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? d.mode
            micUID = try c.decodeIfPresent(String.self, forKey: .micUID)
            localeID = try c.decodeIfPresent(String.self, forKey: .localeID) ?? d.localeID
            transcriber = try c.decodeIfPresent(TranscriberChoice.self, forKey: .transcriber) ?? d.transcriber
            whisper = try c.decodeIfPresent(WhisperCLITranscriber.Configuration.self, forKey: .whisper) ?? d.whisper
            inputMethodKey = try c.decodeIfPresent(InputMethodKey.self, forKey: .inputMethodKey) ?? d.inputMethodKey
            restoreInputDelay = try c.decodeIfPresent(Double.self, forKey: .restoreInputDelay) ?? d.restoreInputDelay
            keepMicWarm = try c.decodeIfPresent(Bool.self, forKey: .keepMicWarm) ?? d.keepMicWarm
            warmSeconds = try c.decodeIfPresent(Double.self, forKey: .warmSeconds) ?? d.warmSeconds
            textMethod = try c.decodeIfPresent(TextInserter.Method.self, forKey: .textMethod) ?? d.textMethod
            minimumSeconds = try c.decodeIfPresent(Double.self, forKey: .minimumSeconds) ?? d.minimumSeconds
        }
    }

    public var settings: Settings {
        didSet { if settings != oldValue { settingsChanged(from: oldValue) } }
    }
    public var onStateChange: ((State) -> Void)?
    public var onMessage: ((String) -> Void)?
    public var onTranscript: ((String) -> Void)?
    /// 调试：用这个音频文件代替麦克风（环境变量 VOXPALM_DEBUG_AUDIO_FILE）
    public var debugAudioFile: URL?
    /// 调试：转写结果追加写进这个文件，不贴到前台 App（环境变量 VOXPALM_DEBUG_TRANSCRIPT_FILE）
    public var debugTranscriptFile: URL?

    public private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    private let capture = AudioCapture()
    private let lock = NSLock()
    private var collecting = false
    private var sessionBuffers: [AVAudioPCMBuffer] = []
    private var ring: [AVAudioPCMBuffer] = []
    private var savedDefaultInput: AudioObjectID?
    private var restoreWork: DispatchWorkItem?

    public init(settings: Settings = Settings()) {
        self.settings = settings
        capture.onBuffer = { [weak self] in self?.received($0) }
        if let path = ProcessInfo.processInfo.environment["VOXPALM_DEBUG_AUDIO_FILE"], !path.isEmpty {
            debugAudioFile = URL(fileURLWithPath: path)
        }
        if let path = ProcessInfo.processInfo.environment["VOXPALM_DEBUG_TRANSCRIPT_FILE"], !path.isEmpty {
            debugTranscriptFile = URL(fileURLWithPath: path)
        }
        applyWarm()
    }

    public var micDeviceID: AudioObjectID? {
        settings.micUID.flatMap { AudioDevices.device(uid: $0)?.id }
    }

    // MARK: - VoiceActionHandler

    public var isVoiceActive: Bool { state == .listening || state == .armed }

    public func voiceArm() {
        guard state == .idle else { return }
        switch settings.mode {
        case .builtIn:
            lock.lock()
            sessionBuffers = settings.keepMicWarm ? ring : []
            collecting = true
            lock.unlock()
            startCaptureIfNeeded()
        case .inputMethod:
            switchDefaultInput()
        }
        state = .armed
    }

    public func voiceDisarm() {
        guard state == .armed else { return }
        switch settings.mode {
        case .builtIn:
            lock.lock()
            collecting = false
            sessionBuffers.removeAll()
            lock.unlock()
            stopCaptureUnlessWarm()
        case .inputMethod:
            restoreDefaultInput(after: 0)
        }
        state = .idle
    }

    public func voiceBegin() {
        if state == .idle { voiceArm() }
        guard state == .armed else { return }
        state = .listening
        if settings.mode == .inputMethod {
            guard KeyPoster.canPost else {
                onMessage?("没有辅助功能权限，模拟不了输入法的语音键")
                return
            }
            InputMethodBridge.begin(settings.inputMethodKey)
        }
    }

    public func voiceEnd() {
        guard state == .listening || state == .armed else { return }
        switch settings.mode {
        case .inputMethod:
            if state == .listening { InputMethodBridge.end(settings.inputMethodKey) }
            restoreDefaultInput(after: settings.restoreInputDelay)
            state = .idle
        case .builtIn:
            lock.lock()
            collecting = false
            var buffers = sessionBuffers
            sessionBuffers.removeAll()
            lock.unlock()
            stopCaptureUnlessWarm()
            if let file = debugAudioFile {
                do {
                    buffers = try AudioConversion.read(file)
                } catch {
                    onMessage?("读调试音频失败：\(error.localizedDescription)")
                }
            }
            let seconds = AudioConversion.duration(buffers)
            guard seconds >= settings.minimumSeconds else {
                onMessage?(buffers.isEmpty ? "没录到声音：检查收音设备和麦克风权限" : String(format: "录音太短（%.1f 秒），当成误触", seconds))
                state = .idle
                return
            }
            state = .transcribing
            transcribe(buffers)
        }
    }

    // MARK: - 内置转写

    private func transcribe(_ buffers: [AVAudioPCMBuffer]) {
        let settings = settings
        let started = Date()
        // 主线程上的任务；转写本身是非隔离的异步函数，在后台执行，不卡界面。
        Task { @MainActor [weak self] in
            let result: Result<String, Error>
            do {
                let transcriber = try TranscriberFactory.make(settings.transcriber, whisper: settings.whisper)
                result = .success(try await transcriber.transcribe(buffers, locale: Locale(identifier: settings.localeID)))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            switch result {
            case let .success(text):
                let elapsed = Date().timeIntervalSince(started)
                if text.isEmpty {
                    self.onMessage?("没听出文字")
                } else {
                    if let file = self.debugTranscriptFile {
                        Self.append(text, to: file)
                    } else {
                        TextInserter.insert(text, method: settings.textMethod)
                    }
                    self.onTranscript?(text)
                    self.onMessage?(String(format: "转写用时 %.1f 秒（%.1f 秒录音）", elapsed, AudioConversion.duration(buffers)))
                }
            case let .failure(error):
                self.onMessage?("转写失败：\(error)")
            }
            self.state = .idle
        }
    }

    private static func append(_ text: String, to file: URL) {
        let line = Data((text + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: file)
        }
    }

    private func received(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if collecting {
            sessionBuffers.append(buffer)
        } else if settings.keepMicWarm {
            ring.append(buffer)
            var total = AudioConversion.duration(ring)
            while total > settings.warmSeconds, let first = ring.first {
                total -= Double(first.frameLength) / first.format.sampleRate
                ring.removeFirst()
            }
        }
    }

    private func startCaptureIfNeeded() {
        guard debugAudioFile == nil, !capture.isRunning || capture.deviceID != (micDeviceID ?? AudioDevices.defaultInputID) else { return }
        switch MicrophoneAccess.status {
        case .authorized:
            do {
                try capture.start(deviceID: micDeviceID)
            } catch {
                onMessage?("开麦失败：\(error)")
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.onMessage?(granted ? "已允许麦克风，请再按一次" : "没有麦克风权限：系统设置 → 隐私与安全性 → 麦克风")
                }
            }
        default:
            onMessage?("没有麦克风权限：系统设置 → 隐私与安全性 → 麦克风 → 打开「掌声」")
        }
    }

    private func stopCaptureUnlessWarm() {
        guard !settings.keepMicWarm else { return }
        capture.stop()
    }

    private func settingsChanged(from old: Settings) {
        if old.micUID != settings.micUID, capture.isRunning {
            capture.stop()
        }
        applyWarm()
    }

    private func applyWarm() {
        if settings.keepMicWarm, settings.mode == .builtIn {
            startCaptureIfNeeded()
        } else if state == .idle {
            capture.stop()
            lock.lock()
            ring.removeAll()
            lock.unlock()
        }
    }

    // MARK: - 外部输入法：临时切换系统默认输入

    private func switchDefaultInput() {
        restoreWork?.cancel()
        restoreWork = nil
        guard let target = micDeviceID else { return }
        let current = AudioDevices.defaultInputID
        guard current != target else { return }
        if savedDefaultInput == nil { savedDefaultInput = current }
        if !AudioDevices.setDefaultInput(target) { onMessage?("切换收音设备失败") }
    }

    private func restoreDefaultInput(after delay: Double) {
        guard let saved = savedDefaultInput else { return }
        let work = DispatchWorkItem { [weak self] in
            AudioDevices.setDefaultInput(saved)
            self?.savedDefaultInput = nil
            self?.restoreWork = nil
        }
        restoreWork?.cancel()
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
