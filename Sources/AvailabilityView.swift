import SwiftUI

struct AvailabilityView: View {
    @EnvironmentObject var session: Session
    @State private var data: AvailabilityResp?
    @State private var err: String?
    @State private var newRule = false
    @State private var newExc = false
    @State private var tab = 0

    var body: some View {
        List {
            if let e = err { ErrorBar(text: e).cardRow() }

            CardBox(padding: 10) {
                Picker("", selection: $tab) {
                    Text("每周规则").tag(0)
                    Text("例外").tag(1)
                    Text("未来两周").tag(2)
                }
                .pickerStyle(.segmented)
            }
            .cardRow(top: 8)

            if data == nil { Loading().cardRow() }

            if let d = data {
                if tab == 0 {
                    let empty = (0..<7).allSatisfy { (d.rules_by_wd[String($0)] ?? []).isEmpty }
                    if empty {
                        CardBox {
                            EmptyState(icon: "calendar.badge.clock",
                                       title: "还没有设置可排时段",
                                       detail: "定好每周几点到几点能排课，排课时超出这个范围会提醒你。",
                                       tone: .accent,
                                       action: ("加每周规则", { newRule = true }))
                        }
                        .cardRow(top: 10)
                    } else {
                        ForEach(0..<7, id: \.self) { w in
                            let rules = d.rules_by_wd[String(w)] ?? []
                            let name = d.wd_names.indices.contains(w) ? d.wd_names[w] : "周\(w)"
                            GroupTitle(text: name,
                                       trailing: rules.isEmpty ? "不排课" : "\(rules.count) 段",
                                       icon: rules.isEmpty ? "moon.zzz" : "calendar")
                                .cardRow(top: 12, bottom: 2)
                            if rules.isEmpty {
                                CardBox(padding: 12) {
                                    Text("不排课").font(.footnote).foregroundStyle(Theme.ink3)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .cardRow(top: 2, bottom: 2)
                            }
                            ForEach(rules) { r in
                                CardBox(padding: 13, tint: Theme.accent.opacity(0.75)) {
                                    HStack {
                                        Image(systemName: "clock")
                                            .font(.caption).foregroundStyle(Theme.ink3)
                                        Text("\(r.start_time) – \(r.end_time)")
                                            .font(.subheadline.weight(.medium))
                                            .monospacedDigit().foregroundStyle(Theme.ink)
                                        Spacer()
                                    }
                                    .padding(.leading, 2)
                                }
                                .cardRow(top: 2, bottom: 2)
                                .swipeActions {
                                    Button("删除", role: .destructive) {
                                        Task { await del("rules/\(r.id)") }
                                    }
                                }
                            }
                        }
                    }
                } else if tab == 1 {
                    if d.exceptions.isEmpty {
                        CardBox {
                            EmptyState(icon: "calendar.badge.exclamationmark",
                                       title: "没有例外",
                                       detail: "临时停排（出差、放假）或临时加开，都在这里加。",
                                       tone: .accent,
                                       action: ("加一条例外", { newExc = true }))
                        }
                        .cardRow(top: 10)
                    } else {
                        GroupTitle(text: "例外", trailing: "\(d.exceptions.count) 条",
                                   icon: "calendar.badge.exclamationmark")
                            .cardRow(top: 12, bottom: 2)
                        ForEach(d.exceptions) { e in
                            let block = e.kind == "block"
                            CardBox(padding: 13,
                                    tint: (block ? Theme.danger : Theme.ok).opacity(0.75)) {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 7) {
                                        Text(e.on_date).font(.subheadline.weight(.medium))
                                            .monospacedDigit().foregroundStyle(Theme.ink)
                                        Pill(text: block ? "停排" : "加开",
                                             tone: block ? .danger : .ok)
                                        Spacer(minLength: 4)
                                        if let st = e.start_time, let t = e.end_time {
                                            Text("\(st) – \(t)").font(.footnote)
                                                .monospacedDigit().foregroundStyle(Theme.ink2)
                                        } else {
                                            Text("整天").font(.footnote).foregroundStyle(Theme.ink3)
                                        }
                                    }
                                    if !e.reason.isEmpty {
                                        Text(e.reason).font(.caption).foregroundStyle(Theme.ink3)
                                    }
                                }
                                .padding(.leading, 2)
                            }
                            .cardRow(top: 3, bottom: 3)
                            .swipeActions {
                                Button("删除", role: .destructive) {
                                    Task { await del("exceptions/\(e.id)") }
                                }
                            }
                        }
                        Text("例外压过每周规则：停排整天可不填时段；加开必须带时段。")
                            .font(.caption).foregroundStyle(Theme.ink3)
                            .cardRow(top: 12)
                    }
                } else {
                    GroupTitle(text: "未来两周实际可排", icon: "eye")
                        .cardRow(top: 12, bottom: 2)
                    ForEach(d.preview) { p in
                        CardBox(padding: 12,
                                tint: p.windows.isEmpty ? Theme.ink3.opacity(0.35)
                                                        : Theme.ok.opacity(0.75)) {
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(TZ.md(p.date_)).font(.subheadline.weight(.medium))
                                        .monospacedDigit().foregroundStyle(Theme.ink)
                                    Text(p.wd_name).font(.caption2).foregroundStyle(Theme.ink3)
                                }
                                .frame(width: 54, alignment: .leading)
                                Spacer(minLength: 4)
                                if p.windows.isEmpty {
                                    Text(p.empty_reason ?? "不排课")
                                        .font(.footnote).foregroundStyle(Theme.ink3)
                                } else {
                                    VStack(alignment: .trailing, spacing: 3) {
                                        ForEach(p.windows, id: \.self) { w in
                                            Text(w.joined(separator: " – "))
                                                .font(.footnote).monospacedDigit()
                                                .foregroundStyle(Theme.ink2)
                                        }
                                    }
                                }
                            }
                            .padding(.leading, 2)
                        }
                        .cardRow(top: 3, bottom: 3)
                    }
                }
            }
        }
        .listStyle(.plain)
        .pageBackground()
        .navigationTitle("档期")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("加每周规则") { newRule = true }
                    Button("加例外") { newExc = true }
                } label: { Image(systemName: "plus.circle.fill").font(.title3) }
            }
        }
        .task { if data == nil { await load() } }
        .sheet(isPresented: $newRule) {
            RuleSheet(wdNames: data?.wd_names ?? []) { Task { await load() } }
        }
        .sheet(isPresented: $newExc) { ExceptionSheet { Task { await load() } } }
    }

    private func load() async {
        err = nil
        do { data = try await API(session).get("/coach/api/availability") }
        catch APIError.gone { session.signOut() }
        catch { err = errText(error) }
    }

    private func del(_ suffix: String) async {
        err = nil
        do {
            try await API(session).post("/coach/api/availability/\(suffix)/delete", [:])
            await load()
        } catch { err = errText(error) }
    }
}

