import SwiftUI

@main
struct FitCoachApp: App {
    @StateObject private var session = Session()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .tint(.accentColor)   // 主题色 SSOT=products.yaml theme → AccentColor.colorset（theme_sync.py 派生）
                .preferredColorScheme(.light)   // 亮色主题（与网页端/小程序一致）
        }
    }
}

struct RootView: View {
    @EnvironmentObject var session: Session

    /// `-fitcoach.screen metrics|password|student:<id>|trend:<id>` —— 直接落到某个深层界面。
    /// **只为截图与联调**：模拟器没有点击能力，不给直达入口，嵌套两层以下的界面
    /// 就永远没有人真正看过它长什么样，只能靠「编译过了」自我安慰。
    private var deepScreen: String? {
        UserDefaults.standard.string(forKey: "fitcoach.screen")
    }

    var body: some View {
        if session.isCoach, let s = deepScreen, !s.isEmpty {
            NavigationStack { deepView(s) }
        } else if session.isCoach {
            CoachTabs()
        } else if session.isStudent {
            StudentModeView()
        } else {
            LoginView()
        }
    }

    @ViewBuilder
    private func deepView(_ s: String) -> some View {
        let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "metrics":  MetricsView()
        case "password": PasswordView()
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

    /// 初始 tab 可由启动参数指定：`-fitcoach.tab schedule|students|availability|more`。
    /// 与已有的 `-fitcoach.baseURL` / `-fitcoach.coachCookie` 同一条路子（UserDefaults
    /// 自动收 `-key value` 形式的启动参数），**只为截图/联调可复现**：
    /// 模拟器没有点击能力，不给个入口就只能截到第一个 tab，其余屏永远没人真正看过。
    @State private var tab: String =
        UserDefaults.standard.string(forKey: "fitcoach.tab") ?? "schedule"

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { ScheduleView() }
                .tabItem { Label("日程", systemImage: "calendar") }
                .tag("schedule")
            NavigationStack { StudentsView() }
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
    @State private var showServer = false
    @State private var showSignOut = false

    var body: some View {
        List {
            GroupTitle(text: "管理", icon: "slider.horizontal.3").cardRow(top: 10, bottom: 2)
            CardBox(padding: 0) {
                VStack(spacing: 0) {
                    MoreLink(icon: "ruler", tone: .accent, title: "体测项目",
                             detail: "成长数据测什么，在这里定") { MetricsView() }
                    MoreDivider()
                    MoreLink(icon: "mappin.and.ellipse", tone: .ok, title: "上课地点",
                             detail: "排课时可选的地点") { LocationsView() }
                    MoreDivider()
                    MoreLink(icon: "list.bullet.rectangle", tone: .violet, title: "变更记录",
                             detail: "谁在什么时候改了什么") { AuditView() }
                }
            }
            .cardRow()

            GroupTitle(text: "账号", icon: "person.crop.circle").cardRow(top: 14, bottom: 2)
            CardBox(padding: 0) {
                VStack(spacing: 0) {
                    MoreLink(icon: "key.fill", tone: .warn, title: "修改密码",
                             detail: "与网页端同一个账号") { PasswordView() }
                }
            }
            .cardRow()

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
                        if !v.isEmpty { session.baseURL = v.hasSuffix("/") ? String(v.dropLast()) : v }
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
            do { data = try await API(session).get("/coach/api/students/\(studentId)/growth") }
            catch { err = errText(error) }
        }
    }
}
