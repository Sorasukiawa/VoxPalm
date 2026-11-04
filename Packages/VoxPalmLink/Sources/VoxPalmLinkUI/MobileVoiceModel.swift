import Combine
import Foundation
import VoxPalmLink
import VoxPalmLinkNetwork

@MainActor protocol MobileAudioSource: AnyObject {
    var permissionGranted: Bool { get }
    func requestPermission(_ completion: @escaping (Bool) -> Void)
    func start(onPCM: @escaping (Data) -> Void, onFailure: @escaping () -> Void) throws
    /// 收尾期间仍可交付末块；completion 必须在全部 PCM 回调之后。
    func finish(_ completion: @escaping (Bool) -> Void)
    func cancel()
}

@MainActor final class MobileVoiceModel: ObservableObject {
    enum Phase: Equatable { case idle, waitingForMac, recording, finishing, transcribing }
    struct Connection {
        let ready: () -> Bool
        let send: (LinkMessage) throws -> Void
        let disconnect: () -> Void
    }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var microphoneAllowed: Bool
    @Published private(set) var requestingPermission = false
    @Published private(set) var message = "按住说话，松开后在 Mac 上转写。"
    private let microphone: any MobileAudioSource
    private let connection: Connection
    private var id: UUID?
    private var chunks: UInt32 = 0
    private var frames = 0
    private var deadline: Task<Void, Never>?
    var active: Bool { phase != .idle }

    convenience init(link: ClientPairingModel, microphone: any MobileAudioSource) {
        self.init(microphone: microphone, connection: Connection(ready: { [weak link] in link?.connectedID != nil },
            send: { [weak link] value in guard let link else { throw SecureLinkError.connection }; try link.sendAudio(value) },
            disconnect: { [weak link] in link?.stop() }))
        link.onVoiceFeedback = { [weak self] in self?.receive($0) }
        link.onConnectionEnded = { [weak self] in self?.cancel(disconnected: true) }
    }
    init(microphone: any MobileAudioSource, connection: Connection) {
        self.microphone = microphone; self.connection = connection
        microphoneAllowed = microphone.permissionGranted
    }
    func requestPermission() {
        guard !requestingPermission, !active else { return }
        requestingPermission = true
        microphone.requestPermission { [weak self] granted in
            guard let self else { return }
            self.requestingPermission = false; self.microphoneAllowed = granted
            self.message = granted ? "麦克风已就绪。连接 Mac 后按住说话。" : "麦克风未获授权，请在系统设置中允许掌声使用麦克风。"
        }
    }
    func refreshPermission() { microphoneAllowed = microphone.permissionGranted }
    func begin() {
        guard !active, connection.ready(), microphoneAllowed, microphone.permissionGranted else { return }
        let id = UUID(); self.id = id; chunks = 0; frames = 0
        phase = .waitingForMac; message = "正在等待 Mac…"; armDeadline(seconds: 8, id: id)
        do { try connection.send(.audioStart(id: id, format: PCMFormat(sampleRate: 16_000))) }
        catch { cancel(disconnected: true); connection.disconnect() }
    }
    func release() {
        guard let id else { return }
        if phase == .waitingForMac { cancel(); return }
        guard phase == .recording else { return }
        phase = .finishing; message = "正在收尾…"
        microphone.finish { [weak self] success in
            guard let self, self.id == id, self.phase == .finishing else { return }
            guard success else { self.cancel(); self.message = "录音收尾失败，本次已取消。"; return }
            self.phase = .transcribing; self.message = "Mac 正在转写…"; self.armDeadline(seconds: 135, id: id)
            do { try self.connection.send(.audioEnd(id: id, chunkCount: self.chunks)) }
            catch { self.cancel(disconnected: true); self.connection.disconnect() }
        }
    }
    private func accept(_ pcm: Data, id: UUID) {
        guard self.id == id, phase == .recording || phase == .finishing else { return }
        guard !pcm.isEmpty, pcm.count <= 1280, pcm.count.isMultiple(of: 2), frames + pcm.count / 2 <= 16_000 * 300 else {
            cancel(); message = "录音数据异常或已达到上限，本次已取消。"; return
        }
        let index = chunks; chunks += 1; frames += pcm.count / 2
        do { try connection.send(.audioChunk(id: id, index: index, pcm: pcm)) }
        catch { cancel(disconnected: true); connection.disconnect() }
    }
    func receive(_ feedback: VoiceFeedback) {
        guard id == feedback.id else { return }
        switch feedback.state {
        case .accepted:
            guard phase == .waitingForMac else { return }
            phase = .recording; message = "正在录音，松开后转写"; armDeadline(seconds: 300, id: feedback.id)
            do {
                try microphone.start(onPCM: { [weak self] in self?.accept($0, id: feedback.id) }, onFailure: { [weak self] in
                    guard let self, self.id == feedback.id else { return }
                    self.cancel(); self.message = "收音已中断，本次已取消，请重新按住说话。"
                })
            } catch { cancel(); message = "无法打开手机麦克风，本次已取消。" }
        case .transcribing:
            if phase == .transcribing { message = "Mac 正在转写…" }
        default:
            let oldPhase = phase; let old = id
            clear()
            if oldPhase != .transcribing, let old {
                do { try connection.send(.audioCancel(id: old)) } catch { connection.disconnect() }
            }
            switch feedback.state {
            case .finished: message = "文字已输入到 Mac。"
            case .copied: message = "文字已放到 Mac 剪贴板，请在 Mac 上按 ⌘V。"
            case .tooShort: message = "说话太短，请再按住说一句。"
            case .noText: message = "Mac 没有识别出文字，请重试。"
            case .busy: message = "Mac 正在处理另一轮语音，请稍后再试。"
            case .requiresBuiltIn: message = "请在 Mac 设置 → 语音中选择「内置转写」。"
            case .unavailable: message = "Mac 暂停了语音输入，请检查监听状态。"
            case .cancelled: message = "本次已取消，未提交文字。"
            default: message = "Mac 转写失败，请查看 Mac 上的提示。"
            }
        }
    }
    func cancel(disconnected: Bool = false) {
        guard let old = id else { return }
        let ended = phase == .transcribing
        clear()
        if !disconnected {
            // 音频结束包已经发出后，断开通道才能撤销 Mac 上尚未完成的转写。
            if ended { connection.disconnect() }
            else { do { try connection.send(.audioCancel(id: old)) } catch { connection.disconnect() } }
        }
        message = disconnected ? "连接已断开，本次语音已取消。" : "本次已取消。"
    }
    private func clear() {
        id = nil; phase = .idle; deadline?.cancel(); deadline = nil; microphone.cancel()
    }
    private func armDeadline(seconds: Double, id: UUID) {
        deadline?.cancel()
        deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, self.id == id else { return }
            self.cancel(); self.message = "等待或录音已达到上限，本次已取消。"
        }
    }
}
