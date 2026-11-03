import AVFoundation
import Foundation

/// 单次录音的预算；不包含模型、格式转换或系统音频驱动的内存。
struct VoiceLimits {
    var recordingSeconds: Double = 300
    var recordingBytes: Int = 128 * 1024 * 1024
    var recordingBuffers: Int = 32_768
    var transcriptionSeconds: Double = 120
}

/// 由 VoiceSession 的音频锁保护。只保留预算内的前缀，巨大容量的小片段也不会占住整块内存。
struct RecordingBuffer {
    let limits: VoiceLimits
    private(set) var buffers: [AVAudioPCMBuffer] = []
    private(set) var seconds: Double = 0
    private(set) var bytes: Int = 0
    private(set) var limitReached = false

    mutating func append(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard !limitReached, input.frameLength > 0 else { return nil }
        let format = input.format
        let stride = Int(format.streamDescription.pointee.mBytesPerFrame)
        let list = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let bytesPerFrame = stride * list.count
        guard format.sampleRate.isFinite, format.sampleRate > 0, bytesPerFrame > 0,
              buffers.count < limits.recordingBuffers else {
            limitReached = true
            return nil
        }
        let availableTime = max(0, limits.recordingSeconds - seconds) * format.sampleRate
        let timeFrames = Int(min(Double(UInt32.max), availableTime.rounded(.down)))
        let memoryFrames = max(0, limits.recordingBytes - bytes) / bytesPerFrame
        let frames = min(Int(input.frameLength), timeFrames, memoryFrames)
        guard frames > 0,
              let kept = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            limitReached = true
            return nil
        }
        kept.frameLength = AVAudioFrameCount(frames)
        let target = UnsafeMutableAudioBufferListPointer(kept.mutableAudioBufferList)
        for i in list.indices {
            guard let source = list[i].mData, let destination = target[i].mData,
                  Int(list[i].mDataByteSize) >= frames * stride else {
                limitReached = true
                return nil
            }
            memcpy(destination, source, frames * stride)
        }
        buffers.append(kept)
        seconds += Double(frames) / format.sampleRate
        bytes += frames * bytesPerFrame
        limitReached = frames < Int(input.frameLength) || frames == timeFrames || frames == memoryFrames
            || buffers.count == limits.recordingBuffers
        return kept
    }
}
