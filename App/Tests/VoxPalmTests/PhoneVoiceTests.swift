import Foundation
import AVFoundation
import Testing
import VoxPalmLink
import Network
@testable import VoxPalmLinkNetwork
@testable import VoxPalmVoice
@testable import VoxPalm

@Test @MainActor func 不允许手机语音时拒绝且其他设备不能取消当前会话() {
    var settings = VoiceSession.Settings(); settings.minimumSeconds = 10
    var dependencies = VoiceSession.Dependencies(); dependencies.currentTarget = { nil }
    let voice = VoiceSession(settings: settings, dependencies: dependencies)
    voice.debugAudioFile = nil; voice.debugTranscriptFile = nil
    var allowed = false, feedback: [(UUID, VoiceFeedback)] = []
    let coordinator = PhoneVoiceCoordinator(voice: voice, allowed: { allowed }, feedback: { feedback.append(($0, $1)) })
    voice.onStateChange = { coordinator.stateChanged($0) }
    voice.onOutcome = { coordinator.receivedOutcome($0) }
    let peer = UUID(), other = UUID(), id = UUID()
    coordinator.receive(.audioStart(id: id, format: PCMFormat(sampleRate: 16_000)), from: peer)
    #expect(feedback.last?.1.state == .unavailable && voice.state == .idle)
    // 不启动收音或转写：外部输入法模式直接拒绝。
    allowed = true; voice.settings.mode = .inputMethod
    coordinator.receive(.audioStart(id: id, format: PCMFormat(sampleRate: 16_000)), from: peer)
    #expect(feedback.last?.1.state == .requiresBuiltIn)
    coordinator.cancel(peer: other)
    #expect(voice.state == .idle)
    voice.settings.mode = .builtIn
    coordinator.receive(.audioStart(id: id, format: PCMFormat(sampleRate: 16_000)), from: peer)
    #expect(voice.state == .listening && feedback.last?.1.state == .accepted)
    coordinator.cancel(peer: other)
    coordinator.receive(.audioEnd(id: id, chunkCount: 0), from: other)
    #expect(voice.state == .listening)
    coordinator.receive(.audioChunk(id: id, index: 0, pcm: Data(count: 1280)), from: peer)
    coordinator.receive(.audioEnd(id: id, chunkCount: 1), from: peer)
    #expect(voice.state == .idle && feedback.last?.1.state == .tooShort)
}

@MainActor private final class TestKeys: LinkCredentialStore {
    var keys: [UUID: LinkCredential] = [:]
    func save(_ credential: LinkCredential) throws { keys[credential.id] = credential }
    func remove(id: UUID) throws { keys.removeValue(forKey: id) }
    func load(id: UUID) throws -> LinkCredential? { keys[id] }
}

@MainActor private final class PhoneTranscriber: Transcriber {
    let name = "合成手机转写"
    var wait = false
    var completed = 0
    var pending: CheckedContinuation<String, Never>?
    func transcribe(_ buffers: [AVAudioPCMBuffer], locale: Locale) async throws -> String {
        #expect(AudioConversion.duration(buffers) >= 0.3)
        let text: String
        if wait { text = await withCheckedContinuation { pending = $0 } }
        else { text = "合成手机文字" }
        completed += 1; return text
    }
}

@MainActor private func eventually(_ condition: () -> Bool) async throws {
    while !condition() { try await Task.sleep(for: .milliseconds(5)) }
}

@Test(.timeLimit(.minutes(1))) @MainActor func 加密手机音频进入Mac转写且断线取消未完成投递() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try LinkDeviceStore(url: directory.appendingPathComponent("host.json"), credentials: TestKeys())
    let key = try LinkCredential(hostID: store.identity, clientID: UUID())
    try store.save(key); try store.activate(id: key.id)
    let host = HostPairingModel(store: store, loopbackOnly: true)
    let transcriber = PhoneTranscriber()
    var insertions: [String] = [], returns = 0
    var settings = VoiceSession.Settings(); settings.transcriber = .appleSpeech
    var dependencies = VoiceSession.Dependencies()
    dependencies.currentTarget = { nil }; dependencies.prepareDelivery = { _ in }
    dependencies.makeTranscriber = { _, _ in transcriber }
    dependencies.insertText = { text, _, _ in insertions.append(text); return (.inserted(appName: "假窗口"), nil) }
    dependencies.sendReturn = { _ in returns += 1; return "不应调用" }
    let voice = VoiceSession(settings: settings, dependencies: dependencies)
    voice.debugAudioFile = nil; voice.debugTranscriptFile = nil
    let bridge = PhoneVoiceCoordinator(voice: voice, allowed: { true }, feedback: { host.sendVoiceFeedback($1, to: $0) })
    host.onAudioMessage = { bridge.receive($1, from: $0) }; host.onPeerDisconnected = { bridge.cancel(peer: $0) }
    voice.onStateChange = { bridge.stateChanged($0) }; voice.onOutcome = { bridge.receivedOutcome($0) }
    host.setEnabled(true); defer { host.setEnabled(false) }
    try await eventually { host.ports[key.id] != nil }
    let client = SecureLinkClient(credential: key, endpoint: .hostPort(host: "127.0.0.1", port: host.ports[key.id]!))
    var ready = false, states: [VoiceFeedback] = []
    client.onReady = { ready = true }; client.onVoiceFeedback = { states.append($0) }
    client.start(); defer { client.stop() }
    try await eventually { ready }
    func sendAudio(_ id: UUID) async throws {
        try client.send(.audioStart(id: id, format: PCMFormat(sampleRate: 16_000)))
        try await eventually { states.contains(VoiceFeedback(id: id, state: .accepted)) }
        for index in 0..<8 { try client.send(.audioChunk(id: id, index: UInt32(index), pcm: Data(repeating: 1, count: 1280))) }
        try client.send(.audioEnd(id: id, chunkCount: 8))
    }
    let first = UUID(); try await sendAudio(first)
    try await eventually { states.last == VoiceFeedback(id: first, state: .finished) }
    #expect(insertions == ["合成手机文字"] && returns == 0)
    transcriber.wait = true
    let second = UUID(); try await sendAudio(second)
    try await eventually { transcriber.pending != nil }
    client.stop()
    try await eventually { voice.state == .idle }
    transcriber.pending?.resume(returning: "断线后的迟到文字")
    try await eventually { transcriber.completed == 2 }
    for _ in 0..<5 { await Task.yield() }
    #expect(insertions == ["合成手机文字"] && returns == 0)
}
