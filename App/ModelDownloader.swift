import Foundation
import MOICore

final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    var progress: (@Sendable (Double) -> Void)?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var cancelled = false
    private var expectedBytes: Int64 = 0

    func download(_ model: ModelSpec, token: String) async throws -> URL {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock(); defer { lock.unlock() }
                guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                self.expectedBytes = model.bytes
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 3600
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                var request = URLRequest(url: model.url)
                if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
                let task = session.downloadTask(with: request)
                self.task = task; task.resume()
            }
        }, onCancel: { self.cancel() })
    }
    func cancel() {
        lock.lock(); cancelled = true; let current = task; lock.unlock()
        current?.cancel()
    }
    private func finish(_ result: Result<URL, Error>) {
        lock.lock(); let pending = continuation; continuation = nil; let current = session; session = nil; task = nil; lock.unlock()
        pending?.resume(with: result); current?.finishTasksAndInvalidate()
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > expectedBytes + 1024 { downloadTask.cancel(); return }
        progress?(min(1, Double(totalBytesWritten) / Double(expectedBytes)))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
            finish(.failure(MOIError(400, "Download refused. For gated models, accept the model terms on Hugging Face and supply a read token."))); return
        }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".litertlm")
        do { try FileManager.default.moveItem(at: location, to: destination); finish(.success(destination)) }
        catch { finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}
