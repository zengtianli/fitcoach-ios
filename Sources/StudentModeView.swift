import SwiftUI

/// 学员端：只读，凭同一条分享链接的 token。
/// 后端 `/s/api/view` 返回的是 9 键窄视图 —— 价格 / 备注 / 变更记录在结构上进不来。
struct StudentModeView: View {
    @EnvironmentObject var session: Session
    @State private var data: StudentView?
    @State private var err: String?
    @State private var loading = false

    var body: some View {
        NavigationStack {
            List {
                if let e = err { ErrorBar(text: e).listRowBackground(Color.clear) }
                if loading && data == nil { Loading().listRowBackground(Color.clear) }

                if let d = data {
                    Section {
                        VStack(spacing: 6) {
                            Text("\(max(d.available_total, 0))")
                                .font(.system(size: 56, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text("剩余可用课时").font(.subheadline).foregroundStyle(.secondary)
                            if d.over_used > 0 {
                                Text("已超上 \(d.over_used) 节").font(.footnote).foregroundStyle(.red)
                            }
                            if d.lapsed_total > 0 {
                                Text("另有 \(d.lapsed_total) 节已过期未用")
                                    .font(.footnote).foregroundStyle(.orange)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }

                    if let n = d.next_session {
                        Section("下一节") {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(n.start_at).font(.headline).monospacedDigit()
                                HStack(spacing: 8) {
                                    Text("\(n.duration_min) 分钟").font(.caption)
                                    if let l = n.location_name, !l.isEmpty {
                                        Label(l, systemImage: "mappin").font(.caption)
                                    }
                                }
                                .foregroundStyle(.secondary)
                                if !n.content.isEmpty { Text(n.content).font(.caption) }
                            }
                        }
                    }

                    if !d.packages.isEmpty {
                        Section("课包") {
                            ForEach(d.packages) { p in
                                HStack {
                                    Text("剩 \(p.remaining) 节").monospacedDigit()
                                    Spacer()
                                    if let e = p.expires_on {
                                        Text("到期 \(e)").font(.footnote).foregroundStyle(.secondary)
                                    }
                                    BucketTag(bucket: p.bucket)
                                }
                            }
                        }
                    }

                    if !d.upcoming_cancelled.isEmpty {
                        Section("已取消的预约") {
                            ForEach(d.upcoming_cancelled) { s in
                                HStack {
                                    Text(TZ.mdhm(s.start_at)).monospacedDigit()
                                    Spacer()
                                    StatusTag(status: s.status, label: s.status_label)
                                }
                            }
                        }
                    }

                    Section("上课记录（\(d.history.count)）") {
                        if d.history.isEmpty { EmptyHint(text: "还没有上过课") }
                        ForEach(d.history) { s in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(TZ.mdhm(s.start_at)).font(.subheadline).monospacedDigit()
                                    Spacer()
                                    StatusTag(status: s.status, label: s.status_label)
                                }
                                HStack(spacing: 8) {
                                    if let l = s.location_name, !l.isEmpty {
                                        Text(l).font(.caption).foregroundStyle(.secondary)
                                    }
                                    if !s.content.isEmpty {
                                        Text(s.content).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(data?.student_name ?? "我的课时")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await load() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("退出") { session.leaveStudent() }
                }
            }
            .task { if data == nil { await load() } }
        }
    }

    private func load() async {
        loading = true; err = nil
        defer { loading = false }
        do { data = try await API(session).get("/s/api/view", student: true) }
        catch APIError.gone {
            err = "这条链接已失效（可能被教练重新签发或吊销），找教练要一条新的。"
        }
        catch { err = errText(error) }
    }
}
