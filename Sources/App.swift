import SwiftUI
#if os(iOS)
import UIKit
#endif

@main
struct FitCoachApp: App {
    #if os(macOS)
    // 平台验收车道的静默启动（-lane_quiet）；不传参数时什么都不做（Shared/LaneSignal.swift）
    @NSApplicationDelegateAdaptor(LaneAppDelegate.self) private var laneDelegate
    #endif
    @StateObject private var session = Session()

    init() {
        // 手表来要「今天」时 iPhone 可能是在后台被唤起的：会话代理要在第一时间挂上（其余平台空操作）
        WatchLink.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .appLifecycleMobile(productID: "fitcoach-ios", channel: MobileProductLifecycle.channel,
                                    configuration: MobileProductLifecycle.configuration,
                                    placement: session.isCoach && !session.showingLogin ? .settings : .footer)
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FitCoachPortableConfigurationApplied"))) { note in
                    guard let base = note.object as? String else { return }
                    session.coachCookie = nil
                    session.studentToken = nil
                    session.coachEmail = nil
                    session.studentMode = false
                    session.baseURL = base
                    session.showingLogin = true
                }
                .environmentObject(session)
                .tint(.accentColor)   // 主题色 SSOT=products.yaml theme → AccentColor.colorset（theme_sync.py 派生）
                #if !os(visionOS)
                .preferredColorScheme(.light)   // 亮色主题（与网页端/小程序一致）；Vision Pro 只有玻璃，见 Theme.swift
                #endif
        }
        #if os(macOS)
        // Mac 默认窗口太窄，摆不下侧栏 + 日程看板
        .defaultSize(width: 1180, height: 780)
        #elseif os(visionOS)
        // Vision Pro 的默认窗口偏扁，字号也比 Mac 大一圈：给侧栏 + 日程 + 课时余额三列留够宽度
        .defaultSize(width: 1360, height: 860)
        #endif
    }
}

struct RootView: View {
    @EnvironmentObject var session: Session
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    /// 只认 iPad 的 regular：iPhone Pro Max 横屏时尺寸类也是 regular，但那块屏摆不下侧栏 + 看板，
    /// 仍走原来的底部 TabView。
    private var wide: Bool { hSize == .regular && UIDevice.current.userInterfaceIdiom == .pad }
    #else
    private let wide = true      // Mac 与 Vision Pro 的窗口一律按宽屏排
    #endif

    /// `-fitcoach.screen metrics|password|student:<id>|trend:<id>` —— 直接落到某个深层界面。
    /// **只为截图与联调**：模拟器没有点击能力，不给直达入口，嵌套两层以下的界面
    /// 就永远没有人真正看过它长什么样，只能靠「编译过了」自我安慰。
    private var deepScreen: String? {
        UserDefaults.standard.string(forKey: "fitcoach.screen")
    }

    var body: some View {
        Group {
            if session.showingLogin {
                LoginView(initialMode: session.loginMode)
            } else if session.isCoach, let s = deepScreen, !s.isEmpty {
                NavigationStack { deepView(s) }
            } else if session.isCoach {
                CoachTabs()
            } else if session.isStudent {
                StudentModeView()
            } else if deepScreen == "register" {
                RegisterView()                  // 截图/联调直达注册页（未登录态才有意义）
            } else {
                LoginView()
            }
        }
        .environment(\.wideLayout, wide)
        .task {
            LaneSignal.applyOrientation()
            LaneSignal.applyWindowFrame()
            WatchLink.shared.publish()
        }
        // 登录 / 退出 / 换服务器：手表跟着换成新的「今天」或清空
        .onChange(of: session.coachCookie) { _, _ in WatchLink.shared.publish(force: true) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { WatchLink.shared.publish() }
        }
        #if os(macOS)
        .frame(minWidth: 820, minHeight: 560)
        #endif
    }

