import SwiftUI

/// One row in any meeting list, whether recorded on this Mac or read from the sync folder.
struct MeetingListItem: Identifiable, Hashable {
    enum Source: Hashable {
        case local
        case otherMac
        case teammate(String)
    }

    let id: String
    let title: String
    let date: Date
    let duration: Double?
    let status: String
    let source: Source
    let route: Route
    var folder: String? = nil
    var demo = false

    var isBusy: Bool { ["recording", "queued", "processing"].contains(status) }

    var symbol: String {
        switch source {
        case .local: "laptopcomputer"
        case .otherMac: "desktopcomputer"
        case .teammate: "person.2"
        }
    }

    var subtitle: String {
        switch source {
        case .local: shortDate(date)
        case .otherMac: "\(shortDate(date)) · 내 다른 Mac"
        case .teammate(let author): "\(shortDate(date)) · \(author)"
        }
    }

    @MainActor
    static func all(_ store: MeetingStore, _ workspace: WorkspaceStore) -> [MeetingListItem] {
        let local = (store.meetings.isEmpty ? workspace.localMeetings : store.meetings).map {
            MeetingListItem(id: $0.id, title: $0.title, date: $0.createdAt, duration: $0.duration, status: $0.status, source: .local, route: .local($0.id), demo: $0.demo == true)
        }
        let shared = workspace.shared.map {
            MeetingListItem(id: $0.id, title: $0.title, date: $0.createdAt, duration: $0.duration, status: "done",
                            source: $0.mine == true ? .otherMac : .teammate($0.author), route: .shared($0.id), folder: $0.folder)
        }
        return (local + shared).sorted { $0.date > $1.date }
    }
}

/// Where a meeting came from, as a sidebar space and a filter on the meetings page.
enum MeetingScope: String, Hashable, CaseIterable {
    case all, thisMac, otherMacs, shared

    func contains(_ item: MeetingListItem) -> Bool {
        switch self {
        case .all: true
        case .thisMac: item.source == .local
        case .otherMacs: item.source == .otherMac
        case .shared: if case .teammate = item.source { true } else { false }
        }
    }

    func title(sharedName: String?) -> String {
        switch self {
        case .all: "전체"
        case .thisMac: "이 Mac"
        case .otherMacs: "내 다른 Mac"
        case .shared: sharedName ?? "공유됨"
        }
    }

    var symbol: String {
        switch self {
        case .all: "tray.full"
        case .thisMac: "laptopcomputer"
        case .otherMacs: "desktopcomputer"
        case .shared: "person.2"
        }
    }
}

enum MeetingPeriod: Int, CaseIterable, Hashable {
    case any, today, week, month

    var title: String {
        switch self {
        case .any: "전체 기간"
        case .today: "오늘"
        case .week: "최근 7일"
        case .month: "최근 30일"
        }
    }

    func contains(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .any: true
        case .today: calendar.isDateInToday(date)
        case .week: date >= now.addingTimeInterval(-7 * 86_400)
        case .month: date >= now.addingTimeInterval(-30 * 86_400)
        }
    }
}

/// Newest-first sections for a long list: 오늘, 어제, 이번 주, 이번 달, then one per month.
struct MeetingPeriodGroup: Identifiable {
    let title: String
    let items: [MeetingListItem]
    var id: String { title }

    static func grouped(_ items: [MeetingListItem], now: Date = Date(), calendar: Calendar = .current) -> [MeetingPeriodGroup] {
        var groups: [MeetingPeriodGroup] = []
        for item in items {
            let title = bucket(item.date, now: now, calendar: calendar)
            if groups.last?.title == title {
                groups[groups.count - 1] = MeetingPeriodGroup(title: title, items: groups[groups.count - 1].items + [item])
            } else {
                groups.append(MeetingPeriodGroup(title: title, items: [item]))
            }
        }
        return groups
    }

    private static func bucket(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "오늘" }
        if calendar.isDateInYesterday(date) { return "어제" }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return "이번 주" }
        if calendar.isDate(date, equalTo: now, toGranularity: .month) { return "이번 달" }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(.dateTime.month(.wide)) }
        return date.formatted(.dateTime.year().month(.wide))
    }
}

