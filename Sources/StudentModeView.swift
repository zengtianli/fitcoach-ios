import SwiftUI

/// 学员端：只读，凭同一条分享链接的 token。
/// 后端 `/s/api/view` 返回的是窄视图 —— 价格 / 备注 / 变更记录在结构上进不来。
/// 成长部分同理：`StudentGrowthView` 根本没有 note 字段（后端 INV-7 的延伸）。
///
/// 文案原则：**这一屏是给家长看的**。别把教练端的行话搬过来 ——
/// 「improved=false」写成「退步」会让家长第一反应是换机构，写成人话才有用。
struct StudentModeView: View {
    @EnvironmentObject var session: Session
    @State private var data: StudentView?
    @State private var err: String?
    @State private var loading = false

    var body: some View {
        NavigationStack {
            List {
                if let e = err { ErrorBar(text: e).cardRow(top: 10) }
                if loading && data == nil { CardBox { Loading() }.cardRow(top: 10) }

                if let d = data {
                    // ── 余额大字 ─────────────────────────────────────────
                    CardBox {
                        VStack(spacing: 6) {
                            Text("\(max(d.available_total, 0))")
                                .font(.system(size: 58, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Theme.accent)
                            Text("剩余可用课时")
                                .font(.subheadline).foregroundStyle(Theme.ink2)
                            if d.over_used > 0 {
                                Pill(text: "已超上 \(d.over_used) 节", tone: .danger,
                                     icon: "exclamationmark")
                            }
                            if d.lapsed_total > 0 {
                                Pill(text: "另有 \(d.lapsed_total) 节已过期未用", tone: .warn,
                                     icon: "hourglass")
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .cardRow(top: 10)

                    // ── 下一节 ───────────────────────────────────────────
                    if let n = d.next_session {
                        GroupTitle(text: "下一节课", icon: "calendar.badge.clock")
                            .cardRow(top: 14, bottom: 2)
                        CardBox(tint: Theme.accent) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(n.start_at)
                                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                                    .monospacedDigit().foregroundStyle(Theme.ink)
                                HStack(spacing: 6) {
                                    Pill(text: "\(n.duration_min) 分钟", tone: .neutral, icon: "clock")
                                    if let l = n.location_name, !l.isEmpty {
                                        Pill(text: l, tone: .neutral, icon: "mappin")
                                    }
                                }
                                if !n.content.isEmpty {
                                    Text(n.content).font(.caption).foregroundStyle(Theme.ink2)
                                }
                            }
                        }
                        .cardRow()
                    }

                    // ── 成长 ─────────────────────────────────────────────
                    if !d.growth.isEmpty {
                        GroupTitle(text: "训练成果", trailing: "\(d.growth.count) 项",
                                   icon: "chart.line.uptrend.xyaxis")
                            .cardRow(top: 14, bottom: 2)
                        ForEach(d.growth) { g in
                            StudentGrowthCell(g: g).cardRow()
                        }
                    }

                    // ── 课包 ─────────────────────────────────────────────
                    if !d.packages.isEmpty {
                        GroupTitle(text: "课包", trailing: "\(d.packages.count) 个",
                                   icon: "shippingbox")
                            .cardRow(top: 14, bottom: 2)
                        CardBox(padding: 12) {
                            VStack(spacing: 10) {
                                ForEach(d.packages) { p in
                                    HStack(spacing: 8) {
                                        Text("剩 \(p.remaining) 节")
                                            .font(.subheadline.weight(.medium)).monospacedDigit()
                                            .foregroundStyle(Theme.ink)
                                        Spacer()
                                        if let e = p.expires_on {
                                            Text("到期 \(e)")
                                                .font(.caption).monospacedDigit()
                                                .foregroundStyle(Theme.ink3)
                                        }
                                        BucketTag(bucket: p.bucket)
                                    }
                                    if p.id != d.packages.last?.id {
                                        Divider().overlay(Theme.hairline)
                                    }
                                }
                            }
                        }
                        .cardRow()
                    }

                    // ── 已取消的预约 ─────────────────────────────────────
                    if !d.upcoming_cancelled.isEmpty {
                        GroupTitle(text: "已取消的预约", trailing: "\(d.upcoming_cancelled.count)",
                                   icon: "xmark.circle")
                            .cardRow(top: 14, bottom: 2)
                        CardBox(padding: 12) {
                            VStack(spacing: 9) {
                                ForEach(d.upcoming_cancelled) { s in
                                    HStack {
                                        Text(TZ.mdhm(s.start_at))
                                            .font(.subheadline).monospacedDigit()
                                            .foregroundStyle(Theme.ink2)
                                        Spacer()
                                        StatusTag(status: s.status, label: s.status_label)
                                    }
                                }
                            }
                        }
                        .cardRow()
                    }

                    // ── 上课记录 ─────────────────────────────────────────
                    GroupTitle(text: "上课记录", trailing: "\(d.history.count) 节",
                               icon: "checkmark.circle")
                        .cardRow(top: 14, bottom: 2)
                    if d.history.isEmpty {
                        CardBox {
                            EmptyState(icon: "figure.run",
                                       title: "还没有上过课",
                                       detail: "第一节课上完后，这里会记下每一次训练。",
                                       tone: .accent)
                        }
                        .cardRow(bottom: 20)
                    }
                    ForEach(d.history) { s in
                        CardBox(padding: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(TZ.mdhm(s.start_at))
                                        .font(.subheadline.weight(.medium)).monospacedDigit()
                                        .foregroundStyle(Theme.ink)
                                    Spacer()
                                    StatusTag(status: s.status, label: s.status_label)
                                }
                                if !s.content.isEmpty || (s.location_name?.isEmpty == false) {
                                    HStack(spacing: 6) {
                                        if let l = s.location_name, !l.isEmpty {
                                            Pill(text: l, tone: .neutral, icon: "mappin")
                                        }
                                        if !s.content.isEmpty {
                                            Text(s.content).font(.caption)
                                                .foregroundStyle(Theme.ink2).lineLimit(1)
                                        }
                                    }
                                }
                            }
                        }
                        .cardRow(top: 3, bottom: 3)
                    }
                }
            }
            .listStyle(.plain)
            .pageBackground()
            .navigationTitle(data?.student_name ?? "我的课时")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await load() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("退出") { session.leaveStudent() }
                }
            }
            .task { if data == nil { await load() } }
        }
    }

    private func load() async {
        loading = true; err = nil
        defer { loading = false }
        do { data = try await API(session).get("/s/api/view", student: true) }
        catch APIError.gone {
            err = "这条链接已失效（可能被教练重新签发或吊销），找教练要一条新的。"
        }
        catch { err = errText(error) }
    }
}

