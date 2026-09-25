import AppKit
import SwiftUI

struct AIModel: Decodable, Identifiable {
    let id: String
    let role: String
    let name: String
    let installed: Bool
    let downloading: Bool
    let bytes: Int64
    let expected_bytes: Int64
    let error: String?
    let overridden: Bool

    var progress: Double { expected_bytes > 0 ? min(0.99, Double(bytes) / Double(expected_bytes)) : 0 }
}

struct ModelsOverview: Decodable {
    let folder: String
    let total_bytes: Int64
    let busy: Bool
    let models: [AIModel]
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

@MainActor
final class ModelStore: ObservableObject {
    @Published private(set) var overview: ModelsOverview?
    @Published var error: String?

    var models: [AIModel] { overview?.models ?? [] }
    var missing: [AIModel] { models.filter { !$0.installed && !$0.downloading } }

    /// Polls for the app's lifetime: every second during a download, otherwise every few seconds.
    func watch() async {
        while !Task.isCancelled {
            await load()
            let downloading = models.contains { $0.downloading }
            try? await Task.sleep(for: .seconds(downloading ? 1 : 4))
        }
    }

    func load() async {
        if let overview: ModelsOverview = try? await LocalAPI.request("api/models") { self.overview = overview }
    }

    func install(_ ids: [String]) async {
        error = nil
        for id in ids {
            do { overview = try await LocalAPI.request("api/models/\(id)", method: "POST") }
            catch { self.error = error.localizedDescription }
        }
    }

    func delete(_ model: AIModel) async {
        error = nil
        do { overview = try await LocalAPI.request("api/models/\(model.id)", method: "DELETE") }
        catch { self.error = error.localizedDescription }
    }
}

/// The four models with their state: install, progress, delete. Settings and onboarding share it.
struct ModelListSection: View {
    @ObservedObject var store: ModelStore
    var title: String? = "AI 모델"
    var footer: String? = "모델은 이 Mac에서만 실행돼요. 지운 모델은 다음 회의를 처리할 때 자동으로 다시 받아요."
    /// nil hides the delete buttons (onboarding).
    var delete: ((AIModel) -> Void)? = nil

    var body: some View {
        SettingsSection(title, footer: footer) {
            if store.models.isEmpty {
                SettingsRow(symbol: "cpu", title: "모델 목록을 불러오는 중", detail: "로컬 작업 프로세스를 시작하고 있어요") {
                    ProgressView().controlSize(.small)
                }
            }
            ForEach(store.models) { model in
                SettingsRow(symbol: Self.symbol(model.id), title: model.name, detail: detail(model),
                            detailColor: model.error == nil ? .secondary : .recording) {
                    trailing(model)
                }
            }
            if store.missing.count > 1 {
                SettingsRow(title: "설치하지 않은 모델 \(store.missing.count)개",
                            detail: "모두 \(formatBytes(store.missing.reduce(0) { $0 + $1.expected_bytes }))") {
                    Button("모두 설치") { Task { await store.install(store.missing.map(\.id)) } }
                        .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                }
            }
            if let error = store.error { ErrorLine(text: error) }
        }
    }

    @ViewBuilder
    private func trailing(_ model: AIModel) -> some View {
        if model.downloading {
            SetupState(kind: .progress(model.progress))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("받는 중")
        } else if model.installed {
            if let delete {
                Button("삭제") { delete(model) }
                    .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                    .disabled(store.overview?.busy ?? true)
                    .help(store.overview?.busy == true ? "녹음하거나 회의를 처리하는 동안에는 지울 수 없어요" : "")
            } else {
                SetupState(kind: .done("설치됨"))
            }
        } else {
            SetupState(kind: .action("설치") { Task { await store.install([model.id]) } })
        }
    }

    private func detail(_ model: AIModel) -> String {
        var parts = [model.role]
        if model.downloading {
            parts.append("받는 중 \(formatBytes(model.bytes)) / \(formatBytes(model.expected_bytes))")
        } else if model.installed {
            parts.append(formatBytes(model.bytes))
        } else if let error = model.error {
            parts.append("설치하지 못했어요: \(error)")
        } else {
            parts.append("설치 안 됨 · \(formatBytes(model.expected_bytes))")
        }
        if model.overridden { parts.append("환경 변수로 다른 모델 사용 중") }
        return parts.joined(separator: " · ")
    }

    static func symbol(_ id: String) -> String {
        switch id {
        case "diarization": "person.2.wave.2"
        case "asr": "waveform"
        case "aligner": "text.alignleft"
        default: "text.quote"
        }
    }
}

/// Settings ▸ AI 모델: the models, the space they take, and removing Exanote with them.
struct ModelSettingsView: View {
    @ObservedObject var store: ModelStore
    @StateObject private var uninstaller = Uninstaller()
    @State private var deleting: AIModel?
    @State private var confirmingUninstall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            ModelListSection(store: store, title: nil, delete: { deleting = $0 })

