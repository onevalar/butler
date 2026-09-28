// Adapted from TimelineUI by Christian Tietze (https://codeberg.org/ctietze/timeline-ui), MIT License —
// see LICENSE.txt in this folder. Kept: the hour grid, the event block look (4pt leading bar over a
// 20% tint) and the side-by-side column layout for overlapping events. Changed for Butler: items are
// placed on a given day and hour range, blocks are tappable, a red "now" line, Chinese labels, and
// slightly rounder blocks to sit with Liquid Glass.

import SwiftUI

/// One block on the timeline.
struct TimelineItem: Identifiable, Hashable {
    let id: String
    let title: String
    var subtitle: String? = nil
    let startDate: Date
    let endDate: Date
    var isAllDay = false
    let color: Color
    var isCompleted = false
}

enum TimelineMetrics {
    static let hourHeight: CGFloat = 44
    static let labelWidth: CGFloat = 48
    static let blockRadius: CGFloat = 5
}

/// Hour lines, event blocks and (on today) the now line, for `hours` of `day`.
struct TimelineHourGrid: View {
    let items: [TimelineItem]
    let day: Date
    let hours: ClosedRange<Int>
    var now: Date = .now
    var onTap: ((TimelineItem) -> Void)? = nil

    private let calendar = Calendar.current
    private var hourHeight: CGFloat { TimelineMetrics.hourHeight }
    private var labelWidth: CGFloat { TimelineMetrics.labelWidth }

    private var showsNow: Bool {
        calendar.isDate(now, inSameDayAs: day) && hours.contains(calendar.component(.hour, from: now))
    }

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = geometry.size.width - labelWidth - 8
            ZStack(alignment: .topLeading) {
                hourLines
                ForEach(layout()) { placed in
                    block(placed, contentWidth: contentWidth)
                }
                if showsNow { nowLine(width: geometry.size.width) }
            }
        }
        .frame(height: CGFloat(hours.count) * hourHeight)
    }

    // MARK: Grid

    private var hourLines: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(hours), id: \.self) { hour in
                HStack(alignment: .top, spacing: 0) {
                    Text(String(format: "%02d:00", hour % 24))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .opacity(hidesLabel(hour) ? 0 : 1)
                        .frame(width: labelWidth, alignment: .trailing)
                        .padding(.trailing, 8)
                        .offset(y: -7)
                    Rectangle()
                        .fill(.quaternary)
                        .frame(height: 0.5)
                        .frame(maxWidth: .infinity)
                }
                .frame(height: hourHeight, alignment: .top)
                .id("hour-\(hour)")
            }
        }
    }

    /// Like Apple Calendar: the hour label that would collide with the now label steps aside.
    private func hidesLabel(_ hour: Int) -> Bool {
        guard showsNow else { return false }
        let minutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        return abs(minutes - hour * 60) < 20
    }

    private func y(for date: Date) -> CGFloat {
        let seconds = date.timeIntervalSince(calendar.startOfDay(for: day)) - Double(hours.lowerBound) * 3600
        return CGFloat(seconds / 3600) * hourHeight
    }

    private func nowLine(width: CGFloat) -> some View {
        // Laid out top-down from the grid's top edge so the line's centre sits exactly on `now`.
        VStack(spacing: 0) {
            Color.clear.frame(height: max(y(for: now) - 8, 0))
            HStack(spacing: 0) {
                Text(now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.red)
                    .frame(width: labelWidth - 4, alignment: .trailing)
                    .padding(.trailing, 4)
                Circle().fill(.red).frame(width: 8, height: 8)
                Rectangle().fill(.red).frame(height: 1.5)
            }
            .frame(height: 16)
            Spacer(minLength: 0)
        }
        .frame(width: width, height: CGFloat(hours.count) * hourHeight, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Blocks (column layout as in TimelineUI)

    private struct Placed: Identifiable {
        let item: TimelineItem
        var column = 0
        var totalColumns = 1
        var id: String { item.id }
    }

    private func layout() -> [Placed] {
        let dayStart = calendar.startOfDay(for: day)
        let rangeStart = dayStart.addingTimeInterval(Double(hours.lowerBound) * 3600)
        let rangeEnd = dayStart.addingTimeInterval(Double(hours.upperBound + 1) * 3600)
        var placed = items.filter { !$0.isAllDay && $0.startDate < rangeEnd && $0.endDate > rangeStart }
            .sorted { $0.startDate < $1.startDate }
            .map { Placed(item: $0) }
        var columns: [[Placed]] = []
        for index in placed.indices {
            if let column = columns.firstIndex(where: { ($0.last?.item.endDate ?? .distantPast) <= placed[index].item.startDate }) {
                placed[index].column = column
                columns[column].append(placed[index])
            } else {
                placed[index].column = columns.count
                columns.append([placed[index]])
            }
        }
        let total = max(columns.count, 1)
        for index in placed.indices { placed[index].totalColumns = total }
        return placed
    }

    private func block(_ placed: Placed, contentWidth: CGFloat) -> some View {
        let item = placed.item
        let top = max(y(for: item.startDate), 0)
        let bottom = min(y(for: item.endDate), CGFloat(hours.count) * hourHeight)
        let height = max(bottom - top, 24)
        let width = contentWidth / CGFloat(placed.totalColumns)
        let x = labelWidth + 8 + width * CGFloat(placed.column)
        return HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(item.isCompleted ? Color.secondary : item.color).frame(width: 4)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    if item.isCompleted { Image(systemName: "checkmark") }
                    Text(item.title).strikethrough(item.isCompleted).lineLimit(1)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(item.isCompleted ? .secondary : .primary)
                if let subtitle = item.subtitle, height > 36 {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 8)
            .padding(.top, 4)
            Spacer(minLength: 0)
        }
        .frame(width: width - 2, height: height, alignment: .topLeading)
        .background(item.isCompleted ? Color.secondary.opacity(0.08) : item.color.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: TimelineMetrics.blockRadius, style: .circular))
        .offset(x: x, y: top)
        .onTapGesture { onTap?(item) }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(item.startDate.formatted(date: .omitted, time: .shortened)) \(item.title)\(item.isCompleted ? "，已完成" : "")")
    }
}

