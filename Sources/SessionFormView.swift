import SwiftUI

/// 排课 / 改课。sessionId == nil 即新建。
///
/// 两个后端契约必须照做，违反会静默改错数据：
///   ① 建课与改课是**两条不同端点**，改课端点**不收 status**（改状态唯一入口是 …/status）
///   ② 409 = 软警告可 force 重试；400 = 硬拒，force 也没用 —— 不能把 400 也引导去重试
struct SessionFormView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss

    let sessionId: Int?
    var studentId: Int?
    var presetDate: String?
    let onDone: () -> Void

    @State private var form: SessionFormResp?
    @State private var pickedStudent: Int?
    @State private var pickedPackage: Int?
    @State private var pickedLocation: Int = 0        // 0 = 不指定
    @State private var day = Date()
    @State private var startT = Date()
    @State private var endT = Date()
    @State private var content = ""
    @State private var status = "scheduled"
    @State private var reason = ""
    @State private var reasonCode = ""
    @State private var force = false
    @State private var busy = false
    @State private var err: String?
    @State private var softWarns: [Warn] = []
    @State private var askForce = false
    @State private var requestID = UUID()
    @State private var formDate = ""
    @State private var duration = 60
    @State private var quickSetup = false

    private var isEdit: Bool { sessionId != nil }

    var body: some View {
        NavigationStack {
            Form {
                if form == nil { Loading() }
                if let e = err { Section { ErrorBar(text: e) } }

                if let f = form {
                    Section("学员") {
                        if f.students.isEmpty {
                            Text("先到「学员」添加一个姓名，再添加课包，即可排课。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Picker("学员", selection: Binding(
                            get: { pickedStudent ?? -1 },
                            set: { pickedStudent = $0 < 0 ? nil : $0 }
                        )) {
                            Text("请选择").tag(-1)
                            ForEach(f.students) { Text($0.name).tag($0.id) }
                        }
                        .onChange(of: pickedStudent) { _, new in
                            // 换学员必须重取课包 —— 课包是按学员算的，沿用上一个学员的
                            // 列表会让「排给 A 的课扣了 B 的包」，而且它不会报错。
                            if new != nil { Task { await reload(studentId: new) } }
                        }
                    }

                    Section {
                        if f.packages.isEmpty {
                            Text(pickedStudent == nil ? "先选学员" : "这个学员还没有可用课包")
                                .foregroundStyle(.secondary).font(.footnote)
                        }
                        Picker("课包", selection: Binding(
                            get: { pickedPackage ?? -1 },
                            set: { pickedPackage = $0 < 0 ? nil : $0 }
                        )) {
                            Text("请选择").tag(-1)
                            ForEach(f.packages) { p in
                                Text(p.label + (p.selectable ? "" : "（不可选）")).tag(p.package_id)
                            }
                        }
                    } header: {
                        Text("课包")
                    } footer: {
                        Text("已默认选择优先使用的课包，也可以手动更换。")
                    }

                    Section("时间") {
                        DatePicker("日期", selection: $day, displayedComponents: .date)
                            .environment(\.timeZone, TZ.zone)
                            .onChange(of: day) { _, _ in
                                Task { await reload(studentId: pickedStudent) }
                            }
                        DatePicker("开始", selection: $startT, displayedComponents: .hourAndMinute)
                            .environment(\.timeZone, TZ.zone)
                            .onChange(of: startT) { _, _ in
                                if !isEdit { applyDuration() }
                            }
                        DatePicker("结束", selection: $endT, displayedComponents: .hourAndMinute)
                            .environment(\.timeZone, TZ.zone)
                        if !isEdit {
                            HStack {
                                ForEach([30, 60, 90], id: \.self) { minutes in
                                    Button("\(minutes) 分钟") {
                                        duration = minutes; applyDuration()
                                    }.buttonStyle(.bordered)
                                }
                            }
                        }
                        if formDate != TZ.dateString(day) {
                            ProgressView("正在更新当天档期…")
                        } else if !f.windows.isEmpty {
                            HStack {
                                Text("当日可排").font(.footnote).foregroundStyle(.secondary)
                                Spacer()
                                Text(f.windows.map { $0.joined(separator: "–") }.joined(separator: "  "))
                                    .font(.footnote).monospacedDigit()
                            }
                        } else if let r = f.windows_reason {
                            Text(r).font(.footnote).foregroundStyle(.orange)
                            Button("准备常用档期") { quickSetup = true }
                        }
                    }

                    Section("地点 / 内容") {
                        Picker("地点", selection: $pickedLocation) {
                            Text("不指定").tag(0)
                            ForEach(f.locations) { Text($0.name).tag($0.id) }
                        }
                        TextField("上课内容（可不填）", text: $content, axis: .vertical)
                            .lineLimit(1...4)
                        HStack {
                            ForEach(["基础体能", "力量训练", "拉伸放松"], id: \.self) { value in
                                Button(value) { content = value }.buttonStyle(.bordered)
                            }
                        }
                    }

                    if !isEdit {
                        Section {
                            Picker("状态", selection: $status) {
                                ForEach(Vocab.statuses, id: \.self) {
                                    Text(Vocab.statusLabels[$0] ?? $0).tag($0)
                                }
                            }
                        } header: {
                            Text("建课状态")
                        } footer: {
                            Text("补录已经上过的课时选「已上课」。未来时间不允许直接标为已上课 / 未到。")
                        }
                    }

                    if isEdit || status != "scheduled" {
                        ReasonFields(reason: $reason, reasonCode: $reasonCode,
                                     required: !isEdit && status != "scheduled", showForce: false, force: $force)
                    }

                    Section {
                        Button {
                            Task { await submit(force: false) }
                        } label: {
                            HStack { Spacer()
                                if busy { ProgressView() } else { Text(isEdit ? "保存改动" : "排这一节").bold() }
                                Spacer() }
                        }
                        .disabled(busy || pickedPackage == nil)
                    }
                }
            }
            .navigationTitle(isEdit ? "改课" : "排课")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .task { await reload(studentId: studentId) }
            .sheet(isPresented: $quickSetup, onDismiss: {
                Task { await reload(studentId: pickedStudent) }
            }) {
                NavigationStack { QuickSetupView() }
            }
            .alert("有警告，确认要这么排吗？", isPresented: $askForce) {
                Button("取消", role: .cancel) {}
                Button("强制排入", role: .destructive) { Task { await submit(force: true) } }
            } message: {
                Text(softWarns.map(\.message).joined(separator: "\n"))
            }
        }
    }

    private func reload(studentId sid: Int?) async {
        let request = UUID()
        requestID = request
        err = nil
        var q: [String: String] = [:]
        if let s = sid { q["student_id"] = String(s) }
        if let id = sessionId { q["session_id"] = String(id) }
        let requestedDate = form == nil ? (presetDate ?? TZ.dateString(day)) : TZ.dateString(day)
        q["date"] = requestedDate
        do {
            let f: SessionFormResp = try await API(session).get("/coach/api/session-form", query: q)
            guard requestID == request else { return }
            let first = form == nil
            form = f
            formDate = requestedDate
            if first {
                if let s = f.session {
                    pickedStudent = s.student_id
                    pickedPackage = s.package_id
                    pickedLocation = s.location_id ?? 0
                    content = s.content
                    day = TZ.date(fromDate: String(s.start_at.prefix(10)))
                    startT = TZ.date(fromTime: TZ.hm(s.start_at))
                    endT = TZ.date(fromTime: TZ.hm(s.end_at))
                } else {
                    pickedStudent = sid ?? (f.students.count == 1 ? f.students.first?.id : nil)
                    pickedLocation = f.locations.count == 1 ? (f.locations.first?.id ?? 0) : 0
                    content = "基础体能"
                    day = TZ.date(fromDate: presetDate ?? f.today)
                    startT = TZ.date(fromTime: "10:00")
                    endT = TZ.date(fromTime: "11:00")
                }
            }
            if pickedPackage == nil || !f.packages.contains(where: { $0.package_id == pickedPackage }) {
                pickedPackage = f.default_package_id
            }
        } catch {
            guard requestID == request else { return }
            err = errText(error)
        }
    }

    private func applyDuration() {
        endT = TZ.calendar.date(byAdding: .minute, value: duration, to: startT) ?? startT
    }

    private func fields() -> [String: String] {
        let d = TZ.dateString(day)
        return [
            "package_id": pickedPackage.map(String.init) ?? "",
            "start_at": "\(d) \(TZ.timeString(startT))",
            "end_at": "\(d) \(TZ.timeString(endT))",
            "location_id": pickedLocation == 0 ? "" : String(pickedLocation),
            "content": content,
            "reason": reason,
        ]
    }

    private func submit(force doForce: Bool) async {
        busy = true; err = nil
        defer { busy = false }
        var f = fields()
        if doForce { f["force"] = "on" }
        do {
            if let id = sessionId {
                try await API(session).post("/coach/api/sessions/\(id)", f)
            } else {
                f["status"] = status
                f["reason_code"] = reasonCode
                try await API(session).post("/coach/api/sessions", f)
            }
            onDone(); dismiss()
        } catch APIError.needsForce(let w) {
            softWarns = w; askForce = true
        } catch {
            // 400 = 硬拒（课包已作废 / 未来的课不能标已上课 / 时间不合法…）
            // 这类 force 也不放行，所以**不能**在这里引导「强制重试」
            err = errText(error)
        }
    }
}
