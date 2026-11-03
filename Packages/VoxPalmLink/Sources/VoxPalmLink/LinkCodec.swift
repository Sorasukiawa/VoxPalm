import Foundation

/// 确定的二进制格式，不依赖 Swift 枚举布局或 JSON 解析器的宽松行为。
public enum LinkCodec {
    public static func encode(_ envelope: LinkEnvelope) throws -> Data {
        try envelope.validate()
        var writer = Writer()
        writer.uint(UInt64(envelope.protocolVersion), bytes: 2)
        writer.uuid(envelope.deviceID); writer.uuid(envelope.sessionID)
        writer.uint(envelope.sequence, bytes: 8)
        switch envelope.message {
        case .heartbeat: writer.byte(0)
        case let .button(button):
            writer.byte(1); writer.byte(UInt8(button.id.utf8.count))
            writer.data.append(contentsOf: button.id.utf8); writer.byte(button.phase.rawValue)
        case let .pointer(pointer):
            writer.byte(2)
            switch pointer {
            case let .move(x, y): writer.byte(1); writer.double(x); writer.double(y)
            case let .scroll(x, y): writer.byte(2); writer.double(x); writer.double(y)
            case let .button(button, phase): writer.byte(3); writer.byte(button.rawValue); writer.byte(phase.rawValue)
            }
        case let .audioStart(id, format):
            writer.byte(3); writer.uuid(id); writer.uint(UInt64(format.sampleRate), bytes: 4)
            writer.byte(format.channels); writer.byte(format.encoding)
        case let .audioChunk(id, index, pcm):
            writer.byte(4); writer.uuid(id); writer.uint(UInt64(index), bytes: 4)
            writer.uint(UInt64(pcm.count), bytes: 2); writer.data.append(pcm)
        case let .audioEnd(id, count):
            writer.byte(5); writer.uuid(id); writer.uint(UInt64(count), bytes: 4)
        case let .audioCancel(id): writer.byte(6); writer.uuid(id)
        }
        guard writer.data.count <= LinkLimits.maximumFrameBytes else { throw LinkError.oversized }
        return writer.data
    }

    public static func decode(_ data: Data) throws -> LinkEnvelope {
        guard data.count <= LinkLimits.maximumFrameBytes else { throw LinkError.oversized }
        var reader = Reader(data)
        let version = UInt16(try reader.uint(bytes: 2))
        guard version == LinkLimits.protocolVersion else { throw LinkError.unsupportedVersion }
        let device = try reader.uuid(), session = try reader.uuid()
        let sequence = try reader.uint(bytes: 8)
        let message: LinkMessage
        switch try reader.byte() {
        case 0: message = .heartbeat
        case 1:
            let length = Int(try reader.byte())
            let bytes = try reader.take(length)
            guard let id = String(data: bytes, encoding: .utf8),
                  let phase = ButtonPhase(rawValue: try reader.byte()) else { throw LinkError.invalidPayload }
            message = .button(RemoteButton(id: id, phase: phase))
        case 2:
            switch try reader.byte() {
            case 1: message = .pointer(.move(x: try reader.double(), y: try reader.double()))
            case 2: message = .pointer(.scroll(x: try reader.double(), y: try reader.double()))
            case 3:
                guard let button = PointerButton(rawValue: try reader.byte()),
                      let phase = ButtonPhase(rawValue: try reader.byte()) else { throw LinkError.invalidPayload }
                message = .pointer(.button(button, phase))
            default: throw LinkError.unknownMessage
            }
        case 3:
            let id = try reader.uuid()
            message = .audioStart(id: id, format: PCMFormat(sampleRate: UInt32(try reader.uint(bytes: 4)),
                                                          channels: try reader.byte(), encoding: try reader.byte()))
        case 4:
            let id = try reader.uuid(), index = UInt32(try reader.uint(bytes: 4))
            let count = Int(try reader.uint(bytes: 2))
            guard count <= 3840 else { throw LinkError.oversized }
            message = .audioChunk(id: id, index: index, pcm: try reader.take(count))
        case 5: message = .audioEnd(id: try reader.uuid(), chunkCount: UInt32(try reader.uint(bytes: 4)))
        case 6: message = .audioCancel(id: try reader.uuid())
        default: throw LinkError.unknownMessage
        }
        guard reader.remaining == 0 else { throw LinkError.trailingBytes }
        let envelope = LinkEnvelope(protocolVersion: version, deviceID: device, sessionID: session,
                                    sequence: sequence, message: message)
        try envelope.validate()
        return envelope
    }

    public static func frame(_ envelope: LinkEnvelope) throws -> Data {
        let body = try encode(envelope)
        var writer = Writer(); writer.uint(UInt64(body.count), bytes: 4); writer.data.append(body)
        return writer.data
    }
}

private struct Writer {
    var data = Data()
    mutating func byte(_ value: UInt8) { data.append(value) }
    mutating func uint(_ value: UInt64, bytes: Int) {
        for offset in (0..<bytes).reversed() { byte(UInt8(truncatingIfNeeded: value >> (offset * 8))) }
    }
    mutating func double(_ value: Double) { uint(value.bitPattern, bytes: 8) }
    mutating func uuid(_ value: UUID) { withUnsafeBytes(of: value.uuid) { data.append(contentsOf: $0) } }
}

private struct Reader {
    let data: Data
    var cursor: Data.Index
    init(_ data: Data) { self.data = data; cursor = data.startIndex }
    var remaining: Int { data.endIndex - cursor }
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw LinkError.truncated }
        let end = cursor + count
        defer { cursor = end }
        return data.subdata(in: cursor..<end)
    }
    mutating func byte() throws -> UInt8 {
        guard remaining >= 1 else { throw LinkError.truncated }
        defer { cursor += 1 }
        return data[cursor]
    }
    mutating func uint(bytes: Int) throws -> UInt64 {
        var value: UInt64 = 0
        for _ in 0..<bytes { value = (value << 8) | UInt64(try byte()) }
        return value
    }
    mutating func double() throws -> Double { Double(bitPattern: try uint(bytes: 8)) }
    mutating func uuid() throws -> UUID {
        let b = Array(try take(16))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
