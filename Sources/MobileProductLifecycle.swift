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
    #if os(macOS)
    /// 本机登录态属于哪台服务器。运行中的窗口跟随 `fitcoach config` 命令时，只拨同步开关也会走到 onChange：
    /// 服务器没变就不该把人登出。创建下面的配置对象时读一次，窗口里改服务器地址时由 App.swift 跟上。
    static var appliedBase = Session.defaultBaseURL
    #endif
    static let configuration: AppConfiguration? = {
        let configuration = AppConfiguration(productID: "fitcoach-mobile", defaultsKeys: ["fitcoach.baseURL"])
        #if os(macOS)
        // 在任何导入或同步之前读好。不能靠静态属性的初值去读偏好：静态属性第一次用到才取值，
        // 那时导入已经写完，读到的是新地址（`_ = appliedBase` 也不触发取值，2026-10-07 实测）。
        appliedBase = UserDefaults.standard.string(forKey: "fitcoach.baseURL") ?? Session.defaultBaseURL
        #endif
        configuration.onChange = { applyPortableConfiguration() }
        return configuration
    }()

    /// 导入或同步把配置写进本机之后：服务器地址只认 https，换了服务器就清掉属于原服务器的登录态。
    /// 窗口进程里由 `configuration.onChange` 调；`fitcoach config` 的命令进程（AppCommand）在退出前自己同步调一次——
    /// App 没开着时没有别人替它做，而 onChange 是异步投递的，短命的命令进程等不到。
    static func applyPortableConfiguration() {
        let defaults = UserDefaults.standard
        let candidate = defaults.string(forKey: "fitcoach.baseURL") ?? Session.defaultBaseURL
        let url = URL(string: candidate)
        let accepted = url?.scheme == "https" && url?.host != nil && url?.user == nil && url?.password == nil ? candidate : Session.defaultBaseURL
        defaults.set(accepted, forKey: "fitcoach.baseURL")
        #if os(macOS)
        guard accepted != appliedBase else { return }
        appliedBase = accepted
        #endif
        // Credentials belong to the server that issued them, never to imported configuration.
        ["fitcoach.coachCookie", "fitcoach.studentToken", "fitcoach.coachEmail"].forEach(defaults.removeObject(forKey:))
        defaults.set(false, forKey: "fitcoach.studentMode")
        NotificationCenter.default.post(name: Notification.Name("FitCoachPortableConfigurationApplied"), object: accepted)
    }
}
