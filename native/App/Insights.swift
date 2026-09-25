import Charts
import SwiftUI

struct SpeechSegment {
    let speaker: String
    let start: Double
    let end: Double
}

struct SpeakerStat: Identifiable {
    let name: String
    var seconds: Double
    var turns: Int
    var id: String { name }
}

struct NoteSection: Identifiable {
    let title: String
    let count: Int
    var id: String { title }

    /// Colors follow meaning, so the same kind of section looks the same in every meeting.
    var color: TagColor {
        if title.contains("할 일") || title.contains("액션") { return .blue }
        if title.contains("결정") { return .green }
        if title.contains("질문") || title.contains("이슈") || title.contains("리스크") { return .orange }
        return .gray
    }
}

extension MeetingDocument {
    /// Speakers in order of first appearance; this order fixes each speaker's color.
    var speakerOrder: [String] {
        var seen: [String] = []
        for line in lines where !seen.contains(line.speaker) { seen.append(line.speaker) }
        return seen
    }

    var totalSeconds: Double {
        max(duration ?? 0, lines.reduce(0) { max($0, $1.end ?? $1.start) }, 1)
    }

    /// Speaking spans. Local results carry real end times; synced transcripts only have start
    /// times, so the end is estimated from the text length and capped at the next line.
    var segments: [SpeechSegment] {
        lines.enumerated().map { index, line in
            let start = line.start
            let next = index + 1 < lines.count ? lines[index + 1].start : (duration ?? .infinity)
            let estimated = start + max(1.5, Double(line.text.count) / 5)
            let end = line.end ?? min(max(next, start + 0.5), estimated)
            return SpeechSegment(speaker: line.speaker, start: start, end: max(end, start + 0.3))
        }
    }

    var speakerStats: [SpeakerStat] {
        var stats: [String: SpeakerStat] = [:]
        for segment in segments {
            stats[segment.speaker, default: SpeakerStat(name: segment.speaker, seconds: 0, turns: 0)].seconds += segment.end - segment.start
        }
        var previous: String?
        for line in lines where line.speaker != previous {
            stats[line.speaker]?.turns += 1
            previous = line.speaker
        }
        return stats.values.sorted { $0.seconds > $1.seconds }
    }

    /// "## 할 일" style headings with the number of bullet items under each.
    var noteSections: [NoteSection] {
        var sections: [NoteSection] = []
        var title: String?
        var count = 0
        func flush() { if let title, count > 0 { sections.append(NoteSection(title: title, count: count)) } }
        for raw in notes.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") || line.hasPrefix("### ") {
                flush()
                title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                count = 0
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                count += 1
            }
        }
        flush()
        return sections
    }
}

/// Horizontal bars: each speaker's share of speaking time.
struct SpeakerShareView: View {
    let document: MeetingDocument

    var body: some View {
        let stats = document.speakerStats
        let total = max(stats.reduce(0) { $0 + $1.seconds }, 0.001)
        let order = document.speakerOrder
        VStack(alignment: .leading, spacing: 12) {
            BlockTitle(text: "화자별 발언 비율")
            VStack(spacing: 10) {
                ForEach(stats) { stat in
                    let share = stat.seconds / total
                    let color = TagColor.speaker(stat.name, in: order)
                    HStack(spacing: 10) {
                        Tag(text: document.displayName(stat.name), color: color).frame(width: 100, alignment: .leading)
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.raised)
                                Capsule().fill(color.solid).frame(width: max(6, proxy.size.width * share))
                            }
                        }
                        .frame(height: 8)
                        Text("\(Int((share * 100).rounded()))%")
                            .font(.exTimecode)
                            .frame(width: 38, alignment: .trailing)
                    }
                    .help("\(formatDuration(stat.seconds)) · 발언 \(stat.turns)번")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(document.displayName(stat.name)), 발언 비율 \(Int((share * 100).rounded()))퍼센트, \(formatDuration(stat.seconds))")
                }
            }
        }
    }
}

/// One lane per speaker across the meeting; click a lane to play from that moment.
struct SpeakerTimeline: View {
    let document: MeetingDocument
    @ObservedObject var playback: AudioPlayback
    @State private var windowIndex = 0
    @State private var followPlayback = true

