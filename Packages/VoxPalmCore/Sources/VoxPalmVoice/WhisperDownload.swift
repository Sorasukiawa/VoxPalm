import CryptoKit
import Foundation

/// 下载 whisper.cpp 的模型：先下到模型目录里的临时文件，大小和 SHA-256 都对上才改成正式文件名。
/// 一个来源下不动就换下一个；中途断了或者取消了，记住断点，重试时从断点接着下（只记在这次运行里）。
public enum WhisperDownload {
    public enum Progress: Sendable, Equatable {
        case downloading(received: Int64, total: Int64, host: String)
        case verifying
    }

    public enum Failure: Error, CustomStringConvertible {
        case notEnoughSpace(needed: Int64)
        case badStatus(Int, host: String)
        case corrupted
        case network(String)

        public var description: String {
            switch self {
            case let .notEnoughSpace(needed):
                return "磁盘空间不够，要 \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .decimal))"
            case let .badStatus(code, host): return "\(host) 返回 \(code)"
            case .corrupted: return "下载的文件和官方的对不上，已经删掉"
            case let .network(message): return message
            }
        }
    }

    /// 下载并核对，成功后返回模型文件位置。progress 在后台线程回调，一秒十来次。取消外面的 Task 就停下。
    @discardableResult
    public static func run(_ model: WhisperModel, progress: @escaping @Sendable (Progress) -> Void) async throws -> URL {
        let directory = WhisperModel.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 临时文件和下好的模型同时在盘上，留一点余量
        let needed = model.bytes + model.bytes / 10
        if let free = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < needed {
            throw Failure.notEnoughSpace(needed: needed)
        }
        let partial = directory.appendingPathComponent(".\(model.fileName).download")
        defer { try? FileManager.default.removeItem(at: partial) }
        var lastError: Error = Failure.network("没有可用的下载地址")
        for source in model.sources {
            try Task.checkCancellation()
            let host = source.host ?? source.absoluteString
            do {
                try await fetch(source, to: partial) { received, total in
                    progress(.downloading(received: received, total: total > 0 ? total : model.bytes, host: host))
                }
                progress(.verifying)
                guard try matches(partial, model) else {
                    // 下坏的文件不留断点，换个来源从头下
                    resumeStore.take(source)
                    throw Failure.corrupted
                }
                try? FileManager.default.removeItem(at: model.fileURL)
                try FileManager.default.moveItem(at: partial, to: model.fileURL)
                // 模型能重新下载，不占时间机器的备份
                var file = model.fileURL
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? file.setResourceValues(values)
                return model.fileURL
            } catch let error where error is CancellationError {
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// 下载的文件和清单里记的一样：先比大小，再算 SHA-256（几百 MB 要一两秒）。
    static func matches(_ file: URL, _ model: WhisperModel) throws -> Bool {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        guard Int64(size) == model.bytes else { return false }
        return try sha256(of: file) == model.sha256
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 一次下载

    /// 断点：下到一半断了、被取消时系统给的续传数据，按下载地址存
    static let resumeStore = ResumeStore()

    final class ResumeStore: @unchecked Sendable {
        private let lock = NSLock()
        private var data: [URL: Data] = [:]

        func put(_ value: Data?, for url: URL) {
            lock.lock()
            data[url] = value
            lock.unlock()
        }

        @discardableResult
        func take(_ url: URL) -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return data.removeValue(forKey: url)
        }
    }

    private static func fetch(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let delegate = FetchDelegate(destination: destination, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        // 连不上的来源（比如在中国大陆连 Hugging Face）20 秒没动静就换下一个
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = resumeStore.take(url).map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel { resumeStore.put($0, for: url) }
        }
    }

    private final class FetchDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let destination: URL
        let progress: @Sendable (Int64, Int64) -> Void
        var continuation: CheckedContinuation<Void, Error>?
        private var moveError: Error?
        private var lastReport = Date.distantPast

        init(destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) {
            self.destination = destination
            self.progress = progress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            // 每收一小块都会回调，界面一秒刷十来次就够了
            let now = Date()
            guard now.timeIntervalSince(lastReport) > 0.1 || totalBytesWritten == totalBytesExpectedToWrite else { return }
            lastReport = now
            progress(totalBytesWritten, totalBytesExpectedToWrite)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // 系统给的临时文件回调一结束就删，要当场挪走
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                moveError = Failure.badStatus(http.statusCode, host: downloadTask.originalRequest?.url?.host ?? "下载地址")
                return
            }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                moveError = error
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let continuation = continuation
            self.continuation = nil
            if let error = error as? URLError {
                if error.code == .cancelled {
                    continuation?.resume(throwing: CancellationError())
                    return
                }
                // 断在半路的留着断点，下次接着下
                if let url = task.originalRequest?.url { WhisperDownload.resumeStore.put(error.downloadTaskResumeData, for: url) }
                continuation?.resume(throwing: Failure.network(Self.describe(error, host: task.originalRequest?.url?.host)))
            } else if let error = error ?? moveError {
                continuation?.resume(throwing: error)
            } else {
                continuation?.resume()
            }
        }

        static func describe(_ error: URLError, host: String?) -> String {
            let host = host ?? "下载地址"
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost: return "网络断了"
            case .timedOut: return "连 \(host) 超时"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "连不上 \(host)"
            default: return "\(host)：\(error.localizedDescription)"
            }
        }
    }
}
