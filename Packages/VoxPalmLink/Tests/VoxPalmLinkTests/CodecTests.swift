import Foundation
import Testing
@testable import VoxPalmLink

private let peer = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
private let session = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
private let audioID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

private func envelope(_ message: LinkMessage, sequence: UInt64 = 1) -> LinkEnvelope {
    LinkEnvelope(deviceID: peer, sessionID: session, sequence: sequence, message: message)
}

@Test func 心跳固定字节样本与网络字节序() throws {
    let expected = Data([
        0, 0, 0, 43, 0, 1,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2,
        1, 2, 3, 4, 5, 6, 7, 8, 0
    ])
    let message = envelope(.heartbeat, sequence: 0x0102030405060708)
    #expect(try LinkCodec.frame(message) == expected)
    #expect(try LinkCodec.decode(expected.dropFirst(4)) == message)
}

private let messages: [LinkMessage] = [
    .heartbeat,
    .button(RemoteButton(id: "voice.hold-1", phase: .down)),
    .button(RemoteButton(id: "voice.hold-1", phase: .up)),
    .button(RemoteButton(id: "voice.hold-1", phase: .cancel)),
    .pointer(.move(x: -3.25, y: 0)), .pointer(.scroll(x: 2, y: -1)),
    .pointer(.button(.primary, .down)), .pointer(.button(.secondary, .up)),
    .pointer(.button(.middle, .cancel)),
    .audioStart(id: audioID, format: PCMFormat(sampleRate: 16_000)),
    .audioChunk(id: audioID, index: 42, pcm: Data([0, 128, 255, 127])),
    .audioEnd(id: audioID, chunkCount: 43), .audioCancel(id: audioID)
]

@Test(arguments: messages) func 各类消息往返不改变字段(_ message: LinkMessage) throws {
    let input = envelope(message)
    #expect(try LinkCodec.decode(LinkCodec.encode(input)) == input)
}

@Test func 截断未知类型尾随字节和错误版本均拒绝() throws {
    let original = try LinkCodec.encode(envelope(.audioChunk(id: audioID, index: 0, pcm: Data([1, 0, 2, 0]))))
    for end in 0..<original.count { #expect(throws: LinkError.self) { try LinkCodec.decode(original.prefix(end)) } }
    var unknown = try LinkCodec.encode(envelope(.heartbeat)); unknown[42] = 255
    #expect(throws: LinkError.unknownMessage) { try LinkCodec.decode(unknown) }
    var version = original; version[1] = 2
    #expect(throws: LinkError.unsupportedVersion) { try LinkCodec.decode(version) }
    #expect(throws: LinkError.trailingBytes) { try LinkCodec.decode(original + Data([0])) }
    #expect(throws: LinkError.oversized) { try LinkCodec.decode(Data(count: 65_537)) }
}

@Test func 负零和大整数精确保留但非有限数值拒绝() throws {
    let value = envelope(.pointer(.move(x: -0.0, y: 4096)), sequence: UInt64.max)
    let encoded = try LinkCodec.encode(value)
    #expect(try LinkCodec.encode(LinkCodec.decode(encoded)) == encoded)
    for bad in [Double.nan, .infinity, -.infinity, 4097, -4097] {
        #expect(throws: LinkError.invalidPayload) { try LinkCodec.encode(envelope(.pointer(.move(x: bad, y: 0)))) }
    }
}

@Test func 标识音频格式和块大小严格校验() throws {
    for id in ["", "中文", "../", "a b", "a\n", String(repeating: "x", count: 65)] {
        #expect(throws: LinkError.invalidPayload) { try LinkCodec.encode(envelope(.button(RemoteButton(id: id, phase: .down)))) }
    }
    for format in [PCMFormat(sampleRate: 44_100), PCMFormat(sampleRate: 16_000, channels: 2), PCMFormat(sampleRate: 16_000, encoding: 2)] {
        #expect(throws: LinkError.invalidPayload) { try LinkCodec.encode(envelope(.audioStart(id: audioID, format: format))) }
    }
    for pcm in [Data(), Data([0]), Data(count: 3842)] {
        #expect(throws: LinkError.invalidPayload) { try LinkCodec.encode(envelope(.audioChunk(id: audioID, index: 0, pcm: pcm))) }
    }
    #expect(throws: LinkError.invalidPayload) { try LinkCodec.encode(envelope(.heartbeat, sequence: 0)) }
}

@Test func 所有分割位置与合并消息都正确分帧() throws {
    let first = try LinkCodec.frame(envelope(.button(RemoteButton(id: "talk", phase: .down))))
    let second = try LinkCodec.frame(envelope(.heartbeat, sequence: 2))
    let combined = first + second
    for split in 0...combined.count {
        var framer = LinkFramer()
        let output = try framer.append(combined.prefix(split)) + framer.append(combined.dropFirst(split))
        #expect(output == [Data(first.dropFirst(4)), Data(second.dropFirst(4))])
        #expect(framer.bufferedByteCount == 0)
        try framer.finish()
    }
}

@Test func 最大帧分段接收时缓冲有界() throws {
    let body = Data(repeating: 7, count: LinkLimits.maximumFrameBytes)
    let frame = Data([0, 1, 0, 0]) + body
    var framer = LinkFramer(), output: [Data] = []
    for start in stride(from: 0, to: frame.count, by: 16_384) {
        output += try framer.append(frame[start..<min(start + 16_384, frame.count)])
        #expect(framer.bufferedByteCount <= LinkLimits.maximumFrameBytes)
    }
    #expect(output == [body])
}

@Test func 错误长度超大读取和半帧EOF后不能复用解码器() throws {
    for header in [Data([255, 255, 255, 255]), Data([0, 0, 0, 0]), Data([0, 1, 0, 1])] {
        var framer = LinkFramer()
        #expect(throws: LinkError.oversized) { try framer.append(header) }
        #expect(framer.bufferedByteCount == 0)
        #expect(throws: LinkError.decoderFailed) { try framer.append(Data([0])) }
    }
    var large = LinkFramer()
    #expect(throws: LinkError.oversized) { try large.append(Data(count: 16_385)) }
    for partial in [Data([0, 0]), Data([0, 0, 0, 43, 0, 1])] {
        var framer = LinkFramer(); _ = try framer.append(partial)
        #expect(throws: LinkError.truncated) { try framer.finish() }
        #expect(framer.bufferedByteCount == 0)
    }
    var ended = LinkFramer(); try ended.finish()
    #expect(throws: LinkError.decoderFailed) { try ended.append(Data()) }
}

@Test func 逐字节变异不能静默忽略数据() throws {
    for message in messages {
        let bytes = try LinkCodec.encode(envelope(message))
        for index in bytes.indices {
            var mutated = bytes; mutated[index] ^= 0xA5
            do {
                let decoded = try LinkCodec.decode(mutated)
                #expect(try LinkCodec.encode(decoded) == mutated)
            } catch is LinkError {
                // 畸形消息可以拒绝；接受的消息必须完整保留全部字节含义。
            }
        }
    }
}
