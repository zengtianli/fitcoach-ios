import SwiftUI
import Charts   // Swift Charts：系统框架（iOS 16+，本 target 18），零第三方依赖

// ── 成长数据 ────────────────────────────────────────────────────────────────
// ⚠ 全文件唯一一条铁律：**「进步了没有」不在这一侧判**。
// 后端 domain._progress 已经过了 higher_is_better（50 米跑变快 = 数值变小也是进步），
// 结论经 `improved: Bool?` 送来。这里只负责把它画成箭头和颜色。
// 任何地方写 `delta > 0` 就是第二实现，那正是「同一判据两份」的结构性 bug 来源。

/// 进步与否 → 配色 / 图标 / 文案。**唯一**消费 `improved` 的地方。
enum Progress {
    static func tone(_ improved: Bool?) -> Theme.Tone {
        guard let i = improved else { return .neutral }
        return i ? .ok : .warn
    }
    /// 箭头只表示**数值往哪边走**（delta 的符号），**不表示好坏**。
    /// 好坏走颜色（tone）和文字（label），那才是后端 improved 的结论。
    ///
    /// 为什么要分开：体重 −4.6 是进步，但数值是降的。早先箭头跟着 improved 走，
    /// 于是屏幕上出现「↗ −4.6」—— 箭头朝上、数字是负的，自相矛盾
    /// （2026-08-27 模拟器实测，体重和 50 米跑两项都这样）。
    /// 现在：箭头跟数字，颜色跟判据，两个信息各走各的通道，谁都不骗人。
    static func arrow(delta: Double, improved: Bool?) -> String {
        guard improved != nil else { return "minus" }   // 首测：还没有「变化」
        if delta > 0 { return "arrow.up.right" }
        if delta < 0 { return "arrow.down.right" }
        return "minus"
    }
    /// 给教练看的短标签
    static func label(_ improved: Bool?) -> String {
        guard let i = improved else { return "首测" }
        return i ? "进步" : "退步"
    }
    /// 给家长看的人话（学员端用）
    static func parentLabel(_ improved: Bool?) -> String {
        guard let i = improved else { return "刚做完第一次测试" }
        return i ? "比第一次有进步" : "比第一次退了一点"
    }
}

// ── 教练端：学员详情里的成长区块 ────────────────────────────────────────────

/// 一个项目一行：最新值 / 相对首测的变化 / 测了几次。点进去看趋势图。
struct MetricProgressRow: View {
    let p: MetricProgress

    var body: some View {
        let tone = Progress.tone(p.improved)
        let (fg, bg) = Theme.pair(tone)
        return HStack(spacing: 11) {
            VStack(alignment: .leading, spacing: 3) {
                Text(p.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                HStack(spacing: 4) {
                    Text(p.latest_on).font(.caption2).monospacedDigit()
                        .foregroundStyle(Theme.ink3)
                    Text("·").font(.caption2).foregroundStyle(Theme.ink3)
                    Text("测过 \(p.n_points) 次").font(.caption2).monospacedDigit()
                        .foregroundStyle(Theme.ink3)
                }
            }
            Spacer(minLength: 4)

            // 最新值：这一屏里最该被一眼看到的数
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(Num.s(p.latest_value))
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .monospacedDigit().foregroundStyle(Theme.ink)
                Text(p.unit).font(.caption2).foregroundStyle(Theme.ink3)
            }

            // 相对首测的变化。只测过一次时 improved == nil，显示「首测」而不是「±0」
            HStack(spacing: 3) {
                Image(systemName: Progress.arrow(delta: p.delta, improved: p.improved))
                    .font(.system(size: 9, weight: .bold))
                Text(p.improved == nil ? "首测" : Num.signed(p.delta))
                    .font(.caption.weight(.semibold)).monospacedDigit()
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(bg).foregroundStyle(fg)
            .clipShape(Capsule())
            .frame(minWidth: 62, alignment: .trailing)

        }
    }
}

/// 学员详情页里的整块「成长数据」。**自己吐 List 行**（分组标题 + 卡片），
/// 所以父页面直接把它摆在 List 里就行，不用再包 Section。
///
/// 成长数据是独立取的：它 500 / 404 时不该把整个学员详情页拖黑，
/// 所以失败在这一块里就地报，其余区块照常显示。
struct GrowthPanel: View {
    let studentId: Int
    let data: GrowthResp?
    let err: String?
    let onRecord: () -> Void
    let onReload: () -> Void

