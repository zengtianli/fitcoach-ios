import SwiftUI

/// Product fields and actions only. Transfer, merge and update validation remain in Shared/.
@MainActor
final class FitCoachSettingsModel: ObservableObject {
    let defaults: UserDefaults
    let lifecycle: MobileLifecycleModel
    @Published var server: String
    @Published var message = ""
    @Published var showing = false
    @Published var automaticCheck = AppUpdatePreferences.options(Bundle.main.bundleIdentifier ?? "").automaticCheck
    #if os(macOS)
    let shortcuts: AppShortcuts
    @Published var shortcutEnabled: Bool
    @Published var shortcutKey: String
    #endif

    init(configuration: AppConfiguration?, channel: MobileUpdateChannel, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lifecycle = MobileLifecycleModel(productID: "fitcoach-ios", channel: channel, configuration: configuration)
        server = defaults.string(forKey: "fitcoach.baseURL") ?? Session.defaultBaseURL
        #if os(macOS)
        let shortcuts = AppShortcuts(defaults: defaults) {
            NotificationCenter.default.post(name: .fitcoachReload, object: nil)
        }
        self.shortcuts = shortcuts
        shortcutEnabled = shortcuts.enabled
        shortcutKey = shortcuts.binding.key
        #endif
    }

    func saveServer() {
        do {
            let candidate = server.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: candidate), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil else { throw AppUpdateError("请输入不含账号密码的 HTTPS 服务地址；原配置已保留。") }
            guard let config = lifecycle.configuration,
                  var envelope = try JSONSerialization.jsonObject(with: config.exportData()) as? [String: Any],
                  var values = envelope["values"] as? [String: Any] else { throw AppUpdateError("配置当前不可用。") }
            values["defaults.fitcoach.baseURL"] = candidate
            envelope["values"] = values
            try config.importData(JSONSerialization.data(withJSONObject: envelope))
            defaults.synchronize()
            message = "服务地址已保存；更换服务器需重新登录。"
        } catch { message = error.localizedDescription }
    }

    func setAutomaticCheck(_ value: Bool) {
        do {
            let identity = Bundle.main.bundleIdentifier ?? ""
            var options = AppUpdatePreferences.options(identity)
            options.automaticCheck = value
            try AppUpdatePreferences.save(options, identity)
            automaticCheck = value
        } catch { message = error.localizedDescription }
    }

    #if os(macOS)
    func setShortcutEnabled(_ enabled: Bool) {
        shortcuts.setEnabled(enabled); shortcutEnabled = shortcuts.enabled
    }
    func saveShortcut() {
        do {
            try shortcuts.setBinding(.init(key: shortcutKey.lowercased(), modifiers: .command))
            message = shortcuts.descriptionText
        } catch { message = error.localizedDescription }
    }
    #endif
}

struct FitCoachSettingsPanel: View {
    @ObservedObject var model: FitCoachSettingsModel
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("服务地址") {
                    TextField("HTTPS 服务地址", text: $model.server)
                        .accessibilityIdentifier("settings.server")
                        .autocorrectionDisabled()
                    Button("保存服务地址", action: model.saveServer)
                    Text("只同步服务地址、应用快捷键和更新选项；账号、凭据和目录授权只在本机。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                #if os(macOS)
                Section("应用快捷键") {
                    Toggle("启用刷新快捷键", isOn: Binding(get: { model.shortcutEnabled }, set: model.setShortcutEnabled))
                    HStack {
                        Text("⌘")
                        TextField("R", text: $model.shortcutKey).frame(width: 50)
                        Button("保存快捷键", action: model.saveShortcut)
                    }
                    Text("默认 ⌘R 刷新日程和学员；仅在本 App 内生效。系统编辑键保留，菜单冲突会拒绝保存。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("启动时自动检查更新", isOn: Binding(get: { model.automaticCheck }, set: model.setAutomaticCheck))
                #endif
                if !model.message.isEmpty { Text(model.message).font(.caption) }
            }
            .frame(height: 300)
            AppLifecycleMobilePanel(model: model.lifecycle)
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(width: 600, height: 760)
        #endif
    }
}

struct FitCoachSettingsEntry: View {
    @EnvironmentObject private var model: FitCoachSettingsModel
    var body: some View {
        Button { model.showing = true } label: { Label("配置与更新", systemImage: "gearshape") }
    }
}

private struct FitCoachSettingsModifier: ViewModifier {
    @StateObject var model: FitCoachSettingsModel
    let placement: AppLifecycleMobilePlacement
    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if case .footer = placement {
                    HStack { Spacer(); FitCoachSettingsEntry(); Spacer() }
                        .font(.footnote).padding(.vertical, 7).background(.bar)
                }
            }
            .environmentObject(model)
            .sheet(isPresented: $model.showing) { FitCoachSettingsPanel(model: model) }
            .task {
                model.lifecycle.start()
                #if os(macOS)
                model.shortcuts.installMenu()
                if AppUpdatePreferences.due(Bundle.main.bundleIdentifier ?? "") { model.lifecycle.checkForUpdates() }
                #endif
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FitCoachOpenSettings"))) { _ in model.showing = true }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("AppConfigurationStatusChanged"))) { _ in model.lifecycle.refreshConfiguration() }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                model.lifecycle.refreshConfiguration()
                #if os(macOS)
                model.shortcuts.refresh()
                model.shortcutEnabled = model.shortcuts.enabled
                model.shortcutKey = model.shortcuts.binding.key
                model.automaticCheck = AppUpdatePreferences.options(Bundle.main.bundleIdentifier ?? "").automaticCheck
                #endif
            }
            .onReceive(model.lifecycle.$updateStatus) { status in
                guard !model.lifecycle.checking, model.lifecycle.release != nil || status.hasPrefix("检查未完成：") else { return }
                #if os(macOS)
                let result: Result<AppRelease, Error>
                if let release = model.lifecycle.release { result = .success(release) }
                else { result = .failure(AppUpdateError(status)) }
                AppUpdatePreferences.record(Bundle.main.bundleIdentifier ?? "", result, source: .privateCloud(channel: MobileProductLifecycle.macChannel))
                #endif
            }
    }
}

extension View {
    func fitcoachSettings(channel: MobileUpdateChannel, configuration: AppConfiguration?, placement: AppLifecycleMobilePlacement) -> some View {
        modifier(FitCoachSettingsModifier(model: FitCoachSettingsModel(configuration: configuration, channel: channel), placement: placement))
    }
}

#if os(macOS)
struct FitCoachSettingsCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("配置与更新…") { NotificationCenter.default.post(name: Notification.Name("FitCoachOpenSettings"), object: nil) }
                .keyboardShortcut(",", modifiers: .command)
        }
    }
}
#endif
