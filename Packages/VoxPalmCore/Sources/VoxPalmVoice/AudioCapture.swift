import AVFoundation
import CoreAudio
import Foundation
import VoxPalmDevices

/// 直接从指定的收音设备录音（CoreAudio HAL），不改系统默认输入。回调在录音线程。
public final class AudioCapture {
    public enum CaptureError: Error, CustomStringConvertible {
        case noDevice
        case unsupportedFormat
        case coreAudio(String, OSStatus)

        public var description: String {
            switch self {
            case .noDevice: return "没有可用的收音设备"
            case .unsupportedFormat: return "这个收音设备的格式不支持"
            case let .coreAudio(step, status): return "CoreAudio \(step) 失败（\(status)）"
            }
        }
    }

    public var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    public private(set) var format: AVAudioFormat?
    public private(set) var deviceID: AudioObjectID?
    public var isRunning: Bool { procID != nil }

    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "voxpalm.audio-capture")

    public init() {}

    deinit {
        stop()
    }

    /// `deviceID` 为 nil 时用系统默认输入。
    public func start(deviceID requested: AudioObjectID?) throws {
        stop()
        let id = requested ?? AudioDevices.defaultInputID
        guard id != AudioObjectID(kAudioObjectUnknown), AudioDevices.device(id: id)?.hasInput == true else { throw CaptureError.noDevice }
        guard var asbd = Self.virtualInputFormat(id), asbd.mFormatID == kAudioFormatLinearPCM,
              let format = AVAudioFormat(streamDescription: &asbd) else { throw CaptureError.unsupportedFormat }
        self.format = format
        deviceID = id
        var newProc: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&newProc, id, queue) { [weak self] _, input, _, _, _ in
            self?.deliver(input, format: format)
        }
        guard status == noErr, let newProc else { throw CaptureError.coreAudio("创建录音回调", status) }
        status = AudioDeviceStart(id, newProc)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(id, newProc)
            throw CaptureError.coreAudio("开始录音", status)
        }
        procID = newProc
    }

    public func stop() {
        guard let procID, let deviceID else { return }
        AudioDeviceStop(deviceID, procID)
        AudioDeviceDestroyIOProcID(deviceID, procID)
        queue.sync {}
        self.procID = nil
    }

    private func deliver(_ list: UnsafePointer<AudioBufferList>, format: AVAudioFormat) {
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = source.first, first.mDataByteSize > 0 else { return }
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return }
        let frames = AVAudioFrameCount(Int(first.mDataByteSize) / bytesPerFrame)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        let target = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for (index, src) in source.enumerated() where index < target.count {
            guard let srcData = src.mData, let dstData = target[index].mData else { continue }
            memcpy(dstData, srcData, Int(min(src.mDataByteSize, target[index].mDataByteSize)))
        }
        onBuffer?(buffer)
    }

    static func virtualInputFormat(_ id: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioStreamID>.size) else { return nil }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &streams) == noErr, let stream = streams.first else { return nil }
        var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyVirtualFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(stream, &formatAddress, 0, nil, &formatSize, &asbd) == noErr else { return nil }
        return asbd
    }
}

/// 音频格式转换和文件读写。
public enum AudioConversion {
    /// 把一串缓冲转成目标格式（比如 16 kHz 单声道），一次性转完。
    public static func convert(_ buffers: [AVAudioPCMBuffer], to target: AVAudioFormat) throws -> [AVAudioPCMBuffer] {
        guard let source = buffers.first?.format else { return [] }
        if source == target { return buffers }
        guard let converter = AVAudioConverter(from: source, to: target) else { throw AudioCapture.CaptureError.unsupportedFormat }
        var queue = buffers[...]
        var output: [AVAudioPCMBuffer] = []
        let ratio = target.sampleRate / source.sampleRate
        while true {
            let capacity = AVAudioFrameCount(Double(4096) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { break }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if let next = queue.popFirst() {
                    inputStatus.pointee = .haveData
                    return next
                }
                inputStatus.pointee = .endOfStream
                return nil
            }
            if let error { throw error }
            if out.frameLength > 0 { output.append(out) }
            if status == .endOfStream || status == .error { break }
        }
        return output
    }

    public static func duration(_ buffers: [AVAudioPCMBuffer]) -> Double {
        buffers.reduce(0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
    }

    /// 读整个音频文件（调试用：用录好的声音代替麦克风）。
    public static func read(_ url: URL) throws -> [AVAudioPCMBuffer] {
        let file = try AVAudioFile(forReading: url)
        var result: [AVAudioPCMBuffer] = []
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { break }
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            result.append(buffer)
        }
        return result
    }

    /// 写 16 kHz 单声道 16 位 WAV（whisper.cpp 要这个格式）。
    public static func writeWhisperWAV(_ buffers: [AVAudioPCMBuffer], to url: URL) throws {
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false) else { return }
        let converted = try convert(buffers, to: mono)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        for buffer in converted { try file.write(from: buffer) }
    }
}
