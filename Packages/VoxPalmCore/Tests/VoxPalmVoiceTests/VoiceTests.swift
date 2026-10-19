import AVFoundation
import Foundation
import Testing
@testable import VoxPalmVoice

@Test func whisper参数带语言和简体提示() {
    let args = WhisperCLITranscriber.arguments(model: "/m.bin", audio: "/a.wav", locale: Locale(identifier: "zh-CN"))
    #expect(args.starts(with: ["-m", "/m.bin", "-f", "/a.wav", "-l", "zh", "-nt", "-np"]))
    #expect(args.contains("--prompt"))
    #expect(!WhisperCLITranscriber.arguments(model: "m", audio: "a", locale: Locale(identifier: "en-US")).contains("--prompt"))
}

@Test func 没配置whisper会报错() {
    #expect(throws: TranscriberError.self) {
        _ = try WhisperCLITranscriber(configuration: .init(executablePath: "/nope", modelPath: "/nope.bin"))
    }
}

private func sine(seconds: Double, rate: Double, channels: AVAudioChannelCount) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
    let frames = AVAudioFrameCount(seconds * rate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for c in 0..<Int(channels) {
        for i in 0..<Int(frames) { buffer.floatChannelData![c][i] = sin(Float(i) * 2 * .pi * 440 / Float(rate)) * 0.3 }
    }
    return buffer
}

@Test func 转成16k单声道时长不变() throws {
    let buffers = [sine(seconds: 0.5, rate: 48_000, channels: 2), sine(seconds: 0.5, rate: 48_000, channels: 2)]
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let converted = try AudioConversion.convert(buffers, to: target)
    #expect(abs(AudioConversion.duration(converted) - 1.0) < 0.02)
    #expect(converted.first?.format.sampleRate == 16_000)
}

@Test func 写出whisper用的WAV() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("voxpalm-test-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try AudioConversion.writeWhisperWAV([sine(seconds: 1, rate: 44_100, channels: 1)], to: url)
    let file = try AVAudioFile(forReading: url)
    #expect(file.fileFormat.sampleRate == 16_000)
    #expect(file.fileFormat.channelCount == 1)
    #expect(abs(Double(file.length) / 16_000 - 1.0) < 0.02)
}

@Test func 中文转写去掉多余空格() {
    #expect(TranscriptCleaner.clean("你好 ，这是掌声的语音测试 ，按住说话") == "你好，这是掌声的语音测试，按住说话")
    #expect(TranscriptCleaner.clean("用 Claude Code 写代码") == "用 Claude Code 写代码")
    #expect(TranscriptCleaner.clean("按住 说话") == "按住说话")
    #expect(TranscriptCleaner.clean("hello world") == "hello world")
}
