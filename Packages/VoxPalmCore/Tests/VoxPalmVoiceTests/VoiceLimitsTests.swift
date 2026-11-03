import AVFoundation
import Foundation
import Testing
import VoxPalmEngine
@testable import VoxPalmVoice

private func audio(_ seconds: Double, channels: AVAudioChannelCount = 1, interleaved: Bool = false,
                   capacitySeconds: Double? = nil) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: channels, interleaved: interleaved)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount((capacitySeconds ?? seconds) * 16_000))!
    buffer.frameLength = AVAudioFrameCount(seconds * 16_000)
    for block in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
        block.mData!.assumingMemoryBound(to: Float.self).initialize(repeating: 0.25, count: Int(block.mDataByteSize) / 4)
    }
    return buffer
}

@Test(arguments: [false, true]) func 录音按时长截取最后一块且保持声道(_ interleaved: Bool) {
    var limits = VoiceLimits(); limits.recordingSeconds = 0.75
    var recording = RecordingBuffer(limits: limits)
    _ = recording.append(audio(0.5, channels: 2, interleaved: interleaved))
    #expect(!recording.limitReached)
    let last = recording.append(audio(0.5, channels: 2, interleaved: interleaved))
    #expect(last?.frameLength == 4_000 && last?.format.channelCount == 2)
    #expect(recording.seconds == 0.75 && recording.bytes == 96_000 && recording.limitReached)
    #expect(recording.append(audio(1)) == nil)
    #expect(recording.buffers.count == 2)
    for block in UnsafeMutableAudioBufferListPointer(last!.mutableAudioBufferList) {
        #expect(block.mData!.assumingMemoryBound(to: Float.self)[Int(block.mDataByteSize) / 4 - 1] == 0.25)
    }
}

@Test func 录音内存和缓冲块都有上限且不保留过大的原始容量() {
    var limits = VoiceLimits(); limits.recordingBytes = 32_000
    var recording = RecordingBuffer(limits: limits)
    let kept = recording.append(audio(1, capacitySeconds: 10))
    #expect(kept?.frameCapacity == 8_000 && recording.seconds == 0.5)
    #expect(recording.bytes == 32_000 && recording.limitReached)
    limits.recordingBuffers = 2; limits.recordingBytes = 100_000
    recording = RecordingBuffer(limits: limits)
    _ = recording.append(audio(0.01)); _ = recording.append(audio(0.01))
    #expect(recording.limitReached && recording.buffers.count == 2)
}

private final class LimitInput: ExternalAudioInput {
    let device = ExternalAudioDevice(uid: "external-audio:limits", name: "假麦", detail: "内存音频")
    var feeds: [(AVAudioPCMBuffer) -> Void] = []
    var stops: [(Result<Void, Error>) -> Void] = []
    func start(sessionID: UUID, onBuffer: @escaping (AVAudioPCMBuffer) -> Void, onFailure: @escaping (String) -> Void) {
        feeds.append(onBuffer)
    }
    func stop(sessionID: UUID, completion: @escaping (Result<Void, Error>) -> Void) { stops.append(completion) }
}

@MainActor private final class LimitTranscriber: Transcriber {
    let name = "可控转写"
    var durations: [Double] = []
    var wait = false
    var cancellations = 0
    func transcribe(_ buffers: [AVAudioPCMBuffer], locale: Locale) async throws -> String {
        durations.append(AudioConversion.duration(buffers))
        if wait {
            do { try await Task.sleep(for: .seconds(30)) }
            catch { cancellations += 1; throw error }
        }
        return "合成测试"
    }
}

@MainActor private final class LimitFixture {
    let input = LimitInput()
    let transcriber = LimitTranscriber()
    var outcomes: [VoiceSession.Outcome] = []
    var insertions = 0
    var returns = 0
    var session: VoiceSession!
    init(_ limits: VoiceLimits) {
        var settings = VoiceSession.Settings()
        settings.transcriber = .appleSpeech; settings.micUID = input.device.uid; settings.minimumSeconds = 0
        var dependencies = VoiceSession.Dependencies(); dependencies.limits = limits
        dependencies.currentTarget = { nil }
        dependencies.makePreview = { _, _, _ in nil }
        dependencies.makeTranscriber = { [transcriber] _, _ in transcriber }
        dependencies.prepareDelivery = { _ in }
        dependencies.insertText = { [weak self] _, _, _ in
            self?.insertions += 1
            return (.inserted(appName: "假窗口"), nil)
        }
        dependencies.sendReturn = { [weak self] _ in self?.returns += 1; return "假回车" }
        session = VoiceSession(settings: settings, dependencies: dependencies, externalInputs: { [input] in [input] })
        session.debugAudioFile = nil; session.debugTranscriptFile = nil
        session.onOutcome = { [weak self] in self?.outcomes.append($0) }
    }
}

