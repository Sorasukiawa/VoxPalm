import Foundation
import Testing
import VoxPalmLink
@testable import VoxPalmLinkUI

@MainActor private final class Microphone: MobileAudioSource {
    var permissionGranted = true
    var starts = 0, cancels = 0
    var permissions: ((Bool) -> Void)?
    var pcm: ((Data) -> Void)?
    var failure: (() -> Void)?
    var finished: ((Bool) -> Void)?
    func requestPermission(_ completion: @escaping (Bool) -> Void) { permissions = completion }
    func start(onPCM: @escaping (Data) -> Void, onFailure: @escaping () -> Void) throws {
        starts += 1; pcm = onPCM; failure = onFailure
    }
    func finish(_ completion: @escaping (Bool) -> Void) { finished = completion }
    func cancel() { cancels += 1 }
}

@MainActor private final class Fixture {
    let mic = Microphone()
    var messages: [LinkMessage] = []
    var disconnects = 0
    var model: MobileVoiceModel!
    init() {
        model = MobileVoiceModel(microphone: mic, connection: .init(ready: { true }, send: { [weak self] in self?.messages.append($0) },
            disconnect: { [weak self] in self?.disconnects += 1 }))
    }
    func start() throws -> UUID {
        model.begin()
        guard case let .audioStart(id, _) = messages.last else { throw TestError.missingStart }
        return id
    }
    enum TestError: Error { case missingStart }
}

@Test @MainActor func 未获Mac接受不开麦且提前松开丢弃迟到接受() throws {
    let f = Fixture(), id = try f.start()
    #expect(f.mic.starts == 0)
    f.model.release()
    f.model.receive(VoiceFeedback(id: id, state: .accepted))
    #expect(f.mic.starts == 0 && f.model.phase == .idle)
    #expect(f.messages.last == .audioCancel(id: id))
}

@Test @MainActor func 录音尾块送完后才发结束且完成反馈不再发取消() throws {
    let f = Fixture(), id = try f.start()
    f.model.receive(VoiceFeedback(id: id, state: .accepted))
    f.mic.pcm?(Data(repeating: 1, count: 1280)); f.model.release()
    #expect(f.model.phase == .finishing)
    f.mic.pcm?(Data(repeating: 2, count: 320))
    #expect(f.messages.count == 3)
    f.mic.finished?(true)
    #expect(f.messages.last == .audioEnd(id: id, chunkCount: 2))
    #expect(f.model.phase == .transcribing)
    let count = f.messages.count
    f.model.receive(VoiceFeedback(id: id, state: .finished))
    #expect(f.model.phase == .idle && f.messages.count == count)
    #expect(f.model.message == "文字已输入到 Mac。")
}

@Test @MainActor func 取消和新一轮隔离旧PCM与收尾回调() throws {
    let f = Fixture(), first = try f.start()
    f.model.receive(VoiceFeedback(id: first, state: .accepted))
    let oldPCM = f.mic.pcm; f.model.release(); let oldFinish = f.mic.finished
    f.model.cancel()
    let second = try f.start(); f.model.receive(VoiceFeedback(id: second, state: .accepted))
    let count = f.messages.count
    oldPCM?(Data(repeating: 3, count: 1280)); oldFinish?(true)
    f.model.receive(VoiceFeedback(id: first, state: .failed))
    #expect(f.messages.count == count && f.model.phase == .recording)
    f.model.cancel(disconnected: true)
    #expect(f.messages.count == count && f.model.phase == .idle)
}

@Test @MainActor func 转写期间取消断开连接而不发送非法音频取消包() throws {
    let f = Fixture(), id = try f.start()
    f.model.receive(VoiceFeedback(id: id, state: .accepted))
    f.mic.pcm?(Data(repeating: 1, count: 1280)); f.model.release(); f.mic.finished?(true)
    let count = f.messages.count
    f.model.cancel()
    #expect(f.disconnects == 1 && f.messages.count == count && f.model.phase == .idle)
}

@Test @MainActor func 麦克风授权晚到不自动开麦且异常块取消() throws {
    let f = Fixture(); f.mic.permissionGranted = false; f.model.refreshPermission()
    f.model.requestPermission(); f.model.begin()
    #expect(f.messages.isEmpty && f.mic.starts == 0)
    f.mic.permissionGranted = true; f.mic.permissions?(true)
    #expect(f.messages.isEmpty && f.mic.starts == 0)
    let id = try f.start(); f.model.receive(VoiceFeedback(id: id, state: .accepted))
    f.mic.pcm?(Data(count: 1282))
    #expect(f.model.phase == .idle && f.messages.last == .audioCancel(id: id))
}

private final class Counter: @unchecked Sendable { var value = 0 }
@Test func PCM交付积压有界且只排一个通知() {
    let calls = Counter(), queue = PCMDeliveryQueue(maximumBytes: 8) { calls.value += 1 }
    queue.append(Data(count: 4)); queue.append(Data(count: 4)); queue.append(Data(count: 2))
    #expect(calls.value == 1)
    let batch = queue.drain()
    #expect(batch.failed && batch.buffers.isEmpty)
    queue.close(); queue.append(Data(count: 4))
    #expect(queue.drain().buffers.isEmpty && calls.value == 1)
}
