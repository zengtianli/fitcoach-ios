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
            if let e = err { ErrorBar(text: e).listRowBackground(Color.clear) }

            // 视图切换 + 日期翻页放在列表里，不放 toolbar：
            // .bottomBar 会被 TabView 的 tab bar 压住（实测截图里两层字重叠），
            // 而 topBarLeading 塞 segmented 会把标题挤成「2026-08-2…」。
            VStack(spacing: 10) {
                Picker("", selection: $range) {
                    Text("今天").tag("today")
                    Text("本周").tag("week")
                    Text("过时").tag("overdue")
                }
                .pickerStyle(.segmented)
                .onChange(of: range) { _, _ in Task { await load() } }

                HStack {
                    Button { date = data?.prev_date ?? ""; Task { await load() } } label: {
                        Image(systemName: "chevron.left").frame(width: 44, height: 30)
                    }
                    Spacer()
                    Button("回到今天") { date = ""; Task { await load() } }
                        .font(.footnote)
                    Spacer()
                    Button { date = data?.next_date ?? ""; Task { await load() } } label: {
                        Image(systemName: "chevron.right").frame(width: 44, height: 30)
                    }
                }
                .buttonStyle(.borderless)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))

            if let d = data, !d.warnings.isEmpty {
                Section("提醒") {
                    ForEach(d.warnings) { w in
                        Button {
                            // 红色告警一律指向「已过时未处理」过滤视图（后端 href 即此意）
                            if w.href.contains("overdue") { range = "overdue"; Task { await load() } }
                        } label: { WarningRow(w: w) }
                        .buttonStyle(.plain)
                    }
                }
            }

            if loading && data == nil { Loading().listRowBackground(Color.clear) }

            if let d = data {
                if d.days.isEmpty {
                    EmptyHint(text: range == "overdue" ? "没有过时未处理的课，很好。" : "这段时间没有安排。")
                        .listRowBackground(Color.clear)
                }
                ForEach(d.days) { g in
                    Section("\(g.date_) \(g.wd_name)") {
                        ForEach(g.sessions) { s in
                            SessionRowCell(s: s, now: d.now)
                                .contentShape(Rectangle())
                                .onTapGesture { statusTarget = s }
                                .swipeActions(edge: .trailing) {
                                    Button("改课") { editing = s }.tint(.blue)
                                }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(data?.title ?? "日程")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNew = true } label: { Image(systemName: "plus") }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(TZ.hm(s.start_at))–\(TZ.hm(s.end_at))")
                    .font(.subheadline).monospacedDigit()
                Text(s.student_name).font(.headline)
                Spacer()
                StatusTag(status: s.status, label: overdue ? "待处理" : nil)
            }
            HStack(spacing: 8) {
                if let l = s.location_name, !l.isEmpty {
                    Label(l, systemImage: "mappin").font(.caption).foregroundStyle(.secondary)
                }
                Text("\(s.duration_min) 分钟").font(.caption).foregroundStyle(.secondary)
                if s.is_backfilled {
                    Text("补录").font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.purple.opacity(0.12))
                        .foregroundStyle(.purple).clipShape(Capsule())
                }
            }
            if !s.content.isEmpty {
                Text(s.content).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
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
