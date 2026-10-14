import Foundation

// Product allowlist and release channel; shared lifecycle code owns transfer/checking.
@MainActor
enum MobileProductLifecycle {
    static var channel: MobileUpdateChannel {
        #if os(macOS)
        return .sandboxCloud(channel: macChannel)
        #else
        return .appStore(id: "6806698109")
        #endif
    }
    /// Mac 版读更新的私有渠道；面板与 `fitcoach update`（AppCommand）用同一个。
    static let macChannel = "private"
    /// 本机登录态属于哪台服务器。运行中的窗口跟随 `fitcoach config` 命令时，只拨同步开关也会走到 onChange：
    /// 服务器没变就不该把人登出。创建下面的配置对象时读一次，窗口里改服务器地址时由 App.swift 跟上。
    static var appliedBase = Session.defaultBaseURL
    static let configuration: AppConfiguration? = {
        let configuration = makeConfiguration()
        // 在任何导入或同步之前读好。不能靠静态属性的初值去读偏好：静态属性第一次用到才取值，
        // 那时导入已经写完，读到的是新地址（`_ = appliedBase` 也不触发取值，2026-10-07 实测）。
        appliedBase = UserDefaults.standard.string(forKey: "fitcoach.baseURL") ?? Session.defaultBaseURL
        configuration.onChange = { applyPortableConfiguration() }
        return configuration
    }()

    static func makeConfiguration(defaults: UserDefaults = .standard) -> AppConfiguration {
        // The KVS envelope is shared by Mac and iOS. Touch clients retain Mac-only fields so an
        // enabled shortcut on the Mac never makes the phone reject the entire configuration.
        let keys = ["fitcoach.baseURL", "appUpdateOptions", "appShortcuts.refresh.enabled", "appShortcuts.refresh.binding"]
        return AppConfiguration(productID: "fitcoach-mobile", defaultsKeys: keys, defaults: defaults, validateDefault: { key, value in
            if key == "fitcoach.baseURL" {
                guard let text = value as? String, let url = URL(string: text), url.scheme == "https",
                      url.host != nil, url.user == nil, url.password == nil else { throw AppUpdateError("配置服务地址必须为不含凭据的 HTTPS 地址；原配置已保留。") }
            }
            if key == "appUpdateOptions" {
                try AppUpdatePreferences.validate(JSONDecoder().decode(AppUpdateOptions.self, from: JSONSerialization.data(withJSONObject: value)))
            }
            #if os(macOS)
            if key == AppShortcuts.enabledKey, !(value is NSNumber) { throw AppUpdateError("快捷键开关必须为布尔值。") }
            if key == AppShortcuts.bindingKey {
                guard let record = value as? [String: Any], let key = record["key"] as? String,
                      let flags = record["modifiers"] as? NSNumber else { throw AppUpdateError("快捷键配置无效。") }
                try AppShortcuts.validate(.init(key: key, modifiers: .init(rawValue: flags.uintValue)))
            }
            #endif
        })
    }

    /// 导入或同步把配置写进本机之后：服务器地址只认 https，换了服务器就清掉属于原服务器的登录态。
    /// 窗口进程里由 `configuration.onChange` 调；`fitcoach config` 的命令进程（AppCommand）在退出前自己同步调一次——
    /// App 没开着时没有别人替它做，而 onChange 是异步投递的，短命的命令进程等不到。
    static func applyPortableConfiguration() {
        let defaults = UserDefaults.standard
        let candidate = defaults.string(forKey: "fitcoach.baseURL") ?? Session.defaultBaseURL
        let url = URL(string: candidate)
        let accepted = url?.scheme == "https" && url?.host != nil && url?.user == nil && url?.password == nil ? candidate : Session.defaultBaseURL
        defaults.set(accepted, forKey: "fitcoach.baseURL")
        guard accepted != appliedBase else { return }
        appliedBase = accepted
        // Credentials belong to the server that issued them, never to imported configuration.
        ["fitcoach.coachCookie", "fitcoach.studentToken", "fitcoach.coachEmail"].forEach(defaults.removeObject(forKey:))
        defaults.set(false, forKey: "fitcoach.studentMode")
        NotificationCenter.default.post(name: Notification.Name("FitCoachPortableConfigurationApplied"), object: accepted)
    }
}
