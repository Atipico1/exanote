import AppKit
import SwiftUI

/// Teams on Google Drive without a server. The owner's app creates a folder with an
/// exanote-team.json inside through the Drive API and shares it by email; Google Drive for desktop
/// then syncs that folder on every member's Mac, where the worker offers it as a sync location
/// (storage.py, TEAM_FILE). Meeting files never go through this API.
struct TeamMember: Decodable, Identifiable, Hashable {
    let id: String
    let type: String
    let role: String
    let emailAddress: String?
    let displayName: String?
}

@MainActor
final class TeamStore: ObservableObject {
    @Published private(set) var members: [String: [TeamMember]] = [:]
    @Published private(set) var busy = false
    @Published var notice: String?
    @Published var error: String?
    /// A team created or joined here that Drive for desktop has not synced yet; chosen once it appears.
    @Published var awaitedTeamID: String?
    @Published var awaitedFolderID: String?

    let account: GoogleAccount
    init(account: GoogleAccount) { self.account = account }

    static let teamFile = "exanote-team.json"
    private static let api = "https://www.googleapis.com/drive/v3"

    /// With authuser, Drive opens in the account signed in to Exanote rather than the browser's default one.
    static func folderURL(_ id: String, as email: String? = nil) -> URL {
        var url = URLComponents(string: "https://drive.google.com/drive/folders/\(id)")!
        if let email { url.queryItems = [URLQueryItem(name: "authuser", value: email)] }
        return url.url!
    }

    func createTeam(named rawName: String) async {
        let name = rawName.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !name.isEmpty, let owner = account.profile?.email else { return }
        await run {
            let teamID = UUID().uuidString.lowercased()
            struct Created: Decodable { let id: String }
            let folder: Created = try await self.drive("POST", "/files?fields=id", json: [
                "name": "Exanote · \(name)",
                "mimeType": "application/vnd.google-apps.folder",
                "description": "Exanote 팀 '\(name)'의 회의록이 동기화되는 폴더예요.",
                "appProperties": ["exanoteTeam": teamID],
            ])
            let team: [String: Any] = [
                "format": 1, "team_id": teamID, "name": name, "folder_id": folder.id, "owner": owner,
                "created_at": ISO8601DateFormatter().string(from: Date()),
            ]
            try await self.upload(Self.teamFile, into: folder.id, json: team)
            self.awaitedTeamID = teamID
            self.awaitedFolderID = folder.id
            self.notice = "'\(name)' 팀을 만들었어요. Google Drive가 폴더를 이 Mac에 내려받으면 저장 위치로 선택돼요."
        }
    }

    func loadMembers(of team: WorkspaceOption) async {
        guard let folderID = team.folder_id else { return }
        do {
            struct List: Decodable { let permissions: [TeamMember] }
            let list: List = try await drive("GET", "/files/\(folderID)/permissions?fields=permissions(id,type,role,emailAddress,displayName)")
            members[folderID] = list.permissions.sorted { ($0.role == "owner" ? 0 : 1, $0.emailAddress ?? "") < ($1.role == "owner" ? 0 : 1, $1.emailAddress ?? "") }
        } catch {
            members[folderID] = nil  // Only the owner's Exanote can read the member list.
        }
    }

