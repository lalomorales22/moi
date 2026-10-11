import SwiftUI
import MOICore

@main struct MOIApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .preferredColorScheme(.dark)
                .onChange(of: phase) { _, value in model.sceneChanged(value) }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in model.memoryWarning() }
        }
    }
}

private let mint = Color(red: 0.63, green: 0.97, blue: 0.65)
private let ink = Color(red: 0.055, green: 0.07, blue: 0.075)
private let panel = Color(red: 0.10, green: 0.12, blue: 0.125)

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            dashboard.tabItem { Label("Station", systemImage: "waveform.path") }.tag(0)
            setup.tabItem { Label("Model", systemImage: "cpu") }.tag(1)
            connection.tabItem { Label("Connect", systemImage: "network") }.tag(2)
            activity.tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }.tag(3)
        }.tint(mint)
            .alert("MOI needs attention", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("Got it", role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
    }

    private var dashboard: some View {
        page {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MOI").font(.system(size: 54, weight: .black, design: .rounded)).tracking(-3)
                    Text("mom’s old iPhone").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Label(model.serving ? "LIVE" : "OFFLINE", systemImage: model.serving ? "circle.fill" : "circle")
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .foregroundStyle(model.serving ? mint : .secondary).padding(11).background(panel, in: Capsule()).padding(.top, 16)
            }
            card {
                Text(model.serving ? "A little phone.\nA working AI server." : "Give an old phone\nsomething new to do.")
                    .font(.system(size: 27, weight: .semibold, design: .rounded)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Image(systemName: "cpu")
                    Text(model.loadedID.flatMap { id in ModelSpec.catalog.first { $0.id == id }?.name } ?? "No model loaded")
                }.font(.subheadline).foregroundStyle(mint)
                Text(model.notice).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(action: { if model.loadedID == nil { tab = 1 } else { model.toggleServer() } }) {
                    HStack {
                        Text(model.loadedID == nil ? "Set up this phone" : model.serving ? "Stop serving" : "Start serving")
                        Spacer(); Image(systemName: model.serving ? "stop.fill" : "arrow.right")
                    }.font(.headline).padding(17).foregroundStyle(ink).background(mint, in: RoundedRectangle(cornerRadius: 15))
                }.disabled(model.isWorking || model.server.busy && !model.serving)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                metric("APP MEMORY", value: "\(model.stats.memoryMB)", unit: "MB", icon: "memorychip")
                metric("AVAILABLE TO APP", value: "\(model.stats.availableMB)", unit: "MB", icon: "square.stack.3d.up")
                metric("BATTERY", value: model.stats.battery, unit: model.stats.charging ? "charging" : "unplugged", icon: model.stats.charging ? "bolt.batteryblock" : "battery.75percent")
                metric("THERMAL STATE", value: model.stats.thermal, unit: "iOS pressure", icon: "thermometer.medium")
            }
            card {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        eyebrow("LAST GENERATION")
                        Text(model.server.lastGeneration?.tokensPerSecond.map { String(format: "%.1f", $0) } ?? "—")
                            .font(.system(size: 42, weight: .semibold, design: .rounded))
                        Text("tokens / second").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 10) {
                        Text("\(model.server.completed) completed")
                        Text("\(model.server.connectionCount) connections")
                        Text(model.server.busy ? "Generating…" : "Ready for work")
                            .foregroundStyle(mint)
                    }.font(.caption.monospaced())
                }
                Text("Measured by the inference engine. Your first request fills this in.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Keep MOI open and the phone powered. Serving keeps the display awake; leaving the app stops the server.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var setup: some View {
        page {
            title("A brain for MOI.", subtitle: "Download once. Run on this phone.")
            ForEach(ModelSpec.catalog) { spec in
                Button { model.selectedID = spec.id } label: {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: model.selectedID == spec.id ? "checkmark.circle.fill" : "circle").foregroundStyle(mint).font(.title2)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(spec.name).font(.headline).foregroundStyle(.white)
                            Text(spec.summary).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                            if model.compatibilityIssue(for: spec) != nil {
                                Text("More RAM required").font(.caption).foregroundStyle(.orange)
                            }
                            if model.loadedID == spec.id { Text("LOADED").font(.caption.monospaced()).foregroundStyle(mint) }
                        }
                        Spacer(minLength: 0)
                    }.padding(20).background(panel, in: RoundedRectangle(cornerRadius: 22))
                        .overlay(RoundedRectangle(cornerRadius: 22).stroke(model.selectedID == spec.id ? mint.opacity(0.6) : .clear))
                }.disabled(model.isWorking || model.serving || model.server.busy)
            }
            card {
                eyebrow("SETUP")
                Text(String(format: "%.1f GB free · %d GB physical memory", model.stats.freeGB, model.stats.totalGB)).font(.subheadline)
                Text(model.compatibilityIssue(for: model.selected) ?? "Qwen 3 is the tested starter for iPhone 11. Larger models need more memory; other phones still need physical-device testing.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if let progress = model.downloadProgress {
                    ProgressView(value: progress).tint(mint)
                    Text("\(model.operation) · \(Int(progress * 100))%").font(.caption.monospaced())
                    if model.operation == "Downloading" { Button("Cancel download") { model.cancelDownload() } }
                } else if model.isWorking {
                    HStack { ProgressView(); Text(model.operation).font(.subheadline) }
                } else {
                    Button(model.installed ? "Load model" : "Download model") { model.installed ? model.load() : model.download() }
                        .buttonStyle(.borderedProminent).tint(mint).foregroundStyle(ink)
                        .disabled(model.serving || model.server.busy || model.compatibilityIssue(for: model.selected) != nil)
                    if model.loadedID != nil { Button("Unload and free memory") { model.unload() }.disabled(model.server.busy) }
                }
                Text("1,024-token context · up to 256 output tokens · one request at a time").font(.caption).foregroundStyle(.secondary)
            }
            card {
                DisclosureGroup("Optional Hugging Face access") {
                    SecureField("Read token for gated downloads", text: $model.hfToken).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                    Text("If a model requires access, accept its terms first. This token is used only for the download and is not saved.").font(.caption).foregroundStyle(.secondary)
                }
                Link("Model card and terms ↗", destination: URL(string: "https://huggingface.co/\(model.selected.repository)")!)
                Text("Model downloads are verified with SHA-256 before loading. You can also copy a catalog model into MOI → Models using Finder file sharing.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var connection: some View {
        page {
            title("Meet your server.", subtitle: "Same Wi-Fi. A URL. Your private key.")
            card {
                eyebrow("API BASE URL")
                Text(model.endpoint + "/v1").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                if model.stats.addresses.isEmpty { Text("Join Wi-Fi to get a LAN address.").font(.caption).foregroundStyle(.orange) }
                HStack { Text("Port"); Spacer(); TextField("8080", text: $model.port).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 90).disabled(model.serving) }
                Button("Copy base URL") { UIPasteboard.general.string = model.endpoint + "/v1" }.buttonStyle(.bordered)
                Text("Bonjour discovery: _moi._tcp").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            card {
                eyebrow("API KEY")
                Text("moi_••••••••••••••••").font(.body.monospaced())
                Button("Copy API key") { model.copyKey() }.buttonStyle(.borderedProminent).tint(mint).foregroundStyle(ink)
                Button("Create a new key") { model.rotateKey() }.disabled(model.serving || model.server.busy)
                Text("Stored in this phone’s Keychain. Clipboard copy expires in two minutes. Stop serving before rotating the key.").font(.caption).foregroundStyle(.secondary)
            }
            card {
                eyebrow("CLIENT SETTINGS")
                LabeledContent("Model", value: model.loadedID ?? model.selectedID)
                LabeledContent("Authentication", value: "Bearer key")
                LabeledContent("Endpoint", value: "/chat/completions")
                Text("Use an OpenAI-compatible client with this base URL. Text messages and SSE streaming are supported. Tools, images, audio, and embeddings are not enabled.").font(.caption).foregroundStyle(.secondary)
            }
            Text("This version uses unencrypted HTTP on a trusted local network. Keep it off public Wi-Fi and don’t port-forward it to the internet.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var activity: some View {
        page {
            title("Work, as it happens.", subtitle: "Request metadata stays in memory.")
            card {
                LabeledContent("Server", value: model.server.status)
                LabeledContent("Completed", value: String(model.server.completed))
                LabeledContent("Errors / rejected", value: String(model.server.failed))
                LabeledContent("Active connections", value: String(model.server.connectionCount))
                if let error = model.server.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
                ForEach(model.server.peers, id: \.self) { peer in Text(peer).font(.caption.monospaced()).foregroundStyle(mint) }
            }
            if model.server.events.isEmpty {
                card {
                    Image(systemName: "network").font(.largeTitle).foregroundStyle(mint)
                    Text("Waiting for the first hello.").font(.headline)
                    Text("API requests show up here. Prompts, responses, and keys are never included in this feed.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            ForEach(model.server.events) { event in
                card {
                    HStack { Text(event.route).font(.caption.monospaced()); Spacer(); Text(String(event.status)).foregroundStyle(event.status < 400 ? mint : .orange) }
                    HStack { Text(event.peer); Spacer(); Text(event.time, style: .time) }.font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func page<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView { VStack(alignment: .leading, spacing: 18, content: content).padding(22).padding(.bottom, 24).frame(maxWidth: 640) }
            .frame(maxWidth: .infinity).background(ink)
    }
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16, content: content).frame(maxWidth: .infinity, alignment: .leading).padding(20).background(panel, in: RoundedRectangle(cornerRadius: 22))
    }
    private func title(_ text: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text).font(.system(size: 32, weight: .bold, design: .rounded))
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }.padding(.vertical, 12)
    }
    private func eyebrow(_ text: String) -> some View { Text(text).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.4).foregroundStyle(.secondary) }
    private func metric(_ title: String, value: String, unit: String, icon: String) -> some View {
        card {
            Image(systemName: icon).foregroundStyle(mint)
            eyebrow(title)
            Text(value).font(.system(size: 27, weight: .semibold, design: .rounded)).minimumScaleFactor(0.6).lineLimit(1)
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
    }
}
