import SwiftUI

/// 手表主页：上下翻两页。
/// 第一页「今天」是抬腕那一眼要看到的：下一节（或正在上的那节）放最上面，下面是今天全部的课按时间排；
/// 第二页是学员课时余额，剩得最少的在前。点任意一节进详情（只读）。
struct WatchHomeView: View {
    let snapshot: WatchSnapshot
    let openFirst: Bool
    @State private var page: Int
    @State private var path: [WatchSnapshot.Lesson] = []

    init(snapshot: WatchSnapshot, startPage: Int = 0, openFirst: Bool = false) {
        self.snapshot = snapshot
        self.openFirst = openFirst
        _page = State(initialValue: startPage)
    }

    var body: some View {
        NavigationStack(path: $path) {
            TabView(selection: $page) {
                // 只在课程开始/结束或课表跨日时刷新；时间显示没有倒计时，不必每分钟重画整页。
                TimelineView(.explicit(refreshDates(from: Date()))) { ctx in
                    WatchTodayPage(snapshot: snapshot, now: ctx.date)
                }
                .containerBackground(WatchStyle.todayBackground, for: .tabView)
                .tag(0)
                WatchBalancesPage(snapshot: snapshot)
                    .containerBackground(WatchStyle.balanceBackground, for: .tabView)
                    .tag(1)
            }
            .tabViewStyle(.verticalPage)
            .navigationDestination(for: WatchSnapshot.Lesson.self) { WatchLessonDetail(lesson: $0) }
        }
        .onAppear {
            // 主页只在拿到快照后才出现：这就是手表上「第一屏有数据」的时刻
            LaneSignal.ready("watch-today")
            if openFirst, path.isEmpty, let first = snapshot.next(after: Date()) ?? snapshot.lessons.first {
                path = [first]
            }
        }
    }

    private func refreshDates(from now: Date) -> [Date] {
        var boundaries = snapshot.lessons.flatMap { [$0.startDate, $0.endDate] }
        // 未来课表在当天零点成为「今天」，当天课表在次日零点显示过期提醒。
        let dayStart = TZ.date(fromDate: snapshot.day)
        boundaries.append(dayStart)
        if let dayEnd = TZ.calendar.date(byAdding: .day, value: 1, to: dayStart) {
            boundaries.append(dayEnd)
        }
        return [now] + Set(boundaries.filter { $0 > now }).sorted()
    }
}

enum WatchStyle {
    static let todayBackground = LinearGradient(colors: [Color.accentColor.opacity(0.55), Color.accentColor.opacity(0.08)],
                                                startPoint: .top, endPoint: .bottom)
    static let balanceBackground = LinearGradient(colors: [Color.green.opacity(0.40), Color.green.opacity(0.05)],
                                                  startPoint: .top, endPoint: .bottom)

    /// 剩几节的颜色：≤1 红、≤3 橙，其余正常（与 iPhone 学员卡「快用完」同一档口径的手表版）
    static func remainingTint(_ n: Int) -> Color {
        n <= 1 ? .red : n <= 3 ? .orange : .primary
    }

    static func statusLabel(_ status: String) -> String { Vocab.statusShort[status] ?? status }
}

// MARK: - 第一页：今天

struct WatchTodayPage: View {
    let snapshot: WatchSnapshot
    let now: Date

    private var today: Bool { snapshot.isToday(now) }

    var body: some View {
        List {
            if !today {
                Label("这是 \(TZ.md(snapshot.day)) 的课表，打开 iPhone 上的上门体育刷新", systemImage: "exclamationmark.arrow.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .listRowBackground(Color.clear)
            }
            if today, let next = snapshot.next(after: now) {
                NavigationLink(value: next) { WatchNextCard(lesson: next, now: now) }
                    .listRowBackground(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.16)))
            } else if today {
                Label(snapshot.lessons.isEmpty ? "今天没有课" : "今天的课都上完了",
                      systemImage: snapshot.lessons.isEmpty ? "cup.and.saucer" : "checkmark.circle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(snapshot.lessons.isEmpty ? Color.secondary : Color.green)
            }

            if !snapshot.lessons.isEmpty {
                Section {
                    ForEach(snapshot.lessons) { l in
                        NavigationLink(value: l) { WatchLessonRow(lesson: l, now: now) }
                    }
                } header: {
                    Text(today ? "今天 \(snapshot.lessons.count) 节" : "\(TZ.md(snapshot.day)) · \(snapshot.lessons.count) 节")
                }
            }

            Text("更新于 \(TZ.timeString(snapshot.generatedAt))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .listRowBackground(Color.clear)
        }
        .navigationTitle("今天")
    }
}

/// 最上面那张卡：下一节（或正在上的那节）。
struct WatchNextCard: View {
    let lesson: WatchSnapshot.Lesson
    let now: Date

