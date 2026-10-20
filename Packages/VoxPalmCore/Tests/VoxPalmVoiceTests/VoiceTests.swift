import AVFoundation
import Foundation
import Testing
import CoreAudio
@testable import VoxPalmDevices
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

@Test func 边录边转格式时长不变() throws {
    // 麦克风每次只给十几毫秒，一段段送进同一个转换器，最后倒干净，总时长要和整段转一样
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let converter = try AudioConversion.StreamConverter(from: sine(seconds: 0.01, rate: 48_000, channels: 2).format, to: target)
    var converted: [AVAudioPCMBuffer] = []
    for _ in 0..<100 { converted += try converter.convert(sine(seconds: 0.01, rate: 48_000, channels: 2)) }
    converted += try converter.flush()
    #expect(abs(AudioConversion.duration(converted) - 1.0) < 0.02)
    #expect(converted.allSatisfy { $0.format.sampleRate == 16_000 })
    // 格式一样就原样交出去
    let same = try AudioConversion.StreamConverter(from: target, to: target)
    let piece = sine(seconds: 0.1, rate: 16_000, channels: 1)
    #expect(try same.convert(piece).first === piece)
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
    #expect(TranscriptCleaner.clean("吃个晚饭 ，顺便聊聊下个月的计划。。") == "吃个晚饭，顺便聊聊下个月的计划。")
    #expect(TranscriptCleaner.clean("二〇〇六年") == "二〇〇六年")
}

private func mic(_ id: AudioObjectID, _ uid: String, _ transport: String, isDefault: Bool = false) -> AudioDeviceInfo {
    AudioDeviceInfo(id: id, uid: uid, name: uid, manufacturer: nil, transport: transport, inputChannels: 1, outputChannels: 0,
                    nominalSampleRate: 16_000, availableSampleRates: [], inputStreamFormat: nil, isDefaultInput: isDefault,
                    isDefaultOutput: false, isDefaultSystemOutput: false, isRunningSomewhere: false)
}

@Test func 收音会被静音时改用Mac麦() {
    let dji = mic(1, "DJI", "Bluetooth", isDefault: true)
    let airpods = mic(2, "AirPods", "Bluetooth")
    let builtIn = mic(3, "BuiltIn", "Built-in")
    let virtual = mic(4, "Virtual", "Virtual")
    // 没有要避开的：跟随系统默认还是交给系统，选了就用选的
    #expect(MicRouting.resolve(selectedUID: nil, inputs: [dji, builtIn], muted: []) == .init(device: nil, avoided: nil))
    #expect(MicRouting.resolve(selectedUID: "AirPods", inputs: [dji, airpods], muted: ["DJI"]) == .init(device: airpods, avoided: nil))
    // 选的就是会静音的那支、或者跟随系统默认而默认正好是它：先换 Mac 自带的麦
    #expect(MicRouting.resolve(selectedUID: "DJI", inputs: [dji, airpods, builtIn], muted: ["DJI"]) == .init(device: builtIn, avoided: dji))
    #expect(MicRouting.resolve(selectedUID: nil, inputs: [dji, airpods, builtIn], muted: ["DJI"]) == .init(device: builtIn, avoided: dji))
    // 选的麦没连上、录音会落到默认输入上：一样要避开
    #expect(MicRouting.resolve(selectedUID: "USB", inputs: [dji, builtIn], muted: ["DJI"]) == .init(device: builtIn, avoided: dji))
    // 没有 Mac 自带的麦（合盖接外接显示器）：换下一个能用的，不用虚拟声卡
    #expect(MicRouting.resolve(selectedUID: nil, inputs: [virtual, dji, airpods], muted: ["DJI"]) == .init(device: airpods, avoided: dji))
    #expect(MicRouting.resolve(selectedUID: nil, inputs: [dji, virtual], muted: ["DJI"]) == .init(device: nil, avoided: dji))
}
