import AVFoundation
import Foundation
import Speech

/// 内置转写。整段说完再转（按住说话一般就几秒，整段转更稳）。
public protocol Transcriber {
    var name: String { get }
    func transcribe(_ buffers: [AVAudioPCMBuffer], locale: Locale) async throws -> String
}

public enum TranscriberError: Error, CustomStringConvertible {
    case unsupportedLocale(String)
    case whisperNotConfigured
    case whisperFailed(String)
    case unavailable(String)

    public var description: String {
        switch self {
        case let .unsupportedLocale(id): return "系统转写不支持这种语言：\(id)"
        case .whisperNotConfigured: return "还没设置 whisper.cpp：需要 whisper-cli 程序和一个 ggml 模型文件"
        case let .whisperFailed(message): return "whisper.cpp 转写失败：\(message)"
        case let .unavailable(message): return message
        }
    }
}

public enum TranscriberChoice: String, Codable, CaseIterable, Sendable {
    /// macOS 26 以上用系统转写，更老的系统用 whisper.cpp
    case automatic
    case appleSpeech
    case whisper

    public var title: String {
        switch self {
        case .automatic: return "自动（新系统用系统转写，老系统用 whisper.cpp）"
        case .appleSpeech: return "系统转写（macOS 26 以上）"
        case .whisper: return "whisper.cpp"
        }
    }
}

public enum TranscriberFactory {
    public static var appleSpeechAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    public static func make(_ choice: TranscriberChoice, whisper: WhisperCLITranscriber.Configuration) throws -> Transcriber {
        switch choice {
        case .automatic:
            if #available(macOS 26, *) { return SpeechAnalyzerTranscriber() }
            return try WhisperCLITranscriber(configuration: whisper)
        case .appleSpeech:
            if #available(macOS 26, *) { return SpeechAnalyzerTranscriber() }
            throw TranscriberError.unavailable("系统转写要 macOS 26 以上")
        case .whisper:
            return try WhisperCLITranscriber(configuration: whisper)
        }
    }
}

// MARK: - Apple SpeechAnalyzer

/// macOS 26 起的系统转写（完全在本机）。优先用 SpeechTranscriber，不支持的语言退到 DictationTranscriber。
@available(macOS 26, *)
public struct SpeechAnalyzerTranscriber: Transcriber {
    public var name: String { "系统转写" }

    public init() {}

    public func transcribe(_ buffers: [AVAudioPCMBuffer], locale: Locale) async throws -> String {
        guard !buffers.isEmpty else { return "" }
        if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
            return try await run(transcriber, buffers: buffers) { results in
                var text = ""
                for try await result in results where result.isFinal { text += String(result.text.characters) }
                return text
            } results: { transcriber.results }
        }
        if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = DictationTranscriber(locale: supported, preset: .shortDictation)
            return try await run(transcriber, buffers: buffers) { results in
                var text = ""
                for try await result in results where result.isFinal { text += String(result.text.characters) }
                return text
            } results: { transcriber.results }
        }
        throw TranscriberError.unsupportedLocale(locale.identifier)
    }

    /// 准备好语言模型（没装就让系统下载），返回状态说明。
    public static func prepare(locale: Locale) async throws -> String {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return "SpeechTranscriber 不支持 \(locale.identifier)，会改用听写模型"
        }
        let module = SpeechTranscriber(locale: supported, preset: .transcription)
        try await ensureAssets(module)
        return "\(supported.identifier) 模型已就绪"
    }

    static func ensureAssets(_ module: any SpeechModule) async throws {
        if await AssetInventory.status(forModules: [module]) >= .installed { return }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }

    private func run<Results: AsyncSequence>(
        _ module: any SpeechModule,
        buffers: [AVAudioPCMBuffer],
        collect: @escaping (Results) async throws -> String,
        results: () -> Results
    ) async throws -> String {
        try await Self.ensureAssets(module)
        let natural = buffers[0].format
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: natural) ?? natural
        let converted = try AudioConversion.convert(buffers, to: format)
        let analyzer = SpeechAnalyzer(modules: [module])
        let sequence = results()
        let collector = Task { try await collect(sequence) }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)
        for buffer in converted { continuation.yield(AnalyzerInput(buffer: buffer)) }
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return TranscriptCleaner.clean(try await collector.value)
    }
}