    func invite(_ rawEmail: String, to team: WorkspaceOption) async {
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let folderID = team.folder_id, email.contains("@") else { error = "초대할 이메일 주소를 확인해 주세요."; return }
        let message = """
        Exanote 팀 '\(team.name)'에 초대했어요. 이 폴더를 열고 '내 드라이브에 바로가기 추가'를 누르면 \
        Mac의 Exanote 설정 ▸ 팀 목록에 나타나요. Exanote에서 '팀 참가'에 이 폴더 링크를 붙여 넣어도 돼요.
        """
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?")
        await run {
            do {
                struct Created: Decodable { let id: String }
                let _: Created = try await self.drive(
                    "POST", "/files/\(folderID)/permissions?sendNotificationEmail=true&fields=id&emailMessage=\(message.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")",
                    json: ["type": "user", "role": "writer", "emailAddress": email])
                self.notice = "\(email)에게 초대 메일을 보냈어요."
            } catch let failure as DriveError where failure.status == 403 {
                // drive.file cannot share a folder once it holds files Exanote did not create itself,
                // such as the meetings Drive for desktop uploaded. Google's own share dialog can.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(email, forType: .string)
                NSWorkspace.shared.open(Self.folderURL(folderID, as: self.account.profile?.email))
                self.notice = "Drive에서 팀 폴더를 열었어요. 폴더 이름 옆 ▾ ▸ 공유 ▸ 공유에서 이메일을 붙여 넣고(복사해 뒀어요) 전송을 누르세요."
            }
            await self.loadMembers(of: team)
        }
    }

    func remove(_ member: TeamMember, from team: WorkspaceOption) async {
        guard let folderID = team.folder_id else { return }
        await run {
            do {
                try await self.send("DELETE", "/files/\(folderID)/permissions/\(member.id)")
                self.notice = "\(member.emailAddress ?? "팀원")의 접근 권한을 없앴어요."
            } catch let failure as DriveError where failure.status == 403 {
                NSWorkspace.shared.open(Self.folderURL(folderID, as: self.account.profile?.email))
                self.notice = "Drive에서 팀 폴더를 열었어요. 폴더 이름 옆 ▾ ▸ 공유 ▸ 공유에서 \(member.emailAddress ?? "팀원") 옆 권한을 '액세스 권한 삭제'로 바꾸세요."
            }
            await self.loadMembers(of: team)
        }
    }

    /// Adds a shortcut to the shared team folder in My Drive so Drive for desktop syncs it. With
    /// drive.file, Google may refuse a folder another person's Exanote created; then the folder
    /// opens in Drive, where one "Add shortcut to Drive" click does the same.
    func join(link: String) async {
        guard let folderID = Self.folderID(in: link) else { error = "Google Drive 폴더 링크를 붙여 넣어 주세요."; return }
        await run {
            do {
                struct Folder: Decodable { let id: String; let name: String; let appProperties: [String: String]? }
                let folder: Folder = try await self.drive("GET", "/files/\(folderID)?fields=id,name,appProperties&supportsAllDrives=true")
                struct Created: Decodable { let id: String }
                let _: Created = try await self.drive("POST", "/files?fields=id", json: [
                    "name": folder.name, "mimeType": "application/vnd.google-apps.shortcut",
                    "shortcutDetails": ["targetId": folder.id],
                ])
                self.awaitedTeamID = folder.appProperties?["exanoteTeam"]
                self.awaitedFolderID = folder.id
                self.notice = "내 드라이브에 '\(folder.name)' 바로가기를 만들었어요. Google Drive가 내려받으면 팀이 나타나요."
            } catch let failure as DriveError where failure.status == 403 || failure.status == 404 {
                self.awaitedFolderID = folderID
                // "Add shortcut" lives in the item menu of Shared with me, not inside the folder itself.
                var shared = URLComponents(string: "https://drive.google.com/drive/shared-with-me")!
                if let email = self.account.profile?.email { shared.queryItems = [URLQueryItem(name: "authuser", value: email)] }
                NSWorkspace.shared.open(shared.url!)
                self.notice = "Drive의 공유 문서함을 열었어요. 팀 폴더 줄의 ⋮ ▸ 정리 ▸ 바로가기 추가 ▸ 내 드라이브를 누르면 팀이 자동으로 나타나요. 방금 초대받았다면 목록에 뜨기까지 몇 분 걸릴 수 있어요."
            }
        }
    }

    static func folderID(in link: String) -> String? {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in [#"/folders/([A-Za-z0-9_-]{10,})"#, #"[?&]id=([A-Za-z0-9_-]{10,})"#, #"^([A-Za-z0-9_-]{25,})$"#] {
            if let match = text.range(of: pattern, options: .regularExpression) {
                let found = String(text[match])
                return found.range(of: #"[A-Za-z0-9_-]{10,}$"#, options: .regularExpression).map { String(found[$0]) }
            }
        }
        return nil
    }

    private func run(_ work: @escaping () async throws -> Void) async {
        busy = true
        error = nil
        notice = nil
        defer { busy = false }
        do { try await work() } catch { self.error = error.localizedDescription }
    }

    private func drive<T: Decodable>(_ method: String, _ path: String, json: [String: Any]? = nil) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await send(method, path, json: json))
    }

    @discardableResult
    private func send(_ method: String, _ path: String, json: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: Self.api + path)!)
        request.httpMethod = method
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return try await perform(request)
    }

    private func upload(_ name: String, into folderID: String, json: [String: Any]) async throws {
        let boundary = "exanote-\(UUID().uuidString)"
        let metadata = try JSONSerialization.data(withJSONObject: ["name": name, "parents": [folderID], "mimeType": "application/json"])
        let content = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
        body += metadata + Data("\r\n--\(boundary)\r\nContent-Type: application/json\r\n\r\n".utf8)
        body += content + Data("\r\n--\(boundary)--\r\n".utf8)
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id")!)
        request.httpMethod = "POST"
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        try await perform(request)
    }

    @discardableResult
    private func perform(_ request: URLRequest) async throws -> Data {
        var request = request
        request.setValue("Bearer \(try await account.accessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            struct Failure: Decodable { struct Detail: Decodable { let message: String? }; let error: Detail? }
            throw DriveError(status: status, message: (try? JSONDecoder().decode(Failure.self, from: data))?.error?.message)
        }
        return data
    }
}