/// All-day items above the grid, as in TimelineUI (thin bar + caption), with a Chinese overflow line.
struct TimelineAllDaySection: View {
    let items: [TimelineItem]
    var limit = 3
    var onTap: ((TimelineItem) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("全天").font(.caption).foregroundStyle(.secondary)
            ForEach(items.prefix(limit)) { item in
                Button { onTap?(item) } label: {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(item.color).frame(width: 4, height: 16)
                        if item.isCompleted { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                        Text(item.title).font(.subheadline).strikethrough(item.isCompleted)
                            .foregroundStyle(item.isCompleted ? .secondary : .primary).lineLimit(1)
                        if let subtitle = item.subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if items.count > limit {
                Text("还有 \(items.count - limit) 项").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, TimelineMetrics.labelWidth + 8)
    }
}

/// A few hours around now (today) or around the day's first event — for the home card.
struct CompactTimelineView: View {
    let items: [TimelineItem]
    let day: Date
    var visibleHours = 4
    var anchorHour: Int? = nil
    var now: Date = .now
    var onTap: ((TimelineItem) -> Void)? = nil

    /// The hours this card shows. Items outside it are listed by the caller.
    static func window(items: [TimelineItem], day: Date, visibleHours: Int, anchorHour: Int? = nil, now: Date = .now,
                       calendar: Calendar = .current) -> ClosedRange<Int> {
        let anchor: Int
        if let anchorHour {
            anchor = anchorHour
        } else if calendar.isDate(now, inSameDayAs: day) {
            anchor = calendar.component(.hour, from: now)
        } else if let first = items.filter({ !$0.isAllDay }).map(\.startDate).min() {
            anchor = calendar.component(.hour, from: first)
        } else {
            anchor = 9
        }
        let start = min(max(0, anchor), 24 - visibleHours)
        return start...(start + visibleHours - 1)
    }

    var body: some View {
        TimelineHourGrid(items: items, day: day,
                         hours: Self.window(items: items, day: day, visibleHours: visibleHours, anchorHour: anchorHour, now: now),
                         now: now, onTap: onTap)
    }
}

/// The whole day: all-day items on top, 24 hours below, opened scrolled to now or the first event.
struct DayTimelineView: View {
    let items: [TimelineItem]
    let day: Date
    var now: Date = .now
    var onTap: ((TimelineItem) -> Void)? = nil

    private var allDay: [TimelineItem] { items.filter(\.isAllDay) }

    var scrollAnchorHour: Int {
        let calendar = Calendar.current
        if calendar.isDate(now, inSameDayAs: day) { return max(0, calendar.component(.hour, from: now) - 1) }
        if let first = items.filter({ !$0.isAllDay }).map(\.startDate).min() {
            return max(0, calendar.component(.hour, from: first) - 1)
        }
        return 8
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !allDay.isEmpty {
                TimelineAllDaySection(items: allDay, onTap: onTap)
                Divider()
            }
            TimelineHourGrid(items: items, day: day, hours: 0...23, now: now, onTap: onTap)
                .padding(.top, 8)
        }
    }
}
