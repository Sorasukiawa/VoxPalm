import Accelerate
import AppKit
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
        /// 外部输入法模式下要「说完回车发送」时，松手后等多久再按回车（等输入法把字放进去）
        public var inputMethodSendDelay: Double = 1.5
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
            inputMethodSendDelay = try c.decodeIfPresent(Double.self, forKey: .inputMethodSendDelay) ?? d.inputMethodSendDelay
            keepMicWarm = try c.decodeIfPresent(Bool.self, forKey: .keepMicWarm) ?? d.keepMicWarm
            warmSeconds = try c.decodeIfPresent(Double.self, forKey: .warmSeconds) ?? d.warmSeconds
            textMethod = try c.decodeIfPresent(TextInserter.Method.self, forKey: .textMethod) ?? d.textMethod
            minimumSeconds = try c.decodeIfPresent(Double.self, forKey: .minimumSeconds) ?? d.minimumSeconds
        }
    }

    public var settings: Settings {
        didSet { if settings != oldValue { settingsChanged(from: oldValue) } }
    }
    /// 一次说话的结果，说话浮窗用它显示「已输入 N 字」「按得太短」等。
    public enum Outcome: Equatable, Sendable {
        /// 字贴到了前台 App 的光标处
        case inserted(characters: Int, appName: String?)
        /// 字没贴进去（缺权限、密码框、不在输入框里、说话时换了目标），已经放进剪贴板
        case copied(characters: Int, reason: DeliveryBlock)
        /// 外部输入法模式：已经松开输入法的语音键，由输入法出字
        case handedToInputMethod
        /// 按得太短，没算数（参数是要按住多久）
        case tooShort(threshold: Double)
        /// 一点声音都没录到
        case noAudio
        /// 录到了声音但没听出字
        case noText
        case failed(String)
    }

    public var onStateChange: ((State) -> Void)?
    public var onOutcome: ((Outcome) -> Void)?
    /// 录音时的音量（0…1），大约每秒 20 次，主线程回调
    public var onLevel: ((Float) -> Void)?
    public var onMessage: ((String) -> Void)?
    public var onTranscript: ((String) -> Void)?
    /// 说话时的实时预览：到目前为止转出来的字（还会变，标点不全），主线程回调
    public var onPartial: ((String) -> Void)?
    /// 调试：用这个音频文件代替麦克风（环境变量 VOXPALM_DEBUG_AUDIO_FILE）。按下时按真实时间一段段送，松手时剩下的一次送完。
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
    /// 实时预览（确认开始说话后才开，按得太短的不开）；和 sessionBuffers 一起由 lock 保护
    private var preview: LivePreview?
    private var ring: [AVAudioPCMBuffer] = []
    private var debugQueue: ArraySlice<AVAudioPCMBuffer> = []
    private var debugFed: Double = 0
    private var debugTimer: Timer?
    private var savedDefaultInput: AudioObjectID?
    private var restoreWork: DispatchWorkItem?
    /// 这次说话的附加要求（说完要不要回车发送）
    private var request = VoiceRequest()
    /// 按下说话键那一刻的出字目标：贴字、按回车前拿它比，换了 App 或输入框就不贴、不按
    private var target: TextTarget?

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

    public func voiceArm(_ request: VoiceRequest) {
        guard state == .idle else { return }
        self.request = request
        // 记下按键这一刻的出字目标。挪到下一轮主循环再读：按键可能来自系统按键拦截的回调，在那里等别的 App 回话会拖慢整个键盘。
        target = nil
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.target = TextTarget.current() }
        }
        switch settings.mode {
        case .builtIn:
            lock.lock()
            sessionBuffers = settings.keepMicWarm ? ring : []
            collecting = true
            lock.unlock()
            startCaptureIfNeeded()
            if let file = debugAudioFile { startDebugFeed(file) }
        case .inputMethod:
            switchDefaultInput()
        }
        state = .armed
    }

    public func voiceDisarm(tooShortFor threshold: Double?) {
        guard state == .armed else { return }
        if let threshold { onOutcome?(.tooShort(threshold: threshold)) }
        switch settings.mode {
        case .builtIn:
            stopDebugFeed()
            lock.lock()
            collecting = false
            sessionBuffers.removeAll()
            let preview = preview
            self.preview = nil
            lock.unlock()
            preview?.stop()
            stopCaptureUnlessWarm()
        case .inputMethod:
            restoreDefaultInput(after: 0)
        }
        state = .idle
    }

    public func voiceBegin(_ request: VoiceRequest) {
        if state == .idle { voiceArm(request) }
        guard state == .armed else { return }
        self.request = request
        state = .listening
        if settings.mode == .builtIn { startPreview() }
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
            if state == .listening { onOutcome?(.handedToInputMethod) }
            if request.sendReturn, state == .listening {
                // 输入法什么时候把字放进去不确定，等一会儿；换了目标或输入框还是空的就不发。
                let target = target
                DispatchQueue.main.asyncAfter(deadline: .now() + settings.inputMethodSendDelay) { [weak self] in
                    MainActor.assumeIsolated { self?.onMessage?(TextDelivery.sendReturn(since: target)) }
                }
            }
            state = .idle
        case .builtIn:
            flushDebugFeed()
            lock.lock()
            collecting = false
            let buffers = sessionBuffers
            sessionBuffers.removeAll()
            let preview = preview
            self.preview = nil
            lock.unlock()
            preview?.stop()
            stopCaptureUnlessWarm()
            let seconds = AudioConversion.duration(buffers)
            guard seconds >= settings.minimumSeconds else {
                onMessage?(buffers.isEmpty ? "没录到声音：检查收音设备和麦克风权限" : String(format: "录音太短（%.1f 秒），当成误触", seconds))
                onOutcome?(buffers.isEmpty ? .noAudio : .tooShort(threshold: settings.minimumSeconds))
                state = .idle
                return
            }
            state = .transcribing
            transcribe(buffers, sendReturn: request.sendReturn, target: target)
        }
    }

    // MARK: - 内置转写

    /// 开始说话后开实时预览，先把预录的声音送进去，之后录到的声音在 received 里接着送。
    private func startPreview() {
        let new = TranscriberFactory.makePreview(settings.transcriber, locale: Locale(identifier: settings.localeID)) { [weak self] text in
            DispatchQueue.main.async { self?.onPartial?(text) }
        }
        guard let new else { return }
        lock.lock()
        for buffer in sessionBuffers { new.append(buffer) }
        let old = preview
        preview = new
        lock.unlock()
        old?.stop()
    }

    private func transcribe(_ buffers: [AVAudioPCMBuffer], sendReturn: Bool, target: TextTarget?) {
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
                    self.onOutcome?(.noText)
                } else {
                    if let file = self.debugTranscriptFile {
                        Self.append(sendReturn ? text + "⏎" : text, to: file)
                        // 调试时不贴，只把出字目标检查的结果写进日志：不碰前台 App 也能看这条路。
                        let (block, now) = TextDelivery.checkPaste(since: target)
                        self.onMessage?("调试：出字目标检查 → " + (block.map { "不贴（\($0.pasteMessage)）" } ?? "会贴到「\(now?.appName ?? "前台 App")」"))
                        self.onOutcome?(.inserted(characters: text.count, appName: "调试文件"))
                    } else {
                        switch TextDelivery.insert(text, method: settings.textMethod, since: target) {
                        case let .copied(block):
                            // 贴不进去：字不丢，留在剪贴板里，浮窗告诉用户为什么、怎么补救。
                            self.onOutcome?(.copied(characters: text.count, reason: block))
                        case let .inserted(appName):
                            self.onOutcome?(.inserted(characters: text.count, appName: appName))
                            if sendReturn {
                                // 等粘贴落进输入框，再确认还是按键时那个输入框、里面有字，才按回车。
                                Task { @MainActor [weak self] in
                                    try? await Task.sleep(nanoseconds: 350_000_000)
                                    self?.onMessage?(TextDelivery.sendReturn(since: target))
                                }
                            }
                        }
                    }
                    self.onTranscript?(text)
                    self.onMessage?(String(format: "转写用时 %.1f 秒（%.1f 秒录音）", elapsed, AudioConversion.duration(buffers)))
                }
            case let .failure(error):
                self.onMessage?("转写失败：\(error)")
                self.onOutcome?(.failed("\(error)"))
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

    private var lastLevelTime: CFAbsoluteTime = 0

    /// 算一段声音的音量，换成 0…1（-50 dBFS 以下算 0）。
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let data = buffer.audioBufferList.pointee.mBuffers.mData else { return 0 }
        let count = Int(buffer.audioBufferList.pointee.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        guard count > 0 else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(data.assumingMemoryBound(to: Float.self), 1, &rms, vDSP_Length(count))
        let db = 20 * log10(max(rms, 1e-7))
        return min(1, max(0, (db + 50) / 50))
    }

    private func received(_ buffer: AVAudioPCMBuffer) {
        let now = CFAbsoluteTimeGetCurrent()
        if onLevel != nil, now - lastLevelTime > 0.05 {
            lastLevelTime = now
            let level = Self.level(of: buffer)
            DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
        }
        lock.lock()
        defer { lock.unlock() }
        if collecting {
            sessionBuffers.append(buffer)
            preview?.append(buffer)
        } else if settings.keepMicWarm {
            ring.append(buffer)
            var total = AudioConversion.duration(ring)
            while total > settings.warmSeconds, let first = ring.first {
                total -= Double(first.frameLength) / first.format.sampleRate
                ring.removeFirst()
            }
        }
    }

    // MARK: - 调试音频

    /// 按真实时间一段段送调试音频，和真麦克风一样：音量会跳，实时预览能看到字一点点出来。
    private func startDebugFeed(_ file: URL) {
        stopDebugFeed()
        do {
            debugQueue = try AudioConversion.read(file)[...]
        } catch {
            onMessage?("读调试音频失败：\(error.localizedDescription)")
            return
        }
        let started = Date()
        debugFed = 0
        debugTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            let elapsed = Date().timeIntervalSince(started)
            while self.debugFed <= elapsed, let next = self.debugQueue.popFirst() {
                self.debugFed += Double(next.frameLength) / next.format.sampleRate
                self.received(next)
            }
        }
    }

    /// 松手了：剩下的一次送完（调试时不用按满整段音频那么久）
    private func flushDebugFeed() {
        debugTimer?.invalidate()
        debugTimer = nil
        while let next = debugQueue.popFirst() { received(next) }
    }

    private func stopDebugFeed() {
        debugTimer?.invalidate()
        debugTimer = nil
        debugQueue = []
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
