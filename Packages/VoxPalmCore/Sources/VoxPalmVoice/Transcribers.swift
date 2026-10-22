import AVFoundation
import Foundation
import Speech

/// 内置转写，整段说完再转（按住说话一般就几秒，整段转标点最全）。说话时的实时预览见 `LivePreview`。
public protocol Transcriber {
    var name: String { get }
    func transcribe(_ buffers: [AVAudioPCMBuffer], locale: Locale) async throws -> String
}

/// 边说边转的预览：说话时把声音一段段送进去，随时报「到目前为止」的字，给浮窗和面板显示。
/// 只管显示，松手后出的字还是整段转的：预览要快，用的是系统的快速模式，标点几乎都会丢（2026-10-19 实测）。
public protocol LivePreview: AnyObject {
    /// 送一段声音，任何线程都能调
    func append(_ buffer: AVAudioPCMBuffer)
    /// 不看了（松手、按得太短、取消）
    func stop()
}

public enum TranscriberError: Error, CustomStringConvertible {
    case unsupportedLocale(String)
    /// 选了「自己的模型文件」但没选、或者文件不在了
    case whisperNotConfigured
    /// 清单里的模型还没下载（参数是模型的短名字）
    case whisperModelMissing(String)
    case whisperFailed(String)
    case unavailable(String)

    public var description: String {
        switch self {
        case let .unsupportedLocale(id): return "系统转写不支持这种语言：\(id)"
        case .whisperNotConfigured: return "还没选 whisper.cpp 的模型文件，在设置 › 语音里选"
        case let .whisperModelMissing(title): return "还没下载语音模型「\(title)」，在设置 › 语音里点下载"
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

    /// 这台 Mac 上这个选择实际用不用 whisper.cpp
    public static func usesWhisper(_ choice: TranscriberChoice) -> Bool {
        choice == .whisper || (choice == .automatic && !appleSpeechAvailable)
    }

    public static func make(_ choice: TranscriberChoice, whisper: WhisperSettings) throws -> Transcriber {
        if usesWhisper(choice) { return try WhisperTranscriber(settings: whisper) }
        if #available(macOS 26, *) { return SpeechAnalyzerTranscriber() }
        throw TranscriberError.unavailable("系统转写要 macOS 26 以上")
    }

    /// 能边说边转就开一个实时预览（macOS 26 以上的系统转写）；whisper.cpp 没有，返回 nil。
    /// onPartial 在后台线程回调，参数是到目前为止的字。
    public static func makePreview(_ choice: TranscriberChoice, locale: Locale, onPartial: @escaping (String) -> Void) -> LivePreview? {
        guard choice != .whisper else { return nil }
        if #available(macOS 26, *) { return SpeechAnalyzerPreview(locale: locale, onPartial: onPartial) }
        return nil
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

/// 系统转写的实时预览：开着一个 SpeechAnalyzer，声音一来就送进去，临时结果（volatile）随时报出来。
/// 模型没装好、格式还没定的时候先送来的声音排在队里，不会丢。
@available(macOS 26, *)
final class SpeechAnalyzerPreview: LivePreview, @unchecked Sendable {
    private let input: AsyncStream<AVAudioPCMBuffer>.Continuation
    private let work: Task<Void, Never>

    init(locale: Locale, onPartial: @escaping (String) -> Void) {
        let (raw, input) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.input = input
        work = Task {
            // 用系统的 progressive 预设（带 fastResults）：大约每秒出一次字。不带 fastResults 的话，
            // 临时结果要憋到声音送完才一起出来，说话时看不到字（2026-10-19 实测）。
            if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
                let module = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
                let texts = module.results.map { (text: String($0.text.characters), isFinal: $0.isFinal) }
                await Self.run(module, texts: texts, raw: raw, onPartial: onPartial)
            } else if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
                let module = DictationTranscriber(locale: supported, preset: .progressiveShortDictation)
                let texts = module.results.map { (text: String($0.text.characters), isFinal: $0.isFinal) }
                await Self.run(module, texts: texts, raw: raw, onPartial: onPartial)
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        input.yield(buffer)
    }

    func stop() {
        input.finish()
    }

    /// 出错（模型装不上、格式转不了）就不显示预览，整段转那边会照常报错。
    private static func run<Texts: AsyncSequence>(
        _ module: any SpeechModule,
        texts: Texts,
        raw: AsyncStream<AVAudioPCMBuffer>,
        onPartial: @escaping (String) -> Void
    ) async where Texts.Element == (text: String, isFinal: Bool) {
        let analyzer = SpeechAnalyzer(modules: [module])
        // 定稿的字一段段接起来；没定稿的那段会被后面的结果换掉。
        let collector = Task {
            var settled = ""
            for try await item in texts {
                if item.isFinal { settled += item.text }
                onPartial(TranscriptCleaner.clean(item.isFinal ? settled : settled + item.text))
            }
        }
        let (stream, feed) = AsyncStream<AnalyzerInput>.makeStream()
        do {
            try await SpeechAnalyzerTranscriber.ensureAssets(module)
            try await analyzer.start(inputSequence: stream)
            var converter: AudioConversion.StreamConverter?
            for await buffer in raw {
                if converter == nil {
                    let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: buffer.format) ?? buffer.format
                    converter = try AudioConversion.StreamConverter(from: buffer.format, to: format)
                }
                for piece in try converter?.convert(buffer) ?? [] { feed.yield(AnalyzerInput(buffer: piece)) }
            }
        } catch {
            // 预览出错不打扰用户，等着松手（raw 结束）再收拾
            for await _ in raw {}
        }
        feed.finish()
        await analyzer.cancelAndFinishNow()
        collector.cancel()
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
            // 系统转写在段和段的接缝处偶尔会多出一个标点（「下个月的计划。。」）
            if collapsible.contains(char), result.last == char { continue }
            result.append(char)
        }
        return result
    }

    /// 连着出现只留一个的标点（「〇〇」「——」这类本来就成对的不算）
    static let collapsible: Set<Character> = ["。", "，", "、", "；", "："]

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