    @ViewBuilder
    private func deepView(_ s: String) -> some View {
        let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "metrics":  MetricsView()
        case "password": PasswordView()
        case "delete-account": AccountDeleteView()
        case "locations": LocationsView()
        case "audit":    AuditView()
        case "student":  StudentDetailView(studentId: Int(parts.count > 1 ? parts[1] : "1") ?? 1)
        case "trend":
            // trend:<studentId>:<metricId> —— 直达趋势图（Swift Charts 那一屏）
            let a = (parts.count > 1 ? parts[1] : "").split(separator: ":").map(String.init)
            TrendProbe(studentId: Int(a.first ?? "1") ?? 1,
                       metricId: Int(a.count > 1 ? a[1] : "1") ?? 1)
        default:         CoachTabs()
        }
    }
}

struct CoachTabs: View {
    @EnvironmentObject var session: Session
    @Environment(\.wideLayout) private var wide

    /// 初始 tab 可由启动参数指定：`-fitcoach.tab schedule|students|availability|more`。
    /// 与已有的 `-fitcoach.baseURL` / `-fitcoach.coachCookie` 同一条路子（UserDefaults
    /// 自动收 `-key value` 形式的启动参数），**只为截图/联调可复现**：
    /// 模拟器没有点击能力，不给个入口就只能截到第一个 tab，其余屏永远没人真正看过。
    @State private var tab: String =
        UserDefaults.standard.string(forKey: "fitcoach.tab") ?? "schedule"

    var body: some View {
        if wide {
            RegularHomeView(tab: $tab)      // iPad 全屏 / Mac / Vision Pro：侧栏 + 日程看板
        } else {
            compact
        }
    }

    /// 窄屏：原来那套底部 TabView，一行没改（App Store 截图就是它）。
    private var compact: some View {
        TabView(selection: $tab) {
            NavigationStack { ScheduleView() }
                .tabItem { Label("日程", systemImage: "calendar") }
                .tag("schedule")
            StudentsView()
                .tabItem { Label("学员", systemImage: "person.2") }
                .tag("students")
            NavigationStack { AvailabilityView() }
                .tabItem { Label("档期", systemImage: "clock") }
                .tag("availability")
            NavigationStack { MoreView() }
                .tabItem { Label("更多", systemImage: "ellipsis.circle") }
                .tag("more")
        }
    }
}

struct MoreView: View {
    @EnvironmentObject var session: Session
    @Environment(\.wideLayout) private var wide
    @State private var showServer = false
    @State private var showSignOut = false

    var body: some View {
        List {
            Button { session.openLogin(student: true) } label: {
                Label("切换账号 / 登录学员端", systemImage: "person.2.circle.fill")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
            }
                .buttonStyle(.borderedProminent)
                .cardRow(top: 10)
            MoreLink(icon: "wand.and.stars", tone: .accent, title: "快速开始",
                     detail: "一键准备地点、档期和常用体测项目") { QuickSetupView() }
                .cardRow(top: 10)
            if !wide {      // 宽屏这三项在侧栏的「管理」里，这里不再重复
                GroupTitle(text: "管理", icon: "slider.horizontal.3").cardRow(top: 10, bottom: 2)
                MoreLink(icon: "ruler", tone: .accent, title: "体测项目",
                         detail: "成长数据测什么，在这里定") { MetricsView() }.cardRow()
                MoreLink(icon: "mappin.and.ellipse", tone: .ok, title: "上课地点",
                         detail: "排课时可选的地点") { LocationsView() }.cardRow()
                MoreLink(icon: "list.bullet.rectangle", tone: .violet, title: "变更记录",
                         detail: "谁在什么时候改了什么") { AuditView() }.cardRow()
            }

            GroupTitle(text: "账号", icon: "person.crop.circle").cardRow(top: 14, bottom: 2)
            MoreLink(icon: "key.fill", tone: .warn, title: "修改密码",
                     detail: "与网页端同一个账号") { PasswordView() }.cardRow()
            MoreLink(icon: "person.crop.circle.badge.xmark", tone: .danger, title: "注销账号",
                     detail: "删除账号与当前业务数据") { AccountDeleteView() }.cardRow()

            CardBox { PrivacySupportLinks() }.cardRow()

            GroupTitle(text: "应用", icon: "gearshape").cardRow(top: 14, bottom: 2)
            CardBox { AppLifecycleMobileEntry() }.cardRow()

            GroupTitle(text: "服务器", icon: "server.rack").cardRow(top: 14, bottom: 2)
            CardBox {
                VStack(alignment: .leading, spacing: 9) {
                    Text(session.baseURL)
                        .font(.footnote).monospaced()
                        .foregroundStyle(Theme.ink2)
                        .textSelection(.enabled)
                    Divider().overlay(Theme.hairline)
                    Button("修改服务器地址") { showServer = true }
                        .font(.subheadline)
                }
            }
            .cardRow()

            CardBox {
                VStack(spacing: 8) {
                    Button {
                        showSignOut = true
                    } label: {
                        Text("退出登录")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Theme.dangerSoft)
                            .foregroundStyle(Theme.danger)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.rInner, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    Text("退出只清掉本机保存的会话凭证，不影响服务器上的数据。")
                        .font(.caption2).foregroundStyle(Theme.ink3)
                        .multilineTextAlignment(.center)
                }
            }
            .cardRow(top: 16)
        }
        .listStyle(.plain)
        .pageBackground()
        .navigationTitle("更多")
        .onAppear { LaneSignal.ready("more") }
        .sheet(isPresented: $showServer) { ServerSheet() }
        .alert("退出登录？", isPresented: $showSignOut) {
            Button("取消", role: .cancel) {}
            Button("退出", role: .destructive) { session.signOut() }
        }
    }
}

