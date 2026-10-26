import AVFoundation
import Foundation
import Testing
import CoreAudio
@testable import VoxPalmDevices
import VoxPalmEngine
@testable import VoxPalmVoice

@Test func whisper按语言给开头提示() {
    #expect(WhisperTranscriber.decoding(for: Locale(identifier: "zh-CN"), knowsCantonese: true) == ("zh", "以下是普通话的句子。"))
    #expect(WhisperTranscriber.decoding(for: Locale(identifier: "zh-TW"), knowsCantonese: true) == ("zh", "以下是國語的句子。"))
    #expect(WhisperTranscriber.decoding(for: Locale(identifier: "yue-CN"), knowsCantonese: true).language == "yue")
    #expect(WhisperTranscriber.decoding(for: Locale(identifier: "yue-CN"), knowsCantonese: false).language == "zh")
    #expect(WhisperTranscriber.decoding(for: Locale(identifier: "en-US"), knowsCantonese: true) == ("en", nil))
}

@Test func whisper模型清单() {
    #expect(Set(WhisperModel.catalog.map(\.id)).count == WhisperModel.catalog.count)
    #expect(WhisperModel.catalog.contains(WhisperModel.recommended))
    for model in WhisperModel.catalog {
        #expect(model.sha256.count == 64 && model.sha256.allSatisfy(\.isHexDigit))
        #expect(model.sources.map(\.host) == ["huggingface.co", "hf-mirror.com"])
        #expect(model.sources.allSatisfy { $0.lastPathComponent == "ggml-\(model.id).bin" })
    }
}

@Test func whisper设置读旧配置() throws {
    // 旧版存的是 whisper-cli 的路径和自己选的模型文件：文件接着用，没选过的用推荐模型
    let old = try JSONDecoder().decode(WhisperSettings.self, from: Data(#"{"executablePath":"/opt/homebrew/bin/whisper-cli","modelPath":"/m/ggml-small.bin"}"#.utf8))
    #expect(old.usesCustomFile && old.modelPath == "/m/ggml-small.bin")
    let empty = try JSONDecoder().decode(WhisperSettings.self, from: Data("{}".utf8))
    #expect(empty.modelID == WhisperModel.recommended.id && empty.modelPath == nil)
    let unknown = WhisperSettings(modelID: "以后删掉的模型")
    #expect(unknown.model == WhisperModel.recommended)
}

@Test func whisper没下载或没选文件会报错() throws {
    let saved = WhisperModel.directory
    defer { WhisperModel.directory = saved }
    WhisperModel.directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxpalm-models-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: WhisperModel.directory) }
    #expect(throws: TranscriberError.self) { _ = try WhisperTranscriber(settings: WhisperSettings(modelID: WhisperSettings.customID)) }
    #expect(throws: TranscriberError.self) { _ = try WhisperTranscriber(settings: WhisperSettings(modelID: WhisperSettings.customID, modelPath: "/nope.bin")) }
    #expect(throws: TranscriberError.self) { _ = try WhisperTranscriber(settings: WhisperSettings()) }
    // 模型目录里有了就算下好了
    try FileManager.default.createDirectory(at: WhisperModel.directory, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: WhisperModel.recommended.fileURL.path, contents: Data())
    #expect(WhisperModel.recommended.isDownloaded)
    #expect(try WhisperSettings().resolvedModelURL() == WhisperModel.recommended.fileURL)
}

@Test func 内置的whisper库能用() async throws {
    #expect(!WhisperTranscriber.version.isEmpty)
    // 坏模型文件：读不进来要报错，不能崩
    let bad = FileManager.default.temporaryDirectory.appendingPathComponent("voxpalm-bad-\(UUID().uuidString).bin")
    try Data("不是模型".utf8).write(to: bad)
    defer { try? FileManager.default.removeItem(at: bad) }
    let transcriber = try WhisperTranscriber(settings: WhisperSettings(modelID: WhisperSettings.customID, modelPath: bad.path))
    await #expect(throws: TranscriberError.self) {
        _ = try await transcriber.transcribe([sine(seconds: 1, rate: 16_000, channels: 1)], locale: Locale(identifier: "zh-CN"))
    }
}