/// 家长视角的一项成果。**没有备注** —— 后端窄 dataclass 里就没这个字段。
/// 文案走 Progress.parentLabel，别在这里另写一套「进步/退步」判断。
struct StudentGrowthCell: View {
    let g: StudentGrowthView

    var body: some View {
        let tone = Progress.tone(g.improved)
        let (fg, _) = Theme.pair(tone)
        return CardBox(padding: 13) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(g.name).font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Text(Num.s(g.latest_value))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit().foregroundStyle(Theme.ink)
                    Text(g.unit).font(.caption).foregroundStyle(Theme.ink3)
                }
                HStack(spacing: 6) {
                    HStack(spacing: 3) {
                        Image(systemName: Progress.arrow(delta: g.delta, improved: g.improved))
                            .font(.system(size: 9, weight: .bold))
                        Text(Progress.parentLabel(g.improved))
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(fg)
                    if g.improved != nil {
                        Text("（\(Num.signed(g.delta)) \(g.unit)）")
                            .font(.caption2).monospacedDigit().foregroundStyle(Theme.ink3)
                    }
                    Spacer()
                    Text("测了 \(g.n_points) 次 · \(TZ.md(g.latest_on))")
                        .font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(Theme.ink3)
                }
                if g.points.count >= 2 {
                    Sparkline(points: g.points, tone: tone)
                        .frame(height: 52)
                }
            }
        }
    }
}
