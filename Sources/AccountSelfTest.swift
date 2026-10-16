import SwiftUI

#if DEBUG
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Test-only access to the mounted views' real State and button actions. No event synthesis.
@MainActor final class AccountPageProbe {
    var fill: (([String: String]) -> Void)?
    var action: ((String) async -> Void)?
    var state: (() -> [String: String])?
    func connect(fill: @escaping ([String: String]) -> Void,
                 action: @escaping (String) async -> Void, state: @escaping () -> [String: String]) {
        self.fill = fill; self.action = action; self.state = state
    }
}
private struct AccountProbeKey: EnvironmentKey { static let defaultValue: AccountPageProbe? = nil }
extension EnvironmentValues {
    var accountPageProbe: AccountPageProbe? {
        get { self[AccountProbeKey.self] }
        set { self[AccountProbeKey.self] = newValue }
    }
}

#if os(macOS) || os(iOS)
@MainActor final class AccountTestPresentation: ObservableObject {
    static let shared = AccountTestPresentation()
    @Published var page = AnyView(Text("账号隔离验收"))
}

/// Requires a disposable bundle identity and a loopback fixture, before any production Session is made.
@MainActor enum AccountSelfTest {
    static var requested: Bool { CommandLine.arguments.contains("--account-self-test") }
    static var base: String { CommandLine.arguments.last ?? "" }
    static var root: URL {
        #if os(macOS)
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["FITCOACH_ACCOUNT_OUT"]!)
        #else
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("account-self-test")
        #endif
    }
    static var checks: [String: Bool] = [:]
    static var window: AnyObject?
    static func launch() {
        guard Bundle.main.bundleIdentifier?.hasPrefix("test.tianli.fitcoach.account.") == true,
              URL(string: base)?.host == "127.0.0.1" else { exit(2) }
        #if os(macOS)
        guard ProcessInfo.processInfo.environment["FITCOACH_ACCOUNT_OUT"] != nil else { exit(2) }
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApp.mainMenu = NSMenu()
        let hosting = NSHostingView(rootView: AccountTestRoot())
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 840), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false; w.contentView = hosting; window = w
        Task { await run(); exit(checks.values.allSatisfy { $0 } ? 0 : 1) }
        RunLoop.main.run()
        #else
        #if targetEnvironment(simulator)
        AccountTestApp.main()
        #else
        exit(2)
        #endif
        #endif
    }
    static func check(_ key: String, _ value: Bool) throws {
        checks[key] = value
        if !value { throw NSError(domain: key, code: 1) }
    }
    static func control(_ fields: [String: Any] = [:]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: base + "/__account_fixture")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    static func mount<V: View>(_ view: V, _ session: Session, name: String) async throws -> AccountPageProbe {
        let probe = AccountPageProbe()
        AccountTestPresentation.shared.page = AnyView(view.environmentObject(session).environment(\.accountPageProbe, probe).id(UUID()))
        for _ in 0..<150 {
            if probe.action != nil { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        try check(name + ".mounted", probe.action != nil)
        // Capture before filling any secret; actual view tree, no constructed screenshots.
        #if os(macOS)
        if let w = window as? NSWindow, let view = w.contentView {
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw URLError(.cannotDecodeContentData) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name + ".png"))
            try check(name + ".offscreen", !w.isVisible && NSApp.activationPolicy() == .prohibited)
        }
        #else
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene, let window = scene.windows.first {
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { context in window.layer.render(in: context.cgContext) }
            try image.pngData()!.write(to: root.appendingPathComponent(name + ".png"))
            try check(name + ".rendered", image.size.width > 0 && image.size.height > 0)
        } else { try check(name + ".rendered", false) }
        #endif
        return probe
    }
    static func send(_ page: AccountPageProbe, _ action: String = "send") async throws {
        _ = try await control(["advance": 61])
        await page.action?(action)
        try check("send.\(checks.count)", page.state?()["error"] == "")
    }
    static func run() async {
        var failure: String?
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let session = Session(baseURL: base)
            let originalPW = "Original coach password", changedPW = "Native changed password", recoveredPW = "Native recovered password"
            let login = try await mount(LoginView(), session, name: "email-login")
            login.fill?(["email": "coach@example.com", "password": originalPW]); await login.action?("submit")
            try check("login.email", session.isCoach && login.state?()["error"] == "")
            let originalID = try await API(session).accountInfo().coach_id
            session.studentToken = "independent-student-sentinel"
            let bind = try await mount(PhoneSecurityView(), session, name: "phone-binding")
            await bind.action?("load")
            bind.fill?(["phone": "13800138000", "password": originalPW])
            try await send(bind)
            let cookie = session.coachCookie
            bind.fill?(["code": "000000"]); await bind.action?("submit")
            try check("phone_binding.wrong_code_preserves_session", session.coachCookie == cookie && bind.state?()["error"] != "")
            bind.fill?(["code": "246810"]); await bind.action?("submit")
            let key = bind.state?()["key"] ?? ""
            try check("phone_binding.recovery_key_gate", !key.isEmpty && session.coachCookie == cookie)
            await bind.action?("continue")
            try check("phone_binding.unsaved_key_blocks_continue", session.coachCookie == cookie)
            bind.fill?(["saved": "true"])
            await bind.action?("continue")
            try check("phone_binding.rotated_cookie", session.coachCookie != cookie && bind.state?()["phone_hint"]?.hasSuffix("8000") == true)
            let swap = try await mount(PhoneSecurityView(), session, name: "phone-change")
            await swap.action?("load"); swap.fill?(["password": originalPW])
            try await send(swap, "sendOld"); swap.fill?(["oldCode": "246810"]); await swap.action?("confirmOld")
            swap.fill?(["phone": "13900139000"]); try await send(swap)
            swap.fill?(["code": "246810"]); await swap.action?("submit")
            try check("phone_change.dual_number", swap.state?()["error"] == "" && swap.state?()["phone_hint"]?.hasSuffix("9000") == true)
            let sameID = try await API(session).accountInfo().coach_id
            try check("data_preservation.coach_id", sameID == originalID)
            session.signOut()
            try check("logout.local_and_student_boundary", !session.isCoach && session.showingLogin && session.studentToken == "independent-student-sentinel")
            let sms = try await mount(PhoneAccountView(mode: .login), session, name: "sms-login")
            sms.fill?(["phone": "13900139000"]); try await send(sms)
            sms.fill?(["code": "246810"]); await sms.action?("submit")
            try check("phone_login.normal", session.isCoach && sms.state?()["error"] == "")
            _ = try await control(["risk": true])
            session.signOut()
            let risk = try await mount(PhoneAccountView(mode: .login), session, name: "risk-login")
            risk.fill?(["phone": "13900139000"]); try await send(risk)
            risk.fill?(["code": "246810"]); await risk.action?("submit")
            try check("abuse_protection.independent_proof", !session.isCoach && risk.state?()["error"] != "" && risk.state?()["grant"]?.isEmpty == false)
            risk.fill?(["ownership": key]); await risk.action?("submit")
            try check("phone_login.risk_recovery", session.isCoach && risk.state?()["error"] == "")
            _ = try await control(["advance": 901])
            let recover = try await mount(PhoneAccountView(mode: .recover), session, name: "password-recovery")
            recover.fill?(["phone": "13900139000", "password": recoveredPW, "ownership": key])
            try await send(recover); recover.fill?(["code": "246810"]); await recover.action?("submit")
            try check("password_recovery.native", !session.isCoach && recover.state?()["message"]?.isEmpty == false && recover.state?()["password"] == "")
            let relogin = try await mount(LoginView(), session, name: "recovered-login")
            relogin.fill?(["email": "coach@example.com", "password": recoveredPW]); await relogin.action?("submit")
            try check("password_recovery.login", session.isCoach)
            let password = try await mount(PasswordView(), session, name: "password-change")
            password.fill?(["oldPassword": "incorrect", "password": changedPW]); await password.action?("submit")
            try check("password_change.error_preserves_session", password.state?()["error"] != "" && session.isCoach)
            password.fill?(["oldPassword": recoveredPW]); await password.action?("submit")
            try check("password_change.native", password.state?()["done"] == "true" && password.state?()["password"] == "" && session.isCoach)
            let preserved = try await control()
            try check("data_preservation.business_and_other_tenant", preserved["student_intact"] as? Bool == true && preserved["other_intact"] as? Bool == true)
            session.signOut()
            let registration = try await mount(PhoneAccountView(mode: .register), session, name: "registration")
            registration.fill?(["phone": "13700137000", "agreed": "true"]); try await send(registration)
            registration.fill?(["code": "246810"]); await registration.action?("submit")
            try check("registration.save_key_before_entry", !session.isCoach && registration.state?()["key"]?.isEmpty == false)
            registration.fill?(["saved": "true"]); await registration.action?("continue")
            try check("registration.native", session.isCoach)
            let security = try await mount(PhoneSecurityView(), session, name: "phone-only-password")
            await security.action?("load"); try await send(security, "sendIdentity")
            security.fill?(["identityCode": "246810"]); await security.action?("confirmIdentity")
            security.fill?(["newPassword": "Phone-only native password"]); await security.action?("setPassword")
            try check("phone_verification.set_password", security.state?()["error"] == "" && security.state?()["has_password"] == "true")
            let deletion = try await mount(AccountDeleteView(), session, name: "account-deletion")
            await deletion.action?("submit")
            let deleted = try await control()
            try check("account_deletion.native", !session.isCoach && session.studentToken == nil && deleted["phone_account_deleted"] as? Bool == true && deletion.state?()["error"] == "")
            let unknown = try await mount(PhoneAccountView(mode: .register), session, name: "send-recovery")
            unknown.fill?(["phone": "13500135000"])
            _ = try await control(["fail": true, "advance": 901])
            await unknown.action?("send")
            let first = try await control()
            await unknown.action?("send")
            let second = try await control()
            try check("abuse_protection.unknown_send_not_resent", (first["sends"] as? Int) == (second["sends"] as? Int) && unknown.state?()["error"]?.isEmpty == false)
        } catch { failure = (error as NSError).domain; checks["suite.completed"] = false }
        let result: [String: Any] = ["checks": checks, "error": failure as Any? ?? NSNull(),
            "sms_transport": "fake", "real_sms_sent": 0,
            "method": "mounted real SwiftUI pages; direct production button actions; disposable localhost backend and identity"]
        try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]).write(to: root.appendingPathComponent("native.json"), options: .atomic)
        #if os(iOS)
        LaneSignal.ready("account-self-test-finished")
        #endif
    }
}
private struct AccountTestRoot: View {
    @ObservedObject var presentation = AccountTestPresentation.shared
    var body: some View { presentation.page.preferredColorScheme(.light).background(Color.white) }
}
#if os(iOS)
private struct AccountTestApp: App {
    var body: some Scene { WindowGroup { AccountTestRoot().task { await AccountSelfTest.run() } } }
}
#endif
#else
// Release builds contain no test route, test UI or fixture controls.
enum AccountSelfTest { static var requested: Bool { false } }
#endif
#else
enum AccountSelfTest { static var requested: Bool { false } }
#endif
