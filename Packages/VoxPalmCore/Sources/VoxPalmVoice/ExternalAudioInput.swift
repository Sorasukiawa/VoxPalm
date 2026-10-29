import AVFoundation
import Foundation

/// 非系统声卡的收音来源。UID 使用独立命名空间，缺失时也不能回落系统默认麦。
public struct ExternalAudioDevice: Equatable {
    public static let prefix = "external-audio:"
    public let uid: String
    public let name: String
    public let detail: String
    public let controlDeviceID: String?
    public let problem: String?

    public init(uid: String, name: String, detail: String, controlDeviceID: String? = nil, problem: String? = nil) {
        precondition(Self.isExternal(uid))
        self.uid = uid
        self.name = name
        self.detail = detail
        self.controlDeviceID = controlDeviceID
        self.problem = problem
    }

    public static func isExternal(_ uid: String?) -> Bool { uid?.hasPrefix(prefix) == true }
}

/// 方法与完成／失败回调在主线程；PCM 可以从后台送入，但交出后不能再修改。
/// start 必须立即返回，不得阻塞按键松开；stop 必须撤销准备中的 start。
/// stop 成功意味着硬件已关麦并完成本轮资源恢复，失败则本轮不得转写或投递。
/// 每次调用都带会话标识；迟到的旧回调由 VoiceSession 丢弃。当前不支持预热或外部输入法。
public protocol ExternalAudioInput: AnyObject {
    var device: ExternalAudioDevice { get }
    func start(sessionID: UUID, onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
               onFailure: @escaping (String) -> Void)
    func stop(sessionID: UUID, completion: @escaping (Result<Void, Error>) -> Void)
}

/// 同一个适配器可以同时提供控制设备和音频，避免建立两条争抢硬件的连接。
public protocol ExternalAudioInputProvider: AnyObject {
    var audioInputs: [ExternalAudioInput] { get }
}