    var body: some View {
        let order = document.speakerOrder
        let total = document.totalSeconds
        let windowSize = total > 300 ? 300.0 : total
        let pageCount = max(1, Int(ceil(total / windowSize)))
        let page = min(windowIndex, pageCount - 1)
        let from = Double(page) * windowSize
        let until = min(from + windowSize, total)
        let span = until - from
        let segments = document.segments.filter { $0.end > from && $0.start < until }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                BlockTitle(text: "발언 흐름")
                Spacer(minLength: 4)
                if pageCount > 1 {
                    Button { windowIndex = max(0, page - 1); followPlayback = false } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(page == 0)
                    .help("이전 5분")
                    Menu {
                        ForEach(0..<pageCount, id: \.self) { index in
                            let start = Double(index) * windowSize
                            Button("\(clock(start))–\(clock(min(start + windowSize, total)))") {
                                windowIndex = index
                                followPlayback = false
                            }
                        }
                    } label: {
                        Text("\(page + 1)/\(pageCount)").font(.exTimecode)
                    }
                    .help("다른 시간 구간으로 이동")
                    Button { windowIndex = min(pageCount - 1, page + 1); followPlayback = false } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(page == pageCount - 1)
                    .help("다음 5분")
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .padding(.bottom, 4)
            ForEach(order, id: \.self) { speaker in
                let color = TagColor.speaker(speaker, in: order)
                HStack(spacing: 10) {
                    Tag(text: document.displayName(speaker), color: color).frame(width: 100, alignment: .leading)
                    GeometryReader { proxy in
                        let width = proxy.size.width
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.raised)
                            ForEach(Array(segments.enumerated()).filter { $0.element.speaker == speaker }, id: \.offset) { _, segment in
                                let start = max(segment.start, from)
                                let end = min(segment.end, until)
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(color.solid)
                                    .frame(width: max(2, width * (end - start) / span))
                                    .offset(x: width * (start - from) / span)
                            }
                            if playback.isLoaded, playback.current > from, playback.current <= until {
                                Rectangle().fill(Color.primary.opacity(0.7)).frame(width: 1.5)
                                    .offset(x: width * (playback.current - from) / span)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            if playback.isLoaded {
                                followPlayback = true
                                playback.play(from: from + span * location.x / max(width, 1))
                            }
                        }
                    }
                    .frame(height: 14)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(document.displayName(speaker)) 발언 구간")
            }
            HStack {
                Text(clock(from))
                Spacer()
                Text(clock(until))
            }
            .font(.exTimecodeSmall)
            .foregroundStyle(.tertiary)
            .padding(.leading, 110)
        }
        .onChange(of: playback.current) { _, current in
            if followPlayback && playback.playing && pageCount > 1 {
                windowIndex = min(pageCount - 1, Int(current / windowSize))
            }
        }
        .help(playback.isLoaded ? "막대를 누르면 그 시점부터 재생해요" : "")
    }
}

/// Home: minutes recorded on each of the last seven days.
struct WeekChart: View {
    let items: [MeetingListItem]

    private struct Day: Identifiable {
        let date: Date
        let minutes: Double
        let count: Int
        var id: Date { date }
    }

    private var days: [Day] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        return (0..<7).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let matches = items.filter { calendar.isDate($0.date, inSameDayAs: day) && $0.status == "done" }
            return Day(date: day, minutes: matches.compactMap(\.duration).reduce(0, +) / 60, count: matches.count)
        }
    }

    var body: some View {
        let days = days
        let count = days.reduce(0) { $0 + $1.count }
        let minutes = days.reduce(0) { $0 + $1.minutes }
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Tag(text: "회의 \(count)개", color: .blue)
                Tag(text: "총 \(formatDuration(minutes * 60))", color: .green)
                if let busiest = days.max(by: { $0.minutes < $1.minutes }), busiest.minutes > 0 {
                    Tag(text: "가장 많은 날 \(busiest.date.formatted(.dateTime.weekday(.abbreviated)))", color: .gray)
                }
            }
            Chart(days) { day in
                BarMark(x: .value("날짜", day.date, unit: .day), y: .value("분", day.minutes), width: .ratio(0.5))
                    .foregroundStyle(Calendar.current.isDateInToday(day.date) ? Color.brandText : TagColor.blue.solid.opacity(0.55))
                    .cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Color.hairline)
                    AxisValueLabel { if let minutes = value.as(Double.self) { Text(minutes == 0 ? "0" : formatDuration(minutes * 60)) } }
                }
            }
            .frame(height: 110)
            .accessibilityLabel("최근 7일 회의 시간 그래프")
        }
    }
}
