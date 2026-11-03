import Foundation

public enum LinkLimits {
    public static let protocolVersion: UInt16 = 1
    public static let maximumFrameBytes = 65_536
    public static let maximumReadBytes = 16_384
    public static let maximumHeldButtons = 16
    public static let maximumAudioSessions = 256
    public static let maximumRecordingSeconds = 300
    public static let idleTimeout: Duration = .seconds(10)
}

/// 错误只描述类别，不包含设备身份、消息正文或声音。
public enum LinkError: Error, Equatable, Sendable {
    case unsupportedVersion, unknownMessage, truncated, trailingBytes, oversized, invalidPayload
    case decoderFailed, invalidTransition, untrustedPeer, wrongPeer, wrongSession
    case replayedMessage, sequenceGap, sequenceExhausted, invalidEventOrder
    case resourceLimit, audioDiscontinuity, idleTimeout
}

public enum ButtonPhase: UInt8, Sendable, Equatable {
    case down = 1, up = 2, cancel = 3
}

public struct RemoteButton: Sendable, Equatable {
    public let id: String
    public let phase: ButtonPhase
    public init(id: String, phase: ButtonPhase) { self.id = id; self.phase = phase }
}

public enum PointerButton: UInt8, Sendable, Equatable, CaseIterable {
    case primary = 1, secondary = 2, middle = 3
}

public enum PointerMessage: Sendable, Equatable {
    case move(x: Double, y: Double)
    case scroll(x: Double, y: Double)
    case button(PointerButton, ButtonPhase)
}

public struct PCMFormat: Sendable, Equatable {
    public let sampleRate: UInt32
    public let channels: UInt8
    public let encoding: UInt8

    /// encoding=1 是有符号 16 位小端 PCM；v1 只接受单声道。
    public init(sampleRate: UInt32, channels: UInt8 = 1, encoding: UInt8 = 1) {
        self.sampleRate = sampleRate; self.channels = channels; self.encoding = encoding
    }

    public func validate() throws {
        guard [16_000, 48_000].contains(sampleRate), channels == 1, encoding == 1 else {
            throw LinkError.invalidPayload
        }
    }
}

public enum LinkMessage: Sendable, Equatable {
    case heartbeat
    case button(RemoteButton)
    case pointer(PointerMessage)
    case audioStart(id: UUID, format: PCMFormat)
    case audioChunk(id: UUID, index: UInt32, pcm: Data)
    case audioEnd(id: UUID, chunkCount: UInt32)
    case audioCancel(id: UUID)

    func validate() throws {
        switch self {
        case .heartbeat, .audioEnd, .audioCancel: break
        case let .button(button):
            let bytes = Array(button.id.utf8)
            guard !bytes.isEmpty, bytes.count <= 64,
                  bytes.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                      || (97...122).contains($0) || [45, 46, 95].contains($0) }) else {
                throw LinkError.invalidPayload
            }
        case let .pointer(.move(x, y)), let .pointer(.scroll(x, y)):
            guard x.isFinite, y.isFinite, abs(x) <= 4096, abs(y) <= 4096 else { throw LinkError.invalidPayload }
        case .pointer(.button): break
        case let .audioStart(_, format): try format.validate()
        case let .audioChunk(_, _, pcm):
            // 更精确的 40 ms 限制由接收状态按本轮采样率判断。
            guard !pcm.isEmpty, pcm.count <= 3840, pcm.count.isMultiple(of: 2) else { throw LinkError.invalidPayload }
        }
    }
}

public struct LinkEnvelope: Sendable, Equatable {
    public let protocolVersion: UInt16
    public let deviceID: UUID
    public let sessionID: UUID
    public let sequence: UInt64
    public let message: LinkMessage

    public init(protocolVersion: UInt16 = LinkLimits.protocolVersion, deviceID: UUID,
                sessionID: UUID, sequence: UInt64, message: LinkMessage) {
        self.protocolVersion = protocolVersion; self.deviceID = deviceID
        self.sessionID = sessionID; self.sequence = sequence; self.message = message
    }

    func validate() throws {
        guard protocolVersion == LinkLimits.protocolVersion else { throw LinkError.unsupportedVersion }
        guard sequence > 0 else { throw LinkError.invalidPayload }
        try message.validate()
    }
}
