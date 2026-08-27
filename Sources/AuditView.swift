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
            if let e = err { ErrorBar(text: e).cardRow() }

            CardBox(padding: 13) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("显示全部（含常规排课）", isOn: $all)
                        .font(.subheadline)
                        .onChange(of: all) { _, _ in Task { await load() } }
                    if let d = data, studentFilter == nil {
                        Divider().overlay(Theme.hairline)
                        Picker("学员", selection: $student) {
                            Text("全部").tag(0)
                            ForEach(d.students) { Text($0.name).tag($0.id) }
                        }
                        .font(.subheadline)
                        .onChange(of: student) { _, _ in Task { await load() } }
                    }
                    Text("默认只列纠错 / 通融 / 补录这类需要解释的改动。")
                        .font(.caption2).foregroundStyle(Theme.ink3)
                }
            }
            .cardRow(top: 8)

            if data == nil { Loading().cardRow() }

            if let d = data {
                if d.rows.isEmpty {
                    CardBox {
                        EmptyState(icon: "checkmark.shield",
                                   title: all ? "还没有任何变更" : "没有需要解释的改动",
                                   detail: all ? "排课、改状态都会记在这里。"
                                              : "纠错、通融、补录这类改动才会默认出现。\n打开上面的开关看全部。",
                                   tone: .ok)
                    }
                    .cardRow(top: 10)
                } else {
                    GroupTitle(text: "记录", trailing: "\(d.rows.count) 条", icon: "clock.arrow.circlepath")
                        .cardRow(top: 12, bottom: 2)
                    ForEach(d.rows) { r in
                        AuditCell(r: r).cardRow(top: 3, bottom: 3)
                    }
                }
            }
        }
        .listStyle(.plain)
        .pageBackground()
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

    private var kindTone: Theme.Tone {
        switch r.kind {
        case "correction": return .warn
        case "concession": return .violet
        case "backfill":   return .accent
        default:           return .neutral
        }
    }
    private var kindLabel: String {
        ["normal": "常规", "correction": "纠错", "concession": "通融",
         "backfill": "补录", "admin": "管理"][r.kind] ?? r.kind
    }

    var body: some View {
        CardBox(padding: 13, tint: Theme.pair(kindTone).0.opacity(0.7)) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Pill(text: kindLabel, tone: kindTone)
                    if let n = r.student_name {
                        Text(n).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    }
                    Spacer(minLength: 4)
                    // delta 是后端算好的课时增减，正 = 退回给学员，负 = 多扣
                    if r.delta != 0 {
                        Pill(text: r.delta > 0 ? "退回 \(r.delta) 节" : "多扣 \(-r.delta) 节",
                             tone: r.delta > 0 ? .ok : .danger)
                    }
                }

                Text("\(r.entity).\(r.field)")
                    .font(.caption2).monospaced().foregroundStyle(Theme.ink3)

                HStack(spacing: 6) {
                    Text(r.old_value ?? "—")
                        .font(.footnote).foregroundStyle(Theme.ink2)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Theme.pageBG)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.ink3)
                    Text(r.new_value ?? "—")
                        .font(.footnote.weight(.medium)).foregroundStyle(Theme.ink)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Theme.accentSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                if let s = r.session_start_at {
                    Text("课次 \(TZ.mdhm(s))").font(.caption).monospacedDigit()
                        .foregroundStyle(Theme.ink3)
                }
                if !r.reason.isEmpty || r.reason_code != nil {
                    Text([Vocab.reasonLabel(r.reason_code), r.reason]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(Theme.ink2)
                }
                Text("\(r.at) · \(r.actor)")
                    .font(.caption2).monospacedDigit().foregroundStyle(Theme.ink3)
            }
            .padding(.leading, 2)
        }
    }
}
