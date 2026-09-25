import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum Route: Hashable {
    case home
    case meetings
    case local(String)
    case shared(String)
    case settings(SettingsTab)
    case space(MeetingScope)
    case folder(String)
}

/// Sidebar selection plus back/forward history for the toolbar arrows.
@MainActor
final class Navigator: ObservableObject {
    @Published var route: Route? = .home {
        didSet {
            guard !restoring, let oldValue, oldValue != route else { return }
            back.append(oldValue)
            forward.removeAll()
        }
    }
    @Published private(set) var back: [Route] = []
    @Published private(set) var forward: [Route] = []
    private var restoring = false

    func goBack() { move(from: &back, to: &forward) }
    func goForward() { move(from: &forward, to: &back) }

    /// Changes the route without a history entry, for switching tabs within one page.
    func replace(with route: Route) {
        restoring = true
        self.route = route
        restoring = false
    }

    private func move(from source: inout [Route], to destination: inout [Route]) {
        guard let target = source.popLast() else { return }
        if let route { destination.append(route) }
        restoring = true
        route = target
        restoring = false
    }
}

/// Launch, quit and "opened at login" hooks; everything else lives in AppModel.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        MainActor.assumeIsolated { AppModel.shared.launch(atLogin: atLogin); AppUpdater.shared.start() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { AppModel.shared.shouldTerminate() }
    }

    /// Closing the window keeps Exanote in the menu bar, listening for the next meeting.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct ExanoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @ObservedObject private var store = AppModel.shared.store
    @ObservedObject private var workspace = AppModel.shared.workspace
    @ObservedObject private var calendar = AppModel.shared.calendar
    @ObservedObject private var detector = AppModel.shared.detector
    @ObservedObject private var nav = AppModel.shared.nav
    @ObservedObject private var actions = AppModel.shared.actions
    @Environment(\.openWindow) private var openWindow
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage(RecordingPrefs.onboarded) private var onboarded = false
    @State private var importing = false

    init() { AppPaths.migrateFromOpenNotes() }

    // Everything macOS's afconvert can read, so no ffmpeg is needed.
    private static let importableExtensions: Set<String> = ["wav", "mp3", "m4a", "aac", "mp4", "mov", "flac", "aiff", "aif", "caf", "ogg"]

    var body: some Scene {
        Window("Exanote", id: "main") {
            NavigationSplitView {
                Sidebar(store: store, workspace: workspace, nav: nav, folders: model.folders, items: items, sharedName: sharedName, find: find)
                    .navigationSplitViewColumnWidth(min: 252, ideal: 270, max: 400)
            } detail: {
                detail
                    .navigationTitle(windowTitle)
                    // The toolbar spans both columns, so it stays clear and each column paints its
                    // own color up to the top edge: gray sidebar, white page, as in Notion.
                    .background(Color.canvas.ignoresSafeArea())
                    .overlay(alignment: .top) { ToolbarBackdrop() }
                    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            }
            .accessibilityHidden(!onboarded)
            .tint(Color.brandText)
            .toolbar { toolbar }
            .toolbar(onboarded ? .automatic : .hidden, for: .windowToolbar)
            .overlay {
                if !onboarded {
                    OnboardingView(model: model) {
                        withAnimation(.easeOut(duration: 0.25)) { onboarded = true }
                        nav.route = .home
                    }
                    .ignoresSafeArea()
                    .transition(.opacity)
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .movie, .mpeg4Audio, .mp3, .wav], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    Task {
                        await store.importFile(url)
                        if let id = store.selectedID { nav.route = .local(id) }
                    }
                }
            }
            .background(MainWindowReader(model: model))
            .onAppear { model.openMainWindow = { openWindow(id: "main") } }
            .environmentObject(actions)
            .dropDestination(for: URL.self) { urls, _ in
                // Dropping an audio file anywhere on the window imports it, like other Mac apps.
                guard let url = urls.first, Self.importableExtensions.contains(url.pathExtension.lowercased()),
                      !store.recording, !store.busy else { return false }
                Task {
                    await store.importFile(url)
                    if let id = store.selectedID { nav.route = .local(id) }
                }
                return true
            }
            .alert("회의 이름 변경", isPresented: Binding(get: { actions.renaming != nil }, set: { if !$0 { actions.renaming = nil } })) {
                TextField("회의 이름", text: $actions.renameText)
                Button("취소", role: .cancel) {}
                Button("저장") { actions.commitRename() }.keyboardShortcut(.defaultAction)
            } message: {
                Text(actions.syncFolderName.map { "\($0)에 있는 사본의 이름도 함께 바뀌어요." } ?? "새 이름을 입력하세요.")
            }
            .alert(deleteTitle, isPresented: Binding(get: { actions.deleting != nil }, set: { if !$0 { actions.deleting = nil } })) {
                Button("휴지통으로 이동", role: .destructive) { actions.commitDelete() }
                Button("취소", role: .cancel) {}
            } message: {
                Text(deleteMessage)
            }
            .alert("작업을 완료하지 못했어요", isPresented: Binding(get: { actions.failure != nil }, set: { if !$0 { actions.failure = nil } })) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(actions.failure ?? "")
            }
            .modifier(PermissionAlert(permission: $model.missingPermission))
            .modifier(FolderAlerts(folders: model.folders))
            .onChange(of: nav.route) { _, new in
                if case .local(let id) = new, store.selectedID != id { store.selectedID = id }
            }
            .onChange(of: store.selectedID) { _, _ in Task { await store.loadSelected() } }
            .preferredColorScheme(colorScheme)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1180, height: 800)
        .commands {
            CommandGroup(after: .appInfo) { CheckForUpdatesCommand() }
            CommandGroup(replacing: .newItem) {
                Button(store.recording ? "녹음 종료" : "새 회의 녹음") {
                    store.recording ? model.stopMeeting() : model.startMeeting()
                }
                .keyboardShortcut("n")
                .disabled(store.busy)
                // The scene does not observe the one-second recording clock, so these titles stay fixed.
                Button("녹음 일시정지 또는 재개") { model.togglePause() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(!store.recording)
                Button("북마크 추가") { model.addBookmark() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                    .disabled(!store.recording)
                Divider()
                Button("오디오 파일 가져오기…") { importing = true }
                    .keyboardShortcut("o")
                    .disabled(store.busy || store.recording)
            }
            CommandGroup(after: .textEditing) {
                Button("찾기") { find() }.keyboardShortcut("f")
            }
            // Settings is a page of the main window, not a separate window.
            CommandGroup(replacing: .appSettings) {
                Button("설정…") { model.showMain(route: .settings(.general)) }.keyboardShortcut(",")
            }
        }

        MenuBarExtra {
            MenuBarContent(model: model, session: model.session, store: store, detector: detector, calendar: calendar)
        } label: {
            MenuBarLabel(session: model.session, store: store)
        }
        .menuBarExtraStyle(.window)
    }

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    private var items: [MeetingListItem] { MeetingListItem.all(store, workspace) }

    /// Teammates' meetings are named after the team or shared drive they come from.
    private var sharedName: String? {
        guard let selected = workspace.selected, selected.kind == "team" || selected.kind == "google-shared" else { return nil }
        return selected.name
    }

    private var windowTitle: String {
        switch nav.route {
        case .meetings: "회의"
        case .local: store.selected?.title ?? "회의"
        case .shared(let id): workspace.shared.first { $0.id == id }?.title ?? "공유된 회의"
        case .settings: "설정"
        case .space(let scope): scope.title(sharedName: sharedName)
        case .folder(let id): model.folders.folder(id: id)?.name ?? "폴더"
        case .home, nil: "홈"
        }
    }

    private var deleteTitle: String {
        "‘\(actions.deleting?.title ?? "")’ 회의를 삭제할까요?"
    }

    private var deleteMessage: String {
        let local = "녹음과 노트를 휴지통으로 옮겨요. Finder의 휴지통에서 되돌릴 수 있어요."
        guard let folder = actions.syncFolderName else { return local }
        return local + " \(folder)의 사본도 삭제되어 다른 기기와 팀원의 목록에서도 사라져요."
    }

    private func find() {
        if nav.route == .home || nav.route == nil { nav.route = .meetings }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NotificationCenter.default.post(name: .focusSearch, object: nil)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { nav.goBack() } label: { Label("뒤로", systemImage: "chevron.left") }
                .disabled(nav.back.isEmpty)
                .keyboardShortcut("[", modifiers: .command)
                .help("뒤로")
            Button { nav.goForward() } label: { Label("앞으로", systemImage: "chevron.right") }
                .disabled(nav.forward.isEmpty)
                .keyboardShortcut("]", modifiers: .command)
                .help("앞으로")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { importing = true } label: { Label("파일 가져오기", systemImage: "square.and.arrow.down") }
                .buttonStyle(PillButtonStyle())
                .disabled(store.busy || store.recording)
                .help("오디오나 영상 파일에서 회의 노트를 만듭니다")
        }
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 6) {
                if store.recording { PauseButton(model: model, session: model.session) }
                RecordButton(store: store, session: model.session, start: { model.startMeeting() }, stop: { model.stopMeeting() })
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch nav.route {
        case .meetings, .space:
            let scope: MeetingScope = if case .space(let scope) = nav.route { scope } else { .all }
            MeetingsView(items: items, scope: scope, sharedName: sharedName,
                         select: { nav.replace(with: $0 == .all ? .meetings : .space($0)) }) { nav.route = $0 }
        case .folder(let id):
            MeetingsView(items: items, scope: .all, sharedName: sharedName, folderID: id,
                         select: { nav.replace(with: $0 == .all ? .meetings : .space($0)) }) { nav.route = $0 }
        case .local:
            LocalMeetingView(store: store, workspace: workspace)
        case .shared(let id):
            SharedMeetingView(meetingID: id, workspace: workspace)
        case .settings(let tab):
            SettingsPage(tab: tab, select: { nav.replace(with: .settings($0)) }, model: model,
                         workspace: workspace, calendar: calendar)
        case .home, nil:
            HomeView(meetings: store, calendar: calendar, detector: detector, recent: items, open: { nav.route = $0 },
                     startMeeting: { model.startMeeting($0) }, importFile: { importing = true })
        }
    }
}

