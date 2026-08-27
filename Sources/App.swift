import SwiftUI

@main
struct FitCoachApp: App {
    @StateObject private var session = Session()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .tint(.blue)
                .preferredColorScheme(.light)   // 亮色主题（与网页端/小程序一致）
        }
    }
}

struct RootView: View {
    @EnvironmentObject var session: Session

    var body: some View {
        if session.isCoach {
            CoachTabs()
        } else if session.isStudent {
            StudentModeView()
        } else {
            LoginView()
        }
    }
}

struct CoachTabs: View {
    @EnvironmentObject var session: Session

    var body: some View {
        TabView {
            NavigationStack { ScheduleView() }
                .tabItem { Label("日程", systemImage: "calendar") }
            NavigationStack { StudentsView() }
                .tabItem { Label("学员", systemImage: "person.2") }
            NavigationStack { AvailabilityView() }
                .tabItem { Label("档期", systemImage: "clock") }
            NavigationStack { MoreView() }
                .tabItem { Label("更多", systemImage: "ellipsis.circle") }
        }
    }
}

struct MoreView: View {
    @EnvironmentObject var session: Session
    @State private var showServer = false

    var body: some View {
        List {
            Section {
                NavigationLink { LocationsView() } label: {
                    Label("上课地点", systemImage: "mappin.and.ellipse")
                }
                NavigationLink { AuditView() } label: {
                    Label("变更记录", systemImage: "list.bullet.rectangle")
                }
            }
            Section("服务器") {
                Text(session.baseURL).font(.footnote).foregroundStyle(.secondary)
                Button("修改服务器地址") { showServer = true }
            }
            Section {
                Button("退出登录", role: .destructive) { session.signOut() }
            } footer: {
                Text("退出只清掉本机保存的会话凭证，不影响服务器上的数据。")
            }
        }
        .navigationTitle("更多")
        .sheet(isPresented: $showServer) { ServerSheet() }
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