@Test func 下载的模型按SHA256核对() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("voxpalm-sha-\(UUID().uuidString)")
    try Data("abc".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(try WhisperDownload.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    let right = WhisperModel(id: "t", title: "t", summary: "", bytes: 3, sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    let wrongSize = WhisperModel(id: "t", title: "t", summary: "", bytes: 4, sha256: right.sha256)
    let wrongHash = WhisperModel(id: "t", title: "t", summary: "", bytes: 3, sha256: String(repeating: "0", count: 64))
    #expect(try WhisperDownload.matches(file, right))
    #expect(try !WhisperDownload.matches(file, wrongSize))
    #expect(try !WhisperDownload.matches(file, wrongHash))
}

@Test func 模型落盘失败保留原文件() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxpalm-install-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("model.bin")
    try Data("旧模型".utf8).write(to: destination)
    #expect(throws: NSError.self) {
        try WhisperDownload.installVerifiedFile(directory.appendingPathComponent("不存在"), to: destination)
    }
    #expect(try Data(contentsOf: destination) == Data("旧模型".utf8))
    let replacement = directory.appendingPathComponent("replacement.bin")
    try Data("新模型".utf8).write(to: replacement)
    try WhisperDownload.installVerifiedFile(replacement, to: destination)
    #expect(try Data(contentsOf: destination) == Data("新模型".utf8))
    #expect(!FileManager.default.fileExists(atPath: replacement.path))
}