private struct RecordButton: View {

    @ObservedObject var store: MeetingStore
    @ObservedObject var session: RecordingSession
    let start: () -> Void
    let stop: () -> Void

    var body: some View {
        if store.recording {
            Button(action: stop) {
                HStack(spacing: 8) {
                    Circle().fill(.white).frame(width: 7, height: 7).opacity(session.paused ? 0.4 : 1).accessibilityHidden(true)
                    Text(clock(Double(session.elapsed))).font(.exTimer)
                    Text("종료")
                }
            }
            .buttonStyle(PillButtonStyle(kind: .danger))
            .disabled(store.busy)
            .accessibilityLabel("녹음 종료")
            .help("녹음을 끝내고 회의 노트를 만듭니다 (⌘N)")
        } else {
            Button(action: start) { Label("녹음 시작", systemImage: "record.circle") }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .disabled(store.busy)
                .help("바로 녹음을 시작합니다. 실시간 번역은 녹음 화면에서 켤 수 있어요 (⌘N)")
        }
    }
}

private struct Sidebar: View {
    @ObservedObject var store: MeetingStore
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var nav: Navigator
    @ObservedObject var folders: FolderStore
    let items: [MeetingListItem]
    let sharedName: String?
    let find: () -> Void
    @EnvironmentObject private var actions: MeetingActions
    @AppStorage(DisplayName.key) private var savedDisplayName = ""
    @State private var editingDisplayName = false

