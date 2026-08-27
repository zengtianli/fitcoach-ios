import SwiftUI

/// 变更记录。审计只增不改不删（后端触发器保证），这里纯只读。
struct AuditView: View {
    @EnvironmentObject var session: Session
    var studentFilter: Int? = nil
    var showAll: Bool = false

    @State private var data: AuditResp?
    @State private var err: String?
    @State private var all = false
    @State private var student: Int = 0

    var body: some View {
        List {
            if let e = err { ErrorBar(text: e).listRowBackground(Color.clear) }
            if data == nil { Loading().listRowBackground(Color.clear) }

            Section {
                Toggle("显示全部（含常规排课）", isOn: $all)
                    .onChange(of: all) { _, _ in Task { await load() } }
                if let d = data, studentFilter == nil {
                    Picker("学员", selection: $student) {
                        Text("全部").tag(0)
                        ForEach(d.students) { Text($0.name).tag($0.id) }
                    }
                    .onChange(of: student) { _, _ in Task { await load() } }
                }
            } footer: {
                Text("默认只列纠错 / 通融 / 补录这类需要解释的改动。")
            }

            if let d = data {
                if d.rows.isEmpty { EmptyHint(text: "没有记录") }
                ForEach(d.rows) { r in AuditCell(r: r) }
            }
        }
        .navigationTitle("变更记录")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task {
            if data == nil {
                all = showAll
                student = studentFilter ?? 0
                await load()
            }
        }
    }

    private func load() async {
        err = nil
        var q: [String: String] = [:]
        if all { q["all"] = "1" }
        let sid = studentFilter ?? (student == 0 ? nil : student)
        if let s = sid { q["student_id"] = String(s) }
        do { data = try await API(session).get("/coach/api/audit", query: q) }
        catch APIError.gone { session.signOut() }
        catch { err = errText(error) }
    }
}

struct AuditCell: View {
    let r: AuditRow

    private var kindColor: Color {
        switch r.kind {
        case "correction": return .orange
        case "concession": return .purple
        case "backfill": return .blue
        case "admin": return .secondary
        default: return .secondary
        }
    }
    private var kindLabel: String {
        ["normal": "常规", "correction": "纠错", "concession": "通融",
         "backfill": "补录", "admin": "管理"][r.kind] ?? r.kind
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(kindLabel).font(.caption2).bold()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(kindColor.opacity(0.14))
                    .foregroundStyle(kindColor).clipShape(Capsule())
                if let n = r.student_name { Text(n).font(.subheadline).bold() }
                Spacer()
                if r.delta != 0 {
                    Text(r.delta > 0 ? "退回 \(r.delta) 节" : "多扣 \(-r.delta) 节")
                        .font(.caption).foregroundStyle(r.delta > 0 ? .green : .red)
                }
            }
            Text("\(r.entity).\(r.field)：\(r.old_value ?? "—") → \(r.new_value ?? "—")")
                .font(.footnote)
            if let s = r.session_start_at {
                Text("课次 \(TZ.mdhm(s))").font(.caption).foregroundStyle(.secondary)
            }
            if !r.reason.isEmpty || r.reason_code != nil {
                Text([Vocab.reasonLabel(r.reason_code), r.reason]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("\(r.at) · \(r.actor)").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}
