import SwiftUI

struct MeetingFolder: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
}

struct FolderRule: Decodable, Hashable {
    let series_id: String
    let title: String
    let folder_id: String
}

/// "앞으로 이 반복 일정도 이 폴더에 넣을까요?", offered after filing one occurrence.
struct FolderSuggestion: Decodable, Identifiable {
    let series_id: String
    let title: String
    let folder_id: String
    var id: String { series_id }
}

private struct FoldersState: Decodable {
    let folders: [MeetingFolder]
    let assignments: [String: String]
    let rules: [FolderRule]
    let suggestion: FolderSuggestion?
    let created: MeetingFolder?
}

/// The user's folders (worker: src/exanote/folders.py). Local and teammates' meetings file alike.
@MainActor
final class FolderStore: ObservableObject {
    struct Naming: Identifiable {
        let id = UUID()
        let folder: MeetingFolder?
        let moving: [String]
    }

    @Published private(set) var folders: [MeetingFolder] = []
    @Published private(set) var assignments: [String: String] = [:]
    @Published private(set) var rules: [FolderRule] = []
    @Published var suggestion: FolderSuggestion?
    @Published var naming: Naming?
    @Published var nameText = ""
    @Published var deleting: MeetingFolder?
    @Published var error: String?

    func folder(of meetingID: String) -> MeetingFolder? {
        assignments[meetingID].flatMap { id in folders.first { $0.id == id } }
    }

    func folder(id: String) -> MeetingFolder? { folders.first { $0.id == id } }

    func count(_ folder: MeetingFolder, among ids: Set<String>) -> Int {
        assignments.filter { $0.value == folder.id && ids.contains($0.key) }.count
    }

    func rules(for folder: MeetingFolder) -> [FolderRule] { rules.filter { $0.folder_id == folder.id } }

    func load() async {
        if let state: FoldersState = try? await LocalAPI.request("api/folders") { apply(state) }
    }

    func requestCreate(moving ids: [String] = []) {
        nameText = ""
        naming = Naming(folder: nil, moving: ids)
    }

    func requestRename(_ folder: MeetingFolder) {
        nameText = folder.name
        naming = Naming(folder: folder, moving: [])
    }

