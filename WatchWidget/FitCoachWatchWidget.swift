import SwiftUI
import WidgetKit

/// 表盘复杂功能「下一节课」。**不联网**：读手表 app 写进本机钥匙串的「今天」快照（Watch/SnapshotStore.swift）。
///
/// 时间线在每节课结束的那一刻切到下一节，过零点再切一次（快照不是今天的就显示「打开 iPhone 同步课表」）。
/// 数据变了由手表 app 主动 reloadAllTimelines，不靠这里轮询。
struct NextEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchSnapshot?
}

struct NextProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextEntry {
        NextEntry(date: .now, snapshot: .demo())        // 系统会把占位打码，只看形状
    }

    func getSnapshot(in context: Context, completion: @escaping (NextEntry) -> Void) {
        completion(NextEntry(date: .now, snapshot: SnapshotStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextEntry>) -> Void) {
        let now = Date()
        let snap = SnapshotStore.load()
        let midnight = TZ.calendar.date(byAdding: .day, value: 1, to: TZ.calendar.startOfDay(for: now)) ?? now
        let dates = [now] + (snap?.changeDates(after: now) ?? []).filter { $0 < midnight } + [midnight]
        completion(Timeline(entries: dates.map { NextEntry(date: $0, snapshot: snap) }, policy: .after(midnight)))
    }
}

@main
struct FitCoachWatchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FitCoachNextLesson", provider: NextProvider()) { entry in
            NextLessonComplication(state: NextLessonState(date: entry.date, snapshot: entry.snapshot))
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("下一节课")
        .description("今天的下一节：时间、学员、地点与剩余课时")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}