/// Keep the matching words visible instead of truncating the beginning of a long utterance.
private enum SearchExcerpt {
    static func text(_ source: String, query: String, context: Bool = false) -> AttributedString {
        let plain = source.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !query.isEmpty,
              let match = plain.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return AttributedString(plain)
        }
        var visible = plain
        if context {
            var start = plain.index(match.lowerBound, offsetBy: -22, limitedBy: plain.startIndex) ?? plain.startIndex
            var end = plain.index(match.upperBound, offsetBy: 45, limitedBy: plain.endIndex) ?? plain.endIndex
            // Expand a bounded amount to avoid cutting a Korean word or a number in half.
            for _ in 0..<12 {
                guard start > plain.startIndex else { break }
                let previous = plain.index(before: start)
                guard !plain[previous].isWhitespace else { break }
                start = previous
            }
            for _ in 0..<12 {
                guard end < plain.endIndex, !plain[end].isWhitespace else { break }
                end = plain.index(after: end)
            }
            visible = (start > plain.startIndex ? "… " : "") + String(plain[start..<end]) + (end < plain.endIndex ? " …" : "")
        }
        var result = AttributedString(visible)
        var cursor = visible.startIndex
        while cursor < visible.endIndex,
              let range = visible.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: cursor..<visible.endIndex) {
            if let lower = AttributedString.Index(range.lowerBound, within: result),
               let upper = AttributedString.Index(range.upperBound, within: result) {
                result[lower..<upper].foregroundColor = Color.primary
                result[lower..<upper].backgroundColor = Color.yellow.opacity(0.25)
                result[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
            }
            cursor = range.upperBound
        }
        return result
    }
}

struct MeetingListRow: View {
    let item: MeetingListItem
    /// The first transcript or summary line matching a search.
    var snippet: String? = nil
    var searchQuery: String = ""
    var folderName: String? = nil
    /// Non-nil while choosing meetings: a checkbox replaces the source icon.
    var checked: Bool? = nil

