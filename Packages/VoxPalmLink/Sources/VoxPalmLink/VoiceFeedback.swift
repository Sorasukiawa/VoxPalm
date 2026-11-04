import Foundation

/// 只回传固定状态，不包含声音、转写文本或系统错误正文。
public struct VoiceFeedback: Equatable, Sendable {
    public enum State: UInt8, Sendable, CaseIterable {
        case accepted = 1, transcribing, finished, copied, tooShort, noText, cancelled, failed, busy, requiresBuiltIn, unavailable
    }
    public let id: UUID
    public let state: State
    public init(id: UUID, state: State) { self.id = id; self.state = state }
}

public enum VoiceFeedbackCodec {
    public static func frame(_ value: VoiceFeedback, session: UUID) -> Data {
        var data = Data([0, 0, 0, 74, 1])
        data.append(contentsOf: session.uuidString.utf8)
        data.append(contentsOf: value.id.uuidString.utf8)
        data.append(value.state.rawValue)
        return data
    }
    public static func decode(_ body: Data, session: UUID) throws -> VoiceFeedback {
        let bytes = Array(body)
        guard bytes.count == 74, bytes[0] == 1,
              let receivedSession = UUID(uuidString: String(decoding: bytes[1..<37], as: UTF8.self)), receivedSession == session,
              let id = UUID(uuidString: String(decoding: bytes[37..<73], as: UTF8.self)),
              let state = VoiceFeedback.State(rawValue: bytes[73]) else { throw LinkError.invalidPayload }
        return VoiceFeedback(id: id, state: state)
    }
}
