import SwiftUI
import WidgetKit

/// 表盘复杂功能「下一节课」的画法。表盘扩展（WatchWidget/）和手表 app 里的预览页（-fitcoach.watchScreen complications）
/// 编同一份 —— 模拟器上配不了表盘，预览页是这些画面唯一能被截图核对的地方。
struct NextLessonState {
    let date: Date
    let snapshot: WatchSnapshot?

    /// 快照是今天的才算数：过了零点、或 iPhone 好几天没打开，宁可显示「去同步」也不显示昨天的课
    var today: Bool { snapshot?.isToday(date) ?? false }
    var lessons: [WatchSnapshot.Lesson] { today ? snapshot?.lessons ?? [] : [] }
    var next: WatchSnapshot.Lesson? { today ? snapshot?.next(after: date) : nil }
    /// 今天要上的（不含取消的）与其中已经结束的 —— 圆形进度环用
    var total: Int { lessons.filter { $0.status != "cancelled" }.count }
    var done: Int { lessons.filter { $0.status != "cancelled" && ($0.status != "scheduled" || $0.endDate <= date) }.count }
    var left: Int { today ? snapshot?.upcoming(after: date).count ?? 0 : 0 }
    var live: Bool { next.map { $0.startDate <= date } ?? false }

    var emptyLine: String {
        if snapshot == nil || !today { return "打开 iPhone 同步课表" }
        return lessons.isEmpty ? "今天没有课" : "今天的课都上完了"
    }
}

struct NextLessonComplication: View {
    @Environment(\.widgetFamily) private var family
    let state: NextLessonState

    var body: some View {
        switch family {
        case .accessoryCircular: NextCircular(state: state)
        case .accessoryInline: NextInline(state: state)
        case .accessoryCorner: NextCorner(state: state)
        default: NextRectangular(state: state)
        }
    }
}

/// 圆形：今天的进度环（已结束 / 今天总共）+ 中间下一节的开始时间。
struct NextCircular: View {
    let state: NextLessonState

    var body: some View {
        if let n = state.next {
            Gauge(value: Double(state.done), in: 0...Double(max(state.total, 1))) {
                Image(systemName: "figure.strengthtraining.traditional")
            } currentValueLabel: {
                Text(n.start)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
        } else {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: state.today && state.total > 0 ? "checkmark" : "figure.strengthtraining.traditional")
                    .font(.system(size: 18, weight: .semibold))
                    .widgetAccentable()
            }
        }
    }
}

/// 矩形：下一节 HH:MM / 学员 · 地点 / 剩几节 · 今天还有几节。
struct NextRectangular: View {
    let state: NextLessonState

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let n = state.next {
                Label(state.live ? "正在上 \(n.start)" : "下一节 \(n.start)",
                      systemImage: "figure.strengthtraining.traditional")
                    .font(.headline)
                    .widgetAccentable()
                Text(n.place.map { "\(n.student) · \($0)" } ?? n.student)
                    .lineLimit(1)
                Text([n.remaining.map { "剩 \($0) 节" }, "今天还有 \(state.left) 节"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Label(AppName.short, systemImage: "figure.strengthtraining.traditional")
                    .font(.headline)
                    .widgetAccentable()
                Text(state.emptyLine).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 表盘顶上一行字。
struct NextInline: View {
    let state: NextLessonState

    var body: some View {
        if let n = state.next {
            Label("\(n.start) \(n.student)", systemImage: "figure.strengthtraining.traditional")
        } else {
            Label(state.emptyLine, systemImage: "figure.strengthtraining.traditional")
        }
    }
}

/// 四角：中间一个图标，沿弧写「HH:MM 学员」。
struct NextCorner: View {
    let state: NextLessonState

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: state.next == nil && state.today && state.total > 0 ? "checkmark"
                  : "figure.strengthtraining.traditional")
                .font(.system(size: 16, weight: .semibold))
                .widgetAccentable()
        }
        .widgetLabel {
            if let n = state.next {
                Text("\(n.start) \(n.student)")
            } else {
                Text(state.today && state.total > 0 ? "上完了" : AppName.short)
            }
        }
    }
}

enum AppName {
    static let short = "上门体育"
}