    var body: some View {
        Group {
            GroupTitle(text: "成长数据",
                       trailing: data.map { "\($0.progress.count) 项" },
                       icon: "chart.line.uptrend.xyaxis")
                .cardRow(top: 14, bottom: 2)

            if let e = err {
                CardBox { ErrorBar(text: e) }.cardRow()
            } else if let d = data {
                // 出勤：家长第二关心的事，教练端也要一眼看到
                CardBox {
                    HStack(spacing: 8) {
                        StatBlock(value: "\(d.attendance.rate)%", label: "到课率",
                                  tone: d.attendance.rate >= 90 ? .ok : .warn)
                        StatBlock(value: "\(d.attendance.completed)", label: "已上课")
                        StatBlock(value: "\(d.attendance.no_show)", label: "未到",
                                  tone: d.attendance.no_show > 0 ? .warn : .neutral)
                        StatBlock(value: "\(d.attendance.cancelled)", label: "已取消")
                    }
                }
                .cardRow()

                CardBox {
                    if d.progress.isEmpty {
                        EmptyState(icon: "chart.line.uptrend.xyaxis",
                                   title: d.metrics.isEmpty ? "还没有体测项目" : "还没有测量记录",
                                   detail: d.metrics.isEmpty
                                        ? "先到「更多 → 体测项目」建几个项目，再回来录成绩。"
                                        : "录第一次成绩，之后每次测完都能看到趋势。",
                                   tone: .accent,
                                   action: d.metrics.isEmpty ? nil : ("录一次成绩", onRecord))
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(d.progress.enumerated()), id: \.element.metric_id) { i, p in
                                NavigationLink {
                                    MetricTrendView(studentId: studentId,
                                                    progress: p,
                                                    points: d.series[String(p.metric_id)] ?? [],
                                                    measurements: d.measurements.filter {
                                                        $0.metric_id == p.metric_id
                                                    },
                                                    onChanged: onReload)
                                } label: {
                                    MetricProgressRow(p: p)
                                }
                                .buttonStyle(.plain)
                                if i < d.progress.count - 1 {
                                    Divider().overlay(Theme.hairline).padding(.vertical, 9)
                                }
                            }
                        }
                    }
                }
                .cardRow()

                if !d.progress.isEmpty {
                    Button(action: onRecord) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                            Text("录一次成绩").font(.subheadline.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Theme.accentSoft)
                        .foregroundStyle(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.rInner, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .cardRow(top: 2)
                }
            } else {
                CardBox { Loading() }.cardRow()
            }
        }
    }
}

// ── 趋势图 ──────────────────────────────────────────────────────────────────

/// 一个项目的趋势。Swift Charts 画折线 + 点，下面列每次测量（含备注，教练端才有）。
struct MetricTrendView: View {
    @EnvironmentObject var session: Session
    let studentId: Int
    let progress: MetricProgress
    let points: [GrowthPoint]
    let measurements: [Measurement]
    /// 删掉一条测量后通知父页面重取 —— 趋势/首测/最好成绩全要重算
    var onChanged: () -> Void = {}

    @State private var deleting: Measurement?
    @State private var err: String?
    @Environment(\.dismiss) private var dismiss

    /// Y 轴范围：留 12% 余量。默认从 0 起会把「63.9→65.2 的下降」压成一条直线，
    /// 看不出任何变化 —— 体测数值的信息全在小幅波动里。
    private var yRange: ClosedRange<Double> {
        let vs = points.map(\.value)
        guard let lo = vs.min(), let hi = vs.max() else { return 0...1 }
        if lo == hi { return (lo - max(abs(lo) * 0.1, 1))...(hi + max(abs(hi) * 0.1, 1)) }
        let pad = (hi - lo) * 0.12
        return (lo - pad)...(hi + pad)
    }

    private var tone: Theme.Tone { Progress.tone(progress.improved) }

