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
    @State private var showLinkURL = false
    // 成长数据独立取（/coach/api/students/{id}/growth），失败单独报，
    // 不能让它把整个学员详情拖成一片空白
    @State private var growth: GrowthResp?
    @State private var growthErr: String?
    @State private var recording = false

    /// 展示顺序：可用 → 已过期 → 已用完 → 已作废
    private let bucketOrder = ["active", "lapsed", "exhausted", "voided"]

    var body: some View {
        List {
            if let e = err { ErrorBar(text: e).cardRow() }
            if data == nil { CardBox { Loading() }.cardRow() }

            if let d = data {
                // ── 余额总览 ─────────────────────────────────────────────
                CardBox {
                    VStack(spacing: 12) {
                        HStack(spacing: 10) {
                            StatBlock(value: "\(d.totals.available_total)", label: "可用课时",
                                      tone: d.totals.available_total <= 0 ? .danger : .accent,
                                      big: true)
                            if d.totals.lapsed_total > 0 {
                                StatBlock(value: "\(d.totals.lapsed_total)", label: "过期未用",
                                          tone: .warn, big: true)
                            }
                            if d.totals.over_used > 0 {
                                StatBlock(value: "\(d.totals.over_used)", label: "已超上",
                                          tone: .danger, big: true)
                            }
                        }
                        if !d.student.note.isEmpty {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "note.text")
                                    .font(.caption2).foregroundStyle(Theme.ink3)
                                Text(d.student.note).font(.caption).foregroundStyle(Theme.ink2)
                                Spacer(minLength: 0)
                            }
                        }
                        if d.student.is_active == 0 {
                            HStack(spacing: 6) {
                                Image(systemName: "pause.circle.fill").foregroundStyle(Theme.warn)
                                Text("此学员已停用，链接已被吊销")
                                    .font(.caption).foregroundStyle(Theme.warn)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .cardRow(top: 10)

                // ── 成长数据 ─────────────────────────────────────────────
                GrowthPanel(studentId: studentId, data: growth, err: growthErr,
                            onRecord: { recording = true },
                            onReload: { Task { await loadGrowth() } })

                // ── 学员端链接 ───────────────────────────────────────────
                GroupTitle(text: "学员端链接", icon: "link").cardRow(top: 14, bottom: 2)
                CardBox {
                    VStack(alignment: .leading, spacing: 10) {
                        if linkBusy { Loading() }
                        if let l = link, let url = l.link_url {
                            HStack(spacing: 10) {
                                ShareLink(item: URL(string: url) ?? URL(string: "https://fit.tianli.cyou")!) {
                                    Label("分享", systemImage: "square.and.arrow.up")
                                        .font(.subheadline.weight(.semibold))
                                }
                                Divider().frame(height: 16)
                                Button {
                                    UIPasteboard.general.string = url
                                } label: {
                                    Label("复制", systemImage: "doc.on.doc")
                                        .font(.subheadline.weight(.semibold))
                                }
                                Spacer()
                                Button(showLinkURL ? "隐藏" : "看链接") { showLinkURL.toggle() }
                                    .font(.caption)
                            }
                            if showLinkURL {
                                Text(url).font(.caption2).monospaced()
                                    .foregroundStyle(Theme.ink3).textSelection(.enabled)
                            }
                            Divider().overlay(Theme.hairline)
                            HStack {
                                Button("重新签发") { Task { await token("rotate") } }
                                    .font(.footnote)
                                Spacer()
                                Button("吊销链接", role: .destructive) { showRevoke = true }
                                    .font(.footnote)
                            }
                            Text("链接即凭证，谁拿到谁能看这个学员的课时（看不到价格、备注与变更记录）。怀疑外泄就重新签发，旧链接立即失效。")
                                .font(.caption2).foregroundStyle(Theme.ink3)
                        } else {
                            EmptyState(icon: "link.badge.plus",
                                       title: "还没签发学员链接",
                                       detail: "签发后把链接发给学员，他就能自己看剩余课时与下一节课。",
                                       tone: .accent,
                                       action: ("签发学员链接", { Task { await token("rotate") } }))
                        }
                    }
                }
                .cardRow()

                // ── 课包 ─────────────────────────────────────────────────
                ForEach(bucketOrder, id: \.self) { b in
                    if let ps = d.buckets[b], !ps.isEmpty {
                        GroupTitle(text: "\(Vocab.bucketLabels[b] ?? b)课包",
                                   trailing: "\(ps.count) 个", icon: "shippingbox")
                            .cardRow(top: 14, bottom: 2)
                        ForEach(ps) { p in
                            PackageCell(p: p)
                                .contentShape(Rectangle())
                                .onTapGesture { editPackage = p }
                                .cardRow()
                                .swipeActions(edge: .trailing) {
                                    Button(p.voided_at == nil ? "作废" : "撤销作废") {
                                        voidTarget = p
                                    }
                                    .tint(p.voided_at == nil ? Theme.danger : Theme.accent)
                                }
                        }
                    }
                }

                // ── 课次 ─────────────────────────────────────────────────
                GroupTitle(text: "课次", trailing: "\(d.sessions.count) 节", icon: "calendar")
                    .cardRow(top: 14, bottom: 2)
                if d.sessions.isEmpty {
                    CardBox {
                        EmptyState(icon: "calendar.badge.plus",
                                   title: "还没有课次",
                                   detail: "排第一节课，或补录已经上过的课。",
                                   tone: .accent,
                                   action: ("排一节课", { newSession = true }))
                    }
                    .cardRow()
                }
                ForEach(d.sessions) { s in
                    CardBox(padding: 12) {
                        HStack(spacing: 10) {
                            Text(TZ.mdhm(s.start_at))
                                .font(.subheadline.weight(.medium)).monospacedDigit()
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                            if !s.content.isEmpty {
                                Text(s.content).font(.caption)
                                    .foregroundStyle(Theme.ink2).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            StatusTag(status: s.status)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { statusTarget = s }
                    .cardRow(top: 3, bottom: 3)
                    .swipeActions(edge: .trailing) {
                        Button("改课") { editSession = s }.tint(Theme.accent)
                    }
                }

                NavigationLink {
                    AuditView(studentFilter: studentId, showAll: true)
                } label: {
                    CardBox(padding: 13) {
                        HStack {
                            Label("这个学员的变更记录", systemImage: "list.bullet.rectangle")
                                .font(.subheadline)
                            Spacer()
                        }
                    }
                }
                .buttonStyle(.plain)
                .cardRow(top: 14, bottom: 20)
            }
        }
        .listStyle(.plain)
        .pageBackground()
        .navigationTitle(data?.student.name ?? "学员")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { editStudent = true } label: { Label("改资料", systemImage: "pencil") }
                    Button { newPackage = true } label: { Label("加课包", systemImage: "plus.rectangle.on.folder") }
                    Button { newSession = true } label: { Label("排一节课", systemImage: "calendar.badge.plus") }
                    Button { recording = true } label: { Label("录体测成绩", systemImage: "ruler") }
                } label: { Image(systemName: "ellipsis.circle.fill").font(.title3) }
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
        .sheet(isPresented: $recording) {
            MeasurementFormSheet(studentId: studentId) { Task { await loadGrowth() } }
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
        await loadGrowth()
    }

    private func loadGrowth() async {
        growthErr = nil
        do { growth = try await API(session).get("/coach/api/students/\(studentId)/growth") }
        catch { growthErr = errText(error) }
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
        CardBox(padding: 13) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("\(p.total_sessions) 节课包")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    if p.unit_price_cents > 0 {
                        Text("¥\(Money.yuanShort(p.unit_price_cents))/节")
                            .font(.caption).monospacedDigit().foregroundStyle(Theme.ink3)
                    }
                    Spacer(minLength: 4)
                    BucketTag(bucket: p.bucket)
                }
                HStack(spacing: 10) {
                    StatBlock(value: "\(p.remaining)", label: "剩余",
                              tone: p.remaining < 0 ? .danger : .accent)
                    StatBlock(value: "\(p.bookable)", label: "还能排")
                    StatBlock(value: "\(p.booked)", label: "已排")
                    StatBlock(value: "\(p.used)", label: "已消耗")
                }
                HStack(spacing: 6) {
                    Pill(text: "购于 \(p.purchased_on)", tone: .neutral, icon: "calendar")
                    if let e = p.expires_on {
                        Pill(text: "到期 \(e)",
                             tone: p.bucket == "lapsed" ? .warn : .neutral, icon: "hourglass")
                    }
                }
                if p.voided_at != nil {
                    Text("已作废\(p.void_reason.isEmpty ? "" : "：" + p.void_reason)")
                        .font(.caption2).foregroundStyle(Theme.danger)
                }
                if !p.note.isEmpty {
                    Text(p.note).font(.caption2).foregroundStyle(Theme.ink3)
                }
            }
        }
    }
}
