import SwiftUI

/// 体测项目管理（更多 tab 下）。
/// GET/POST /coach/api/metrics · POST /coach/api/metrics/{id} · POST /coach/api/metrics/seed
struct MetricsView: View {
    @EnvironmentObject var session: Session
    @State private var data: MetricsResp?
    @State private var err: String?
    @State private var editing: Metric?
    @State private var showNew = false
    @State private var seeding = false

    private var active: [Metric] { (data?.metrics ?? []).filter { $0.is_active == 1 } }
    private var inactive: [Metric] { (data?.metrics ?? []).filter { $0.is_active == 0 } }

    var body: some View {
        List {
            if let e = err { ErrorBar(text: e).cardRow() }
            if data == nil { Loading().cardRow() }

            if let d = data {
                if d.metrics.isEmpty {
                    CardBox {
                        EmptyState(
                            icon: "ruler",
                            title: "还没有体测项目",
                            detail: "先灌一套常用项目（体重、立定跳远、50 米跑…），\n再按自己的需要改。",
                            tone: .accent,
                            action: (seeding ? "正在灌…" : "一键灌默认项目", { Task { await seed() } })
                        )
                    }
                    .cardRow(top: 10)
                }

                if !active.isEmpty {
                    GroupTitle(text: "在用", trailing: "\(active.count)", icon: "ruler")
                        .cardRow(top: 10, bottom: 2)
                    ForEach(active) { m in
                        MetricCell(m: m)
                            .contentShape(Rectangle())
                            .onTapGesture { editing = m }
                            .cardRow(top: 3, bottom: 3)
                    }
                }

                if !inactive.isEmpty {
                    GroupTitle(text: "已停用", trailing: "\(inactive.count)", icon: "eye.slash")
                        .cardRow(top: 12, bottom: 2)
                    ForEach(inactive) { m in
                        MetricCell(m: m).opacity(0.55)
                            .contentShape(Rectangle())
                            .onTapGesture { editing = m }
                            .cardRow(top: 3, bottom: 3)
                    }
                }

                if !d.metrics.isEmpty {
                    Text("停用不删：已录的成绩全部保留，只是录新成绩时不再出现在下拉里。")
                        .font(.caption).foregroundStyle(Theme.ink3)
                        .cardRow(top: 14)
                }
            }
        }
        .listStyle(.plain)
        .pageBackground()
        .navigationTitle("体测项目")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNew = true } label: { Image(systemName: "plus.circle.fill").font(.title3) }
            }
        }
        .task { if data == nil { await load() } }
        .sheet(isPresented: $showNew) { MetricFormSheet(metric: nil) { Task { await load() } } }
        .sheet(item: $editing) { m in MetricFormSheet(metric: m) { Task { await load() } } }
    }

    private func load() async {
        err = nil
        do { data = try await API(session).get("/coach/api/metrics") }
        catch APIError.gone { session.signOut() }
        catch { err = errText(error) }
    }

    private func seed() async {
        seeding = true; err = nil
        defer { seeding = false }
        do {
            try await API(session).post("/coach/api/metrics/seed", [:])
            await load()
        } catch { err = errText(error) }
    }
}

struct MetricCell: View {
    let m: Metric
    var body: some View {
        CardBox(padding: 13) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(m.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    HStack(spacing: 6) {
                        if !m.unit.isEmpty { Pill(text: m.unit, tone: .neutral) }
                        // 方向是项目的固有属性，不是「进步与否」的判据（那个在后端）
                        Pill(text: m.higher_is_better == 1 ? "越高越好" : "越低越好",
                             tone: m.higher_is_better == 1 ? .ok : .accent,
                             icon: m.higher_is_better == 1 ? "arrow.up" : "arrow.down")
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.ink3)
            }
        }
    }
}

struct MetricFormSheet: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let metric: Metric?
    let onDone: () -> Void

    @State private var name = ""
    @State private var unit = ""
    @State private var higher = true
    @State private var sortOrder = ""
    @State private var isActive = true
    @State private var busy = false
    @State private var err: String?

    var body: some View {
        NavigationStack {
            Form {
                if let e = err { Section { ErrorBar(text: e) } }
                Section {
                    TextField("项目名（如 立定跳远）", text: $name)
                    TextField("单位（如 cm、秒、个；可不填）", text: $unit)
                }
                Section {
                    Picker("方向", selection: $higher) {
                        Text("数值越大越好").tag(true)
                        Text("数值越小越好").tag(false)
                    }
                } footer: {
                    Text("50 米跑、体重这类填「越小越好」。填错会让「进步」判反 —— 判定在服务器做，依据的就是这一项。")
                }
                Section {
                    TextField("排序（数字小的排前面）", text: $sortOrder)
                        .keyboardType(.numberPad)
                }
                if metric != nil {
                    Section {
                        Toggle("在用", isOn: $isActive)
                    } footer: {
                        Text("停用不删：已录成绩全部保留，只是不再出现在录成绩的下拉里。")
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
            .navigationTitle(metric == nil ? "新项目" : "改项目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .onAppear {
                if let m = metric {
                    name = m.name; unit = m.unit
                    higher = m.higher_is_better == 1
                    sortOrder = String(m.sort_order)
                    isActive = m.is_active == 1
                }
            }
        }
    }

    private func submit() async {
        busy = true; err = nil
        defer { busy = false }
        var f: [String: String] = [
            "name": name, "unit": unit,
            "higher_is_better": higher ? "on" : "",
            "sort_order": sortOrder.isEmpty ? "0" : sortOrder,
        ]
        do {
            if let m = metric {
                // is_active 每次都必须提交 —— 缺字段后端按 0 处理（同 student / location），
                // 会把项目静默停用，而且不报错
                f["is_active"] = isActive ? "on" : ""
                try await API(session).post("/coach/api/metrics/\(m.id)", f)
            } else {
                try await API(session).post("/coach/api/metrics", f)
            }
            onDone(); dismiss()
        } catch {
            err = errText(error)
        }
    }
}
