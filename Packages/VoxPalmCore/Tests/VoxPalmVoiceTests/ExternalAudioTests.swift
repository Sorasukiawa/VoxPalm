import AVFoundation
import Foundation
import Testing
import VoxPalmEngine
@testable import VoxPalmVoice

private final class TestAudioInput: ExternalAudioInput {
    var device = ExternalAudioDevice(uid: "external-audio:test", name: "测试麦", detail: "内存假件")
    var starts: [(UUID, (AVAudioPCMBuffer) -> Void, (String) -> Void)] = []
    var stops: [(UUID, (Result<Void, Error>) -> Void)] = []
    func start(sessionID: UUID, onBuffer: @escaping (AVAudioPCMBuffer) -> Void, onFailure: @escaping (String) -> Void) {
        starts.append((sessionID, onBuffer, onFailure))
    }
    func stop(sessionID: UUID, completion: @escaping (Result<Void, Error>) -> Void) { stops.append((sessionID, completion)) }
}
private actor AudioRecorder: Transcriber {
    nonisolated let name = "测试转写"
    var durations: [Double] = []
    func transcribe(_ buffers: [AVAudioPCMBuffer], locale: Locale) async throws -> String {
        durations.append(AudioConversion.duration(buffers))
        return "" // 不执行真实贴字或模拟按键。
    }
}
private func tone(_ seconds: Double) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    let count = AVAudioFrameCount(seconds * 48000)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
    buffer.frameLength = count
    buffer.floatChannelData![0].initialize(repeating: 0.1, count: Int(count))
    return buffer
}
@MainActor private func makeSession(_ input: TestAudioInput?, recorder: AudioRecorder = AudioRecorder(), warm: Bool = false,
                                   mode: VoiceSession.Mode = .builtIn) -> VoiceSession {
    var settings = VoiceSession.Settings()
    settings.micUID = "external-audio:test"; settings.transcriber = .appleSpeech
    settings.keepMicWarm = warm; settings.mode = mode
    var dependencies = VoiceSession.Dependencies()
    dependencies.currentTarget = { nil }
    dependencies.makePreview = { _, _, _ in nil }
    dependencies.makeTranscriber = { _, _ in recorder }
    dependencies.inputDevices = { Issue.record("外部来源不应枚举或回落系统声卡"); return [] }
    dependencies.setDefaultInput = { _ in Issue.record("外部来源不应切换系统默认输入"); return false }
    let session = VoiceSession(settings: settings, dependencies: dependencies, externalInputs: { input.map { [$0] } ?? [] })
    session.debugAudioFile = nil; session.debugTranscriptFile = nil
    return session
}
@MainActor private func settle(_ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(2)
    while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    #expect(condition())
}

@Test @MainActor func 外部来源缺失不回落系统麦() {
    let session = makeSession(nil)
    session.voiceBegin(VoiceRequest())
    #expect(session.state == .idle)
}
@Test @MainActor func 外部来源忽略预热且拒绝外部输入法() {
    let input = TestAudioInput()
    let warm = makeSession(input, warm: true)
    #expect(input.starts.isEmpty)
    warm.voiceBegin(VoiceRequest())
    #expect(input.starts.count == 1)
    warm.voiceCancel()
    let ime = makeSession(input, mode: .inputMethod)
    ime.voiceBegin(VoiceRequest())
    #expect(ime.state == .idle)
    #expect(input.starts.count == 1)
}
@Test @MainActor func 外部录音关麦确认之后才转写() async {
    let input = TestAudioInput(), recorder = AudioRecorder()
    let session = makeSession(input, recorder: recorder)
    session.voiceBegin(VoiceRequest()); input.starts[0].1(tone(1))
    session.voiceEnd()
    #expect(session.state == .transcribing)
    #expect(await recorder.durations.isEmpty)
    #expect(!session.canStartVoice)
    input.stops[0].1(.success(()))
    await settle { session.state == .idle }
    #expect(await recorder.durations == [1])
}
@Test @MainActor func 准备中松手仍撤销且旧声音不能混入下一轮() async {
    let input = TestAudioInput(), recorder = AudioRecorder()
    let session = makeSession(input, recorder: recorder)
    session.voiceArm(VoiceRequest())
    let oldBuffer = input.starts[0].1, oldFailure = input.starts[0].2
    session.voiceDisarm(tooShortFor: 0.3)
    #expect(input.stops.count == 1 && !session.canStartVoice)
    oldBuffer(tone(2))
    input.stops[0].1(.success(()))
    await settle { session.canStartVoice }
    session.voiceBegin(VoiceRequest())
    oldBuffer(tone(2)); oldFailure("迟到错误")
    input.starts[1].1(tone(0.5))
    session.voiceEnd(); input.stops[1].1(.success(()))
    await settle { session.state == .idle }
    #expect(await recorder.durations == [0.5])
}
@Test @MainActor func 外部收音启动失败取消且等资源回收() async {
    let input = TestAudioInput(), recorder = AudioRecorder()
    let session = makeSession(input, recorder: recorder)
    session.voiceBegin(VoiceRequest()); input.starts[0].2("连接失败")
    await settle { !input.stops.isEmpty }
    #expect(session.state == .idle && !session.canStartVoice)
    input.starts[0].1(tone(1)); input.stops[0].1(.success(()))
    await settle { session.canStartVoice }
    #expect(await recorder.durations.isEmpty)
}
@Test @MainActor func 松手后关麦失败不转写() async {
    let input = TestAudioInput(), recorder = AudioRecorder()
    let session = makeSession(input, recorder: recorder)
    session.voiceBegin(VoiceRequest()); input.starts[0].1(tone(1)); session.voiceEnd()
    input.stops[0].1(.failure(NSError(domain: "测试", code: 1)))
    await settle { session.state == .idle }
    #expect(await recorder.durations.isEmpty)
}
@Test @MainActor func 停止期间取消阻止迟到完成投递() async {
    let input = TestAudioInput(), recorder = AudioRecorder()
    let session = makeSession(input, recorder: recorder)
    session.voiceBegin(VoiceRequest()); input.starts[0].1(tone(1)); session.voiceEnd()
    session.voiceCancel()
    input.stops[0].1(.success(()))
    await settle { session.canStartVoice }
    #expect(await recorder.durations.isEmpty)
}
@Test @MainActor func 收音断线或停止中断线都取消() async {
    for afterRelease in [false, true] {
        let input = TestAudioInput(), recorder = AudioRecorder()
        let session = makeSession(input, recorder: recorder)
        session.voiceBegin(VoiceRequest()); input.starts[0].1(tone(1))
        if afterRelease { session.voiceEnd() }
        input.device = ExternalAudioDevice(uid: input.device.uid, name: "测试麦", detail: "", problem: "断开")
        session.inputDevicesChanged()
        #expect(session.state == .idle)
        input.stops[0].1(.success(()))
        await settle { session.canStartVoice }
        #expect(await recorder.durations.isEmpty)
    }
}