    var body: some View {
        List {
            if let e = err { ErrorBar(text: e).cardRow(top: 8) }

            // 结论卡：三个数一眼看完
            CardBox {
                VStack(spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(Num.s(progress.latest_value))
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink)
                        Text(progress.unit).font(.title3).foregroundStyle(Theme.ink3)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Pill(text: Progress.label(progress.improved),
                                 tone: tone,
                                 icon: Progress.arrow(delta: progress.delta,
                                                      improved: progress.improved))
                            Text("最新 \(progress.latest_on)")
                                .font(.caption2).monospacedDigit().foregroundStyle(Theme.ink3)
                        }
                    }
                    HStack(spacing: 8) {
                        StatBlock(value: progress.improved == nil ? "—" : Num.signed(progress.delta),
                                  label: "相对首测", tone: tone)
                        StatBlock(value: Num.s(progress.best_value), label: "历史最好", tone: .accent)
                        StatBlock(value: "\(progress.n_points)", label: "测量次数")
                    }
                    HStack {
                        Text("首测 \(progress.first_on) · \(Num.s(progress.first_value)) \(progress.unit)")
                            .font(.caption2).monospacedDigit().foregroundStyle(Theme.ink3)
                        Spacer()
                        Text(progress.higher_is_better == 1 ? "越高越好" : "越低越好")
                            .font(.caption2).foregroundStyle(Theme.ink3)
                    }
                }
            }
            .cardRow(top: 8)

            GroupTitle(text: "趋势", icon: "chart.xyaxis.line").cardRow(top: 12, bottom: 2)
            CardBox {
                if points.count < 2 {
                    EmptyState(icon: "chart.dots.scatter",
                               title: "只测过一次",
                               detail: "再测一次就能看到趋势线。",
                               tone: .accent)
                } else {
                    chart.frame(height: 210)
                }
            }
            .cardRow()

            GroupTitle(text: "每次测量", trailing: "\(measurements.count) 条",
                       icon: "list.bullet").cardRow(top: 12, bottom: 2)
            ForEach(measurements) { m in
                CardBox(padding: 12) {
                    HStack(spacing: 10) {
                        Text(m.taken_on).font(.caption).monospacedDigit()
                            .foregroundStyle(Theme.ink2).frame(width: 78, alignment: .leading)
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(Num.s(m.value))
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .monospacedDigit().foregroundStyle(Theme.ink)
                            Text(m.unit).font(.caption2).foregroundStyle(Theme.ink3)
                        }
                        Spacer(minLength: 4)
                        // 备注是教练自用的，学员端结构上拿不到（StudentGrowthView 没这字段）
                        if !m.note.isEmpty {
                            Text(m.note).font(.caption).foregroundStyle(Theme.ink3)
                                .lineLimit(1)
                        }
                    }
                }
                .cardRow(top: 3, bottom: 3)
                .swipeActions(edge: .trailing) {
                    Button("删除", role: .destructive) { deleting = m }
                }
            }
        }
        .listStyle(.plain)
        .pageBackground()
        .navigationTitle(progress.name)
        .navigationBarTitleDisplayMode(.inline)
        .alert("删除这条测量？", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        )) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) {
                if let m = deleting { Task { await remove(m) } }
            }
        } message: {
            Text("删掉后趋势会重算。这条记录不可恢复。")
        }
    }

    private var chart: some View {
        let (fg, _) = Theme.pair(tone)
        return Chart {
            ForEach(points) { p in
                let d = TZ.date(fromDate: p.taken_on)
                AreaMark(x: .value("日期", d), y: .value("值", p.value))
                    .foregroundStyle(
                        .linearGradient(colors: [fg.opacity(0.22), fg.opacity(0.02)],
                                        startPoint: .top, endPoint: .bottom)
                    )
                    .interpolationMethod(.monotone)
                LineMark(x: .value("日期", d), y: .value("值", p.value))
                    .foregroundStyle(fg)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("日期", d), y: .value("值", p.value))
                    .foregroundStyle(fg)
                    .symbolSize(58)
            }
        }
        .chartYScale(domain: yRange)
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel {
                    if let d = v.as(Double.self) {
                        Text(Num.s(d)).font(.caption2).monospacedDigit()
                            .foregroundStyle(Theme.ink3)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { v in
                AxisValueLabel {
                    if let d = v.as(Date.self) {
                        Text(TZ.md(TZ.dateString(d))).font(.caption2).monospacedDigit()
                            .foregroundStyle(Theme.ink3)
                    }
                }
            }
        }
    }

    private func remove(_ m: Measurement) async {
        deleting = nil
        do {
            try await API(session).post("/coach/api/measurements/\(m.id)/delete", [:])
            onChanged()
            dismiss()          // 这一页的 points 是传进来的快照，删完必须退回去重取
        } catch {
            err = errText(error)
        }
    }
}

// ── 录成绩 ──────────────────────────────────────────────────────────────────

