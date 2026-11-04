import Foundation
import Testing
@testable import VoxPalmLink

@Test(arguments: VoiceFeedback.State.allCases) func 反馈逐字节还原并拒绝错误会话(_ state: VoiceFeedback.State) throws {
    let session = UUID(), value = VoiceFeedback(id: UUID(), state: state)
    var framer = LinkFramer(), bodies: [Data] = []
    for byte in VoiceFeedbackCodec.frame(value, session: session) { bodies += try framer.append(Data([byte])) }
    let body = try #require(bodies.first)
    #expect(try VoiceFeedbackCodec.decode(body, session: session) == value)
    #expect(throws: LinkError.invalidPayload) { try VoiceFeedbackCodec.decode(body, session: UUID()) }
    #expect(throws: LinkError.invalidPayload) { try VoiceFeedbackCodec.decode(body + Data([0]), session: session) }
}
