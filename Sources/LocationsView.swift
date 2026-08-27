import SwiftUI

struct LocationsView: View {
    @EnvironmentObject var session: Session
    @State private var data: LocationsResp?
    @State private var err: String?
    @State private var showNew = false
    @State private var editing: Location?

    var body: some View {
        List {
            if let e = err { ErrorBar(text: e).cardRow() }
            if data == nil { Loading().cardRow() }
            if let d = data {
                let active = d.locations.filter { $0.is_active == 1 }
                let off = d.locations.filter { $0.is_active == 0 }

                if d.locations.isEmpty {
                    CardBox {
                        EmptyState(icon: "mappin.and.ellipse",
                                   title: "还没有上课地点",
                                   detail: "加一个地点，排课时就能选它。",
                                   tone: .accent,
                                   action: ("加第一个地点", { showNew = true }))
                    }
                    .cardRow(top: 10)
                } else {
                    GroupTitle(text: "启用中", trailing: "\(active.count)", icon: "mappin.circle.fill")
                        .cardRow(top: 10, bottom: 2)
                    ForEach(active) { l in
                        Button { editing = l } label: { LocationCell(l: l) }
                            .buttonStyle(.plain)
                            .cardRow(top: 3, bottom: 3)
                    }
                    if !off.isEmpty {
                        GroupTitle(text: "已停用", trailing: "\(off.count)", icon: "eye.slash")
                            .cardRow(top: 14, bottom: 2)
                        ForEach(off) { l in
                            Button { editing = l } label: { LocationCell(l: l).opacity(0.55) }
                                .buttonStyle(.plain)
                                .cardRow(top: 3, bottom: 3)
                        }
                        Text("停用不删：历史课次上的地点名照旧显示，只是排新课时不再出现。")
                            .font(.caption).foregroundStyle(Theme.ink3)
                            .cardRow(top: 12)
                    }
                }
            }
        }
        .listStyle(.plain)
        .pageBackground()
        .navigationTitle("上课地点")
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
        .sheet(isPresented: $showNew) { LocationSheet(location: nil) { Task { await load() } } }
        .sheet(item: $editing) { l in LocationSheet(location: l) { Task { await load() } } }
    }

    private func load() async {
        err = nil
        do { data = try await API(session).get("/coach/api/locations") }
        catch APIError.gone { session.signOut() }
        catch { err = errText(error) }
    }
}

struct LocationCell: View {
    let l: Location
    var body: some View {
        CardBox(padding: 13) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Theme.okSoft).frame(width: 34, height: 34)
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.ok)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(l.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    if !l.address.isEmpty {
                        Text(l.address).font(.caption).foregroundStyle(Theme.ink3).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.ink3)
            }
        }
    }
}

struct LocationSheet: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let location: Location?
    let onDone: () -> Void

    @State private var name = ""
    @State private var address = ""
    @State private var isActive = true
    @State private var busy = false
    @State private var err: String?

    var body: some View {
        NavigationStack {
            Form {
                if let e = err { Section { ErrorBar(text: e) } }
                Section {
                    TextField("名称", text: $name)
                    TextField("地址（可不填）", text: $address, axis: .vertical).lineLimit(1...3)
                }
                if location != nil {
                    Section {
                        Toggle("启用", isOn: $isActive)
                    } footer: {
                        Text("停用不删除 —— 历史课次里引用它的记录要保持可读。")
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
            .navigationTitle(location == nil ? "新地点" : "改地点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .onAppear {
                if let l = location { name = l.name; address = l.address; isActive = l.is_active == 1 }
            }
        }
    }

    private func submit() async {
        busy = true; err = nil
        defer { busy = false }
        do {
            if let l = location {
                // 同 students：is_active 必须每次提交，缺字段后端按停用处理
                try await API(session).post("/coach/api/locations/\(l.id)", [
                    "name": name, "address": address, "is_active": isActive ? "on" : "",
                ])
            } else {
                try await API(session).post("/coach/api/locations", ["name": name, "address": address])
            }
            onDone(); dismiss()
        } catch { err = errText(error) }
    }
}
