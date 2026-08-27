import SwiftUI

struct ScheduleView: View {
    @EnvironmentObject var session: Session
    @State private var range = "today"
    @State private var date = ""
    @State private var data: ScheduleResp?
    @State private var err: String?
    @State private var loading = false
    @State private var showNew = false
    @State private var editing: SessionRow?
    @State private var statusTarget: SessionRow?

    var body: some View {
        List {
            if let e = err { ErrorBar(text: e).cardRow() }

            // 视图切换 + 日期翻页放在列表里，不放 toolbar：
            // .bottomBar 会被 TabView 的 tab bar 压住（实测截图里两层字重叠），
            // 而 topBarLeading 塞 segmented 会把标题挤成「2026-08-2…」。
            CardBox(padding: 12) {
                VStack(spacing: 12) {
                    Picker("", selection: $range) {
                        Text("今天").tag("today")
                        Text("本周").tag("week")
                        Text("过时").tag("overdue")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: range) { _, _ in Task { await load() } }

                    HStack(spacing: 0) {
                        Button { date = data?.prev_date ?? ""; Task { await load() } } label: {
                            Image(systemName: "chevron.left")
                                .font(.footnote.weight(.semibold))
                                .frame(width: 44, height: 32)
                                .background(Theme.pageBG)
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        Spacer()
                        VStack(spacing: 1) {
                            Text(data?.title ?? "—")
                                .font(.subheadline.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(Theme.ink)
                            Button("回到今天") { date = ""; Task { await load() } }
                                .font(.caption2)
                        }
                        Spacer()
                        Button { date = data?.next_date ?? ""; Task { await load() } } label: {
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .frame(width: 44, height: 32)
                                .background(Theme.pageBG)
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            .cardRow(top: 8)

            if let d = data, !d.warnings.isEmpty {
                GroupTitle(text: "提醒", trailing: "\(d.warnings.count)", icon: "bell.badge")
                    .cardRow(top: 10, bottom: 2)
                CardBox(padding: 12) {
                    VStack(spacing: 10) {
                        ForEach(d.warnings) { w in
                            Button {
                                // 红色告警一律指向「已过时未处理」过滤视图（后端 href 即此意）
                                if w.href.contains("overdue") { range = "overdue"; Task { await load() } }
                            } label: { WarningRow(w: w) }
                            .buttonStyle(.plain)
                            if w.id != d.warnings.last?.id {
                                Divider().overlay(Theme.hairline)
                            }
                        }
                    }
                }
                .cardRow()
            }

            if loading && data == nil { Loading().cardRow() }

            if let d = data {
                if d.days.isEmpty {
                    CardBox {
                        if range == "overdue" {
                            EmptyState(icon: "checkmark.seal.fill",
                                       title: "没有过时未处理的课",
                                       detail: "上过的课都已经标好状态了，不用补。",
                                       tone: .ok)
                        } else {
                            EmptyState(icon: "calendar.badge.plus",
                                       title: "这段时间还没有安排",
                                       detail: "点右上角的 + 排第一节课。",
                                       tone: .accent,
                                       action: ("排一节课", { showNew = true }))
                        }
                    }
                    .cardRow(top: 10)
                }
                ForEach(d.days) { g in
                    GroupTitle(text: "\(TZ.md(g.date_)) \(g.wd_name)",
                               trailing: "\(g.sessions.count) 节",
                               icon: g.date_ == d.today ? "sun.max.fill" : "calendar")
                        .cardRow(top: 12, bottom: 2)
                    ForEach(g.sessions) { s in
                        SessionRowCell(s: s, now: d.now)
                            .contentShape(Rectangle())
                            .onTapGesture { statusTarget = s }
                            .cardRow()
                            .swipeActions(edge: .trailing) {
                                Button("改课") { editing = s }.tint(Theme.accent)
                            }
                    }
                }
            }
        }
        .listStyle(.plain)
        .pageBackground()
        .navigationTitle("日程")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNew = true } label: {
                    Image(systemName: "plus.circle.fill").font(.title3)
                }
            }
        }
        .task { if data == nil { await load() } }
        .sheet(isPresented: $showNew) {
            SessionFormView(sessionId: nil, studentId: nil, presetDate: data?.date)
                { Task { await load() } }
        }
        .sheet(item: $editing) { s in
            SessionFormView(sessionId: s.id, studentId: s.student_id, presetDate: nil)
                { Task { await load() } }
        }
        .sheet(item: $statusTarget) { s in
            StatusSheet(session_: s) { Task { await load() } }
        }
    }

    private func load() async {
        loading = true; err = nil
        defer { loading = false }
        do {
            let d: ScheduleResp = try await API(session)
                .get("/coach/api/schedule", query: ["range": range, "date": date])
            data = d
            date = d.date
        } catch APIError.gone {
            // 未过闸与「不存在」后端刻意不区分；日程列表这条路上只可能是掉线
            session.signOut()
        } catch {
            err = errText(error)
        }
    }
}

struct SessionRowCell: View {
    let s: SessionRow
    let now: String

    /// 过时仍停在 scheduled = 教练还没标状态。这是学员端「待确认」的同一判据。
    private var overdue: Bool { s.status == "scheduled" && s.end_at <= now }

    private var tone: Theme.Tone {
        overdue ? .danger : StatusTag.tone(s.status)
    }

    var body: some View {
        let (fg, _) = Theme.pair(tone)
        return CardBox(padding: 0, tint: fg.opacity(0.85)) {
            HStack(alignment: .top, spacing: 12) {
                // 时间列：固定宽度，多张卡片的时间才能竖着对齐成一条线
                // 宽度必须容得下 5 个等宽字符 + rounded 字面的字距，且 lineLimit(1)：
                // 46pt 时实测「09:00」被折成「09:0 / 0」—— 数字换行没有任何报错，
                // 只是看起来像排版坏了。改宽度前先在模拟器上看一眼。
                VStack(alignment: .leading, spacing: 1) {
                    Text(TZ.hm(s.start_at))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .monospacedDigit().foregroundStyle(Theme.ink)
                    Text(TZ.hm(s.end_at))
                        .font(.caption).monospacedDigit().foregroundStyle(Theme.ink3)
                }
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 56, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(s.student_name)
                            .font(.headline).foregroundStyle(Theme.ink)
                        Spacer(minLength: 4)
                        StatusTag(status: s.status, label: overdue ? "待处理" : nil)
                    }
                    HStack(spacing: 6) {
                        Pill(text: "\(s.duration_min) 分钟", tone: .neutral, icon: "clock")
                        if let l = s.location_name, !l.isEmpty {
                            Pill(text: l, tone: .neutral, icon: "mappin")
                        }
                        if s.is_backfilled {
                            Pill(text: "补录", tone: .violet, icon: "arrow.uturn.backward")
                        }
                    }
                    if !s.content.isEmpty {
                        Text(s.content)
                            .font(.caption).foregroundStyle(Theme.ink2).lineLimit(2)
                    }
                }
            }
            .padding(.vertical, 12)
            .padding(.trailing, 13)
            .padding(.leading, 11)
        }
    }
}

/// 改状态。12 条边全开，判据全在后端 —— 这里不做任何「哪些能改」的本地判断，
/// 只把后端的 400 文案原样呈现（含「请勾选强制覆盖后重试」）。
struct StatusSheet: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let session_: SessionRow
    let onDone: () -> Void

