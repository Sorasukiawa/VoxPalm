import Foundation
import Network
import Testing
import VoxPalmLink
@testable import VoxPalmLinkNetwork

@Test(.timeLimit(.minutes(1))) @MainActor func 语音经TLS回环传送并返回接收与转写状态() async throws {
    let key = try LinkCredential(hostID: UUID(), clientID: UUID()), store = MemoryCredentials()
    try store.save(key)
    let host = try SecureLinkHost(credential: key, store: store, loopbackOnly: true)
    var port: NWEndpoint.Port?, received = Data(), ended = false
    host.onReady = { port = $0 }
    host.onMessage = { value in
        switch value {
        case let .audioStart(id, _): host.sendVoiceFeedback(VoiceFeedback(id: id, state: .accepted))
        case let .audioChunk(_, _, pcm): received.append(pcm)
        case let .audioEnd(id, _):
            ended = true; host.sendVoiceFeedback(VoiceFeedback(id: id, state: .transcribing))
            host.sendVoiceFeedback(VoiceFeedback(id: id, state: .finished))
        default: break
        }
    }
    host.start(); defer { host.stop() }
    try await waitFor { port != nil }
    let client = SecureLinkClient(credential: key, endpoint: .hostPort(host: "127.0.0.1", port: port!))
    var ready = false, statuses: [VoiceFeedback] = []
    client.onReady = { ready = true }; client.onVoiceFeedback = { statuses.append($0) }
    client.start(); defer { client.stop() }
    try await waitFor { ready }
    let id = UUID(), pcm = Data(repeating: 42, count: 1280)
    try client.send(.audioStart(id: id, format: PCMFormat(sampleRate: 16_000)))
    try await waitFor { statuses.first?.state == .accepted }
    try client.send(.audioChunk(id: id, index: 0, pcm: pcm))
    try client.send(.audioEnd(id: id, chunkCount: 1))
    try await waitFor { statuses.last?.state == .finished }
    #expect(ended && received == pcm)
    #expect(statuses.map(\.state) == [.accepted, .transcribing, .finished])
    #expect(statuses.allSatisfy { $0.id == id })
}

@Test(.timeLimit(.minutes(1))) @MainActor func 打开关闭与撤销均通知上层取消已结束音频的转写() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let keys = MemoryCredentials(), store = try LinkDeviceStore(url: directory.appendingPathComponent("devices.json"), credentials: keys)
    let key = try LinkCredential(hostID: store.identity, clientID: UUID()); try store.save(key); try store.activate(id: key.id)
    let model = HostPairingModel(store: store, loopbackOnly: true)
    var cancellations: [UUID] = []
    model.onPeerDisconnected = { cancellations.append($0) }
    model.setEnabled(true); model.setEnabled(false)
    #expect(cancellations == [key.id])
    model.setEnabled(true); model.revoke(key.id); model.setEnabled(false)
    #expect(cancellations == [key.id, key.id])
}