struct DriveError: LocalizedError {
    let status: Int
    let message: String?
    var errorDescription: String? {
        switch status {
        case 401: "Google에 다시 로그인해 주세요."
        case 403: "이 폴더에 대한 권한이 없어요." + (message.map { " (\($0))" } ?? "")
        case 404: "폴더를 찾을 수 없어요. 링크와 공유 여부를 확인해 주세요."
        default: "Google Drive 요청이 실패했어요" + (message.map { ": \($0)" } ?? ".")
        }
    }
}

/// Settings ▸ 팀: Google sign-in, the teams synced on this Mac, members and invitations.
struct TeamSection: View {
    @ObservedObject var workspace: WorkspaceStore
    @StateObject private var account: GoogleAccount
    @StateObject private var teams: TeamStore
    @State private var newTeam = ""
    @State private var inviteLink = ""
    @State private var invitee: [String: String] = [:]
    @State private var removal: (member: TeamMember, team: WorkspaceOption)?

    init(workspace: WorkspaceStore) {
        self.workspace = workspace
        let account = GoogleAccount()
        _account = StateObject(wrappedValue: account)
        _teams = StateObject(wrappedValue: TeamStore(account: account))
    }

    private var teamOptions: [WorkspaceOption] { workspace.overview?.options.filter { $0.kind == "team" } ?? [] }
    private var driveAccounts: Set<String> {
        Set(workspace.overview?.options.filter { $0.kind.hasPrefix("google") || $0.kind == "team" }.map(\.account) ?? [])
    }