    @State private var to = ""
    @State private var reason = ""
    @State private var reasonCode = ""
    @State private var force = false
    @State private var busy = false
    @State private var err: String?

    private var needsReason: Bool { Vocab.needsReason(from: session_.status) }

    var body: some View {
        NavigationStack {
            Form {
                Section("这一节") {
                    LabeledContent(session_.student_name, value: TZ.mdhm(session_.start_at))
                    LabeledContent("当前状态", value: session_.status_label)
                    if !session_.content.isEmpty {
                        LabeledContent("内容", value: session_.content)
                    }
                }
                if let e = err { Section { ErrorBar(text: e) } }
                Section("改为") {
                    Picker("目标状态", selection: $to) {
                        Text("请选择").tag("")
                        ForEach(Vocab.statuses.filter { $0 != session_.status }, id: \.self) {
                            Text(Vocab.statusLabels[$0] ?? $0).tag($0)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                ReasonFields(reason: $reason, reasonCode: $reasonCode,
                             required: needsReason, showForce: true, force: $force)
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack { Spacer()
                            if busy { ProgressView() } else { Text("保存").bold() }
                            Spacer() }
                    }
                    .disabled(busy || to.isEmpty || (needsReason && reason.trimmingCharacters(in: .whitespaces).isEmpty))
                } footer: {
                    Text("已上课 / 未到 都扣 1 节；已取消不扣。每次改动都会写进变更记录。")
                }
                NavigationLink("查看这一节的变更记录") {
                    AuditView(studentFilter: session_.student_id, showAll: true)
                }
            }
            .navigationTitle("改状态")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
    }

    private func submit() async {
        busy = true; err = nil
        defer { busy = false }
        do {
            try await API(session).post("/coach/api/sessions/\(session_.id)/status", [
                "to": to, "reason": reason, "reason_code": reasonCode,
                "force": force ? "on" : "",
            ])
            onDone(); dismiss()
        } catch {
            err = errText(error)
        }
    }
}