    private var displayName: String { DisplayName.resolved(savedDisplayName) }

    private var inSettings: Bool {
        if case .settings = nav.route { return true }
        return false
    }

    /// Recording or processing meetings always show, then the newest up to five, as Aside lists
    /// three recent chats and "Show all". The meetings page holds the rest.
    private var recent: [MeetingListItem] {
        let busy = items.filter(\.isBusy)
        return busy + items.filter { !$0.isBusy }.prefix(max(0, 5 - busy.count))
    }

    private var spaces: [MeetingScope] {
        [.thisMac, .otherMacs, .shared].filter { scope in items.contains(where: scope.contains) }
    }

    @ViewBuilder
    private func recentStatus(_ item: MeetingListItem) -> some View {
        switch item.status {
        case "recording":
            Circle().fill(Color.recording).frame(width: 7, height: 7).accessibilityLabel("녹음 중")
        case "queued", "processing":
            Text("처리 중").font(.sidebar(offset: -4)).foregroundStyle(.tertiary)
        case "error":
            Image(systemName: "exclamationmark.circle").font(.sidebar(offset: -4)).foregroundStyle(Color.recording).accessibilityLabel("오류")
        default:
            EmptyView()
        }
    }

    private func relativeDay(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(.dateTime.hour().minute()) }
        if calendar.isDateInYesterday(date) { return "어제" }
        return date.formatted(.dateTime.month().day())
    }

    private func shortcutIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.sidebar(offset: -2, weight: .medium))
            .frame(width: CGFloat(Typography.shared.sidebarSize) + 8,
                   height: CGFloat(Typography.shared.sidebarSize) + 8)
    }

    var body: some View {
        List(selection: $nav.route) {
            Section {
                ForEach(recent) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.sidebar(offset: -2)).foregroundStyle(.secondary)
                            .frame(width: CGFloat(Typography.shared.sidebarSize) + 2)
                        Text(item.title).font(.sidebar()).lineLimit(1)
                        Spacer(minLength: 4)
                        recentStatus(item)
                    }
                    .sidebarRow(item.route, selected: nav.route)
                    .draggable(item.id)
                    .contextMenu { MeetingContextMenu(item: item) }
                }
                if items.count > recent.count {
                    Button { nav.route = .meetings } label: {
                        Text("모두 보기").font(.sidebar()).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                .sidebarSpacing()
                }
            } header: {
                SidebarHeader(title: "최근")
            }

            if spaces.count > 1 {
                Section {
                    ForEach(spaces, id: \.self) { scope in
                        HStack {
                            Label { Text(scope.title(sharedName: sharedName)).font(.sidebar()).lineLimit(1) } icon: {
                                Image(systemName: scope.symbol).font(.sidebar(offset: -2)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(items.filter(scope.contains).count)").font(.sidebar(offset: -4).monospacedDigit()).foregroundStyle(.tertiary)
                        }
                        .sidebarRow(.space(scope), selected: nav.route)
                    }
                } header: {
                    SidebarHeader(title: "공간")
                }
            }

            Section {
                let ids = Set(items.map(\.id))
                ForEach(folders.folders) { folder in
                    HStack {
                        Label { Text(folder.name).font(.sidebar()).lineLimit(1) } icon: { Image(systemName: "folder").font(.sidebar(offset: -2)).foregroundStyle(.secondary) }
                        Spacer()
                        Text("\(folders.count(folder, among: ids))").font(.sidebar(offset: -4).monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    .sidebarRow(.folder(folder.id), selected: nav.route)
                    // Drop a meeting from the sidebar or the meetings page to file it.
                    .dropDestination(for: String.self) { dropped, _ in
                        Task { await folders.move(dropped, to: folder.id) }
                        return true
                    }
                    .contextMenu {
                        Button("이름 변경…") { folders.requestRename(folder) }
                        Button("삭제…", role: .destructive) { folders.deleting = folder }
                    }
                }
                Button { folders.requestCreate() } label: {
                    Label { Text("새 폴더").font(.sidebar()) } icon: { Image(systemName: "plus").font(.sidebar(offset: -2)).foregroundStyle(.secondary) }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sidebarSpacing()
            } header: {
                SidebarHeader(title: "폴더")
            }
        }
        .font(.sidebar())
        .environment(\.defaultMinListRowHeight, Typography.shared.sidebarRowHeight)
        .listStyle(.sidebar)
        .labelStyle(SidebarLabelStyle())
        .scrollContentBackground(.hidden)
        .background(PlainSidebarSelection())
        .onDeleteCommand {
            // ⌫ / Edit ▸ 삭제 on a selected meeting asks before moving it to the Trash.
            guard case .local(let id) = nav.route, let item = items.first(where: { $0.id == id }), !item.isBusy else { return }
            actions.requestDelete(id: id, title: item.title)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Button { nav.route = .meetings; find() } label: {
                    HStack(spacing: 8) {
                        Text("검색").foregroundStyle(.secondary)
                        Spacer()
                        Text("⌘K").font(.sidebar(offset: -4)).foregroundStyle(.secondary)
                            .padding(.horizontal, 4).padding(.vertical, 2)
                            .background(Color.sidebarSelection, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .font(.sidebar(offset: -2))
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.hairline))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("k", modifiers: .command)
                HStack(spacing: 4) {
                    Button { nav.route = .home } label: {
                        HStack(spacing: 6) {
                            shortcutIcon("house.fill")
                            Text("홈")
                        }.frame(height: CGFloat(Typography.shared.sidebarSize) + 8)
                    }
                    .buttonStyle(SidebarShortcutStyle(selected: nav.route == .home))
                    Button { nav.route = .meetings } label: {
                        shortcutIcon("tray.full").accessibilityLabel("회의")
                    }
                    .buttonStyle(SidebarShortcutStyle(selected: nav.route == .meetings))
                    .help("회의 · \(items.count)개")
                    Button { nav.route = .settings(.calendar) } label: {
                        shortcutIcon("calendar").accessibilityLabel("캘린더")
                    }
                    .buttonStyle(SidebarShortcutStyle(selected: nav.route == .settings(.calendar)))
                    .help("캘린더")
                    Spacer(minLength: 0)
                }
                .font(.sidebar(offset: -2, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 16)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) {
                Rectangle().fill(Color.hairline).frame(height: 1)
                SetupChecklist(model: AppModel.shared) { nav.route = .settings($0) }
                HStack(spacing: 10) {
                    Button { editingDisplayName = true } label: {
                        HStack(spacing: 10) {
                            Text(String(displayName.prefix(1)))
                                .font(.app(size: 12, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 26, height: 26)
                                // Neutral, so a lime letter in a lime shape stays the logo's alone.
                                .background(Color.raised, in: Circle())
                                .accessibilityHidden(true)
                            Text(displayName).font(.sidebar(offset: -2, weight: .medium)).lineLimit(1)
                            Image(systemName: "chevron.down").font(.sidebar(offset: -6)).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(displayName), 표시 이름 변경")
                    .help("표시 이름 변경")
                    .sheet(isPresented: $editingDisplayName) { DisplayNameEditor() }
                    Spacer(minLength: 0)
                    Button { nav.route = .settings(.general) } label: {
                        Label("설정", systemImage: "gearshape").labelStyle(.iconOnly)
                            .frame(width: 26, height: 26)
                            .background(inSettings ? Color.sidebarSelection : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(inSettings ? Color.primary : Color.secondary)
                    .help("설정 (⌘,)")
                }
                .padding(.horizontal, 6)
            }
            .padding(12)
        }
        .background(Color.sidebar.ignoresSafeArea())
    }
}

private struct PauseButton: View {
    let model: AppModel
    @ObservedObject var session: RecordingSession

    var body: some View {
        Button { model.togglePause() } label: {
            Label(session.paused ? "녹음 재개" : "일시정지", systemImage: session.paused ? "play.fill" : "pause.fill").labelStyle(.iconOnly)
        }
        .buttonStyle(PillButtonStyle(compact: true))
        .help(session.paused ? "녹음 재개 (⌘⇧P)" : "녹음 일시정지 (⌘⇧P)")
    }
}

/// Section headings share the leading edge of the sidebar row icons.
private struct SidebarHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.sidebar(offset: -5, weight: .medium))
            .foregroundStyle(.secondary)
            .textCase(nil)
            .padding(.leading, 12)
            .padding(.top, Typography.shared.sidebarSectionGap)
            .padding(.bottom, 2)
    }
}

/// Keep symbol and title separate as the user enlarges sidebar text.
private struct SidebarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .font(.sidebar(offset: -2))
                .frame(width: CGFloat(Typography.shared.sidebarSize) + 2)
            configuration.title
        }
    }
}

private struct SidebarShortcutStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        SidebarShortcutContent(label: configuration.label, selected: selected, pressed: configuration.isPressed)
    }
}

private struct SidebarShortcutContent<Content: View>: View {
    let label: Content
    let selected: Bool
    let pressed: Bool
    @State private var hovering = false
    var body: some View {
        label
            .padding(.horizontal, 8).padding(.vertical, 6)
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .background(selected || pressed ? Color.sidebarSelection : hovering ? Color.sidebarHover : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}