@Test func 模型下载取消或校验失败不覆盖旧模型() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxpalm-download-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = WhisperModel(id: "test", title: "测试", summary: "", bytes: 3,
                             sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    let destination = directory.appendingPathComponent(model.fileName)
    try Data("旧模型".utf8).write(to: destination)
    await #expect(throws: WhisperDownload.Failure.self) {
        try await WhisperDownload.run(model, directory: directory, fetch: { _, partial, _ in
            try Data("错误文件".utf8).write(to: partial)
        }, progress: { _ in })
    }
    #expect(try Data(contentsOf: destination) == Data("旧模型".utf8))
    for cancelDuringVerification in [false, true] {
        let cancelled = Task {
            try await WhisperDownload.run(model, directory: directory, fetch: { _, partial, _ in
                try Data("abc".utf8).write(to: partial)
                if !cancelDuringVerification { withUnsafeCurrentTask { $0?.cancel() } }
            }, progress: { progress in
                if cancelDuringVerification, progress == .verifying { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try Data(contentsOf: destination) == Data("旧模型".utf8))
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [model.fileName])
    let downloaded = try await WhisperDownload.run(model, directory: directory, fetch: { _, partial, _ in
        try Data("abc".utf8).write(to: partial)
    }, progress: { _ in })
    #expect(downloaded == destination)
    #expect(try Data(contentsOf: downloaded) == Data("abc".utf8))
}

private actor DeferredTranscriber: Transcriber {
    nonisolated var name: String { "测试转写" }
    private var continuation: CheckedContinuation<String, Error>?
    private var started: CheckedContinuation<Void, Never>?

    func transcribe(_ buffers: [AVAudioPCMBuffer], locale: Locale) async throws -> String {
        try await withCheckedThrowingContinuation {
            continuation = $0
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish() {
        continuation?.resume(returning: "")
        continuation = nil
    }
}

@Test(arguments: [false, true]) @MainActor func 取消或换设置后晚结果不改变新会话(_ changeSettings: Bool) async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("voxpalm-session-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: file) }
    let audio = sine(seconds: 0.4, rate: 16_000, channels: 1)
    try AVAudioFile(forWriting: file, settings: audio.format.settings).write(from: audio)
    let transcriber = DeferredTranscriber()
    var dependencies = VoiceSession.Dependencies()
    dependencies.currentTarget = { nil }
    dependencies.makeTranscriber = { _, _ in transcriber }
    dependencies.makePreview = { _, _, _ in nil }
    var settings = VoiceSession.Settings()
    settings.transcriber = .appleSpeech
    let session = VoiceSession(settings: settings, dependencies: dependencies)
    session.debugAudioFile = file
    var outcomes: [VoiceSession.Outcome] = []
    session.onOutcome = { outcomes.append($0) }
    session.voiceBegin(VoiceRequest())
    session.voiceEnd()
    #expect(session.state == .transcribing)
    #expect(!session.isVoiceActive && !session.canStartVoice)
    await transcriber.waitUntilStarted()
    if changeSettings { session.settings.localeID = "en-US" }
    else { session.voiceCancel() }
    #expect(session.state == .idle)
    #expect(session.canStartVoice)
    session.voiceArm(VoiceRequest())
    await transcriber.finish()
    // 给旧转写的主线程收尾机会；它必须保留新一轮 armed 状态，也不能发出旧结果。
    try await Task.sleep(nanoseconds: 20_000_000)
    #expect(session.state == .armed)
    #expect(outcomes.isEmpty)
    session.voiceCancel()
}

@Test @MainActor func 切换语音配置会松开旧输入法键并取消延迟回车() async throws {
    var settings = VoiceSession.Settings()
    settings.mode = .inputMethod
    settings.inputMethodSendDelay = 0.01
    let oldKey = settings.inputMethodKey
    var began: [InputMethodKey] = []
    var ended: [InputMethodKey] = []
    var returned = 0
    var dependencies = VoiceSession.Dependencies()
    dependencies.currentTarget = { nil }
    dependencies.canPostInputMethodKey = { true }
    dependencies.beginInputMethod = { began.append($0) }
    dependencies.endInputMethod = { ended.append($0) }
    dependencies.sendReturn = { _ in returned += 1; return "测试回车" }
    let session = VoiceSession(settings: settings, dependencies: dependencies)
    session.voiceBegin(VoiceRequest())
    session.settings.mode = .builtIn
    #expect(session.state == .idle)
    #expect(began == [oldKey] && ended == [oldKey])

    session.settings.mode = .inputMethod
    var request = VoiceRequest()
    request.sendReturn = true
    session.voiceBegin(request)
    session.voiceEnd()
    session.voiceCancel()
    try await Task.sleep(nanoseconds: 30_000_000)
    #expect(returned == 0)
}

@Test @MainActor func 没有发键权限不会报告交给输入法成功() {
    var settings = VoiceSession.Settings()
    settings.mode = .inputMethod
    var dependencies = VoiceSession.Dependencies()
    dependencies.currentTarget = { nil }
    dependencies.canPostInputMethodKey = { false }
    var keyEvents = 0
    dependencies.beginInputMethod = { _ in keyEvents += 1 }
    dependencies.endInputMethod = { _ in keyEvents += 1 }
    let session = VoiceSession(settings: settings, dependencies: dependencies)
    var outcomes: [VoiceSession.Outcome] = []
    session.onOutcome = { outcomes.append($0) }
    session.voiceBegin(VoiceRequest())
    session.voiceEnd()
    #expect(session.state == .idle && keyEvents == 0)
    #expect(outcomes.count == 1)
    #expect(!outcomes.contains(.handedToInputMethod))
}

@Test(arguments: [false, true]) @MainActor func 无效自定义输入法快捷键不会报告成功(_ usesHold: Bool) {
    var settings = VoiceSession.Settings()
    settings.mode = .inputMethod
    settings.inputMethodKey = InputMethodKey(key: .custom, style: .tap)
    if usesHold {
        settings.inputMethodKey.style = .hold
        settings.inputMethodKey.custom = .init(keyCode: 49, modifiers: 1 << 19, display: "⌥Space")
    }
    var dependencies = VoiceSession.Dependencies()
    dependencies.currentTarget = { nil }
    dependencies.canPostInputMethodKey = { true }
    var keyEvents = 0
    dependencies.beginInputMethod = { _ in keyEvents += 1 }
    dependencies.endInputMethod = { _ in keyEvents += 1 }
    let session = VoiceSession(settings: settings, dependencies: dependencies)
    var outcomes: [VoiceSession.Outcome] = []
    session.onOutcome = { outcomes.append($0) }
    session.voiceBegin(VoiceRequest())
    session.voiceEnd()
    #expect(session.state == .idle && keyEvents == 0)
    #expect(outcomes.count == 1)
    guard let outcome = outcomes.first else { return }
    if case .failed = outcome {} else { Issue.record("缺少快捷键或使用不支持的按法时应明确报告失败") }
}

@Test @MainActor func 待回车时允许新说话并取消旧回车() async throws {
    var settings = VoiceSession.Settings()
    settings.mode = .inputMethod
    settings.inputMethodSendDelay = 0.01
    var returned = 0
    var dependencies = VoiceSession.Dependencies()
    dependencies.currentTarget = { nil }
    dependencies.canPostInputMethodKey = { true }
    dependencies.beginInputMethod = { _ in }
    dependencies.endInputMethod = { _ in }
    dependencies.sendReturn = { _ in returned += 1; return "测试回车" }
    let session = VoiceSession(settings: settings, dependencies: dependencies)
    session.voiceBegin(VoiceRequest(sendReturn: true))
    session.voiceEnd()
    #expect(session.canStartVoice && !session.isVoiceActive)
    session.voiceBegin(VoiceRequest())
    #expect(session.isVoiceActive)
    try await Task.sleep(nanoseconds: 30_000_000)
    #expect(returned == 0)
    session.voiceCancel()
}

/// 真模型端到端：设了 VOXPALM_TEST_WHISPER_MODEL（ggml 模型文件）才跑，用 say 合成一句中文转回来。
@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXPALM_TEST_WHISPER_MODEL"] != nil))
func whisper真模型转中文() async throws {
    let model = ProcessInfo.processInfo.environment["VOXPALM_TEST_WHISPER_MODEL"]!
    let audio = FileManager.default.temporaryDirectory.appendingPathComponent("voxpalm-say-\(UUID().uuidString).aiff")
    defer { try? FileManager.default.removeItem(at: audio) }
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-v", "Tingting", "-o", audio.path, "今天天气很好，我们去公园散步吧。"]
    try say.run()
    say.waitUntilExit()
    let transcriber = try WhisperTranscriber(settings: WhisperSettings(modelID: WhisperSettings.customID, modelPath: model))
    let text = try await transcriber.transcribe(try AudioConversion.read(audio), locale: Locale(identifier: "zh-CN"))
    #expect(text.contains("公园"))
    #expect(!text.contains(","))
}

private func sine(seconds: Double, rate: Double, channels: AVAudioChannelCount) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
    let frames = AVAudioFrameCount(seconds * rate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for c in 0..<Int(channels) {
        for i in 0..<Int(frames) { buffer.floatChannelData![c][i] = sin(Float(i) * 2 * .pi * 440 / Float(rate)) * 0.3 }
    }
    return buffer
}

@Test func 转成16k单声道时长不变() throws {
    let buffers = [sine(seconds: 0.5, rate: 48_000, channels: 2), sine(seconds: 0.5, rate: 48_000, channels: 2)]
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let converted = try AudioConversion.convert(buffers, to: target)
    #expect(abs(AudioConversion.duration(converted) - 1.0) < 0.02)
    #expect(converted.first?.format.sampleRate == 16_000)
}

@Test func 边录边转格式时长不变() throws {
    // 麦克风每次只给十几毫秒，一段段送进同一个转换器，最后倒干净，总时长要和整段转一样
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let converter = try AudioConversion.StreamConverter(from: sine(seconds: 0.01, rate: 48_000, channels: 2).format, to: target)
    var converted: [AVAudioPCMBuffer] = []
    for _ in 0..<100 { converted += try converter.convert(sine(seconds: 0.01, rate: 48_000, channels: 2)) }
    converted += try converter.flush()
    #expect(abs(AudioConversion.duration(converted) - 1.0) < 0.02)
    #expect(converted.allSatisfy { $0.format.sampleRate == 16_000 })
    // 格式一样就原样交出去
    let same = try AudioConversion.StreamConverter(from: target, to: target)
    let piece = sine(seconds: 0.1, rate: 16_000, channels: 1)
    #expect(try same.convert(piece).first === piece)
}

@Test func 转成whisper用的样本() throws {
    let samples = try AudioConversion.whisperSamples([sine(seconds: 1, rate: 44_100, channels: 2)])
    #expect(abs(samples.count - 16_000) < 320)
    #expect(samples.contains { abs($0) > 0.1 })
    // 不到 1 秒的补静音，whisper.cpp 才肯转
    #expect(WhisperTranscriber.padded([Float](repeating: 0.2, count: 8_000)).count == 17_600)
    #expect(WhisperTranscriber.padded(samples + samples).count == samples.count * 2)
}

@Test func whisper中文的半角标点换成全角() {
    #expect(TranscriptCleaner.widenChinesePunctuation("下午三点的会改到四点,地点不变,对吗?") == "下午三点的会改到四点，地点不变，对吗？")
    #expect(TranscriptCleaner.widenChinesePunctuation("用 Claude, 版本 1.5, 好的") == "用 Claude, 版本 1.5, 好的")
    #expect(TranscriptCleaner.widenChinesePunctuation("好的。,") == "好的。,")
}

@Test func 中文转写去掉多余空格() {
    #expect(TranscriptCleaner.clean("你好 ，这是掌声的语音测试 ，按住说话") == "你好，这是掌声的语音测试，按住说话")
    #expect(TranscriptCleaner.clean("用 Claude Code 写代码") == "用 Claude Code 写代码")
    #expect(TranscriptCleaner.clean("按住 说话") == "按住说话")
    #expect(TranscriptCleaner.clean("hello world") == "hello world")
    #expect(TranscriptCleaner.clean("吃个晚饭 ，顺便聊聊下个月的计划。。") == "吃个晚饭，顺便聊聊下个月的计划。")
    #expect(TranscriptCleaner.clean("二〇〇六年") == "二〇〇六年")
}

private func mic(_ id: AudioObjectID, _ uid: String, _ transport: String, isDefault: Bool = false) -> AudioDeviceInfo {
    AudioDeviceInfo(id: id, uid: uid, name: uid, manufacturer: nil, transport: transport, inputChannels: 1, outputChannels: 0,
                    nominalSampleRate: 16_000, availableSampleRates: [], inputStreamFormat: nil, isDefaultInput: isDefault,
                    isDefaultOutput: false, isDefaultSystemOutput: false, isRunningSomewhere: false)
}

@Test func 收音会被静音时改用Mac麦() {
    let dji = mic(1, "DJI", "Bluetooth", isDefault: true)
    let airpods = mic(2, "AirPods", "Bluetooth")
    let builtIn = mic(3, "BuiltIn", "Built-in")
    let virtual = mic(4, "Virtual", "Virtual")
    // 没有要避开的：跟随系统默认还是交给系统，选了就用选的
    #expect(MicRouting.resolve(selectedUID: nil, inputs: [dji, builtIn], muted: []) == .init(device: nil, avoided: nil))
    #expect(MicRouting.resolve(selectedUID: "AirPods", inputs: [dji, airpods], muted: ["DJI"]) == .init(device: airpods, avoided: nil))
    // 选的就是会静音的那支、或者跟随系统默认而默认正好是它：先换 Mac 自带的麦
    #expect(MicRouting.resolve(selectedUID: "DJI", inputs: [dji, airpods, builtIn], muted: ["DJI"]) == .init(device: builtIn, avoided: dji))
    #expect(MicRouting.resolve(selectedUID: nil, inputs: [dji, airpods, builtIn], muted: ["DJI"]) == .init(device: builtIn, avoided: dji))
    // 选的麦没连上、录音会落到默认输入上：一样要避开
    #expect(MicRouting.resolve(selectedUID: "USB", inputs: [dji, builtIn], muted: ["DJI"]) == .init(device: builtIn, avoided: dji))
    // 没有 Mac 自带的麦（合盖接外接显示器）：换下一个能用的，不用虚拟声卡
    #expect(MicRouting.resolve(selectedUID: nil, inputs: [virtual, dji, airpods], muted: ["DJI"]) == .init(device: airpods, avoided: dji))
    #expect(MicRouting.resolve(selectedUID: nil, inputs: [dji, virtual], muted: ["DJI"]) == .init(device: nil, avoided: dji))
}

@Test func 手柄麦克风掉线不能回退成Mac麦但重连后仍可选择() {
    let uid = "AppleUSBAudioEngine:Sony Interactive Entertainment:DualSense Edge Wireless Controller:test-port:2"
    let builtIn = mic(1, "Mac", "Built-in", isDefault: true)
    let controller = mic(2, uid, "USB")
    #expect(MicRouting.resolve(selectedUID: uid, inputs: [builtIn], muted: []) ==
            .init(device: nil, avoided: nil, unavailableUID: uid))
    #expect(MicRouting.resolve(selectedUID: uid, inputs: [builtIn, controller], muted: []) ==
            .init(device: controller, avoided: nil))
    // 普通麦克风继续遵循已有的系统默认回退，不扩大本次行为改动。
    #expect(MicRouting.resolve(selectedUID: "missing-usb-mic", inputs: [builtIn], muted: []) ==
            .init(device: nil, avoided: nil))
}

@Test(arguments: [VoiceSession.Mode.builtIn, .inputMethod]) @MainActor
func 手柄麦缺失时不进入正在听也不触发外部输入法(_ mode: VoiceSession.Mode) {
    var settings = VoiceSession.Settings()
    settings.mode = mode
    settings.micUID = "AppleUSBAudioEngine:Sony Interactive Entertainment:DualSense Edge Wireless Controller:missing-test-port:2"
    var keyBegins = 0
    var dependencies = VoiceSession.Dependencies()
    dependencies.currentTarget = { nil }
    dependencies.canPostInputMethodKey = { true }
    dependencies.beginInputMethod = { _ in keyBegins += 1 }
    let session = VoiceSession(settings: settings, dependencies: dependencies)
    session.debugAudioFile = nil
    var states: [VoiceSession.State] = []
    var failures = 0
    session.onStateChange = { states.append($0) }
    session.onOutcome = { if case .failed = $0 { failures += 1 } }
    session.voiceArm(VoiceRequest())
    session.voiceBegin(VoiceRequest())
    #expect(session.state == .idle)
    #expect(states.isEmpty)
    #expect(keyBegins == 0)
    #expect(failures == 2)
}

@Test(arguments: [false, true]) @MainActor
func 手柄麦在预备后或说话中断开会取消并还原默认输入(_ afterBegin: Bool) async throws {
    let uid = "AppleUSBAudioEngine:Sony Interactive Entertainment:DualSense Edge Wireless Controller:test-port:2"
    let builtIn = mic(1, "Mac", "Built-in", isDefault: true)
    var inputs = [builtIn, mic(2, uid, "USB")]
    var currentInput: AudioObjectID = 1
    var writes: [AudioObjectID] = []
    var begins = 0, ends = 0
    var restored: (() -> Void)?
    var dependencies = VoiceSession.Dependencies()
    dependencies.currentTarget = { nil }
    dependencies.inputDevices = { inputs }
    dependencies.defaultInputID = { currentInput }
    dependencies.setDefaultInput = {
        currentInput = $0; writes.append($0)
        if $0 == 1 { let complete = restored; restored = nil; complete?() }
        return true
    }
    dependencies.canPostInputMethodKey = { true }
    dependencies.beginInputMethod = { _ in begins += 1 }
    dependencies.endInputMethod = { _ in ends += 1 }
    var settings = VoiceSession.Settings()
    settings.mode = .inputMethod
    settings.micUID = uid
    let session = VoiceSession(settings: settings, dependencies: dependencies)
    session.debugAudioFile = nil
    session.voiceArm(VoiceRequest())
    #expect(session.state == .armed)
    #expect(currentInput == 2)
    if afterBegin { session.voiceBegin(VoiceRequest()) }
    inputs = [builtIn]
    await withCheckedContinuation { continuation in
        restored = { continuation.resume() }
        if afterBegin { session.inputDevicesChanged() }
        else { session.voiceBegin(VoiceRequest()) }
    }
    #expect(session.state == .idle)
    #expect(begins == (afterBegin ? 1 : 0))
    #expect(ends == (afterBegin ? 1 : 0))
    #expect(currentInput == 1)
    #expect(writes == [2, 1])
}

@Test @MainActor func 预热手柄麦失败后不能把旧预录带入下一轮() async throws {
    actor RecordingTranscriber: Transcriber {
        nonisolated let name = "测试转写"
        var durations: [Double] = []
        func transcribe(_ buffers: [AVAudioPCMBuffer], locale: Locale) async throws -> String {
            durations.append(AudioConversion.duration(buffers))
            return ""
        }
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxpalm-warm-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let empty = directory.appendingPathComponent("empty.wav")
    let audio = sine(seconds: 0.4, rate: 16_000, channels: 1)
    do { _ = try AVAudioFile(forWriting: empty, settings: audio.format.settings) }
    let transcriber = RecordingTranscriber()
    var dependencies = VoiceSession.Dependencies()
    dependencies.currentTarget = { nil }
    dependencies.inputDevices = { [] }
    dependencies.makeTranscriber = { _, _ in transcriber }
    dependencies.makePreview = { _, _, _ in nil }
    var settings = VoiceSession.Settings()
    settings.micUID = "AppleUSBAudioEngine:Sony Interactive Entertainment:DualSense Edge Wireless Controller:missing-test-port:2"
    let session = VoiceSession(settings: settings, dependencies: dependencies)
    session.debugAudioFile = empty
    session.settings.keepMicWarm = true
    session.received(audio) // idle 预热阶段喂入，真正进入 ring 而非 sessionBuffers。
    await withCheckedContinuation { continuation in
        session.onStateChange = { state in
            if state == .idle { session.onStateChange = nil; continuation.resume() }
        }
        session.voiceBegin(VoiceRequest())
        session.voiceEnd()
    }
    #expect(session.state == .idle)
    let before = await transcriber.durations
    #expect(before.count == 1)
    #expect(abs((before.first ?? 0) - 0.4) < 0.001) // 先证明旧预录确实存在并可被下一轮收取。
    session.debugAudioFile = nil
    session.settings.localeID = "en-US" // 同一个 UID 的预热开麦失败。
    session.debugAudioFile = empty
    var last: VoiceSession.Outcome?
    session.onOutcome = { last = $0 }
    session.voiceBegin(VoiceRequest())
    session.voiceEnd()
    #expect(last == .noAudio)
    #expect(session.state == .idle)
    #expect(await transcriber.durations.count == 1)
    session.voiceCancel()
}

@Test(arguments: [false, true]) @MainActor
func 手柄仍在线但输入法默认麦被外部改变时取消且不覆盖外部选择(_ afterBegin: Bool) async throws {
    let uid = "AppleUSBAudioEngine:Sony Interactive Entertainment:DualSense Edge Wireless Controller:test-port:2"
    var currentInput: AudioObjectID = 1
    var writes: [AudioObjectID] = []
    var begins = 0, ends = 0
    var restorationChecked: (() -> Void)?
    func completeRestorationCheck() {
        let complete = restorationChecked
        restorationChecked = nil
        complete?()
    }
    var dependencies = VoiceSession.Dependencies()
    dependencies.currentTarget = { nil }
    dependencies.inputDevices = { [mic(1, "Mac", "Built-in"), mic(2, uid, "USB"), mic(3, "Other", "USB")] }
    dependencies.defaultInputID = { completeRestorationCheck(); return currentInput }
    dependencies.setDefaultInput = {
        currentInput = $0; writes.append($0)
        if $0 == 1 { completeRestorationCheck() }
        return true
    }
    dependencies.canPostInputMethodKey = { true }
    dependencies.beginInputMethod = { _ in begins += 1 }
    dependencies.endInputMethod = { _ in ends += 1 }
    var settings = VoiceSession.Settings()
    settings.mode = .inputMethod
    settings.micUID = uid
    let session = VoiceSession(settings: settings, dependencies: dependencies)
    session.debugAudioFile = nil
    session.voiceArm(VoiceRequest())
    if afterBegin { session.voiceBegin(VoiceRequest()) }
    currentInput = 3 // 用户或系统改了默认输入，DSE 仍在清单中。
    if afterBegin { session.inputDevicesChanged() }
    else { session.voiceBegin(VoiceRequest()) }
    #expect(session.state == .idle)
    #expect(begins == (afterBegin ? 1 : 0))
    #expect(ends == (afterBegin ? 1 : 0))
    await withCheckedContinuation { continuation in restorationChecked = { continuation.resume() } }
    #expect(currentInput == 3)
    #expect(writes == [2])
}

@Test func 左右Option分开发键() throws {
    // 输入法里录成左 Option 的语音键只认左边，键码和区分左右的设备位都要对
    let left = try #require(InputMethodKey.Key.leftOption.modifier)
    #expect(left.keyCode == 58)
    #expect(left.flags == CGEventFlags.maskAlternate.rawValue | 0x20)
    let right = try #require(InputMethodKey.Key.rightOption.modifier)
    #expect(right.keyCode == 61)
    #expect(right.flags == CGEventFlags.maskAlternate.rawValue | 0x40)
    let decoded = try JSONDecoder().decode(InputMethodKey.self, from: Data(#"{"key":"leftOption","style":"tap"}"#.utf8))
    #expect(decoded.key == .leftOption && decoded.style == .tap)
}

@Test func 认得不跟着切麦的输入法() {
    #expect(InputMethodMic.name(ignoringDefaultInput: "com.tencent.inputmethod.wetype.pinyin") == "微信输入法")
    #expect(InputMethodMic.name(ignoringDefaultInput: "com.bytedance.inputmethod.doubaoime.pinyin") == nil)
    #expect(InputMethodMic.name(ignoringDefaultInput: "com.apple.inputmethod.SCIM.ITABC") == nil)
}
