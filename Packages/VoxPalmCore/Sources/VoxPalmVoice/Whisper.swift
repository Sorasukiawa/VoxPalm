import AVFoundation
import Foundation
import os
import whisper

// MARK: - 模型

/// whisper.cpp 能在设置里下载的模型。文件来自 whisper.cpp 官方在 Hugging Face 上的仓库（ggerganov/whisper.cpp），
/// 大小和 SHA-256 照那里的记录写死，下载完逐字节核对。模型不随 App 打包。
public struct WhisperModel: Identifiable, Hashable, Sendable {
    public let id: String
    /// 设置里显示的短名字
    public let title: String
    public let summary: String
    public let bytes: Int64
    public let sha256: String

    public var fileName: String { "ggml-\(id).bin" }

    /// 下载来源，按顺序试：Hugging Face 打不开（比如在中国大陆）再试它的国内镜像。文件一样，下完都要核对 SHA-256。
    public var sources: [URL] {
        ["huggingface.co", "hf-mirror.com"].compactMap { URL(string: "https://\($0)/ggerganov/whisper.cpp/resolve/main/\(fileName)") }
    }

    public static let catalog: [WhisperModel] = [
        WhisperModel(id: "small-q5_1", title: "小", summary: "体积较小，Intel 芯片的 Mac 默认用它；效果和速度还需按设备验证",
                     bytes: 190_085_487, sha256: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"),
        WhisperModel(id: "large-v3-turbo-q5_0", title: "均衡", summary: "Apple 芯片的 Mac 默认用它；已有单机中文转写测试，结果仅供参考",
                     bytes: 574_041_195, sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"),
        WhisperModel(id: "large-v3-turbo-q8_0", title: "更准", summary: "8 位量化版本，体积更大；与其他档位的准确率差异尚未对照验证",
                     bytes: 874_188_075, sha256: "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1"),
    ]

    /// 这台 Mac 默认用哪个：Apple 芯片用「均衡」；Intel 芯片先用体积较小的模型，实际速度仍需真机验证。
    public static var recommended: WhisperModel {
        #if arch(arm64)
        return catalog[1]
        #else
        return catalog[0]
        #endif
    }

    public static func find(_ id: String) -> WhisperModel? { catalog.first { $0.id == id } }

    /// 下载的模型放在哪。App 启动时设成配置文件旁边的 Models（默认 ~/Library/Application Support/VoxPalm/Models），
    /// 用 VOXPALM_CONFIG 调试时跟着测试配置走，不碰真正的模型。
    public static var directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VoxPalm/Models", isDirectory: true)

    public var fileURL: URL { Self.directory.appendingPathComponent(fileName) }

    /// 只有核对过的文件才会放进模型目录，所以在就算下好了。
    public var isDownloaded: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    public var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal) }

    /// 删掉下载的模型（能重新下）；正读在内存里的也放掉。
    public func delete() throws {
        try FileManager.default.removeItem(at: fileURL)
        WhisperEngine.shared.unload()
    }
}

/// whisper.cpp 的设置（存在配置的 voice.whisper 里）。
public struct WhisperSettings: Codable, Hashable, Sendable {
    /// 用清单里的哪个模型；`custom` 表示用 modelPath 指的文件
    public var modelID: String
    /// 自己选的模型文件
    public var modelPath: String?

    public static let customID = "custom"

    public init(modelID: String = WhisperModel.recommended.id, modelPath: String? = nil) {
        self.modelID = modelID
        self.modelPath = modelPath
    }

