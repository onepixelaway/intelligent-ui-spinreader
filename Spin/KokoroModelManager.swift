import Foundation
import Combine

enum KokoroPaths {
    // KokoroSwift uses MLX.loadArrays which only accepts .safetensors. The hexgrad repo
    // ships a PyTorch .pth that MLX cannot read; prince-canuma re-publishes the same
    // weights as safetensors for MLX consumption.
    static let modelFileName = "kokoro-v1_0.safetensors"
    static let modelDownloadURL = URL(string: "https://huggingface.co/prince-canuma/Kokoro-82M/resolve/main/kokoro-v1_0.safetensors")!
    static let modelExpectedBytes: Int64 = 327_115_152

    private static let legacyModelFileNames = ["kokoro-v1_0.pth"]

    static let directory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("KokoroTTS", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var modelURL: URL {
        directory.appendingPathComponent(modelFileName)
    }

    /// Removes cached files from earlier builds (e.g. the .pth that MLX cannot load).
    static func purgeLegacyModelFiles() {
        for name in legacyModelFileNames {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    static var isModelDownloaded: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }

    /// Stricter than `isModelDownloaded`: verifies the file is at least mostly there.
    /// Used before instantiating KokoroTTS, since WeightLoader crashes on partial files.
    static var isModelReady: Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: modelURL.path) else {
            return false
        }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return size >= 100_000_000
    }
}

enum KokoroDownloadState: Equatable {
    case idle
    case downloading(received: Int64, total: Int64)
    case completed
    case failed(String)

    var isActive: Bool {
        if case .downloading = self { return true }
        return false
    }
}

@MainActor
final class KokoroModelManager: NSObject, ObservableObject {
    static let shared = KokoroModelManager()

    @Published private(set) var state: KokoroDownloadState = .idle

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?

    override private init() {
        super.init()
    }

    var isDownloaded: Bool { KokoroPaths.isModelDownloaded }

    func cancel() {
        task?.cancel()
        task = nil
        continuation = nil
        state = .idle
    }

    func download() async throws -> URL {
        // Drop any model file from earlier builds (e.g. .pth) before deciding readiness.
        KokoroPaths.purgeLegacyModelFiles()

        if KokoroPaths.isModelReady {
            state = .completed
            return KokoroPaths.modelURL
        }

        if case .downloading = state {
            throw NSError(domain: "KokoroModelManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Download already in progress"])
        }

        state = .downloading(received: 0, total: KokoroPaths.modelExpectedBytes)

        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = false
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 60 * 60
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let task = session.downloadTask(with: KokoroPaths.modelDownloadURL)
            self.task = task
            task.resume()
        }
    }
}

extension KokoroModelManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : KokoroPaths.modelExpectedBytes
        Task { @MainActor [weak self] in
            self?.state = .downloading(received: totalBytesWritten, total: total)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // URLSession treats HTTP errors (404, 500, etc.) as "successful" downloads of the error body.
        // Reject non-2xx so a tiny error page never reaches WeightLoader.loadWeights (which uses try!).
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            let err = NSError(
                domain: "KokoroModelManager",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Download failed: HTTP \(http.statusCode)"]
            )
            Task { @MainActor [weak self] in
                self?.finishWithError(err)
            }
            return
        }

        let dst = KokoroPaths.modelURL
        do {
            if FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.removeItem(at: dst)
            }
            try FileManager.default.moveItem(at: location, to: dst)
        } catch {
            Task { @MainActor [weak self] in
                self?.finishWithError(error)
            }
            return
        }

        // Sanity check: if the file is implausibly small, treat as a failed download so we don't
        // hand a corrupt file to KokoroSwift on the next play.
        let size = (try? FileManager.default.attributesOfItem(atPath: dst.path)[.size] as? NSNumber)?.int64Value ?? 0
        if size < KokoroPaths.modelExpectedBytes / 2 {
            try? FileManager.default.removeItem(at: dst)
            let err = NSError(
                domain: "KokoroModelManager",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Downloaded file is too small (\(size) bytes); the model may have moved."]
            )
            Task { @MainActor [weak self] in
                self?.finishWithError(err)
            }
            return
        }

        Task { @MainActor [weak self] in
            self?.finishWithSuccess(dst)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor [weak self] in
            // moveItem path already triggered finish on success; skip if continuation gone
            self?.finishWithError(error)
        }
    }

    @MainActor
    private func finishWithSuccess(_ url: URL) {
        state = .completed
        let cont = continuation
        continuation = nil
        task = nil
        session?.invalidateAndCancel()
        session = nil
        cont?.resume(returning: url)
    }

    @MainActor
    private func finishWithError(_ error: Error) {
        guard let cont = continuation else { return }
        state = .failed(error.localizedDescription)
        continuation = nil
        task = nil
        session?.invalidateAndCancel()
        session = nil
        cont.resume(throwing: error)
    }
}

enum KokoroByteFormatter {
    static func megabytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.0f MB", mb)
    }
}
