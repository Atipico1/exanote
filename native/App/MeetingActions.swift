import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    /// Sent by Edit ▸ 찾기 (⌘F); the visible search field takes focus.
    static let focusSearch = Notification.Name("ExanoteFocusSearch")
}

/// Rename, delete, reveal, copy and export, shared by menus, context menus and buttons.
@MainActor
final class MeetingActions: ObservableObject {
    struct Target: Identifiable, Equatable {
        let id: String
        let title: String
    }

    @Published var renaming: Target?
    @Published var renameText = ""
    @Published var deleting: Target?
    @Published var failure: String?

    private weak var store: MeetingStore?
    private weak var workspace: WorkspaceStore?
    private weak var nav: Navigator?

    func attach(store: MeetingStore, workspace: WorkspaceStore, nav: Navigator) {
        self.store = store
        self.workspace = workspace
        self.nav = nav
    }

    var syncFolderName: String? { workspace?.selected?.name }

    func requestRename(id: String, title: String) {
        renameText = title
        renaming = Target(id: id, title: title)
    }

    func commitRename() {
        guard let target = renaming else { return }
        renaming = nil
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != target.title else { return }
        Task {
            await workspace?.rename(meetingID: target.id, title: title)
            try? await store?.refresh()
            await store?.loadSelected()
        }
    }

    func requestDelete(id: String, title: String) {
        deleting = Target(id: id, title: title)
    }

    func commitDelete() {
        guard let target = deleting else { return }
        deleting = nil
        Task {
            struct Deleted: Decodable { let folder: String }
            do {
                let result: Deleted = try await LocalAPI.request("api/meetings/\(target.id)", method: "DELETE")
                // The Trash keeps the recording and notes restorable from Finder.
                try FileManager.default.trashItem(at: URL(fileURLWithPath: result.folder), resultingItemURL: nil)
                store?.meetings.removeAll { $0.id == target.id }
                workspace?.forget(meetingID: target.id)
                if nav?.route == .local(target.id) {
                    store?.selectedID = nil
                    nav?.route = .meetings
                }
                await workspace?.refresh()
                try? await store?.refresh()
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    func revealLocal(_ id: String) {
        // Select the recording itself; the folder is named by an internal ID.
        let folder = LocalAPI.dataDirectory.appending(path: id)
        let audio = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .first { ["m4a", "wav", "mp3", "mp4", "flac", "ogg", "webm"].contains($0.pathExtension.lowercased()) }
        NSWorkspace.shared.activateFileViewerSelecting([audio ?? folder])
    }

    func reveal(folder: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func export(title: String, markdown: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// Right-click menu for a meeting row, matching the detail screen's ⋯ menu.
struct MeetingContextMenu: View {
    let item: MeetingListItem
    @EnvironmentObject private var actions: MeetingActions

    var body: some View {
        switch item.route {
        case .local(let id):
            Button("이름 변경…") { actions.requestRename(id: id, title: item.title) }
            MoveToFolderMenu(ids: [id])
            Button("Finder에서 보기") { actions.revealLocal(id) }
            Divider()
            Button("삭제…", role: .destructive) { actions.requestDelete(id: id, title: item.title) }
                .disabled(item.isBusy)
        case .shared(let id):
            MoveToFolderMenu(ids: [id])
            if let folder = item.folder {
                Button("Finder에서 보기") { actions.reveal(folder: folder) }
            }
        default:
            EmptyView()
        }
    }
}
