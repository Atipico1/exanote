import AppKit
import SwiftUI

struct AIClient: Decodable, Identifiable {
    let id: String
    let name: String
    let state: String
    let install_url: String
}

/// The JSON block other MCP apps (Claude Desktop, Cursor and so on) accept.
struct ManualMCPConfig: Codable {
    struct Entry: Codable {
        let command: String
        let args: [String]
        let env: [String: String]?
    }
    let mcpServers: [String: Entry]
}

private struct IntegrationsOverview: Decodable {
    let clients: [AIClient]
    let manual: ManualMCPConfig
}

@MainActor
final class IntegrationStore: ObservableObject {
    @Published private(set) var clients: [AIClient] = []
    @Published private(set) var manual: ManualMCPConfig?
    @Published private(set) var working: String?
    @Published var error: String?

    func load() async {
        guard let overview: IntegrationsOverview = try? await LocalAPI.request("api/integrations") else { return }
        clients = overview.clients
        manual = overview.manual
    }

    func toggle(_ client: AIClient) async {
        working = client.id
        error = nil
        defer { working = nil }
        do {
            let _: AIClient = try await LocalAPI.request("api/integrations/\(client.id)", method: client.state == "connected" ? "DELETE" : "POST")
        } catch {
            self.error = error.localizedDescription
        }
        await load()
    }

    func copyManual() -> Bool {
        guard let manual else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(manual), let text = String(data: data, encoding: .utf8) else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }
}

/// Settings section: register the read-only meeting-notes MCP server with one click.
struct AIConnectionsSection: View {
    var title: String? = "AI 도구 연결"
    @StateObject private var store = IntegrationStore()
    @State private var copied = false

    var body: some View {
        SettingsSection(title, footer: "연결하면 AI가 회의 목록, 요약, 전사를 읽고 키워드로 검색할 수 있어요. 읽기만 하고 고치거나 지우지 않아요. AI에게 보여 준 내용은 그 AI 서비스로 전송돼요.") {
            if store.clients.isEmpty {
                SettingsRow(symbol: "sparkles", title: "AI 도구를 찾는 중") { ProgressView().controlSize(.small) }
            }
            ForEach(store.clients) { client in
                SettingsRow(symbol: client.id == "codex" ? "terminal" : "sparkles", title: client.name, detail: detail(client)) {
                    control(client)
                }
                .accessibilityElement(children: .contain)
            }
            SettingsRow(symbol: "doc.on.clipboard", title: "다른 MCP 앱", detail: "Claude Desktop, Cursor처럼 JSON 설정을 붙여 넣는 앱") {
                Button(copied ? "복사됨" : "설정 복사") {
                    copied = store.copyManual()
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                }
                .buttonStyle(PillButtonStyle(compact: true))
                .disabled(store.manual == nil)
            }
            if let error = store.error { ErrorLine(text: error) }
        }
        .task { await store.load() }
    }

    @ViewBuilder
    private func control(_ client: AIClient) -> some View {
        if store.working == client.id {
            ProgressView().controlSize(.small)
        } else {
            switch client.state {
            case "connected":
                HStack(spacing: 10) {
                    SetupState(kind: .done("연결됨"))
                    Button("해제") { Task { await store.toggle(client) } }.buttonStyle(PillButtonStyle(kind: .quiet, compact: true))
                }
            case "outdated":
                Button("다시 연결") { Task { await store.toggle(client) } }.buttonStyle(PillButtonStyle(kind: .primary, compact: true))
            case "disconnected":
                Button("연결") { Task { await store.toggle(client) } }.buttonStyle(PillButtonStyle(kind: .primary, compact: true))
            default:
                if let url = URL(string: client.install_url) {
                    Link("설치 안내", destination: url).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.brandText)
                }
            }
        }
    }

    private func detail(_ client: AIClient) -> String {
        switch client.state {
        case "connected": "새로 시작한 세션부터 회의 노트를 읽을 수 있어요"
        case "outdated": "예전 설치 위치를 가리키고 있어요. 다시 연결하세요"
        case "disconnected": "버튼 하나로 연결해요. 따로 설정할 것은 없어요"
        default: "이 Mac에 설치되어 있지 않아요"
        }
    }
}