    /// 以前的版本调本机的 whisper-cli，只存了程序路径和自己选的模型文件：选过文件的接着用它，程序路径不要了。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelPath = try c.decodeIfPresent(String.self, forKey: .modelPath)
        modelID = try c.decodeIfPresent(String.self, forKey: .modelID) ?? (modelPath != nil ? Self.customID : WhisperModel.recommended.id)
    }

    public var usesCustomFile: Bool { modelID == Self.customID }

    /// 选的清单模型；不认识的 id（以后清单改了）当成这台 Mac 的推荐模型
    public var model: WhisperModel { WhisperModel.find(modelID) ?? .recommended }

    /// 转写要用的模型文件；还没下载、没选文件就报错。
    public func resolvedModelURL() throws -> URL {
        if usesCustomFile {
            guard let modelPath, FileManager.default.fileExists(atPath: modelPath) else { throw TranscriberError.whisperNotConfigured }
            return URL(fileURLWithPath: modelPath)
        }
        guard model.isDownloaded else { throw TranscriberError.whisperModelMissing(model.title) }
        return model.fileURL
    }
}

// MARK: - 转写

/// 老系统的兜底：whisper.cpp 内置在 App 里（官方预编译的 xcframework，Apple 芯片上用 Metal 加速），模型在设置里下载。
public struct WhisperTranscriber: Transcriber {
    public var name: String { "whisper.cpp" }
    private let model: URL

    public init(settings: WhisperSettings) throws {
        model = try settings.resolvedModelURL()
    }

    /// 内置的 whisper.cpp 版本号。官方预编译包按构建号打，版本号带「-dev」后缀，显示时去掉。
    public static var version: String {
        let raw = String(cString: whisper_version())
        return raw.hasSuffix("-dev") ? String(raw.dropLast(4)) : raw
    }

    /// 按下说话键时先把模型读进内存，松手后少等一会。没下载好就什么也不做，转写时再报错。
    public static func prepare(settings: WhisperSettings) {
        guard let url = try? settings.resolvedModelURL() else { return }
        WhisperEngine.shared.preload(url)
    }

    public func transcribe(_ buffers: [AVAudioPCMBuffer], locale: Locale) async throws -> String {
        guard !buffers.isEmpty else { return "" }
        let samples = Self.padded(try AudioConversion.whisperSamples(buffers))
        let text = try await WhisperEngine.shared.transcribe(samples, model: model, locale: locale)
        let chinese = ["zh", "yue"].contains(locale.language.languageCode?.identifier ?? "")
        return TranscriptCleaner.clean(chinese ? TranscriptCleaner.widenChinesePunctuation(text) : text)
    }

    /// whisper.cpp 不转不到 1 秒的声音（直接返回空），「好的」这种短句后面补一点静音。
    static func padded(_ samples: [Float]) -> [Float] {
        let minimum = 17_600 // 1.1 秒（16 kHz）
        guard samples.count < minimum else { return samples }
        return samples + [Float](repeating: 0, count: minimum - samples.count)
    }

    /// 告诉模型说的是什么语言，再给一句开头提示：中文不给提示时常常简繁混着出。
    /// 粤语要 large-v3 系列的模型才认得（词表里有粤语），更老的模型当中文转。
    static func decoding(for locale: Locale, knowsCantonese: Bool) -> (language: String, prompt: String?) {
        let code = locale.language.languageCode?.identifier ?? "auto"
        switch code {
        case "zh":
            let traditional = locale.language.script == .hanTraditional || ["TW", "HK", "MO"].contains(locale.language.region?.identifier ?? "")
            return ("zh", traditional ? "以下是國語的句子。" : "以下是普通话的句子。")
        case "yue":
            return (knowsCantonese ? "yue" : "zh", "以下是粤语的句子。")
        default:
            return (code, nil)
        }
    }
}

/// 管 whisper.cpp 的上下文：读模型要零点几秒到一两秒，读一次留着用，5 分钟没用再放掉（大模型占几百 MB 内存）。
/// 同一个上下文不能同时用，所有调用排在一个串行队列上；转写要算一阵，也不占 Swift 并发的线程。
final class WhisperEngine: @unchecked Sendable {
    static let shared = WhisperEngine()
    static let keepAlive: TimeInterval = 300

    private let queue = DispatchQueue(label: "com.sorasukiawa.VoxPalm.whisper", qos: .userInitiated)
    private var context: OpaquePointer?
    private var loadedPath: String?
    private var releaseWork: DispatchWorkItem?
    private var exitHookInstalled = false