@MainActor private func eventually(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    #expect(condition())
}

@Test @MainActor func 到限先等外部关麦再转写且禁止自动发送() async {
    var limits = VoiceLimits(); limits.recordingBytes = 32_000
    let f = LimitFixture(limits)
    f.session.voiceBegin(VoiceRequest(sendReturn: true)); f.input.feeds[0](audio(1))
    await eventually { f.input.stops.count == 1 }
    #expect(f.transcriber.durations.isEmpty && !f.session.canStartVoice)
    #expect(f.outcomes.contains { if case .recordingLimitReached = $0 { return true }; return false })
    f.input.feeds[0](audio(1)) // 关麦回调前仍到来的 PCM 不得继续占用缓冲。
    f.input.stops[0](.success(()))
    await eventually { f.session.state == .idle }
    #expect(f.transcriber.durations == [0.5] && f.insertions == 1)
    try? await Task.sleep(for: .milliseconds(400))
    #expect(f.returns == 0)
    f.session.voiceBegin(VoiceRequest()); f.input.feeds[0](audio(2)); f.input.feeds[1](audio(0.25))
    f.session.voiceEnd(); f.input.stops[1](.success(()))
    await eventually { f.session.state == .idle }
    #expect(f.transcriber.durations == [0.5, 0.25])
}

@Test @MainActor func 到限通知排队时手动松手也不发送() async {
    var limits = VoiceLimits(); limits.recordingBytes = 16_000
    let f = LimitFixture(limits)
    f.session.voiceBegin(VoiceRequest(sendReturn: true)); f.input.feeds[0](audio(1))
    f.session.voiceEnd() // 抢在到限的主线程回调之前。
    f.input.stops[0](.success(()))
    await eventually { f.session.state == .idle }
    try? await Task.sleep(for: .milliseconds(400))
    #expect(f.insertions == 1 && f.returns == 0)
}

@Test @MainActor func 没有音频回调也会到时关麦且旧计时器不结束新录音() async {
    var limits = VoiceLimits(); limits.recordingSeconds = 0.08
    let f = LimitFixture(limits)
    f.session.voiceArm(VoiceRequest())
    await eventually { f.input.stops.count == 1 }
    f.input.stops[0](.success(()))
    await eventually { f.session.canStartVoice }
    f.session.voiceBegin(VoiceRequest()); f.session.voiceCancel()
    f.input.stops[1](.success(()))
    await eventually { f.session.canStartVoice }
    f.session.voiceBegin(VoiceRequest())
    try? await Task.sleep(for: .milliseconds(25))
    #expect(f.session.state == .listening)
    f.session.voiceCancel(); f.input.stops[2](.success(()))
}

@Test @MainActor func 转写超时取消底层并可立即开始下一轮() async {
    var limits = VoiceLimits(); limits.transcriptionSeconds = 0.08
    let f = LimitFixture(limits); f.transcriber.wait = true
    f.session.voiceBegin(VoiceRequest()); f.input.feeds[0](audio(0.5)); f.session.voiceEnd()
    f.input.stops[0](.success(()))
    await eventually { f.transcriber.cancellations == 1 }
    #expect(f.session.canStartVoice && f.insertions == 0)
    #expect(f.outcomes.contains { if case let .failed(text) = $0 { return text.contains("超时") }; return false })
    f.transcriber.wait = false
    f.session.voiceBegin(VoiceRequest()); f.input.feeds[1](audio(0.25)); f.session.voiceEnd()
    f.input.stops[1](.success(()))
    await eventually { f.insertions == 1 }
    #expect(f.session.state == .idle)
}

// 同步模拟主线程繁忙：越过截止时间，仍让松手先于排队的计时器 continuation 执行。
@MainActor private func occupyMainThread() { Thread.sleep(forTimeInterval: 0.08) }

@Test @MainActor func 时间到限但计时器尚未执行时松手仍不发送() async {
    var limits = VoiceLimits(); limits.recordingSeconds = 0.04
    let f = LimitFixture(limits)
    f.session.voiceBegin(VoiceRequest(sendReturn: true)); f.input.feeds[0](audio(0.01))
    occupyMainThread()
    f.session.voiceEnd(); f.input.stops[0](.success(()))
    await eventually { f.session.state == .idle }
    try? await Task.sleep(for: .milliseconds(400))
    #expect(f.insertions == 1 && f.returns == 0)
    #expect(f.outcomes.contains { if case .recordingLimitReached = $0 { return true }; return false })
    let normal = LimitFixture(VoiceLimits())
    normal.session.voiceBegin(VoiceRequest(sendReturn: true)); normal.input.feeds[0](audio(0.01))
    normal.session.voiceEnd(); normal.input.stops[0](.success(()))
    await eventually { normal.returns == 1 }
}

