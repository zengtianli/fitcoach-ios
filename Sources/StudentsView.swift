import SwiftUI

struct StudentsView: View {
    @EnvironmentObject var session: Session
    @State private var data: StudentsResp?
    @State private var err: String?
    @State private var showNew = false
    @State private var q = ""

    private func filter(_ rows: [StudentListRow]) -> [StudentListRow] {
        let k = q.trimmingCharacters(in: .whitespaces)
        return k.isEmpty ? rows : rows.filter { $0.name.localizedCaseInsensitiveContains(k) }
    }

    var body: some View {
        List {
            if let e = err { ErrorBar(text: e).cardRow() }
            if data == nil { CardBox { Loading() }.cardRow() }

            if let d = data {
                let active = filter(d.rows)
                GroupTitle(text: "在册", trailing: "\(d.rows.count) 人", icon: "person.2.fill")
                    .cardRow(top: 8, bottom: 2)

                if active.isEmpty {
                    CardBox {
                        if d.rows.isEmpty {
                            EmptyState(icon: "person.crop.circle.badge.plus",
                                       title: "还没有学员",
                                       detail: "先建一个学员，再给他录课包，就能开始排课了。",
                                       tone: .accent,
                                       action: ("新建学员", { showNew = true }))
                        } else {
                            EmptyState(icon: "magnifyingglass",
                                       title: "没有匹配的学员",
                                       detail: "换个关键词试试，或者清空搜索框。",
                                       tone: .neutral)
                        }
                    }
                    .cardRow()
                }
                ForEach(active) { r in
                    NavigationLink { StudentDetailView(studentId: r.id) } label: {
                        StudentCell(r: r)
                    }
                    .buttonStyle(.plain)
                    .cardRow()
                }

                if !d.inactive.isEmpty {
                    GroupTitle(text: "已停用", trailing: "\(d.inactive.count) 人", icon: "pause.circle")
                        .cardRow(top: 14, bottom: 2)
                    ForEach(filter(d.inactive)) { r in
                        NavigationLink { StudentDetailView(studentId: r.id) } label: {
                            StudentCell(r: r, dimmed: true)
                        }
                        .buttonStyle(.plain)
                        .cardRow()
                    }
                }
            }
        }
        .listStyle(.plain)
        .pageBackground()
        .navigationTitle("学员")
        .searchable(text: $q, prompt: "找学员")
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNew = true } label: {
                    Image(systemName: "person.badge.plus").font(.body.weight(.semibold))
                }
            }
        }
        .task { if data == nil { await load() } }
        .sheet(isPresented: $showNew) { StudentFormSheet(student: nil) { Task { await load() } } }
    }

    private func load() async {
        err = nil
        do { data = try await API(session).get("/coach/api/students") }
        catch APIError.gone { session.signOut() }
        catch { err = errText(error) }
    }
}

struct StudentCell: View {
    let r: StudentListRow
    var dimmed: Bool = false

    /// 头像占位：名字最后一个字。个位数学员，一眼就能认出是谁。
    private var initial: String {
        r.name.last.map(String.init) ?? "?"
    }

    var body: some View {
        let tone: Theme.Tone = r.n_packages == 0 ? .neutral
            : (r.available_total <= 0 ? .danger : .accent)
        let (fg, bg) = Theme.pair(tone)
        return CardBox(padding: 13) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(bg).frame(width: 42, height: 42)
                    Text(initial)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(fg)
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Text(r.name).font(.headline).foregroundStyle(Theme.ink)
                        if r.has_link == 1 {
                            Image(systemName: "link")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    HStack(spacing: 5) {
                        if r.n_packages == 0 {
                            Pill(text: "未录课包", tone: .neutral, icon: "exclamationmark")
                        } else {
                            Pill(text: "还能排 \(r.min_bookable)", tone: .neutral, icon: "calendar")
                        }
                        if r.lapsed_total > 0 {
                            Pill(text: "过期 \(r.lapsed_total)", tone: .warn)
                        }
                        if r.expiring_soon > 0 {
                            Pill(text: "将到期 \(r.expiring_soon)", tone: .warn, icon: "hourglass")
                        }
                    }
                }
                Spacer(minLength: 4)
                if r.n_packages > 0 {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("\(r.available_total)")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(r.available_total <= 0 ? Theme.danger : Theme.ink)
                        Text("可用").font(.system(size: 10)).foregroundStyle(Theme.ink3)
                    }
                }
            }
        }
        .opacity(dimmed ? 0.6 : 1)
    }
}

struct StudentFormSheet: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let student: StudentPublic?
    let onDone: () -> Void

    @State private var name = ""
    @State private var note = ""
    @State private var isActive = true
    @State private var busy = false
    @State private var err: String?
    @State private var warn: String?

    var body: some View {
        NavigationStack {
            Form {
                if let e = err { Section { ErrorBar(text: e) } }
                if let w = warn {
                    Section {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(Theme.warn).font(.footnote)
                            Text(w).font(.footnote).foregroundStyle(Theme.warn)
                        }
                    }
                }
                Section {
                    TextField("姓名", text: $name)
                    TextField("备注（学员看不到）", text: $note, axis: .vertical).lineLimit(1...4)
                }
                if student != nil {
                    Section {
                        Toggle("在册", isOn: $isActive)
                    } footer: {
                        Text("停用会**同时吊销**学员端链接，旧链接立即失效。")
                    }
                }
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack { Spacer()
                            if busy { ProgressView() } else { Text("保存").bold() }
                            Spacer() }
                    }
                    .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle(student == nil ? "新学员" : "改资料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .onAppear {
                if let s = student { name = s.name; note = s.note; isActive = s.is_active == 1 }
            }
        }
    }

    private func submit() async {
        busy = true; err = nil
        defer { busy = false }
        do {
            if let s = student {
                // is_active **每次都必须提交** —— 缺字段后端按 0 处理，会把学员静默停用
                let r = try await API(session).post("/coach/api/students/\(s.id)", [
                    "name": name, "note": note, "is_active": isActive ? "on" : "",
                ])
                if let w = r.warning { warn = w }
            } else {
                try await API(session).post("/coach/api/students", ["name": name, "note": note])
            }
            onDone()
            if warn == nil { dismiss() }
        } catch {
            err = errText(error)
        }
    }
}
