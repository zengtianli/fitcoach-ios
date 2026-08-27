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
            if let e = err { ErrorBar(text: e).listRowBackground(Color.clear) }
            if data == nil { Loading().listRowBackground(Color.clear) }

            if let d = data {
                Section("在册（\(d.rows.count)）") {
                    if filter(d.rows).isEmpty { EmptyHint(text: "没有匹配的学员") }
                    ForEach(filter(d.rows)) { r in
                        NavigationLink { StudentDetailView(studentId: r.id) } label: {
                            StudentCell(r: r)
                        }
                    }
                }
                if !d.inactive.isEmpty {
                    Section("已停用（\(d.inactive.count)）") {
                        ForEach(filter(d.inactive)) { r in
                            NavigationLink { StudentDetailView(studentId: r.id) } label: {
                                StudentCell(r: r).opacity(0.55)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("学员")
        .searchable(text: $q, prompt: "找学员")
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNew = true } label: { Image(systemName: "person.badge.plus") }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(r.name).font(.headline)
                if r.has_link == 1 {
                    Image(systemName: "link").font(.caption2).foregroundStyle(.blue)
                }
                Spacer()
                if r.n_packages == 0 {
                    Text("未录课包").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("可用 \(r.available_total)")
                        .font(.subheadline).monospacedDigit()
                        .foregroundStyle(r.available_total <= 0 ? .red : .primary)
                }
            }
            HStack(spacing: 10) {
                if r.lapsed_total > 0 {
                    Text("过期未用 \(r.lapsed_total)").font(.caption).foregroundStyle(.orange)
                }
                if r.expiring_soon > 0 {
                    Text("即将到期 \(r.expiring_soon)").font(.caption).foregroundStyle(.orange)
                }
                if r.n_packages > 0 {
                    Text("还能排 \(r.min_bookable)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
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
                    Section { Text(w).font(.footnote).foregroundStyle(.orange) }
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
