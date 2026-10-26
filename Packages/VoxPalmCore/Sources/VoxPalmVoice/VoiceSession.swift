import Accelerate
import AppKit
import AVFoundation
import CoreAudio
import Foundation
import os
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
        public var whisper = WhisperSettings()
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
            whisper = try c.decodeIfPresent(WhisperSettings.self, forKey: .whisper) ?? d.whisper
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
    /// 诊断日志：录音用的哪个设备、每半秒的音量（只记数字，不记内容），查「声音录不进来」用
    private let logger = Logger(subsystem: "com.sorasukiawa.VoxPalm", category: "voice")
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
    private var routedDefaultInput: AudioObjectID?
    private var restoreWork: DispatchWorkItem?
    /// 这次说话的附加要求（说完要不要回车发送）
    private var request = VoiceRequest()
    /// 按下说话键那一刻的出字目标：贴字、按回车前拿它比，换了 App 或输入框就不贴、不按
    private var target: TextTarget?
    /// 取消、换设置或开始新一轮后，旧任务即使不响应取消也不能再出字、回车或覆盖新会话。
    private var generation = UUID()
    private var transcriptionTask: Task<Void, Never>?
    private var returnTask: Task<Void, Never>?
    private var warmDuration: Double?

    /// 将系统操作集中在这里，回归测试可以完全使用假件，不开麦、不向前台发键。
    struct Dependencies {
        var currentTarget: @MainActor () -> TextTarget? = { TextTarget.current() }
        var makeTranscriber: (TranscriberChoice, WhisperSettings) throws -> Transcriber = { try TranscriberFactory.make($0, whisper: $1) }
        var makePreview: (TranscriberChoice, Locale, @escaping (String) -> Void) -> LivePreview? = { TranscriberFactory.makePreview($0, locale: $1, onPartial: $2) }
        var canPostInputMethodKey: () -> Bool = { KeyPoster.canPost }
        var beginInputMethod: (InputMethodKey) -> Void = InputMethodBridge.begin
        var endInputMethod: (InputMethodKey) -> Void = InputMethodBridge.end
        var sendReturn: @MainActor (TextTarget?) -> String = { TextDelivery.sendReturn(since: $0) }
        var inputDevices: () -> [AudioDeviceInfo] = AudioDevices.inputs
        var defaultInputID: () -> AudioObjectID = { AudioDevices.defaultInputID }
        var setDefaultInput: (AudioObjectID) -> Bool = AudioDevices.setDefaultInput
    }
    private let dependencies: Dependencies

    public convenience init(settings: Settings = Settings()) {
        self.init(settings: settings, dependencies: Dependencies())
    }

    init(settings: Settings, dependencies: Dependencies) {
        self.settings = settings
        self.dependencies = dependencies
        capture.onBuffer = { [weak self] in self?.received($0) }
        if let path = ProcessInfo.processInfo.environment["VOXPALM_DEBUG_AUDIO_FILE"], !path.isEmpty {
            debugAudioFile = URL(fileURLWithPath: path)
        }
        if let path = ProcessInfo.processInfo.environment["VOXPALM_DEBUG_TRANSCRIPT_FILE"], !path.isEmpty {
            debugTranscriptFile = URL(fileURLWithPath: path)
        }
        applyWarm()
    }

    /// 现在会被控制设备静音的收音设备（音频设备 UID），录音避开它们。App 接上按键引擎。
    public var mutedInputs: () -> Set<String> = { [] }

    /// 这次录音用哪支麦（选的那支被控制设备静音了就换一支，见 MicRouting）
    public func micRoute() -> MicRouting.Route {
        MicRouting.resolve(selectedUID: settings.micUID, inputs: dependencies.inputDevices(), muted: mutedInputs())
    }

    /// 录音用的设备；nil = 系统默认输入
    public var micDeviceID: AudioObjectID? { micRoute().device?.id }

    // MARK: - VoiceActionHandler

    public var isVoiceActive: Bool { state == .listening || state == .armed }
    public var canStartVoice: Bool { state == .idle }

    public func voiceArm(_ request: VoiceRequest) {
        guard state == .idle else { return }
        invalidatePendingWork()
        let generation = generation
        self.request = request
        // 记下按键这一刻的出字目标。挪到下一轮主循环再读：按键可能来自系统按键拦截的回调，在那里等别的 App 回话会拖慢整个键盘。
        target = nil
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation, self.isVoiceActive else { return }
                self.target = self.dependencies.currentTarget()
            }
        }
        switch settings.mode {
        case .builtIn:
            lock.lock()
            sessionBuffers = settings.keepMicWarm ? ring : []
            collecting = true
            lock.unlock()
            guard startCaptureIfNeeded() else {
                lock.lock()
                collecting = false
                sessionBuffers.removeAll()
                ring.removeAll()
                lock.unlock()
                onOutcome?(.failed("没有打开选定的收音设备，请检查连接和麦克风权限"))
                return
            }
            if let file = debugAudioFile { startDebugFeed(file) }
            if TranscriberFactory.usesWhisper(settings.transcriber) { WhisperTranscriber.prepare(settings: settings.whisper) }
        case .inputMethod:
            guard switchDefaultInput() else {
                restoreDefaultInput(after: 0)
                onOutcome?(.failed("无法切换到选定的收音设备，请检查连接"))
                return
            }
        }
        state = .armed
    }

    public func voiceDisarm(tooShortFor threshold: Double?) {
        guard state == .armed else { return }
        invalidatePendingWork()
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
        inputDevicesChanged()
        guard state == .armed else { return }
        self.request = request
        if settings.mode == .inputMethod, !dependencies.canPostInputMethodKey() {
            voiceCancel()
            let message = "没有辅助功能权限，模拟不了输入法的语音键"
            onMessage?(message)
            onOutcome?(.failed(message))
            return
        }
        if settings.mode == .inputMethod, settings.inputMethodKey.key == .custom,
           settings.inputMethodKey.custom == nil || settings.inputMethodKey.style == .hold {
            voiceCancel()
            let message = settings.inputMethodKey.custom == nil
                ? "还没设置输入法的自定义语音快捷键，请先在设置 › 语音中录制"
                : "自定义组合键不支持持续按住，请在设置 › 语音中改用按一下开始、再按一下结束"
            onMessage?(message)
            onOutcome?(.failed(message))
            return
        }
        state = .listening
        if settings.mode == .builtIn { startPreview() }
        if settings.mode == .inputMethod {
            dependencies.beginInputMethod(settings.inputMethodKey)
        }
    }

    public func voiceEnd() {
        guard state == .listening || state == .armed else { return }
        switch settings.mode {
        case .inputMethod:
            if state == .listening { dependencies.endInputMethod(settings.inputMethodKey) }
            restoreDefaultInput(after: settings.restoreInputDelay)
            if state == .listening { onOutcome?(.handedToInputMethod) }
            if request.sendReturn, state == .listening {
                // 输入法什么时候把字放进去不确定，等一会儿；换了目标或输入框还是空的就不发。
                scheduleReturn(since: target, after: settings.inputMethodSendDelay)
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
            logLevels(buffers)
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

    public func voiceCancel() {
        cancel(using: settings)
    }

    /// 音频清单变化时结束丢失手柄麦的录音；松手后已开始的转写继续保留。
    public func inputDevicesChanged() {
        guard debugAudioFile == nil else { return }
        let route = micRoute()
        let missingInput = route.unavailableUID != nil
        var wrongInput = false
        // 分支比较设备编号，避开 Swift 6.3 优化器对可选值短路比较的生命周期错误。
        if settings.mode == .inputMethod, isVoiceActive,
           let selectedUID = settings.micUID, MicRouting.isControllerInput(selectedUID) {
            let currentInput = dependencies.defaultInputID()
            if let device = route.device { wrongInput = device.id != currentInput }
            else { wrongInput = true }
        }
        guard missingInput || wrongInput else { return }
        let wasActive = isVoiceActive
        if wasActive { voiceCancel() }
        capture.stop()
        lock.lock()
        ring.removeAll()
        lock.unlock()
        if wasActive {
            let reason = missingInput ? "手柄麦克风已断开" : "系统收音设备已变化"
            onMessage?("\(reason)，本次说话已取消")
            onOutcome?(.failed("\(reason)，请重新连接或重新按住说话"))
        }
    }

    private func invalidatePendingWork() {
        generation = UUID()
        transcriptionTask?.cancel()
        transcriptionTask = nil
        returnTask?.cancel()
        returnTask = nil
    }

    private func cancel(using activeSettings: Settings) {
        invalidatePendingWork()
        if activeSettings.mode == .inputMethod, state == .listening { dependencies.endInputMethod(activeSettings.inputMethodKey) }
        restoreDefaultInput(after: 0)
        stopDebugFeed()
        lock.lock()
        collecting = false
        sessionBuffers.removeAll()
        let preview = preview
        self.preview = nil
        lock.unlock()
        preview?.stop()
        request = VoiceRequest()
        target = nil
        state = .idle
        if !activeSettings.keepMicWarm || activeSettings.mode != .builtIn { capture.stop() }
    }

    // MARK: - 内置转写

    /// 开始说话后开实时预览，先把预录的声音送进去，之后录到的声音在 received 里接着送。
    private func startPreview() {
        let generation = generation
        let new = dependencies.makePreview(settings.transcriber, Locale(identifier: settings.localeID)) { [weak self] text in
            DispatchQueue.main.async {
                guard let self, self.generation == generation, self.state == .listening else { return }
                self.onPartial?(text)
            }
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
        let generation = generation
        let makeTranscriber = dependencies.makeTranscriber
        let started = Date()
        // 主线程上的任务；转写本身是非隔离的异步函数，在后台执行，不卡界面。
        transcriptionTask = Task { @MainActor [weak self] in
            let result: Result<String, Error>
            do {
                try Task.checkCancellation()
                let transcriber = try makeTranscriber(settings.transcriber, settings.whisper)
                result = .success(try await transcriber.transcribe(buffers, locale: Locale(identifier: settings.localeID)))
            } catch {
                result = .failure(error)
            }
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            self.transcriptionTask = nil
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
                        let (block, now) = TextDelivery.checkPaste(since: target, refocus: false)
                        self.onMessage?("调试：出字目标检查 → " + (block.map { "不贴（\($0.pasteMessage)）" } ?? "会贴到「\(now?.appName ?? "前台 App")」"))
                        self.onOutcome?(.inserted(characters: text.count, appName: "调试文件"))
                    } else {
                        let (result, pasted) = TextDelivery.insert(text, method: settings.textMethod, since: target)
                        switch result {
                        case let .copied(block):
                            // 贴不进去：字不丢，留在剪贴板里，浮窗告诉用户为什么、怎么补救。诊断日志记下当时的目标（不记字）。
                            self.logger.notice("没贴（\(block.pasteMessage, privacy: .public)）：\(pasted?.diagnostics ?? "没读到前台 App", privacy: .public)")
                            self.onOutcome?(.copied(characters: text.count, reason: block))
                        case let .inserted(appName):
                            if let pasted, pasted.refocused { self.logger.notice("贴字：\(pasted.diagnostics, privacy: .public)") }
                            self.onOutcome?(.inserted(characters: text.count, appName: appName))
                            if sendReturn {
                                // 等粘贴落进输入框，再确认还是贴字时那个输入框、里面有字，才按回车。
                                let baseline = pasted ?? target
                                self.scheduleReturn(since: baseline, after: 0.35)
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
            if self.generation == generation { self.state = .idle }
        }
    }

    private func scheduleReturn(since target: TextTarget?, after delay: Double) {
        returnTask?.cancel()
        let generation = generation
        // 配置也能从文件导入，不能让负数、无穷大或过大的延时在转整数时崩溃。
        let seconds = delay.isFinite ? min(60, max(0, delay)) : 1.5
        returnTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            catch { return }
            guard let self, self.generation == generation, self.state == .idle else { return }
            self.returnTask = nil
            self.onMessage?(self.dependencies.sendReturn(target))
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

    /// 收音源的 PCM 入口，在模块内可独立验证预录与会话缓冲，不依赖真实麦克风。
    func received(_ buffer: AVAudioPCMBuffer) {
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
        } else if let warmDuration {
            ring.append(buffer)
            var total = AudioConversion.duration(ring)
            while total > warmDuration, let first = ring.first {
                total -= Double(first.frameLength) / first.format.sampleRate
                ring.removeFirst()
            }
        }
    }

    /// 这次录音每半秒的最大音量（0–99），写进诊断日志：一眼看出声音是从第几秒开始没了。
    private func logLevels(_ buffers: [AVAudioPCMBuffer]) {
        var curve: [Int] = []
        var window = 0.0
        var peak: Float = 0
        for buffer in buffers {
            peak = max(peak, Self.level(of: buffer))
            window += Double(buffer.frameLength) / buffer.format.sampleRate
            if window >= 0.5 {
                curve.append(Int(peak * 99))
                window = 0
                peak = 0
            }
        }
        if window > 0 { curve.append(Int(peak * 99)) }
        logger.notice("录音 \(String(format: "%.1f", AudioConversion.duration(buffers))) 秒，音量每半秒：\(curve.map(String.init).joined(separator: " "), privacy: .public)")
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

    @discardableResult
    private func startCaptureIfNeeded() -> Bool {
        guard debugAudioFile == nil else { return true }
        let route = micRoute()
        guard route.unavailableUID == nil else {
            capture.stop()
            onMessage?("选定的手柄麦克风没连上，请重新连接 USB 或改选收音设备")
            return false
        }
        guard !capture.isRunning || capture.deviceID != (route.device?.id ?? AudioDevices.defaultInputID) else { return true }
        switch MicrophoneAccess.status {
        case .authorized:
            do {
                if let avoided = route.avoided {
                    logger.notice("收音避开 \(avoided.name, privacy: .public)：控制设备接管按键时它会被静音，改用 \(route.device?.name ?? "系统默认输入", privacy: .public)")
                }
                try capture.start(deviceID: route.device?.id)
                let device = capture.deviceID.flatMap { AudioDevices.device(id: $0) }
                logger.notice("开麦 \(device?.name ?? "?", privacy: .public) \(Int(self.capture.format?.sampleRate ?? 0)) Hz \(self.capture.format?.channelCount ?? 0) 声道")
                return true
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
        return false
    }

    private func stopCaptureUnlessWarm() {
        guard !settings.keepMicWarm else { return }
        capture.stop()
    }

    private func settingsChanged(from old: Settings) {
        cancel(using: old)
        if old.micUID != settings.micUID || old.mode != settings.mode {
            capture.stop()
            lock.lock()
            ring.removeAll()
            lock.unlock()
        }
        applyWarm()
    }

    private func applyWarm() {
        lock.lock()
        let seconds = settings.warmSeconds.isFinite ? min(3, max(0, settings.warmSeconds)) : 1
        warmDuration = settings.keepMicWarm && settings.mode == .builtIn ? seconds : nil
        lock.unlock()
        if settings.keepMicWarm, settings.mode == .builtIn {
            if !startCaptureIfNeeded() {
                lock.lock()
                ring.removeAll()
                lock.unlock()
            }
        } else if state == .idle {
            capture.stop()
            lock.lock()
            ring.removeAll()
            lock.unlock()
        }
    }

    // MARK: - 外部输入法：临时切换系统默认输入

    private func switchDefaultInput() -> Bool {
        restoreWork?.cancel()
        restoreWork = nil
        // 跟随系统默认、而默认输入会被控制设备静音时，也临时切到换上的那支
        let route = micRoute()
        guard route.unavailableUID == nil else {
            onMessage?("选定的手柄麦克风没连上，请重新连接 USB 或改选收音设备")
            return false
        }
        guard let target = route.device?.id else { return true }
        if let avoided = route.avoided {
            logger.notice("外部输入法收音避开 \(avoided.name, privacy: .public)，临时切到 \(route.device?.name ?? "?", privacy: .public)")
        }
        let current = dependencies.defaultInputID()
        guard current != target else { return true }
        guard dependencies.setDefaultInput(target) else {
            onMessage?("切换收音设备失败")
            return false
        }
        if savedDefaultInput == nil || routedDefaultInput != current { savedDefaultInput = current }
        routedDefaultInput = target
        return true
    }

    private func restoreDefaultInput(after delay: Double) {
        guard let saved = savedDefaultInput else { return }
        let owned = routedDefaultInput
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let owned, self.dependencies.defaultInputID() == owned { _ = self.dependencies.setDefaultInput(saved) }
            self.savedDefaultInput = nil
            self.routedDefaultInput = nil
            self.restoreWork = nil
        }
        restoreWork?.cancel()
        restoreWork = work
        let seconds = delay.isFinite ? min(60, max(0, delay)) : 1.5
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