struct RuleSheet: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let wdNames: [String]
    let onDone: () -> Void

    @State private var weekday = 1
    @State private var start = TZ.date(fromTime: "09:00")
    @State private var end = TZ.date(fromTime: "12:00")
    @State private var busy = false
    @State private var err: String?

    var body: some View {
        NavigationStack {
            Form {
                if let e = err { Section { ErrorBar(text: e) } }
                Section {
                    Picker("星期", selection: $weekday) {
                        ForEach(0..<7, id: \.self) { w in
                            Text(wdNames.indices.contains(w) ? wdNames[w] : "周\(w)").tag(w)
                        }
                    }
                    DatePicker("开始", selection: $start, displayedComponents: .hourAndMinute)
                        .environment(\.timeZone, TZ.zone)
                    DatePicker("结束", selection: $end, displayedComponents: .hourAndMinute)
                        .environment(\.timeZone, TZ.zone)
                } footer: {
                    Text("星期索引与后端一致：0 = 周日。")
                }
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack { Spacer()
                            if busy { ProgressView() } else { Text("添加").bold() }
                            Spacer() }
                    }.disabled(busy)
                }
            }
            .navigationTitle("每周可排时段")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }

    private func submit() async {
        busy = true; err = nil
        defer { busy = false }
        do {
            try await API(session).post("/coach/api/availability/rules", [
                "weekday": String(weekday),
                "start_time": TZ.timeString(start),
                "end_time": TZ.timeString(end),
            ])
            onDone(); dismiss()
        } catch { err = errText(error) }
    }
}

struct ExceptionSheet: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let onDone: () -> Void

    @State private var day = Date()
    @State private var kind = "block"
    @State private var wholeDay = true
    @State private var start = TZ.date(fromTime: "09:00")
    @State private var end = TZ.date(fromTime: "12:00")
    @State private var reason = ""
    @State private var busy = false
    @State private var err: String?

    var body: some View {
        NavigationStack {
            Form {
                if let e = err { Section { ErrorBar(text: e) } }
                Section {
                    DatePicker("日期", selection: $day, displayedComponents: .date)
                        .environment(\.timeZone, TZ.zone)
                    Picker("类型", selection: $kind) {
                        Text("停排").tag("block")
                        Text("加开").tag("open")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: kind) { _, k in if k == "open" { wholeDay = false } }
                    if kind == "block" { Toggle("整天", isOn: $wholeDay) }
                    if !(kind == "block" && wholeDay) {
                        DatePicker("开始", selection: $start, displayedComponents: .hourAndMinute)
                            .environment(\.timeZone, TZ.zone)
                        DatePicker("结束", selection: $end, displayedComponents: .hourAndMinute)
                            .environment(\.timeZone, TZ.zone)
                    }
                    TextField("原因（可不填）", text: $reason)
                } footer: {
                    Text("加开必须带时段（后端硬约束）。")
                }
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack { Spacer()
                            if busy { ProgressView() } else { Text("添加").bold() }
                            Spacer() }
                    }.disabled(busy)
                }
            }
            .navigationTitle("档期例外")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }

    private func submit() async {
        busy = true; err = nil
        defer { busy = false }
        let timed = !(kind == "block" && wholeDay)
        do {
            try await API(session).post("/coach/api/availability/exceptions", [
                "on_date": TZ.dateString(day),
                "kind": kind,
                "start_time": timed ? TZ.timeString(start) : "",
                "end_time": timed ? TZ.timeString(end) : "",
                "reason": reason,
            ])
            onDone(); dismiss()
        } catch { err = errText(error) }
    }
}
