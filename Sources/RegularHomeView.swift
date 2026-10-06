import SwiftUI

/// 宽屏主页（iPad 全屏 / 宽分屏、Mac、Vision Pro）：侧栏 + 详情（与成长小金库同一结构）。
///
/// 内容视图与 iPhone 是同一批（ScheduleView / StudentsView / AvailabilityView …），这里只决定摆法：
/// 日程旁边多一栏「课时余额」；学员是三栏（侧栏 / 名单 / 详情）；其余页面收成居中的一列，
/// 不让卡片横着拉满整块屏。「管理」三项在 iPhone 上藏在「更多」里，宽屏直接放进侧栏。
/// 窄屏 iPhone 那套底部 TabView 不经过这里（CoachTabs.compact），一个像素都没动。
///
/// 为什么不用 TabView(.sidebarAdaptable)：Mac 上它和「学员」页自带的分栏叠成两层分栏，窗口布局在
/// SplitViewChildController 的最小尺寸上来回失效直到 AppKit 抛异常退出（2026-10-02 Mac 车道实测崩溃报告），
/// 首屏以外的页也画不进离屏截图。显式的 NavigationSplitView + 学员页三栏，一层分栏到底。
struct RegularHomeView: View {
    @Binding var tab: String
    @State private var student: StudentListRow?

    enum Pane: String, CaseIterable, Identifiable {
        case schedule, students, availability, metrics, locations, audit, more
        var id: String { rawValue }
        var title: String {
            switch self {
            case .schedule: return "日程"
            case .students: return "学员"
            case .availability: return "档期"
            case .metrics: return "体测项目"
            case .locations: return "上课地点"
            case .audit: return "变更记录"
            case .more: return "更多"
            }
        }
        var icon: String {
            switch self {
            case .schedule: return "calendar"
            case .students: return "person.2"
            case .availability: return "clock"
            case .metrics: return "ruler"
            case .locations: return "mappin.and.ellipse"
            case .audit: return "list.bullet.rectangle"
            case .more: return "ellipsis.circle"
            }
        }
    }

    private var pane: Pane { Pane(rawValue: tab) ?? .schedule }

    /// 学员名单那一栏：学员卡两枚徽标不折行。Vision Pro 字号大一圈，要更宽。
    #if os(visionOS)
    static let listColumn: (min: CGFloat, ideal: CGFloat) = (360, 420)
    #else
    static let listColumn: (min: CGFloat, ideal: CGFloat) = (320, 360)
    #endif

    var body: some View {
        if pane == .students {
            NavigationSplitView {
                sidebar
            } content: {
                StudentsView(columnSelection: $student)
                    .navigationSplitViewColumnWidth(min: Self.listColumn.min, ideal: Self.listColumn.ideal, max: 460)
            } detail: {
                NavigationStack {
                    if let s = student {
                        StudentDetailView(studentId: s.id).id(s.id)
                    } else {
                        ContentUnavailableView("选择学员", systemImage: "person.2",
                                               description: Text("从名单里选一位，查看课包、课时和成长记录。"))
                    }
                }
            }
        } else {
            NavigationSplitView {
                sidebar
            } detail: {
                NavigationStack { detail }
            }
        }
    }

    private var sidebar: some View {
        List(selection: Binding<String?>(get: { tab }, set: { if let v = $0 { tab = v } })) {
            Section {
                ForEach([Pane.schedule, .students, .availability]) { row($0) }
            }
            Section("管理") {
                ForEach([Pane.metrics, .locations, .audit]) { row($0) }
            }
            Section {
                // 单独一行也放进 ForEach：直接写 row(.more) 时侧栏选中高亮不认它（2026-10-02 iPad / Mac 截图实测）
                ForEach([Pane.more]) { row($0) }
            }
        }
        .navigationTitle(AppIdentity.displayName)
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
    }

    private func row(_ p: Pane) -> some View {
        Label(p.title, systemImage: p.icon).tag(p.rawValue as String?)
    }

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .schedule: ScheduleBoard()
        case .students: EmptyView()          // 三栏，见 body
        case .availability: AvailabilityView().contentWidth(760)
        case .metrics: MetricsView().contentWidth(760)
        case .locations: LocationsView().contentWidth(760)
        case .audit: AuditView().contentWidth(860)
        case .more: MoreView().contentWidth(680)
        }
    }
}