    private var live: Bool { lesson.startDate <= now }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(live ? "正在上" : "下一节")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(live ? Color.green : Color.accentColor)
            Text("\(lesson.start)–\(lesson.end)")
                .font(.system(.title3, design: .rounded).weight(.bold))
                .monospacedDigit()
            Text(lesson.student)
                .font(.headline)
                .lineLimit(1)
            if let place = lesson.place, !place.isEmpty {
                // 不用 Label：手表上 Label 的图标列很宽，地点会被推到半屏外
                HStack(spacing: 3) {
                    Image(systemName: "mappin").font(.system(size: 10, weight: .semibold))
                    Text(place).lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if let left = lesson.remaining {
                Text("剩 \(left) 节")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(WatchStyle.remainingTint(left))
            }
        }
        .padding(.vertical, 4)
    }
}

struct WatchLessonRow: View {
    let lesson: WatchSnapshot.Lesson
    let now: Date

    private var finished: Bool { lesson.status != "scheduled" }

    var body: some View {
        HStack(spacing: 8) {
            Text(lesson.start)
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .frame(width: 42, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(lesson.student)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                if let place = lesson.place, !place.isEmpty {
                    Text(place)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 2)
            WatchStatusGlyph(lesson: lesson, now: now)
        }
        .opacity(finished ? 0.62 : 1)
    }
}

/// 状态一个符号：已上 ✓、未到 !、已取消 ×、该标没标（已结束仍是已排课）红色闹钟、正在上 实心点、待上 空心圈。
struct WatchStatusGlyph: View {
    let lesson: WatchSnapshot.Lesson
    let now: Date

    var body: some View {
        let (name, tint): (String, Color) = {
            switch lesson.status {
            case "completed": return ("checkmark.circle.fill", .green)
            case "no_show": return ("exclamationmark.circle.fill", .orange)
            case "cancelled": return ("xmark.circle", .secondary)
            default:
                if lesson.endDate <= now { return ("clock.badge.exclamationmark", .red) }
                if lesson.startDate <= now { return ("circle.inset.filled", .green) }
                return ("circle", .secondary)
            }
        }()
        Image(systemName: name)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(tint)
            .accessibilityLabel(lesson.isOpen && lesson.endDate <= now ? "待处理" : WatchStyle.statusLabel(lesson.status))
    }
}

// MARK: - 第二页：课时余额

struct WatchBalancesPage: View {
    let snapshot: WatchSnapshot

    var body: some View {
        List {
            if snapshot.balances.isEmpty {
                Text("还没有录课包的学员").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(snapshot.balances) { b in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(b.name).font(.footnote.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(b.remaining)")
                            .font(.system(.title3, design: .rounded).weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(WatchStyle.remainingTint(b.remaining))
                        Text("节").font(.caption2).foregroundStyle(.secondary)
                    }
                    if b.expiringSoon > 0 {
                        Text("\(b.expiringSoon) 节 14 天内到期").font(.caption2).foregroundStyle(.orange)
                    }
                    if b.lapsed > 0 {
                        Text("另有 \(b.lapsed) 节已过期").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("课时余额")
    }
}

// MARK: - 一节课（只读）

struct WatchLessonDetail: View {
    let lesson: WatchSnapshot.Lesson

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(lesson.start)–\(lesson.end)")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .monospacedDigit()
                Text(lesson.student).font(.headline)
                if let place = lesson.place, !place.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.and.ellipse").font(.caption)
                        Text(place)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                if !lesson.content.isEmpty {
                    Text(lesson.content).font(.footnote)
                }
                HStack(spacing: 6) {
                    Text(WatchStyle.statusLabel(lesson.status))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.15)))
                    if let left = lesson.remaining {
                        Text("剩 \(left) 节")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(WatchStyle.remainingTint(left))
                    }
                }
                Text("改状态请在 iPhone 上操作")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(lesson.student)
    }
}