/// 转写结果的收尾：系统转写把几段结果拼起来时，中文之间、中文标点前后会多出空格。
public enum TranscriptCleaner {
    public static func clean(_ text: String) -> String {
        var result = ""
        let chars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        for (index, char) in chars.enumerated() {
            if char == " " {
                let previous = index > 0 ? chars[index - 1] : nil
                let next = index + 1 < chars.count ? chars[index + 1] : nil
                // 两个汉字之间、全角标点前后的空格不要；汉字和英文之间的空格保留。
                let bothWide = (previous.map(isWide) ?? false) && (next.map(isWide) ?? false)
                let nearPunctuation = [previous, next].contains { $0.map(isWidePunctuation) ?? false }
                if bothWide || nearPunctuation { continue }
            }
            result.append(char)
        }
        return result
    }

    static func isWidePunctuation(_ char: Character) -> Bool {
        char.unicodeScalars.contains { (0x3000...0x303F).contains($0.value) || (0xFF00...0xFF0F).contains($0.value) || (0xFF1A...0xFF20).contains($0.value) }
    }

    static func isWide(_ char: Character) -> Bool {
        char.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF: return true
            default: return false
            }
        }
    }
}

// MARK: - whisper.cpp

/// 老系统的兜底：调用本机的 whisper.cpp 命令行（whisper-cli）。模型文件由用户自己选。
public struct WhisperCLITranscriber: Transcriber {
    public struct Configuration: Codable, Hashable, Sendable {
        public var executablePath: String?
        public var modelPath: String?

        public init(executablePath: String? = nil, modelPath: String? = nil) {
            self.executablePath = executablePath
            self.modelPath = modelPath
        }

        /// 没指定程序路径时，到 Homebrew 的常见位置找。
        public var resolvedExecutable: String? {
            if let executablePath, FileManager.default.isExecutableFile(atPath: executablePath) { return executablePath }
            return ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"].first { FileManager.default.isExecutableFile(atPath: $0) }
        }
    }

    public var name: String { "whisper.cpp" }
    private let executable: String
    private let model: String

    public init(configuration: Configuration) throws {
        guard let executable = configuration.resolvedExecutable,
              let model = configuration.modelPath, FileManager.default.fileExists(atPath: model) else {
            throw TranscriberError.whisperNotConfigured
        }
        self.executable = executable
        self.model = model
    }

    public static func arguments(model: String, audio: String, locale: Locale) -> [String] {
        let language = locale.language.languageCode?.identifier ?? "auto"
        var args = ["-m", model, "-f", audio, "-l", language, "-nt", "-np"]
        // 给一句简体的开头提示，减少输出繁体。
        if language == "zh" { args += ["--prompt", "以下是普通话的句子。"] }
        return args
    }

    public func transcribe(_ buffers: [AVAudioPCMBuffer], locale: Locale) async throws -> String {
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("voxpalm-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        try AudioConversion.writeWhisperWAV(buffers, to: wav)
        let log = wav.deletingPathExtension().appendingPathExtension("log")
        defer { try? FileManager.default.removeItem(at: log) }
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Self.arguments(model: model, audio: wav.path, locale: locale)
        let output = Pipe()
        process.standardOutput = output
        // 日志写到临时文件，不用管道，免得日志太多把管道塞满卡住。
        process.standardError = try FileHandle(forWritingTo: log)
        do {
            try process.run()
        } catch {
            throw TranscriberError.whisperFailed(error.localizedDescription)
        }
        let data = await Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = (try? String(contentsOf: log, encoding: .utf8)) ?? "退出码 \(process.terminationStatus)"
            throw TranscriberError.whisperFailed(String(message.suffix(300)))
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
