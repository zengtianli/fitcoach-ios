import SwiftUI

struct StudentDetailView: View {
    @EnvironmentObject var session: Session
    let studentId: Int

    @State private var data: StudentDetailResp?
    @State private var err: String?
    @State private var editStudent = false
    @State private var newPackage = false
    @State private var editPackage: PackageRow?
    @State private var voidTarget: PackageRow?
    @State private var newSession = false
    @State private var editSession: SessionRow?
    @State private var statusTarget: SessionRow?
    @State private var link: LinkResp?
    @State private var linkBusy = false
    @State private var showRevoke = false

    /// 展示顺序：可用 → 已过期 → 已用完 → 已作废
    private let bucketOrder = ["active", "lapsed", "exhausted", "voided"]

    var body: some View {
        List {
            if let e = err { ErrorBar(text: e).listRowBackground(Color.clear) }
            if data == nil { Loading().listRowBackground(Color.clear) }

            if let d = data {
                Section("余额") {
                    LabeledContent("可用合计") {
                        Text("\(d.totals.available_total)").bold().monospacedDigit()
                    }
                    if d.totals.lapsed_total > 0 {
                        LabeledContent("已过期未用") {
                            Text("\(d.totals.lapsed_total)").foregroundStyle(.orange).monospacedDigit()
                        }
                    }
                    if d.totals.over_used > 0 {
                        LabeledContent("已超上") {
                            Text("\(d.totals.over_used) 节").foregroundStyle(.red).monospacedDigit()
                        }
                    }
                    if !d.student.note.isEmpty {
                        LabeledContent("备注", value: d.student.note)
                    }
                    if d.student.is_active == 0 {
                        Text("此学员已停用").font(.footnote).foregroundStyle(.orange)
                    }
                }

                Section {
                    if linkBusy { ProgressView() }
                    if let l = link, let url = l.link_url {
                        ShareLink(item: URL(string: url) ?? URL(string: "https://fit.tianli.cyou")!) {
                            Label("分享学员链接", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            UIPasteboard.general.string = url
                        } label: { Label("复制链接", systemImage: "doc.on.doc") }
                        Text(url).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        Button("重新签发（旧链接立即失效）") { Task { await token("rotate") } }
                        Button("吊销链接", role: .destructive) { showRevoke = true }
                    } else {
                        Button("签发学员链接") { Task { await token("rotate") } }
                    }
                } header: {
                    Text("学员端链接")
                } footer: {
                    Text("链接即凭证，谁拿到谁能看这个学员的课时（看不到价格、备注与变更记录）。怀疑外泄就重新签发。")
                }

                ForEach(bucketOrder, id: \.self) { b in
                    if let ps = d.buckets[b], !ps.isEmpty {
                        Section("\(Vocab.bucketLabels[b] ?? b)课包（\(ps.count)）") {
                            ForEach(ps) { p in
                                PackageCell(p: p)
                                    .contentShape(Rectangle())
                                    .onTapGesture { editPackage = p }
                                    .swipeActions(edge: .trailing) {
                                        Button(p.voided_at == nil ? "作废" : "撤销作废") {
                                            voidTarget = p
                                        }
                                        .tint(p.voided_at == nil ? .red : .blue)
                                    }
                            }
                        }
                    }
                }

                Section("课次（\(d.sessions.count)）") {
                    if d.sessions.isEmpty { EmptyHint(text: "还没有课次") }
                    ForEach(d.sessions) { s in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(TZ.mdhm(s.start_at)).font(.subheadline).monospacedDigit()
                                Spacer()
                                StatusTag(status: s.status)
                            }
                            if !s.content.isEmpty {
                                Text(s.content).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { statusTarget = s }
                        .swipeActions(edge: .trailing) {
                            Button("改课") { editSession = s }.tint(.blue)
                        }
                    }
                }

                NavigationLink("这个学员的变更记录") {
                    AuditView(studentFilter: studentId, showAll: true)
                }
            }
        }
        .navigationTitle(data?.student.name ?? "学员")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("改资料") { editStudent = true }
                    Button("加课包") { newPackage = true }
                    Button("排一节课") { newSession = true }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task { if data == nil { await load() } }
        .sheet(isPresented: $editStudent) {
            StudentFormSheet(student: data?.student) { Task { await load() } }
        }
        .sheet(isPresented: $newPackage) {
            PackageFormSheet(studentId: studentId, package: nil) { Task { await load() } }
        }
        .sheet(item: $editPackage) { p in
            PackageFormSheet(studentId: studentId, package: p) { Task { await load() } }
        }
        .sheet(item: $voidTarget) { p in
            VoidSheet(package: p) { Task { await load() } }
        }
        .sheet(isPresented: $newSession) {
            SessionFormView(sessionId: nil, studentId: studentId, presetDate: nil) {
                Task { await load() }
            }
        }
        .sheet(item: $editSession) { s in
            SessionFormView(sessionId: s.id, studentId: studentId, presetDate: nil) {
                Task { await load() }
            }
        }
        .sheet(item: $statusTarget) { s in
            StatusSheet(session_: s) { Task { await load() } }
        }
        .alert("吊销学员链接？", isPresented: $showRevoke) {
            Button("取消", role: .cancel) {}
            Button("吊销", role: .destructive) { Task { await token("revoke") } }
        } message: {
            Text("学员手里的旧链接会立即变成 404。之后可以重新签发一条新的。")
        }
    }

    private func load() async {
        err = nil
        do {
            data = try await API(session).get("/coach/api/students/\(studentId)")
            link = try await API(session).get("/coach/api/students/\(studentId)/link")
        } catch APIError.gone { session.signOut() }
        catch { err = errText(error) }
    }

    private func token(_ action: String) async {
        linkBusy = true; err = nil
        defer { linkBusy = false }
        do {
            let r = try await API(session).post("/coach/api/students/\(studentId)/token", [
                "action": action, "reason": "",
            ])
            link = LinkResp(has_link: r.link_url != nil, link_url: r.link_url)
        } catch { err = errText(error) }
    }
}

struct PackageCell: View {
    let p: PackageRow
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(p.total_sessions) 节").font(.headline)
                if p.unit_price_cents > 0 {
                    Text("· ¥\(Money.yuanShort(p.unit_price_cents))/节")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                BucketTag(bucket: p.bucket)
            }
            HStack(spacing: 10) {
                Text("剩 \(p.remaining)").font(.subheadline).monospacedDigit()
                    .foregroundStyle(p.remaining < 0 ? .red : .primary)
                Text("还能排 \(p.bookable)").font(.caption).foregroundStyle(.secondary)
                Text("已排 \(p.booked)").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text("购于 \(p.purchased_on)").font(.caption2).foregroundStyle(.secondary)
                if let e = p.expires_on {
                    Text("到期 \(e)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if p.voided_at != nil {
                Text("已作废\(p.void_reason.isEmpty ? "" : "：" + p.void_reason)")
                    .font(.caption2).foregroundStyle(.red)
            }
            if !p.note.isEmpty {
                Text(p.note).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