    var body: some View {
        SettingsSection("팀") {
            if !workspace.googleDriveInstalled {
                SettingsRow(symbol: "externaldrive.badge.icloud", title: "Google Drive 데스크톱이 필요해요", detail: "팀 폴더를 이 Mac에 동기화해요") {
                    Link("다운로드", destination: URL(string: "https://www.google.com/drive/download/")!)
                }
            }
            if !account.configured {
                Text("이 빌드에는 Google 로그인이 설정되지 않았어요. 공유 드라이브를 저장 위치로 고르면 팀과 나눌 수 있어요.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let profile = account.profile {
                SettingsRow(symbol: "person.crop.circle", title: "Google 계정", detail: profile.email) {
                    Button("로그아웃") { Task { await account.signOut() } }
                }
                if workspace.googleDriveInstalled && !driveAccounts.contains(profile.email) {
                    Label("Google Drive 데스크톱에도 \(profile.email)로 로그인해야 팀 폴더가 이 Mac에 동기화돼요.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(teamOptions) { team in teamRow(team, me: profile.email) }
                if teams.awaitedFolderID != nil {
                    Label("Google Drive가 팀 폴더를 내려받는 중이에요…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    TextField("새 팀", text: $newTeam, prompt: Text("팀 이름"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(createTeam)
                    Button("만들기", action: createTeam).disabled(newTeam.trimmingCharacters(in: .whitespaces).isEmpty || teams.busy)
                }
                HStack {
                    TextField("팀 참가", text: $inviteLink, prompt: Text("초대받은 Drive 폴더 링크"))
                        .textFieldStyle(.roundedBorder)
                    Button("참가") { Task { await teams.join(link: inviteLink); inviteLink = "" } }
                        .disabled(inviteLink.isEmpty || teams.busy)
                }
            } else {
                SettingsRow(symbol: "person.crop.circle", title: "Google 계정", detail: account.busy ? "브라우저에서 로그인 중…" : "로그인하면 팀 폴더를 만들고 팀원을 초대할 수 있어요") {
                    if account.busy {
                        Button("취소") { account.cancelSignIn() }
                    } else {
                        Button("Google로 로그인") { Task { await account.signIn() } }
                    }
                }
                Text("로그인하면 팀 폴더를 만들고 팀원을 이메일로 초대할 수 있어요. Exanote는 자신이 만든 폴더와 파일에만 접근해요.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let message = teams.error ?? account.error {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.recording).font(.callout)
            } else if let notice = teams.notice {
                Text(notice).font(.callout).foregroundStyle(.secondary)
            }
        }
        .onChange(of: teamOptions) { _, options in adoptAwaitedTeam(options) }
        .task(id: teams.awaitedFolderID) {
            // Drive for desktop usually syncs a new folder within a minute; poll until it shows up.
            while teams.awaitedFolderID != nil && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await workspace.refresh()
            }
        }
        .confirmationDialog("팀원을 내보낼까요?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })) {
            if let removal {
                Button("\(removal.member.emailAddress ?? "팀원") 내보내기", role: .destructive) {
                    Task { await teams.remove(removal.member, from: removal.team) }
                }
            }
        } message: {
            Text("팀 폴더에 대한 접근 권한이 사라져요. 이미 그 사람의 Mac에 내려받은 회의록은 지워지지 않아요.")
        }
    }

    @ViewBuilder
    private func teamRow(_ team: WorkspaceOption, me: String) -> some View {
        let selected = workspace.selected?.path == team.path
        let owner = team.owner == me
        DisclosureGroup {
            if owner, let folderID = team.folder_id {
                ForEach(teams.members[folderID] ?? []) { member in
                    HStack {
                        Text(member.displayName ?? member.emailAddress ?? member.type)
                        Text(member.emailAddress ?? "").foregroundStyle(.secondary)
                        Spacer()
                        if member.role == "owner" {
                            Text("만든 사람").foregroundStyle(.secondary)
                        } else {
                            Button("내보내기") { removal = (member, team) }.buttonStyle(.link)
                        }
                    }
                    .font(.callout)
                }
                HStack {
                    TextField("초대", text: Binding(get: { invitee[team.path] ?? "" }, set: { invitee[team.path] = $0 }), prompt: Text("초대할 이메일"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { invite(team) }
                    Button("초대", action: { invite(team) }).disabled((invitee[team.path] ?? "").isEmpty || teams.busy)
                }
            } else {
                Text("팀원 초대와 관리는 팀을 만든 \(team.owner ?? "사람")이 해요.").font(.callout).foregroundStyle(.secondary)
            }
            if let folderID = team.folder_id {
                HStack {
                    Button("초대 링크 복사") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(TeamStore.folderURL(folderID).absoluteString, forType: .string)
                        teams.notice = "링크를 복사했어요. 초대받은 팀원이 Exanote ▸ 팀 참가에 붙여 넣으면 돼요."
                    }
                    Button("Drive에서 열기") { NSWorkspace.shared.open(TeamStore.folderURL(folderID)) }
                }
                .buttonStyle(.link)
            }
        } label: {
            HStack {
                Label(team.name, systemImage: "person.3")
                Spacer()
                if selected {
                    Label("저장 위치", systemImage: "checkmark.circle.fill").foregroundStyle(Color.success).font(.callout)
                } else {
                    Button("이 팀에 저장") { Task { await workspace.choose(team.path) } }
                }
            }
        }
        .task(id: team.folder_id) { if owner { await teams.loadMembers(of: team) } }
    }

    private func createTeam() {
        let name = newTeam
        Task {
            await teams.createTeam(named: name)
            if teams.error == nil { newTeam = "" }
        }
    }

    private func invite(_ team: WorkspaceOption) {
        let email = invitee[team.path] ?? ""
        Task {
            await teams.invite(email, to: team)
            if teams.error == nil { invitee[team.path] = "" }
        }
    }

    private func adoptAwaitedTeam(_ options: [WorkspaceOption]) {
        guard let match = options.first(where: {
            ($0.team_id != nil && $0.team_id == teams.awaitedTeamID) || ($0.folder_id != nil && $0.folder_id == teams.awaitedFolderID)
        }) else { return }
        teams.awaitedTeamID = nil
        teams.awaitedFolderID = nil
        teams.notice = "'\(match.name)' 팀 폴더가 동기화됐어요. 이제 이 팀에 회의가 저장돼요."
        Task { await workspace.choose(match.path) }
    }
}