    private init() {
        // whisper.cpp 默认把加载过程一行行打到标准错误；只留出错的，记进系统日志。
        // 「没找到 Core ML 模型」不算错：官方预编译包带 Core ML 加速，没有对应的 Core ML 模型时自动用普通的算法。
        whisper_log_set({ level, text, _ in
            guard level == GGML_LOG_LEVEL_ERROR, let text else { return }
            let message = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.contains("Core ML") else { return }
            whisperLog.error("whisper.cpp：\(message, privacy: .public)")
        }, nil)
    }

    func preload(_ model: URL) {
        queue.async {
            _ = try? self.load(model)
            self.scheduleRelease()
        }
    }

    func transcribe(_ samples: [Float], model: URL, locale: Locale) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.run(samples, model: model, locale: locale) })
                self.scheduleRelease()
            }
        }
    }

    func unload() {
        queue.async { self.free() }
    }

    // 下面都只在 queue 上调

    private func load(_ model: URL) throws -> OpaquePointer {
        if let context, loadedPath == model.path { return context }
        free()
        let started = Date()
        var params = whisper_context_default_params()
        params.use_gpu = true
        guard let loaded = whisper_init_from_file_with_params(model.path, params) else {
            throw TranscriberError.whisperFailed("读不了模型文件「\(model.lastPathComponent)」：不是 whisper.cpp 的 ggml 模型，或者文件坏了")
        }
        whisperLog.info("whisper.cpp 读入模型 \(model.lastPathComponent, privacy: .public)，用时 \(Date().timeIntervalSince(started), format: .fixed(precision: 2)) 秒")
        context = loaded
        loadedPath = model.path
        if !exitHookInstalled {
            exitHookInstalled = true
            // ggml 在进程退出时检查 Metal 显存都还回去了没有，没还就 abort：用完 5 分钟内退出掌声会崩一下（2026-10-22 实测）。
            // 退出前先放掉上下文。要在第一次读模型之后登记：退出时后登记的先跑，才排在 ggml 自己的清理前面。
            atexit { WhisperEngine.shared.freeBeforeExit() }
        }
        return loaded
    }

    /// 退出时调：在队列上放掉上下文，最多等 2 秒（正在转写的话等它转完）。
    private func freeBeforeExit() {
        let done = DispatchSemaphore(value: 0)
        queue.async {
            self.free()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }

    private func run(_ samples: [Float], model: URL, locale: Locale) throws -> String {
        let context = try load(model)
        // 词表比 large-v2 及以前的多一个（51866 个）的是 large-v3 系列，认得粤语
        let (language, prompt) = WhisperTranscriber.decoding(for: locale, knowsCantonese: whisper_model_n_vocab(context) >= 51866)
        // 和 whisper-cli 的默认一样用束搜索（5 条），比贪心解码准
        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        params.beam_search.beam_size = 5
        params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 1)))
        params.no_timestamps = true
        params.no_context = true
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        let status = language.withCString { languagePointer in
            (prompt ?? "").withCString { promptPointer in
                params.language = languagePointer
                params.initial_prompt = prompt == nil ? nil : promptPointer
                return samples.withUnsafeBufferPointer { whisper_full(context, params, $0.baseAddress, Int32($0.count)) }
            }
        }
        guard status == 0 else { throw TranscriberError.whisperFailed("whisper_full 返回 \(status)") }
        var text = ""
        for index in 0..<whisper_full_n_segments(context) {
            if let segment = whisper_full_get_segment_text(context, index) { text += String(cString: segment) }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func scheduleRelease() {
        releaseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.free() }
        releaseWork = work
        queue.asyncAfter(deadline: .now() + Self.keepAlive, execute: work)
    }

    private func free() {
        if let context { whisper_free(context) }
        context = nil
        loadedPath = nil
    }
}

private let whisperLog = Logger(subsystem: "com.sorasukiawa.VoxPalm", category: "whisper")
