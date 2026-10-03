import Foundation

// Product allowlist and release channel; shared lifecycle code owns transfer/checking.
@MainActor
enum MobileProductLifecycle {
    static var channel: MobileUpdateChannel {
        #if os(macOS)
        return .sandboxCloud(channel: "private")
        #else
        return .appStore(id: "6806698109")
        #endif
    }
    static let configuration: AppConfiguration? = {
        let configuration = AppConfiguration(productID: "fitcoach-mobile", defaultsKeys: ["fitcoach.baseURL"])
        configuration.onChange = {
            let defaults = UserDefaults.standard
            let candidate = defaults.string(forKey: "fitcoach.baseURL") ?? Session.defaultBaseURL
            let url = URL(string: candidate)
            let accepted = url?.scheme == "https" && url?.host != nil && url?.user == nil && url?.password == nil ? candidate : Session.defaultBaseURL
            defaults.set(accepted, forKey: "fitcoach.baseURL")
            // Credentials belong to the server that issued them, never to imported configuration.
            ["fitcoach.coachCookie", "fitcoach.studentToken", "fitcoach.coachEmail"].forEach(defaults.removeObject(forKey:))
            defaults.set(false, forKey: "fitcoach.studentMode")
            NotificationCenter.default.post(name: Notification.Name("FitCoachPortableConfigurationApplied"), object: accepted)
        }
        return configuration
    }()
}
