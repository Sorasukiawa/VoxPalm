import Foundation
import Observation
import VoxPalmVoice

/// whisper.cpp 模型的下载状态，设置页的 whisper.cpp 卡片用。
/// 下载在后台跑，关掉设置窗口也不停；退出 App 就停，下次从头下（断点只记在这次运行里）。
@MainActor
@Observable
final class WhisperModels {
    enum Status: Equatable {
        case downloading(received: Int64, total: Int64, host: String)
        case verifying
        case failed(String)
    }

    /// 正在下载或者下载失败的模型；不在这里的看 downloaded
    private(set) var status: [String: Status] = [:]
    /// 模型目录里已经有的（清单里的 id）
    private(set) var downloaded: Set<String> = []
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    func refresh() {
        downloaded = Set(WhisperModel.catalog.filter(\.isDownloaded).map(\.id))
    }

    func isDownloaded(_ model: WhisperModel) -> Bool { downloaded.contains(model.id) }

    /// 设置里选的模型能不能用：清单里的要下好，自己选的文件要还在
    func isReady(_ settings: WhisperSettings) -> Bool {
        settings.usesCustomFile ? (try? settings.resolvedModelURL()) != nil : isDownloaded(settings.model)
    }

    /// 开始下载；失败后再点就是重试，能从断点接着下。
    func download(_ model: WhisperModel) {
        guard tasks[model.id] == nil else { return }
        status[model.id] = .downloading(received: 0, total: model.bytes, host: model.sources.first?.host ?? "")
        log.info("开始下载 whisper.cpp 模型 \(model.id, privacy: .public)")
        // 这个对象跟着 App 一直在（AppModel 持有），下载任务直接拿着它，下完就放手。
        tasks[model.id] = Task {
            let result: Error?
            do {
                try await WhisperDownload.run(model) { progress in
                    Task { @MainActor in self.report(progress, for: model) }
                }
                result = nil
            } catch {
                result = error
            }
            finish(model, error: result)
        }
    }

    func cancel(_ model: WhisperModel) {
        tasks[model.id]?.cancel()
    }

    func delete(_ model: WhisperModel) throws {
        try model.delete()
        refresh()
    }

    /// 调试：画界面截图时摆出下载中、失败的样子
    func simulate(_ value: Status?, for model: WhisperModel) {
        status[model.id] = value
    }

    private func report(_ progress: WhisperDownload.Progress, for model: WhisperModel) {
        // 下载结束以后才到的进度不要了，免得把「已下载」又盖回「正在下载」
        guard tasks[model.id] != nil else { return }
        switch progress {
        case let .downloading(received, total, host): status[model.id] = .downloading(received: received, total: total, host: host)
        case .verifying: status[model.id] = .verifying
        }
    }

    private func finish(_ model: WhisperModel, error: Error?) {
        tasks[model.id] = nil
        switch error {
        case nil:
            status[model.id] = nil
            log.info("whisper.cpp 模型 \(model.id, privacy: .public) 下载好了")
        case is CancellationError:
            status[model.id] = nil
        case let error?:
            status[model.id] = .failed("\(error)")
            log.error("whisper.cpp 模型 \(model.id, privacy: .public) 下载失败：\(String(describing: error), privacy: .public)")
        }
        refresh()
    }
}