/// 宽屏的日程：左边是 iPhone 上那张日程表（同一个 ScheduleView），右边一栏课时余额 ——
/// 排课前一眼看到谁快用完、谁的课包快到期，不用切到「学员」再回来。
/// 摆不下（详情栏宽度 < 760，如 iPad 分屏 2/3）就只留日程。
struct ScheduleBoard: View {
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ScheduleView()
                if geo.size.width >= 760 {
                    Rectangle().fill(Theme.hairline).frame(width: 1).ignoresSafeArea(edges: .bottom)
                    BalancePanel()
                        .frame(width: Self.panelWidth(geo.size.width))
                }
            }
        }
        .pageFill()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                // Mac 没有下拉刷新手势；iPad 接了键盘也一样好用
                Button {
                    NotificationCenter.default.post(name: .fitcoachReload, object: nil)
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

extension ScheduleBoard {
    /// 学员卡两枚徽标（还能排 / 将到期）不折行的最窄宽度。Vision Pro 的字号比 iPad / Mac 大一圈，要更宽。
    static func panelWidth(_ available: CGFloat) -> CGFloat {
        #if os(visionOS)
        return 420
        #else
        return available >= 1000 ? 380 : 360
        #endif
    }
}

/// 看板右栏：课时余额，剩得最少的在前。数据与「学员」页同一个端点、同一张学员卡（StudentCell）。
struct BalancePanel: View {
    @EnvironmentObject var session: Session
    @State private var data: StudentsResp?
    @State private var err: String?
    @State private var open: StudentListRow?

    private var rows: [StudentListRow] {
        (data?.rows ?? []).filter { $0.n_packages > 0 }
            .sorted { ($0.available_total, $0.name) < ($1.available_total, $1.name) }
    }

    var body: some View {
        List {
            GroupTitle(text: "课时余额", trailing: data.map { "\($0.rows.count) 人在册" }, icon: "person.2.fill")
                .cardRow(top: 14, bottom: 2)
            if let e = err { ErrorBar(text: e).cardRow() }
            if data == nil && err == nil { CardBox { Loading() }.cardRow() }

            if let d = data {
                let low = rows.filter { $0.available_total <= 2 }.count
                let expiring = d.rows.filter { $0.expiring_soon > 0 }.count
                CardBox(padding: 10) {
                    HStack(spacing: 8) {
                        StatBlock(value: "\(d.rows.count)", label: "在册", tone: .accent)
                        StatBlock(value: "\(low)", label: "剩 ≤ 2 节", tone: low > 0 ? .danger : .neutral)
                        StatBlock(value: "\(expiring)", label: "14 天内到期", tone: expiring > 0 ? .warn : .neutral)
                    }
                }
                .cardRow()

                if rows.isEmpty {
                    CardBox {
                        EmptyState(icon: "person.crop.circle.badge.plus", title: T("balances.empty.title", "还没有录课包的学员"),
                                   detail: T("balances.empty.detail", "到「学员」里建学员、录课包，余额就会出现在这里。"), tone: .accent)
                    }
                    .cardRow()
                }
                ForEach(rows) { r in
                    StudentCell(r: r)
                        .contentShape(Rectangle())
                        .onTapGesture { open = r }
                        .accessibilityAddTraits(.isButton)
                        .cardRow()
                }
            }
        }
        .listStyle(.plain)
        .pageBackground()
        .navigationDestination(item: $open) { r in StudentDetailView(studentId: r.id) }
        .refreshable { await load() }
        .task { if data == nil { await load() } }
        // 日程每次重拉（改状态、排课之后）余额都可能变了
        .onReceive(NotificationCenter.default.publisher(for: .fitcoachScheduleLoaded)) { _ in
            Task { await load() }
        }
    }

    private func load() async {
        err = nil
        do { data = try await API(session).get("/coach/api/students") }
        catch APIError.gone { session.signOut() }
        catch { err = errText(error) }
    }
}
