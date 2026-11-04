import AVFoundation
import Foundation
import Testing
import VoxPalmEngine
@testable import VoxPalmVoice

@MainActor private final class RemoteTranscriber: Transcriber {
    let name = "合成转写"
    var samples: [Float] = []
    var waiting = false
    var continuation: CheckedContinuation<String, Never>?
    func transcribe(_ buffers: [AVAudioPCMBuffer], locale: Locale) async throws -> String {
        samples = buffers.flatMap { buffer in Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))) }
        if waiting { return await withCheckedContinuation { continuation = $0 } }
        return "合成测试文字"
    }
}
@MainActor private final class RemoteFixture {
    let transcriber = RemoteTranscriber()
    var inserted: [String] = []
    var returns = 0, deviceReads = 0
    var session: VoiceSession!
    init(limits: VoiceLimits = VoiceLimits()) {
        var settings = VoiceSession.Settings(); settings.minimumSeconds = 0.01; settings.transcriber = .appleSpeech
        var dependencies = VoiceSession.Dependencies(); dependencies.limits = limits
        dependencies.currentTarget = { nil }
        dependencies.makeTranscriber = { [transcriber] _, _ in transcriber }
        dependencies.makePreview = { _, _, _ in nil }
        dependencies.prepareDelivery = { _ in }
        dependencies.inputDevices = { [weak self] in self?.deviceReads += 1; return [] }
        dependencies.insertText = { [weak self] text, _, _ in self?.inserted.append(text); return (.inserted(appName: "假窗口"), nil) }
        dependencies.sendReturn = { [weak self] _ in self?.returns += 1; return "假回车" }
        session = VoiceSession(settings: settings, dependencies: dependencies)
        session.debugAudioFile = nil; session.debugTranscriptFile = nil
    }
}
@MainActor private func eventually(_ condition: () -> Bool) async throws {
    while !condition() { try await Task.sleep(for: .milliseconds(5)) }
}

@Test(.timeLimit(.minutes(1))) @MainActor func 手机PCM直接转写保持符号且不读本机麦或自动回车() async throws {
    let f = RemoteFixture(), id = UUID()
    #expect(f.session.beginRemoteAudio(id: id, sampleRate: 16_000))
    var bytes = Data()
    for _ in 0..<160 { bytes.append(contentsOf: [0, 128, 255, 127, 0, 0, 0, 64]) }
    #expect(f.session.appendRemoteAudio(id: id, pcm: bytes))
    f.session.inputDevicesChanged(); f.session.voiceEnd()
    #expect(f.session.state == .listening && f.deviceReads == 0)
    f.session.endRemoteAudio(id: id)
    try await eventually { f.session.state == .idle }
    #expect(f.transcriber.samples.count == 640)
    #expect(f.transcriber.samples.prefix(4) == [-1, Float(32767) / 32768, 0, 0.5])
    #expect(f.inserted == ["合成测试文字"] && f.returns == 0)
}

@Test(.timeLimit(.minutes(1))) @MainActor func 手机转写取消后迟到结果不投递() async throws {
    let f = RemoteFixture(), id = UUID(); f.transcriber.waiting = true
    #expect(f.session.beginRemoteAudio(id: id, sampleRate: 16_000))
    #expect(f.session.appendRemoteAudio(id: id, pcm: Data(count: 1280)))
    f.session.endRemoteAudio(id: id)
    try await eventually { f.transcriber.continuation != nil }
    f.session.cancelRemoteAudio(id: id)
    f.transcriber.continuation?.resume(returning: "迟到文字")
    await Task.yield()
    #expect(f.session.state == .idle && f.inserted.isEmpty && f.returns == 0)
    #expect(!f.session.appendRemoteAudio(id: id, pcm: Data(count: 1280)))
}

@Test @MainActor func 手机到限只取消且不抢已有会话或外部输入法() {
    var limits = VoiceLimits(); limits.recordingBytes = 1000
    let f = RemoteFixture(limits: limits), id = UUID()
    #expect(f.session.beginRemoteAudio(id: id, sampleRate: 16_000))
    #expect(!f.session.beginRemoteAudio(id: UUID(), sampleRate: 16_000))
    #expect(!f.session.appendRemoteAudio(id: id, pcm: Data(count: 1280)))
    #expect(f.session.state == .idle && f.inserted.isEmpty)
    f.session.settings.mode = .inputMethod
    #expect(!f.session.beginRemoteAudio(id: UUID(), sampleRate: 16_000))
    #expect(f.deviceReads == 0)
}

@Test(.timeLimit(.minutes(1))) @MainActor func 转写状态回调断线取消不能重建旧转写() async throws {
    let f = RemoteFixture(), id = UUID()
    #expect(f.session.beginRemoteAudio(id: id, sampleRate: 16_000))
    #expect(f.session.appendRemoteAudio(id: id, pcm: Data(count: 1280)))
    f.session.onStateChange = { state in if state == .transcribing { f.session.cancelRemoteAudio(id: id) } }
    f.session.endRemoteAudio(id: id)
    for _ in 0..<10 { await Task.yield() }
    #expect(f.session.state == .idle && f.transcriber.samples.isEmpty && f.inserted.isEmpty)
}