/// 项目下拉 + 日期 + 数值 + 备注 → POST /coach/api/students/{id}/measurements
struct MeasurementFormSheet: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let studentId: Int
    var preselect: Int? = nil
    let onDone: () -> Void

    /// 项目列表自己取 —— 这个表单从学员详情、趋势页等多处弹出，
    /// 让每个调用方各传一份 metrics 迟早会有一处传的是过期快照。
    @State private var metrics: [Metric] = []
    @State private var metricId: Int = 0
    @State private var day = Date()
    @State private var value = ""
    @State private var note = ""
    @State private var busy = false
    @State private var err: String?

    private var picked: Metric? { metrics.first { $0.id == metricId } }

    var body: some View {
        NavigationStack {
            Form {
                if let e = err { Section { ErrorBar(text: e) } }

                if metrics.isEmpty {
                    Section {
                        Text("还没有可用的体测项目。先到「更多 → 体测项目」建几个。")
                            .font(.footnote).foregroundStyle(Theme.ink2)
                    }
                }

                Section("项目") {
                    Picker("项目", selection: $metricId) {
                        Text("请选择").tag(0)
                        ForEach(metrics) { m in
                            Text(m.unit.isEmpty ? m.name : "\(m.name)（\(m.unit)）").tag(m.id)
                        }
                    }
                }

                // 注意：Section 没有「String 标题 + footer 闭包」这个初始化器
                // （只有 Section(_:content:) 或 Section(content:header:footer:)）。
                // 写成 Section("…") { } footer: { } 会报「generic parameter 'Content'
                // could not be inferred」—— 报错位置指向 Section，看起来像 body 太复杂，
                // 其实是重载选错了。要 footer 就必须把标题也写成 header 闭包。
                Section {
                    DatePicker("测量日期", selection: $day, displayedComponents: .date)
                        .environment(\.timeZone, TZ.zone)
                    HStack {
                        Text("成绩")
                        Spacer()
                        TextField("数值", text: $value)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(maxWidth: 120)
                        if let m = picked, !m.unit.isEmpty {
                            Text(m.unit).foregroundStyle(Theme.ink3)
                        }
                    }
                } header: {
                    Text("这一次")
                } footer: {
                    if let m = picked {
                        Text(m.higher_is_better == 1
                             ? "这个项目**数值越大越好**，进步与否由服务器判定。"
                             : "这个项目**数值越小越好**（如跑步用时、体重），进步与否由服务器判定。")
                    }
                }

                Section {
                    TextField("备注（学员端看不到）", text: $note, axis: .vertical)
                        .lineLimit(1...4)
                } footer: {
                    Text("备注只有你能看到 —— 学员端的成长视图结构上就没有这个字段。")
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack { Spacer()
                            if busy { ProgressView() } else { Text("保存").bold() }
                            Spacer() }
                    }
                    .disabled(busy || metricId == 0 || value.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("录成绩")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .task { await loadMetrics() }
        }
    }

    /// 只列在用的项目：停用项不该出现在录成绩的下拉里（停用不删的语义）
    private func loadMetrics() async {
        do {
            let r: MetricsResp = try await API(session).get("/coach/api/metrics")
            metrics = r.metrics.filter { $0.is_active == 1 }
            if metricId == 0 { metricId = preselect ?? metrics.first?.id ?? 0 }
        } catch {
            err = errText(error)
        }
    }

    private func submit() async {
        busy = true; err = nil
        defer { busy = false }
        do {
            // 数值不在客户端做范围/格式校验 —— 判据在后端 record_measurement，
            // 这边多一份就会两边漂移。非法值后端回 400，原样呈现。
            try await API(session).post("/coach/api/students/\(studentId)/measurements", [
                "metric_id": String(metricId),
                "taken_on": TZ.dateString(day),
                "value": value.trimmingCharacters(in: .whitespaces),
                "note": note,
            ])
            onDone(); dismiss()
        } catch {
            err = errText(error)
        }
    }
}

// ── 迷你趋势线（学员端用）──────────────────────────────────────────────────

/// 家长端的小趋势线：不要坐标轴、不要标注，只要「这条线在往哪走」。
/// 与教练端 MetricTrendView 共用同一份 points 数据，图形实现都留在本文件里 ——
/// 学员端另写一份 Chart 就会出现「两侧曲线画法不一致」的漂移。
struct Sparkline: View {
    let points: [GrowthPoint]
    let tone: Theme.Tone

    private var yRange: ClosedRange<Double> {
        let vs = points.map(\.value)
        guard let lo = vs.min(), let hi = vs.max() else { return 0...1 }
        if lo == hi { return (lo - max(abs(lo) * 0.1, 1))...(hi + max(abs(hi) * 0.1, 1)) }
        let pad = (hi - lo) * 0.18
        return (lo - pad)...(hi + pad)
    }

    var body: some View {
        let (fg, _) = Theme.pair(tone)
        Chart {
            ForEach(points) { p in
                let d = TZ.date(fromDate: p.taken_on)
                AreaMark(x: .value("日期", d), y: .value("值", p.value))
                    .foregroundStyle(.linearGradient(
                        colors: [fg.opacity(0.25), fg.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("日期", d), y: .value("值", p.value))
                    .foregroundStyle(fg)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
            if let last = points.last {
                PointMark(x: .value("日期", TZ.date(fromDate: last.taken_on)),
                          y: .value("值", last.value))
                    .foregroundStyle(fg)
                    .symbolSize(42)
            }
        }
        .chartYScale(domain: yRange)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
    }
}