    var body: some View {
        HStack(spacing: 12) {
            if let checked {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.app(size: 15))
                    .foregroundStyle(checked ? Color.brandText : Color.secondary.opacity(0.6))
                    .frame(width: 20)
                    .accessibilityLabel(checked ? "선택됨" : "선택 안 됨")
            } else {
                Image(systemName: item.status == "recording" ? "record.circle" : item.symbol)
                    .font(.app(size: 13))
                    .foregroundStyle(item.status == "recording" ? Color.recording : Color.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(SearchExcerpt.text(item.title, query: searchQuery)).font(.exHeadline).lineLimit(1)
                    if item.demo { Tag(text: "예시") }
                    if let folderName {
                        Label(folderName, systemImage: "folder")
                            .font(.app(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    switch item.source {
                    case .local: EmptyView()
                    case .otherMac: Tag(text: "내 다른 Mac")
                    case .teammate(let author): Tag(text: author, color: .purple)
                    }
                }
                if let snippet {
                    Text(SearchExcerpt.text(snippet, query: searchQuery, context: true))
                        .font(.app(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            trailing.frame(width: 150, alignment: .trailing)
            Text(shortDate(item.date))
                .font(.exData)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 150, alignment: .trailing)
        }
        .hoverRow()
    }

    @ViewBuilder
    private var trailing: some View {
        switch item.status {
        case "recording": Tag(text: "녹음 중", color: .red)
        case "queued", "processing": Tag(text: "처리 중", color: .yellow)
        case "error": Tag(text: "오류", color: .red)
        default:
            if let duration = item.duration {
                Text(formatDuration(duration))
                    .font(.exData)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private enum MeetingListEntry: Identifiable {
    case heading(String)
    case meeting(MeetingListItem)

    var id: String {
        switch self {
        case .heading(let title): "heading:\(title)"
        case .meeting(let item): "meeting:\(item.id)"
        }
    }
}

/// A Notion-style list: column labels, then rows with no box around them. Rows are built as they
/// scroll into view, so hundreds of meetings cost no more than a screenful.
struct MeetingList: View {
    let items: [MeetingListItem]
    var grouped = false
    var snippets: [String: String] = [:]
    var searchQuery: String = ""
    var folderNames: [String: String] = [:]
    var selection: Binding<Set<String>>? = nil
    let open: (Route) -> Void

    var body: some View {
        let entries: [MeetingListEntry] = grouped
            ? MeetingPeriodGroup.grouped(items).flatMap { group in
                [MeetingListEntry.heading(group.title)] + group.items.map(MeetingListEntry.meeting)
            }
            : items.map(MeetingListEntry.meeting)
        LazyVStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                Text("제목").padding(.leading, 32)
                Spacer()
                Text("길이").frame(width: 150, alignment: .trailing)
                Text("날짜").frame(width: 150, alignment: .trailing)
            }
            .font(.exEyebrow)
            .foregroundStyle(.tertiary)
            .padding(.bottom, 4)
            .accessibilityHidden(true)
            Hairline().padding(.bottom, 4)
            ForEach(entries) { entry in
                switch entry {
                case .heading(let title):
                    Text(title)
                        .font(.app(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 10)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                        .accessibilityAddTraits(.isHeader)
                case .meeting(let item):
                    row(item)
                }
            }
        }
    }

    private func row(_ item: MeetingListItem) -> some View {
        Button {
            if let selection {
                if selection.wrappedValue.contains(item.id) { selection.wrappedValue.remove(item.id) } else { selection.wrappedValue.insert(item.id) }
            } else {
                open(item.route)
            }
        } label: {
            MeetingListRow(item: item, snippet: snippets[item.id], searchQuery: searchQuery, folderName: folderNames[item.id],
                           checked: selection.map { $0.wrappedValue.contains(item.id) })
        }
        .buttonStyle(.plain)
        .draggable(item.id)
        .contextMenu { MeetingContextMenu(item: item) }
    }
}

private struct SearchHit: Decodable {
    let id: String
    let matches: Int
    let snippet: String?
}

struct MeetingsView: View {
    let items: [MeetingListItem]
    let scope: MeetingScope
    let sharedName: String?
    /// Set on a folder's page: only that folder's meetings, with its automatic rules.
    var folderID: String? = nil
    let select: (MeetingScope) -> Void
    let open: (Route) -> Void
    @ObservedObject private var folders = AppModel.shared.folders
    @State private var query = ""
    @State private var period = MeetingPeriod.any
    @State private var hits: [String: SearchHit] = [:]
    @State private var searching = false
    @State private var selection: Set<String>?

    private var folder: MeetingFolder? { folderID.flatMap(folders.folder(id:)) }

    /// 전체 plus each source that has meetings; hidden when everything comes from this Mac.
    private var scopes: [MeetingScope] {
        guard folderID == nil else { return [] }
        let sources = MeetingScope.allCases.filter { $0 != .all && ($0 == scope || items.contains(where: $0.contains)) }
        return sources.count > 1 || scope != .all ? [.all] + sources : []
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    private var inView: [MeetingListItem] {
        items.filter { item in
            if let folderID { return folders.assignments[item.id] == folderID }
            return scope.contains(item)
        }
    }

    private var filtered: [MeetingListItem] {
        inView.filter { item in
            period.contains(item.date) && (trimmed.isEmpty || item.title.localizedCaseInsensitiveContains(trimmed) || hits[item.id] != nil)
        }
    }

    var body: some View {
        PageContainer {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    if folder != nil {
                        Image(systemName: "folder").font(.app(size: 24, weight: .medium)).foregroundStyle(.secondary)
                    }
                    Text(title).font(.exDisplay).tracking(Font.displayTracking)
                }
                Text(subtitle).font(.app(size: 12)).foregroundStyle(.secondary)
                if let folder, !folders.rules(for: folder).isEmpty {
                    HStack(spacing: 6) {
                        Text("자동으로 넣는 반복 일정").font(.app(size: 12)).foregroundStyle(.secondary)
                        ForEach(folders.rules(for: folder), id: \.series_id) { rule in
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.triangle.2.circlepath").font(.app(size: 10))
                                Text(rule.title).font(.app(size: 12, weight: .medium))
                                Button { Task { await folders.forget(rule) } } label: {
                                    Image(systemName: "xmark").font(.app(size: 9, weight: .bold))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("이 반복 일정은 더 이상 자동으로 넣지 않아요")
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(Color.raised, in: Capsule())
                        }
                    }
                    .padding(.top, 6)
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                if let selection {
                    selectionBar(selection)
                } else {
                    HStack(spacing: 12) {
                        if scopes.count > 1 {
                            PillTabs(options: scopes.map { $0.title(sharedName: sharedName) }, selection: Binding(
                                get: { scopes.firstIndex(of: scope) ?? 0 },
                                set: { select(scopes[$0]) }
                            ))
                            .fixedSize()
                        }
                        SearchField(text: $query, prompt: "제목, 전사, 요약 검색")
                        Picker("기간", selection: $period) {
                            ForEach(MeetingPeriod.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                        Button("선택") { selection = [] }
                            .buttonStyle(PillButtonStyle(compact: true))
                            .disabled(filtered.isEmpty)
                            .help("여러 회의를 골라 한 번에 폴더로 옮겨요")
                    }
                }
                if filtered.isEmpty {
                    EmptyState(symbol: folder != nil ? "folder" : trimmed.isEmpty ? "text.bubble" : "text.magnifyingglass",
                               title: searching ? "검색하는 중…" : emptyTitle,
                               message: emptyMessage)
                } else {
                    MeetingList(items: filtered, grouped: trimmed.isEmpty, snippets: hits.compactMapValues(\.snippet), searchQuery: trimmed,
                                folderNames: folderID == nil ? folders.assignments.compactMapValues { folders.folder(id: $0)?.name } : [:],
                                selection: selection == nil ? nil : Binding(get: { selection ?? [] }, set: { selection = $0 }),
                                open: open)
                }
            }
        }
        .task(id: trimmed) { await search() }
        .onExitCommand { selection = nil }
    }

    private func selectionBar(_ chosen: Set<String>) -> some View {
        HStack(spacing: 12) {
            Text(chosen.isEmpty ? "옮길 회의를 고르세요" : "\(chosen.count)개 선택됨").font(.app(size: 13, weight: .medium))
            Button(chosen.count == filtered.count ? "선택 해제" : "모두 선택") {
                selection = chosen.count == filtered.count ? [] : Set(filtered.map(\.id))
            }
            .buttonStyle(.plain)
            .font(.app(size: 12.5))
            .foregroundStyle(Color.brandText)
            Spacer()
            Menu {
                FolderMenuItems(ids: Array(chosen))
            } label: {
                Label("폴더로 이동", systemImage: "folder")
            }
            .menuStyle(.button)
            .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
            .fixedSize()
            .disabled(chosen.isEmpty)
            Button("완료") { selection = nil }.buttonStyle(PillButtonStyle(compact: true)).keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Color.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var title: String {
        if let folder { return folder.name }
        return scope == .all ? "회의" : scope.title(sharedName: sharedName)
    }

    private var emptyTitle: String {
        if !trimmed.isEmpty || period != .any { return "일치하는 회의가 없어요" }
        return folder != nil ? "이 폴더는 비어 있어요" : "아직 회의가 없어요"
    }

    private var emptyMessage: String {
        if !trimmed.isEmpty || period != .any { return "다른 검색어나 기간으로 찾아보세요." }
        if folder != nil { return "회의를 이 폴더로 끌어다 놓거나, 회의를 우클릭해 폴더로 이동을 고르세요." }
        return "녹음을 시작하거나 오디오 파일을 가져오면 여기에 표시돼요."
    }

    private var subtitle: String {
        if !trimmed.isEmpty { return searching ? "‘\(trimmed)’ 찾는 중" : "‘\(trimmed)’ 검색 결과 \(filtered.count)개" }
        if period != .any { return "\(period.title) · 회의 \(filtered.count)개" }
        let count = inView.count
        if folder != nil { return "회의 \(count)개" }
        switch scope {
        case .all: return "이 Mac에서 기록한 회의와 동기화 폴더의 회의 \(count)개"
        case .thisMac: return "이 Mac에서 녹음하거나 가져온 회의 \(count)개"
        case .otherMacs: return "같은 계정의 다른 Mac에서 동기화된 회의 \(count)개"
        case .shared: return "팀원이 동기화 폴더에 올린 회의 \(count)개"
        }
    }

    /// Titles filter as you type; transcripts and summaries are searched by the worker a moment
    /// after typing stops.
    private func search() async {
        guard trimmed.count >= 2 else { hits = [:]; searching = false; return }
        hits = [:]
        searching = true
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let found: [SearchHit] = (try? await LocalAPI.request("api/search", query: [URLQueryItem(name: "q", value: trimmed)])) ?? []
        guard !Task.isCancelled else { return }
        hits = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        searching = false
    }
}