    func commitName() {
        guard let naming else { return }
        self.naming = nil
        let name = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        struct Body: Encodable { let name: String }
        Task {
            do {
                if let folder = naming.folder {
                    apply(try await LocalAPI.request("api/folders/\(folder.id)", method: "PATCH", body: JSONEncoder().encode(Body(name: name))))
                } else {
                    let state: FoldersState = try await LocalAPI.request("api/folders", method: "POST", body: JSONEncoder().encode(Body(name: name)))
                    apply(state)
                    if let created = state.created, !naming.moving.isEmpty { await move(naming.moving, to: created.id) }
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    func delete(_ folder: MeetingFolder) async {
        do { apply(try await LocalAPI.request("api/folders/\(folder.id)", method: "DELETE")) }
        catch { self.error = error.localizedDescription }
    }

    /// folderID nil takes the meetings out of their folder.
    func move(_ ids: [String], to folderID: String?) async {
        struct Body: Encodable { let meeting_ids: [String]; let folder_id: String? }
        do {
            let state: FoldersState = try await LocalAPI.request("api/folders/assignments", method: "PUT",
                                                               body: JSONEncoder().encode(Body(meeting_ids: ids, folder_id: folderID)))
            apply(state)
            suggestion = state.suggestion
        } catch { self.error = error.localizedDescription }
    }

    func acceptSuggestion() {
        guard let suggestion else { return }
        self.suggestion = nil
        struct Body: Encodable { let series_id: String; let title: String; let folder_id: String }
        Task {
            do {
                apply(try await LocalAPI.request("api/folders/rules", method: "POST",
                                                 body: JSONEncoder().encode(Body(series_id: suggestion.series_id, title: suggestion.title, folder_id: suggestion.folder_id))))
            } catch { self.error = error.localizedDescription }
        }
    }

    func forget(_ rule: FolderRule) async {
        let id = rule.series_id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? rule.series_id
        do { apply(try await LocalAPI.request("api/folders/rules/\(id)", method: "DELETE")) }
        catch { self.error = error.localizedDescription }
    }

    private func apply(_ state: FoldersState) {
        folders = state.folders
        assignments = state.assignments
        rules = state.rules
    }
}

/// Create, rename, delete and the rule suggestion, attached once to the main window.
struct FolderAlerts: ViewModifier {
    @ObservedObject var folders: FolderStore

    func body(content: Content) -> some View {
        content
            .alert(folders.naming?.folder == nil ? "새 폴더" : "폴더 이름 변경",
                   isPresented: Binding(get: { folders.naming != nil }, set: { if !$0 { folders.naming = nil } })) {
                TextField("폴더 이름", text: $folders.nameText)
                Button("취소", role: .cancel) {}
                Button(folders.naming?.folder == nil ? "만들기" : "저장") { folders.commitName() }.keyboardShortcut(.defaultAction)
            } message: {
                if let count = folders.naming?.moving.count, count > 0 {
                    Text("만든 폴더로 회의 \(count)개를 옮겨요.")
                }
            }
            .alert(suggestionTitle, isPresented: Binding(get: { folders.suggestion != nil }, set: { if !$0 { folders.suggestion = nil } })) {
                Button("앞으로도 넣기") { folders.acceptSuggestion() }.keyboardShortcut(.defaultAction)
                Button("이번만", role: .cancel) {}
            } message: {
                Text("같은 반복 일정으로 녹음한 다음 회의부터 자동으로 이 폴더에 들어가요. 폴더 화면에서 언제든 끌 수 있어요.")
            }
            .alert("‘\(folders.deleting?.name ?? "")’ 폴더를 삭제할까요?",
                   isPresented: Binding(get: { folders.deleting != nil }, set: { if !$0 { folders.deleting = nil } }), presenting: folders.deleting) { folder in
                Button("폴더 삭제", role: .destructive) { Task { await folders.delete(folder) } }
                Button("취소", role: .cancel) {}
            } message: { _ in
                Text("안에 있던 회의는 지워지지 않고 폴더 밖으로 나와요. 이 폴더의 자동 규칙도 함께 사라져요.")
            }
            .alert("폴더 작업을 완료하지 못했어요", isPresented: Binding(get: { folders.error != nil }, set: { if !$0 { folders.error = nil } })) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(folders.error ?? "")
            }
    }

    private var suggestionTitle: String {
        guard let suggestion = folders.suggestion else { return "" }
        return "앞으로 ‘\(suggestion.title)’도 ‘\(folders.folder(id: suggestion.folder_id)?.name ?? "이 폴더")’에 넣을까요?"
    }
}

/// "폴더로 이동" for one or more meetings, in context menus and the selection bar.
struct MoveToFolderMenu: View {
    let ids: [String]
    var title = "폴더로 이동"

    var body: some View {
        Menu(title) { FolderMenuItems(ids: ids) }
    }
}

struct FolderMenuItems: View {
    let ids: [String]
    @ObservedObject var folders = AppModel.shared.folders

    var body: some View {
        let current = Set(ids.compactMap { folders.assignments[$0] })
        ForEach(folders.folders) { folder in
            Button { Task { await folders.move(ids, to: folder.id) } } label: {
                if current == [folder.id] { Label(folder.name, systemImage: "checkmark") } else { Text(folder.name) }
            }
        }
        if !folders.folders.isEmpty { Divider() }
        Button("새 폴더…") { folders.requestCreate(moving: ids) }
        if !current.isEmpty {
            Button("폴더에서 빼기") { Task { await folders.move(ids, to: nil) } }
        }
    }
}

/// The folder chip on a meeting's page, including while it is being recorded.
struct FolderPicker: View {
    let meetingID: String
    @ObservedObject var folders = AppModel.shared.folders

    var body: some View {
        Menu {
            FolderMenuItems(ids: [meetingID])
        } label: {
            Label(folders.folder(of: meetingID)?.name ?? "폴더 없음", systemImage: "folder")
        }
        .menuStyle(.button)
        .buttonStyle(PillButtonStyle(compact: true))
        .fixedSize()
        .help("이 회의를 넣을 폴더")
    }
}
