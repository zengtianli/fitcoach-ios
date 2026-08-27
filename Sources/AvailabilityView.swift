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
            if let e = err { ErrorBar(text: e).listRowBackground(Color.clear) }
            if data == nil { Loading().listRowBackground(Color.clear) }

            Picker("", selection: $tab) {
                Text("每周规则").tag(0)
                Text("例外").tag(1)
                Text("未来两周").tag(2)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)

            if let d = data {
                if tab == 0 {
                    ForEach(0..<7, id: \.self) { w in
                        let rules = d.rules_by_wd[String(w)] ?? []
                        Section(d.wd_names.indices.contains(w) ? d.wd_names[w] : "周\(w)") {
                            if rules.isEmpty {
                                Text("不排课").font(.footnote).foregroundStyle(.secondary)
                            }
                            ForEach(rules) { r in
                                HStack {
                                    Text("\(r.start_time) – \(r.end_time)").monospacedDigit()
                                    Spacer()
                                }
                                .swipeActions {
                                    Button("删除", role: .destructive) {
                                        Task { await del("rules/\(r.id)") }
                                    }
                                }
                            }
                        }
                    }
                } else if tab == 1 {
                    Section {
                        if d.exceptions.isEmpty { EmptyHint(text: "没有例外") }
                        ForEach(d.exceptions) { e in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(e.on_date).monospacedDigit()
                                    Text(e.kind == "block" ? "停排" : "加开")
                                        .font(.caption2).bold()
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background((e.kind == "block" ? Color.red : Color.green).opacity(0.14))
                                        .foregroundStyle(e.kind == "block" ? .red : .green)
                                        .clipShape(Capsule())
                                    Spacer()
                                    if let s = e.start_time, let t = e.end_time {
                                        Text("\(s) – \(t)").font(.footnote).monospacedDigit()
                                    } else {
                                        Text("整天").font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                                if !e.reason.isEmpty {
                                    Text(e.reason).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions {
                                Button("删除", role: .destructive) {
                                    Task { await del("exceptions/\(e.id)") }
                                }
                            }
                        }
                    } footer: {
                        Text("例外压过每周规则：停排整天可不填时段；加开必须带时段。")
                    }
                } else {
                    Section("未来两周实际可排") {
                        ForEach(d.preview) { p in
                            HStack(alignment: .top) {
                                Text("\(p.date_) \(p.wd_name)").font(.subheadline).monospacedDigit()
                                Spacer()
                                if p.windows.isEmpty {
                                    Text(p.empty_reason ?? "不排课")
                                        .font(.footnote).foregroundStyle(.secondary)
                                } else {
                                    Text(p.windows.map { $0.joined(separator: "–") }
                                            .joined(separator: "\n"))
                                        .font(.footnote).monospacedDigit()
                                        .multilineTextAlignment(.trailing)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("档期")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("加每周规则") { newRule = true }
                    Button("加例外") { newExc = true }
                } label: { Image(systemName: "plus") }
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