/// 「更多」里的一行入口。图标用带底色的小方块 —— 纯 SF Symbol 一列排下来
/// 大小不一（有的宽有的窄），套个固定尺寸的底才能对齐成一条线。
struct MoreLink<Destination: View>: View {
    let icon: String
    let tone: Theme.Tone
    let title: String
    var detail: String? = nil
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        let (fg, bg) = Theme.pair(tone)
        NavigationLink(destination: destination) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(bg).frame(width: 30, height: 30)
                    Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(fg)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
                    if let d = detail {
                        Text(d).font(.caption2).foregroundStyle(Theme.ink3)
                    }
                }
                Spacer(minLength: 4)
                // 这里**刻意不画** chevron：外层是 List 的 NavigationLink，系统会在行尾
                // 自己加一个。自绘会变成两个箭头并排（2026-08-27 模拟器实测）。
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct MoreDivider: View {
    var body: some View {
        Divider().overlay(Theme.hairline).padding(.leading, 55)
    }
}

struct ServerSheet: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://fit.tianli.cyou", text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } footer: {
                    Text("默认 https://fit.tianli.cyou。改这里只在自建/本地调试时才需要。")
                }
            }
            .navigationTitle("服务器地址")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        let server = v.hasSuffix("/") ? String(v.dropLast()) : v
                        if !server.isEmpty && server != session.baseURL {
                            session.studentToken = nil
                            session.signOut()
                            session.baseURL = server
                        }
                        dismiss()
                    }
                }
            }
            .onAppear { text = session.baseURL }
        }
    }
}

/// 只为截图 / 联调：直达某个学员某个项目的趋势图（正式路径是「学员详情 → 点那一行」，
/// 嵌在两层之下，靠点坐标截图不稳）。
/// 取数走与正式路径**同一个**端点、同一份 `GrowthResp`、同一个 `MetricTrendView` ——
/// 另造一条测试专用数据通路的话，截出来的画面证明不了真实界面长什么样。
struct TrendProbe: View {
    @EnvironmentObject var session: Session
    let studentId: Int
    let metricId: Int

    @State private var data: GrowthResp?
    @State private var err: String?

    var body: some View {
        Group {
            if let e = err {
                ErrorBar(text: e).padding()
            } else if let d = data {
                if let pr = d.progress.first(where: { $0.metric_id == metricId }) {
                    MetricTrendView(studentId: studentId, progress: pr,
                                    points: d.series[String(metricId)] ?? [],
                                    measurements: d.measurements.filter { $0.metric_id == metricId })
                } else {
                    // fail-visible：没有这个项目的进度就直说，别停在转圈上假装还在加载
                    EmptyState(icon: "questionmark.circle",
                               title: "metric_id=\(metricId) 没有成长数据",
                               detail: "这个学员在该项目下还没有测量记录。",
                               tone: .warn)
                }
            } else {
                Loading()
            }
        }
        .task {
            do {
                data = try await API(session).get("/coach/api/students/\(studentId)/growth")
                LaneSignal.ready("trend")
            }
            catch { err = errText(error) }
        }
    }
}
