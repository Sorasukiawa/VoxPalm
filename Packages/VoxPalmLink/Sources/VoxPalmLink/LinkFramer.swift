import Foundation

/// 每个 transport 各持有一个实例。出错后不能复用，避免从损坏的字节流里猜边界。
public struct LinkFramer: Sendable {
    private var header = Data()
    private var body = Data()
    private var expected: Int?
    private var failed = false
    public var bufferedByteCount: Int { header.count + body.count }
    public init() {}

    /// 独立使用时输出完整消息体，交给 LinkCodec.decode；每次最多读取 16 KiB。
    /// 使用 LinkSession 时直接传入原始流片段，由会话内部完成分帧，不要再次去掉前缀。
    public mutating func append(_ bytes: Data) throws -> [Data] {
        guard !failed else { throw LinkError.decoderFailed }
        do {
            guard bytes.count <= LinkLimits.maximumReadBytes else { throw LinkError.oversized }
            var frames: [Data] = []
            var cursor = bytes.startIndex
            while cursor < bytes.endIndex {
                if expected == nil {
                    let count = min(4 - header.count, bytes.endIndex - cursor)
                    header.append(bytes[cursor..<(cursor + count)]); cursor += count
                    guard header.count == 4 else { break }
                    let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                    guard size > 0, size <= LinkLimits.maximumFrameBytes else { throw LinkError.oversized }
                    expected = Int(size); header.removeAll(keepingCapacity: true)
                }
                if let expected {
                    let count = min(expected - body.count, bytes.endIndex - cursor)
                    body.append(bytes[cursor..<(cursor + count)]); cursor += count
                    if body.count == expected {
                        frames.append(body); body = Data(); self.expected = nil
                    }
                }
            }
            return frames
        } catch {
            failed = true; header = Data(); body = Data(); expected = nil
            throw error
        }
    }

    /// 收到 EOF 时必须调用；半截报文不能被当成正常结束。
    public mutating func finish() throws {
        guard !failed else { throw LinkError.decoderFailed }
        if !header.isEmpty || expected != nil {
            failed = true; header = Data(); body = Data(); expected = nil
            throw LinkError.truncated
        }
        failed = true
    }
}
