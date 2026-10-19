import SwiftUI
import MOICore

@MainActor final class AppModel: ObservableObject {
    let engine = InferenceEngine()
    lazy var server = HTTPServer(engine: engine)
    @Published var selectedID = UserDefaults.standard.string(forKey: "modelID") ?? "qwen3-0.6b"
    @Published var loadedID: String?
    @Published var operation = ""
    @Published var downloadProgress: Double?
    @Published var notice = "Choose a model to get this phone working."
    @Published var error: String?
    @Published var key = ""
    @Published var port = "8080"
    @Published var stats = DeviceStats()
    @Published var serving = false
    @Published var revision = 0
    private var timer: Timer?
    private var job: Task<Void, Never>?
    private var foreground = true
    /// Set when MOI was serving (or starting) as it went to the background; serving resumes on return.
    private var resumeOnForeground = false
    private var installerAttempted = false
    var selected: ModelSpec { ModelSpec.catalog.first { $0.id == selectedID } ?? ModelSpec.catalog[0] }
    var availableModels: [ModelSpec] { ModelSpec.catalog.filter { compatibilityIssue(for: $0) == nil } }
    var modelsDirectory: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Models") }
    var endpoint: String { "http://\(stats.addresses.first ?? "PHONE_IP"):\(port)" }
    var apiBaseURL: URL? {
        guard let address = stats.addresses.first, let number = UInt16(port), number >= 1024 else { return nil }
        return URL(string: "http://\(address):\(number)/v1")
    }
    var browserURL: URL? { apiBaseURL?.deletingLastPathComponent() }
    var pairingURL: URL? { browserURL.flatMap { server.pairingInvitation?.url(base: $0) } }
    var isWorking: Bool { !operation.isEmpty }
    var installed: Bool { FileManager.default.fileExists(atPath: file(for: selected).path) }
    func compatibilityIssue(for model: ModelSpec) -> String? {
        guard stats.totalGB > 0, stats.totalGB < model.minimumDeviceMemoryGB else { return nil }
        return "\(model.name) needs a phone with at least \(model.minimumDeviceMemoryGB) GB RAM (Gemma 4 E2B already exceeded the iPhone 11’s app memory limit). This phone has \(stats.totalGB) GB; choose a smaller model."
    }

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        do { key = try KeyStore.loadOrCreate(); try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true) }
        catch { self.error = error.localizedDescription }
        server.onChange = { [weak self] in
            guard let self else { return }
            self.serving = self.server.running
            UIApplication.shared.isIdleTimerDisabled = self.server.running || self.server.isStarting || self.isWorking
            self.revision += 1
        }
        server.canGenerate = { ProcessInfo.processInfo.thermalState == .nominal || ProcessInfo.processInfo.thermalState == .fair }
        server.browserOrigins = { [weak self] in
            guard let self, let number = UInt16(self.port) else { return [] }
            return Set(self.stats.addresses.map { "http://\($0):\(number)" })
        }
        sample()
        if !availableModels.contains(where: { $0.id == selectedID }) { selectedID = availableModels.first?.id ?? "qwen3-0.6b" }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.sample() } }
        #if DEBUG
        // Physical-device validation only. Release builds contain no startup override.
        let environment = ProcessInfo.processInfo.environment
        if let testModel = environment["MOI_TEST_MODEL"], ModelSpec.catalog.contains(where: { $0.id == testModel }),
           let testKey = environment["MOI_TEST_API_KEY"], testKey.count >= 24 {
            key = testKey
            selectedID = testModel
            Task {
                if environment["MOI_TEST_DOWNLOAD"] == "1", !self.installed {
                    self.download()
                    while self.isWorking { try? await Task.sleep(nanoseconds: 100_000_000) }
                    guard self.installed else { return }
                }
                self.load()
            }
        }
        #endif
    }
    func file(for model: ModelSpec) -> URL { modelsDirectory.appendingPathComponent(model.filename) }

    func prepareInstallerSetup() {
        let requestFile = modelsDirectory.deletingLastPathComponent().appendingPathComponent("MOI-setup.json")
        guard !installerAttempted, !isWorking, !serving, foreground,
              UIApplication.shared.applicationState == .active,
              FileManager.default.fileExists(atPath: requestFile.path) else { return }
        installerAttempted = true
        let request: InstallationRequest
        do {
            let size = try requestFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 4096 else { throw MOIError(400, "Installer request is too large. Rerun setup from the Mac.") }
            request = try InstallationRequest.parse(Data(contentsOf: requestFile))
        } catch { self.error = error.localizedDescription; return }
        selectedID = request.modelID
        let model = selected
        operation = "Preparing MOI"; error = nil
        UIApplication.shared.isIdleTimerDisabled = true
        job = Task {
            defer { operation = ""; job = nil; UIApplication.shared.isIdleTimerDisabled = server.running }
            do {
                if let issue = compatibilityIssue(for: model) { throw MOIError(400, issue) }
                try installationReceipt(request, state: "loading", message: "Verifying and loading \(model.name)…")
                try await engine.load(spec: model, file: file(for: model))
                try Task.checkCancellation()
                guard foreground else { throw CancellationError() }
                loadedID = model.id
                UserDefaults.standard.set(model.id, forKey: "modelID")
                try installationReceipt(request, state: "checking", message: "Running a short inference check on this iPhone…")
                let check = try ChatRequest.parse(APIJSON.encode(["model": model.id, "messages": [["role": "user", "content": "Say hello."]], "max_tokens": 8]))
                let result = try await engine.generate(check) { _ in }
                guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw MOIError(500, "The model loaded but returned an empty test reply. Rerun setup or choose Gemma 3.")
                }
                try Task.checkCancellation()
                guard foreground else { throw CancellationError() }
                try server.start(port: 8080, key: key, modelID: model.id)
                try installationReceipt(request, state: "starting", message: "Allow Local Network access and keep MOI open on Wi-Fi.")
                for _ in 0..<600 {
                    try Task.checkCancellation()
                    guard foreground else { throw CancellationError() }
                    if server.running && !stats.addresses.isEmpty { break }
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                guard server.running, !stats.addresses.isEmpty else {
                    throw MOIError(503, "Join Wi-Fi and allow MOI's Local Network access, then rerun setup from the Mac.")
                }
                try installationReceipt(request, state: "ready", message: "MOI is ready. Open Connect and scan the QR to chat.", verified: true)
                try FileManager.default.removeItem(at: requestFile)
            } catch {
                server.stop()
                let message = error is CancellationError ? "Setup was interrupted. Keep MOI open and rerun setup from the Mac." : error.localizedDescription
                self.error = message
                try? installationReceipt(request, state: "error", message: message)
            }
        }
    }

    private func installationReceipt(_ request: InstallationRequest, state: String, message: String, verified: Bool = false) throws {
        notice = message
        let receipt: [String: Any] = ["id": request.id, "state": state, "model": request.modelID,
                                     "message": message, "inference_verified": verified, "serving": server.running,
                                     "endpoint": browserURL?.absoluteString ?? ""]
        let destination = modelsDirectory.deletingLastPathComponent().appendingPathComponent("MOI-setup-result.json")
        try APIJSON.encode(receipt).write(to: destination, options: [.atomic, .completeFileProtection])
    }
    func sample() {
        stats = DeviceStats.read(); server.refreshPairing(); revision += 1
        #if DEBUG
        if ProcessInfo.processInfo.environment["MOI_TEST_MODEL"] != nil {
            let report: [String: Any] = ["endpoint": endpoint, "loaded_model": loadedID ?? "", "operation": operation,
                                       "error": error ?? server.lastError ?? "", "app_memory_mb": stats.memoryMB,
                                       "available_memory_mb": stats.availableMB, "physical_memory_gb": stats.totalGB,
                                       "thermal": stats.thermal, "api": server.stats,
                                       "model_choices": availableModels.map(\.id), "download_progress": downloadProgress ?? 0]
            try? APIJSON.encode(report).write(to: modelsDirectory.deletingLastPathComponent().appendingPathComponent("MOI-test-status.json"), options: .atomic)
            // Explicit test-only export of the short-lived invitation, never the main key.
            if ProcessInfo.processInfo.environment["MOI_TEST_PAIRING_EXPORT"] == "1", let url = pairingURL {
                try? Data(url.absoluteString.utf8).write(to: modelsDirectory.deletingLastPathComponent().appendingPathComponent("MOI-test-pairing-url.txt"), options: [.atomic, .completeFileProtection])
            }
        }
        #endif
    }
    func download() {
        guard !isWorking, !serving else { return }
        let model = selected
        if let issue = compatibilityIssue(for: model) { error = issue; return }
        guard stats.freeGB > Double(model.bytes) / 1_000_000_000 + 0.5 else { error = "Free some storage first; leave room for the model and temporary files."; return }
        operation = "Downloading"; downloadProgress = 0; error = nil
        UIApplication.shared.isIdleTimerDisabled = true
        job = Task {
            defer { operation = ""; downloadProgress = nil; job = nil; UIApplication.shared.isIdleTimerDisabled = server.running }
            do {
                let downloader = ModelDownloader()
                downloader.progress = { [weak self] value in Task { @MainActor in self?.downloadProgress = value } }
                let temp = try await downloader.download(model)
                defer { try? FileManager.default.removeItem(at: temp) }
                operation = "Verifying model"
                try await Task.detached(priority: .utility) { try model.verify(file: temp) }.value
                try Task.checkCancellation()
                let target = file(for: model)
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.moveItem(at: temp, to: target)
                var destination = target
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try destination.setResourceValues(values)
                notice = "\(model.name) is downloaded and verified. Load it next."
            } catch is CancellationError { notice = "Download stopped." }
            catch { self.error = error.localizedDescription }
        }
    }
    func load() {
        guard !isWorking, !server.busy, !serving else { return }
        let model = selected; let path = file(for: model)
        if let issue = compatibilityIssue(for: model) { error = issue; return }
        operation = "Loading \(model.name)"; error = nil; loadedID = nil
        UIApplication.shared.isIdleTimerDisabled = true
        job = Task {
            defer { operation = ""; job = nil; UIApplication.shared.isIdleTimerDisabled = server.running }
            do {
                try await engine.load(spec: model, file: path)
                guard foreground else { try await engine.unload(); return }
                loadedID = model.id
                UserDefaults.standard.set(model.id, forKey: "modelID")
                notice = "Model ready. Start serving to accept API calls."
                #if DEBUG
                if ProcessInfo.processInfo.environment["MOI_TEST_MODEL"] == model.id { toggleServer() }
                #endif
            } catch { self.error = error.localizedDescription }
        }
    }
    func toggleServer() {
        if serving || server.isStarting { server.stop(); resumeOnForeground = false; notice = "Server stopped."; return }
        guard let loadedID, let number = UInt16(port), number >= 1024 else { error = "Load a model and use a port from 1024 to 65535."; return }
        do { try server.start(port: number, key: key, modelID: loadedID); notice = "Keep MOI open while serving. Connect clients on the same trusted network." }
        catch { self.error = error.localizedDescription }
    }
    func unload() {
        guard !isWorking, !server.busy else { return }
        server.stop()
        Task {
            do { try await engine.unload(); loadedID = nil; notice = "Model unloaded. Memory released." }
            catch { self.error = error.localizedDescription }
        }
    }
    func rotateKey() {
        guard !serving, !server.busy else { return }
        do { key = try KeyStore.rotate(); notice = "New API key created. Update your clients." }
        catch { self.error = error.localizedDescription }
    }
    func cancelDownload() { job?.cancel() }
    func sceneChanged(_ phase: ScenePhase) {
        // Permission dialogs make the scene inactive without backgrounding the app.
        foreground = phase != .background
        if phase == .active {
            prepareInstallerSetup()
            resumeServingIfNeeded()
        }
        if phase == .background {
            resumeOnForeground = (serving || server.isStarting) && loadedID != nil
            server.stop(); job?.cancel()
            Task { await engine.cancel() }
            UIApplication.shared.isIdleTimerDisabled = false
            notice = resumeOnForeground
                ? "Serving paused while MOI is in the background. It resumes automatically when you return."
                : "MOI left the foreground."
        }
    }

    /// Restarts serving after returning to the foreground if MOI was serving when it left and the
    /// model is still loaded. The server reuses the port and retries briefly if it's still busy.
    private func resumeServingIfNeeded() {
        guard resumeOnForeground else { return }
        guard loadedID != nil else {
            resumeOnForeground = false
            notice = "The model was unloaded while MOI was in the background. Load it again to serve."
            return
        }
        guard !serving, !server.isStarting else { resumeOnForeground = false; return }
        guard !isWorking, !server.busy else {
            // A cancelled generation may still be unwinding; try again shortly while in the foreground.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.foreground else { return }
                self.resumeServingIfNeeded()
            }
            return
        }
        resumeOnForeground = false
        error = nil
        toggleServer()
        if error == nil { notice = "Welcome back. Serving resumed; keep MOI open while clients connect." }
    }
    func memoryWarning() {
        resumeOnForeground = false
        server.stop(); job?.cancel()
        notice = "iOS reported memory pressure. Serving stopped; choose a smaller model."
        Task {
            await engine.cancel()
            while server.busy || isWorking { try? await Task.sleep(nanoseconds: 100_000_000) }
            try? await engine.unload(); loadedID = nil
        }
    }
    func copyKey() { UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: key]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)]) }
}