@Test @MainActor func 预热录音到限后丢弃旧预录和晚到回调() async throws {
    let empty = FileManager.default.temporaryDirectory.appendingPathComponent("voxpalm-limit-warm-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: empty) }
    do { _ = try AVAudioFile(forWriting: empty, settings: audio(0.01).format.settings) }
    let transcriber = LimitTranscriber()
    var dependencies = VoiceSession.Dependencies()
    dependencies.limits.recordingBytes = 6_400
    dependencies.currentTarget = { nil }; dependencies.makePreview = { _, _, _ in nil }
    dependencies.makeTranscriber = { _, _ in transcriber }; dependencies.prepareDelivery = { _ in }
    dependencies.insertText = { _, _, _ in (.inserted(appName: "假窗口"), nil) }
    var settings = VoiceSession.Settings(); settings.transcriber = .appleSpeech; settings.minimumSeconds = 0
    let session = VoiceSession(settings: settings, dependencies: dependencies)
    session.debugAudioFile = empty; session.debugTranscriptFile = nil
    session.settings.keepMicWarm = true
    session.received(audio(0.025)) // 真实地进入闲置预录，而不是本轮录音缓冲。
    session.voiceBegin(VoiceRequest()); session.received(audio(0.2))
    await eventually { session.state == .idle }
    #expect(transcriber.durations == [0.1])
    session.received(audio(0.04)) // 停采后的晚到系统回调也不得填回旧预录。
    session.voiceBegin(VoiceRequest()); session.received(audio(0.025)); session.voiceEnd()
    await eventually { session.state == .idle }
    #expect(transcriber.durations.count == 2)
    #expect(abs(transcriber.durations.last! - 0.025) < 0.0001)
    session.settings.keepMicWarm = false
}

@Test @MainActor func 外部输入法到时只松键不回车() async {
    var dependencies = VoiceSession.Dependencies()
    dependencies.limits.recordingSeconds = 0.04
    dependencies.currentTarget = { nil }; dependencies.inputDevices = { [] }
    dependencies.canPostInputMethodKey = { true }
    var downs = 0, ups = 0, returns = 0
    dependencies.beginInputMethod = { _ in downs += 1 }
    dependencies.endInputMethod = { _ in ups += 1 }
    dependencies.sendReturn = { _ in returns += 1; return "假回车" }
    var settings = VoiceSession.Settings(); settings.mode = .inputMethod; settings.inputMethodSendDelay = 0
    let session = VoiceSession(settings: settings, dependencies: dependencies)
    session.voiceBegin(VoiceRequest(sendReturn: true))
    await eventually { session.state == .idle }
    session.voiceEnd()
    #expect(downs == 1 && ups == 1 && returns == 0)
}

@Test func 同步转写取消会退出工作且下一项能执行() async throws {
    let queue = DispatchQueue(label: "test.cancel.sync")
    let (started, feed) = AsyncStream<Void>.makeStream()
    let work = Task {
        try await TranscriptionCancellation.run(on: queue) { cancellation in
            feed.yield(()); feed.finish()
            let deadline = ContinuousClock.now + .seconds(3)
            while !cancellation.isCancelled, ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.001) }
            try cancellation.check()
            Issue.record("同步运算没有收到取消")
        }
    }
    for await _ in started { break }
    work.cancel()
    await #expect(throws: CancellationError.self) { try await work.value }
    let value = try await TranscriptionCancellation.run(on: queue) { _ in 42 }
    #expect(value == 42)
}

@Test func 排队中取消的转写不进入底层运算() async throws {
    let queue = DispatchQueue(label: "test.cancel.queued")
    let gate = DispatchSemaphore(value: 0)
    queue.async { _ = gate.wait(timeout: .now() + 3) }
    let work = Task {
        try await TranscriptionCancellation.run(on: queue) { _ in Issue.record("已经取消仍开始计算") }
    }
    try await Task.sleep(for: .milliseconds(20))
    work.cancel(); gate.signal()
    await #expect(throws: CancellationError.self) { try await work.value }
}

@Test func 异步清理并发触发只执行一次且等待完成() async {
    actor Count { var count = 0; func increment() { count += 1 } }
    let count = Count()
    let cleanup = TranscriptionCleanup { await count.increment() }
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<8 { group.addTask { await cleanup.start().value } }
    }
    #expect(await count.count == 1)
}