            if let overview = store.overview {
                SettingsSection("저장 공간") {
                    SettingsRow(symbol: "internaldrive", title: "모델이 차지하는 공간 \(formatBytes(overview.total_bytes))",
                                detail: overview.folder.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                        Button("Finder에서 보기") { reveal(overview.folder) }.buttonStyle(PillButtonStyle(compact: true))
                    }
                }
            }

            SettingsSection("Exanote 제거", footer: "앱만 휴지통으로 옮기면 받은 모델은 이 Mac에 남아요.") {
                SettingsRow(symbol: "trash", title: "모델까지 지우고 앱 제거", detail: "AI 도구 연결도 함께 해제해요") {
                    if uninstaller.running {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Exanote 제거…") { confirmingUninstall = true }
                            .buttonStyle(PillButtonStyle(kind: .danger, compact: true))
                            .disabled(store.overview?.busy ?? false)
                    }
                }
                if let error = uninstaller.error { ErrorLine(text: error) }
            }
        }
        .task { await store.load() }
        .alert(deleteTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("삭제", role: .destructive) {
                if let model = deleting { Task { await store.delete(model) } }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("\(formatBytes(deleting?.bytes ?? 0))를 비워요. 이 모델이 없으면 다음 회의를 처리할 때 다시 받아요.")
        }
        .alert("Exanote를 제거할까요?", isPresented: $confirmingUninstall) {
            Button("모델만 지우고 제거", role: .destructive) { Task { await uninstaller.run(removeMeetings: false) } }
            Button("회의 기록까지 지우고 제거", role: .destructive) { Task { await uninstaller.run(removeMeetings: true) } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("AI 모델 \(formatBytes(store.overview?.total_bytes ?? 0))를 바로 삭제하고, AI 도구 연결을 해제한 뒤 앱을 휴지통으로 옮기고 종료해요. 회의 기록까지 지우면 녹음과 노트는 휴지통으로 옮겨져서, 휴지통을 비우기 전까지 되돌릴 수 있어요.")
        }
    }

    private var deleteTitle: String { "‘\(deleting?.name ?? "")’ 모델을 삭제할까요?" }

    private func reveal(_ folder: String) {
        let url = URL(fileURLWithPath: folder)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(AppPaths.data)
        }
    }
}


/// macOS does not tell an app when it is dragged to the Trash, so the models it downloaded would
/// stay behind. This removes them first, then moves the app itself to the Trash and quits.
@MainActor
final class Uninstaller: ObservableObject {
    @Published private(set) var running = false
    @Published var error: String?

    private struct Ignored: Decodable {}
    private struct Client: Decodable { let id: String; let state: String }
    private struct Clients: Decodable { let clients: [Client] }

    func run(removeMeetings: Bool) async {
        running = true
        error = nil
        defer { running = false }
        let files = FileManager.default

        // The worker may not be running; then nothing is reading or downloading a model.
        if let overview: ModelsOverview = try? await LocalAPI.request("api/models") {
            guard !overview.busy else {
                error = "녹음하거나 회의를 처리하는 중이에요. 끝난 뒤 다시 시도하세요."
                return
            }
            // An MCP entry would otherwise point at a Python that is about to be deleted.
            if let overview: Clients = try? await LocalAPI.request("api/integrations") {
                for client in overview.clients where client.state == "connected" || client.state == "outdated" {
                    _ = try? await LocalAPI.request("api/integrations/\(client.id)", method: "DELETE") as Ignored
                }
            }
            do { _ = try await LocalAPI.request("api/shutdown", method: "POST") as Ignored }
            catch { self.error = error.localizedDescription; return }
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(200))
                if (try? await LocalAPI.request("api/status") as Ignored) == nil { break }
            }
        }

        let models = AppPaths.data.appending(path: "models")
        do {
            if files.fileExists(atPath: models.path) { try files.removeItem(at: models) }
            if removeMeetings, files.fileExists(atPath: AppPaths.data.path) { try files.trashItem(at: AppPaths.data, resultingItemURL: nil) }
        } catch {
            self.error = "파일을 지우지 못했어요: \(error.localizedDescription)"
            return
        }

        // Only a distributed build carries its own Python; a development build stays in the repository.
        let app = Bundle.main.bundleURL
        if let python = Bundle.main.resourceURL?.appending(path: "python/bin/python3"), files.isExecutableFile(atPath: python.path) {
            do {
                try files.trashItem(at: app, resultingItemURL: nil)
            } catch {
                let alert = NSAlert()
                alert.messageText = "모델은 지웠지만 앱을 휴지통으로 옮기지 못했어요"
                alert.informativeText = "Finder에서 Exanote를 휴지통으로 직접 옮겨 주세요."
                alert.runModal()
                NSWorkspace.shared.activateFileViewerSelecting([app])
            }
        }
        NSApp.terminate(nil)
    }
}
