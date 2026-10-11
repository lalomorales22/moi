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
    @Published var hfToken = ""
    @Published var port = "8080"
    @Published var stats = DeviceStats()
    @Published var serving = false
    @Published var revision = 0
    private var timer: Timer?
    private var job: Task<Void, Never>?
    private var foreground = true
    var selected: ModelSpec { ModelSpec.catalog.first { $0.id == selectedID } ?? ModelSpec.catalog[0] }
    var modelsDirectory: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Models") }
    var endpoint: String { "http://\(stats.addresses.first ?? "PHONE_IP"):\(port)" }
    var apiBaseURL: URL? {
        guard let address = stats.addresses.first, let number = UInt16(port), number >= 1024 else { return nil }
        return URL(string: "http://\(address):\(number)/v1")
    }
    var isWorking: Bool { !operation.isEmpty }
    var installed: Bool { FileManager.default.fileExists(atPath: file(for: selected).path) }
    func compatibilityIssue(for model: ModelSpec) -> String? {
        guard stats.totalGB > 0, stats.totalGB < model.minimumDeviceMemoryGB else { return nil }
        return "This Gemma 4 build exceeded the iPhone 11’s app memory limit. MOI enables it only on phones with at least 6 GB RAM for further testing. This phone has \(stats.totalGB) GB; choose Qwen 3 instead."
    }

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        do { key = try KeyStore.loadOrCreate(); try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true) }
        catch { self.error = error.localizedDescription }
        server.onChange = { [weak self] in
            guard let self else { return }
            self.serving = self.server.running
            UIApplication.shared.isIdleTimerDisabled = self.server.running || self.isWorking
            self.revision += 1
        }
        server.canGenerate = { ProcessInfo.processInfo.thermalState == .nominal || ProcessInfo.processInfo.thermalState == .fair }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.sample() } }
        #if DEBUG
        // Physical-device validation only. Release builds contain no startup override.
        let environment = ProcessInfo.processInfo.environment
        if let testModel = environment["MOI_TEST_MODEL"], ModelSpec.catalog.contains(where: { $0.id == testModel }),
           let testKey = environment["MOI_TEST_API_KEY"], testKey.count >= 24 {
            key = testKey
            selectedID = testModel
            Task { self.load() }
        }
        #endif
    }
    func file(for model: ModelSpec) -> URL { modelsDirectory.appendingPathComponent(model.filename) }
    func sample() {
        stats = DeviceStats.read(); revision += 1
        #if DEBUG
        if ProcessInfo.processInfo.environment["MOI_TEST_MODEL"] != nil {
            let report: [String: Any] = ["endpoint": endpoint, "loaded_model": loadedID ?? "", "operation": operation,
                                       "error": error ?? server.lastError ?? "", "app_memory_mb": stats.memoryMB,
                                       "available_memory_mb": stats.availableMB, "physical_memory_gb": stats.totalGB,
                                       "thermal": stats.thermal, "api": server.stats]
            try? APIJSON.encode(report).write(to: modelsDirectory.deletingLastPathComponent().appendingPathComponent("MOI-test-status.json"), options: .atomic)
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
        let token = hfToken.trimmingCharacters(in: .whitespacesAndNewlines)
        hfToken = ""
        job = Task {
            defer { operation = ""; downloadProgress = nil; job = nil; UIApplication.shared.isIdleTimerDisabled = server.running }
            do {
                let downloader = ModelDownloader()
                downloader.progress = { [weak self] value in Task { @MainActor in self?.downloadProgress = value } }
                let temp = try await downloader.download(model, token: token)
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
        if serving || server.status == "Starting" { server.stop(); notice = "Server stopped."; return }
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
        foreground = phase == .active
        if phase == .background {
            server.stop(); job?.cancel()
            Task { await engine.cancel() }
            UIApplication.shared.isIdleTimerDisabled = false
            notice = "Serving paused because MOI left the foreground. Tap Start serving when you return."
        }
    }
    func memoryWarning() {
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
