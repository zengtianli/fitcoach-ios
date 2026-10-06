import SwiftUI

/// 挑战和授权仅存内存；失败保留输入，未知发送结果保留 request_id，重发由用户明确触发。
@MainActor
final class PhoneChallenge: ObservableObject {
    @Published var phone = ""
    @Published var code = ""
    @Published var challenge: String?
    @Published var grant: String?
    @Published var deadline = Date.distantPast
    @Published var hints = API.SMSHints()
    @Published var busy = false
    @Published var error: String?
    private var requestID = UUID().uuidString

    func invalidate() { challenge = nil; grant = nil; code = ""; deadline = .distantPast; requestID = UUID().uuidString }
    func send(_ api: API, purpose: String, password: String = "", identity: String = "") async {
        guard !busy, Date() >= deadline else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let r = try await api.phoneSend(purpose: purpose, phone: phone.trimmingCharacters(in: .whitespacesAndNewlines),
                                            requestID: requestID, password: password, identityGrant: identity)
            guard let id = r.challenge_id, !id.isEmpty else { throw APIError.decode("短信挑战响应异常") }
            challenge = id; grant = nil; code = ""; hints = r.hints
            deadline = Date().addingTimeInterval(Double(hints.resend))
            requestID = UUID().uuidString
        } catch { self.error = errText(error) }
    }
    func verify(_ api: API, authenticated: Bool = false) async throws -> String {
        if let grant { return grant }
        guard let challenge else { throw APIError.rejected(T("account.phone.send_first", "请先获取验证码")) }
        let value = try await api.phoneVerify(challenge: challenge, code: code, authenticated: authenticated)
        grant = value
        return value
    }
}

private struct PhoneCodeSection: View {
    @EnvironmentObject var session: Session
    @ObservedObject var flow: PhoneChallenge
    let purpose: String
    var title = "手机号"
    var implicitPhone = false
    var password = ""
    var identity = ""
    var disabled = false

    var body: some View {
        Section {
            if !implicitPhone {
                TextField("中国大陆手机号（+86）", text: $flow.phone)
                    .keyboardType(.phonePad).textContentType(.telephoneNumber)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .disabled(flow.busy || disabled)
                    .onChange(of: flow.phone) { _, _ in flow.invalidate() }
            }
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let remaining = max(0, Int(ceil(flow.deadline.timeIntervalSince(timeline.date))))
                Button(remaining > 0 ? "\(remaining) 秒后可重发" : "获取验证码") {
                    Task { await flow.send(API(session), purpose: purpose, password: password, identity: identity) }
                }.disabled(disabled || flow.busy || remaining > 0 || (!implicitPhone && flow.phone.isEmpty))
            }
            if flow.challenge != nil {
                TextField("短信验证码", text: $flow.code)
                    .keyboardType(.numberPad).textContentType(.oneTimeCode)
                    .disabled(flow.busy || disabled)
                    .onChange(of: flow.code) { _, _ in flow.grant = nil }
            }
            if let error = flow.error { ErrorBar(text: error) }
        } header: { Text(title) } footer: {
            Text(T("account.phone.delivery_help", "仅支持中国大陆 +86；验证码有效 {seconds} 秒。请查收短信{signature}，没有收到时稍后手动重试。", [
                "seconds": "\(flow.hints.ttl)",
                "signature": flow.hints.sign_name.map { "【\($0)】" } ?? "（签名由服务端返回）"
            ]))
        }
    }
}

private struct RecoveryKeySection: View {
    let key: String
    @Binding var saved: Bool
    let continueAction: () -> Void
    var body: some View {
        Section {
            Text(key).font(.body.monospaced()).textSelection(.enabled)
            Toggle("我已保存到密码管理器或安全位置", isOn: $saved)
            Button("完成并继续", action: continueAction).disabled(!saved)
        } header: { Text("保存账号恢复密钥") } footer: {
            Text(T("account.phone.recovery_key_help", "恢复密钥只显示这一次。换设备、号码停用或风险验证时可用于证明账号归属；请妥善保存，不要发送给他人。"))
        }
    }
}

struct PhoneAccountView: View {
    enum Mode: String, Identifiable { case login, register, recover; var id: String { rawValue } }
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    @StateObject private var flow = PhoneChallenge()
    @State private var password = ""
    @State private var repeated = ""
    @State private var recoveryKey = ""
    @State private var recoveryPassword = ""
    @State private var name = ""
    @State private var agreed = false
    @State private var saved = false
    @State private var busy = false
    @State private var error: String?
    @State private var result: API.PhoneResult?
    @State private var message: String?
    private var title: String { mode == .login ? "短信登录" : mode == .register ? "手机注册" : "手机号找回密码" }

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { ErrorBar(text: error) } }
                if let key = result?.recovery_key {
                    RecoveryKeySection(key: key, saved: $saved) { finish() }
                } else if let message {
                    Section { Text(message); Button("返回登录") { session.signOut(); dismiss() } }
                } else {
                    PhoneCodeSection(flow: flow, purpose: mode.rawValue, disabled: busy)
                    if mode == .register {
                        Section("资料") { TextField("怎么称呼你（可选）", text: $name).textContentType(.name) }
                    }
                    Section {
                        SecureField(mode == .login ? "原密码（风险验证时需要）" : "新密码", text: $password)
                            .textContentType(mode == .login ? .password : .newPassword)
                        if mode != .login { SecureField("再输一次", text: $repeated).textContentType(.newPassword) }
                    } header: { Text(mode == .recover ? "新密码" : "密码（可选）") } footer: {
                        Text(T("account.phone.password_help", "手机注册可稍后设置密码；强度由服务器判定。风险登录需原密码或独立恢复密钥。"))
                    }
                    if mode != .register {
                        Section {
                            SecureField(mode == .recover ? "账号恢复密钥" : "账号恢复密钥（风险验证时需要）", text: $recoveryKey).autocorrectionDisabled()
                            if mode == .recover { SecureField("原登录密码（可替代恢复密钥）", text: $recoveryPassword).textContentType(.password) }
                        } header: { Text("独立恢复方式") } footer: {
                            Text(mode == .recover
                                 ? T("account.phone.recovery_ownership_help", "找回密码始终需要短信验证码加独立恢复密钥或原登录密码。未保存恢复密钥且忘记原密码，请联系支持。核验后切换网络，请在当前网络重新获取验证码。")
                                 : T("account.phone.ownership_help", "短信证明当前持有号码；久未使用或网络变化时，还需原密码或注册时保存的恢复密钥。旧号码不可用请联系支持。核验后切换网络，请在当前网络重新获取验证码。"))
                        }
                    }
                    if mode == .register {
                        Section {
                            Toggle("我同意隐私政策并使用手机号认证", isOn: $agreed)
                            PrivacySupportLinks()
                        }
                    }
                    Section {
                        Button(mode == .recover ? "重置密码" : title) { Task { await submit() } }
                            .disabled(busy || flow.busy || flow.challenge == nil || (flow.code.isEmpty && flow.grant == nil)
                                      || (mode != .login && password != repeated) || (mode == .recover && password.isEmpty)
                                      || (mode == .recover && recoveryKey.isEmpty && recoveryPassword.isEmpty)
                                      || (mode == .register && !agreed))
                        if busy { ProgressView() }
                    }
                }
            }
            .disabled(busy)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { if result?.recovery_key == nil { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy || flow.busy) } } }
            .interactiveDismissDisabled(busy || flow.busy || result?.recovery_key != nil)
            .task { if let r = try? await API(session).accountHints() { flow.hints = r.hints } }
        }
    }
    private func submit() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let api = API(session)
            let token = try await flow.verify(api)
            var fields: [String: Any] = ["verification_token": token]
            if mode == .register { fields["display_name"] = name; fields["password"] = password; fields["agreed"] = agreed }
            if mode == .login { fields["password"] = password; fields["recovery_key"] = recoveryKey }
            if mode == .recover { fields["new_password"] = password; fields["recovery_key"] = recoveryKey; fields["password"] = recoveryPassword }
            let r = try await api.accountJSON("/api/phone_\(mode.rawValue)", fields)
            if mode == .recover {
                try? SavedLogin.remove(server: session.baseURL)
                session.coachCookie = nil; session.coachEmail = nil
                password = ""; repeated = ""; recoveryKey = ""; recoveryPassword = ""; flow.invalidate()
                message = r.message ?? T("account.phone.recovered", "密码已重置，请重新登录。原有学员与课程数据保留。")
            } else {
                guard r.cookie != nil else { throw APIError.decode("登录响应缺少会话") }
                result = r
                if r.recovery_key == nil { finish() }
            }
        } catch { self.error = errText(error) }
    }
    private func finish() {
        guard let r = result, let cookie = r.cookie else { return }
        session.coachEmail = r.email?.isEmpty == false ? r.email : nil
        session.coachCookie = cookie; session.studentMode = false; session.showingLogin = false
        password = ""; recoveryKey = ""; flow.invalidate(); result = nil
        dismiss()
    }
}

/// 当前账号绑定、双号换绑和手机号新户设置密码；始终消费原 coach_id 下的账号授权。
struct PhoneSecurityView: View {
    @EnvironmentObject var session: Session
    @StateObject private var phone = PhoneChallenge()
    @StateObject private var old = PhoneChallenge()
    @StateObject private var identity = PhoneChallenge()
    @State private var account: API.PhoneResult?
    @State private var password = ""
    @State private var newPassword = ""
    @State private var repeated = ""
    @State private var saved = false
    @State private var busy = false
    @State private var error: String?
    @State private var result: API.PhoneResult?
    @State private var message: String?
    private var hasPhone: Bool { account?.phone_verified == true }
    private var needsIdentity: Bool { account?.has_password == false && hasPhone }

    var body: some View {
        Form {
            if let error { Section { ErrorBar(text: error); Button("重新读取账号") { Task { await load() } } } }
            if let key = result?.recovery_key {
                RecoveryKeySection(key: key, saved: $saved) { Task { await finishBinding() } }
            } else if let account {
                Section("当前账号") {
                    Text(account.email?.isEmpty == false ? account.email! : "手机账号")
                    Text(account.phone_hint ?? "未绑定手机号")
                    if let message { Text(message).foregroundStyle(Theme.ok) }
                }
                if account.has_password == true {
                    Section("确认当前身份") { SecureField("当前账号密码", text: $password).textContentType(.password) }
                } else if needsIdentity {
                    PhoneCodeSection(flow: identity, purpose: "identity", title: "验证当前绑定号码", implicitPhone: true, disabled: busy)
                    Button("确认当前号码") { Task { await confirmIdentity() } }
                        .disabled(busy || identity.challenge == nil || identity.code.isEmpty)
                }
                if hasPhone {
                    PhoneCodeSection(flow: old, purpose: "change_old", title: "换绑：验证旧号码", implicitPhone: true,
                                     password: password, identity: identity.grant ?? "", disabled: busy)
                    Button("确认旧号码") { Task { await confirmOld() } }
                        .disabled(busy || old.challenge == nil || old.code.isEmpty)
                }
                PhoneCodeSection(flow: phone, purpose: hasPhone ? "change_new" : "bind", title: hasPhone ? "换绑：新手机号" : "绑定手机号",
                                 password: password, identity: old.grant ?? identity.grant ?? "", disabled: busy)
                Section {
                    Button(hasPhone ? "确认换绑" : "确认绑定") { Task { await bind() } }
                        .disabled(busy || phone.busy || old.busy || phone.challenge == nil || phone.code.isEmpty
                                  || (hasPhone && (old.challenge == nil || old.code.isEmpty)))
                } footer: {
                    Text(T("account.phone.binding_help", "绑定与换绑保留原有学员、课程和课包。换绑需旧、新号码都验证；旧号码不可用请联系支持。"))
                }
                if account.has_password == false && hasPhone {
                    Section("设置登录密码") {
                        SecureField("新密码", text: $newPassword).textContentType(.newPassword)
                        SecureField("再输一次", text: $repeated).textContentType(.newPassword)
                        Button("设置密码") { Task { await setPassword() } }
                            .disabled(busy || identity.grant == nil || newPassword.isEmpty || newPassword != repeated)
                    }
                }
            } else if error == nil { Section { ProgressView() } }
        }
        .disabled(busy)
        .navigationTitle("手机号与账号安全").navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(busy || result?.recovery_key != nil)
        .navigationBarBackButtonHidden(busy || result?.recovery_key != nil)
        .task { await load() }
    }
    private func load() async {
        do { account = try await API(session).accountInfo(); phone.hints = account!.hints; old.hints = account!.hints; identity.hints = account!.hints; error = nil }
        catch { self.error = errText(error) }
    }
    private func confirmIdentity() async {
        busy = true; error = nil
        defer { busy = false }
        do { _ = try await identity.verify(API(session), authenticated: true); message = T("account.phone.identity_verified", "当前号码已验证") }
        catch { self.error = errText(error) }
    }
    private func bind() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let api = API(session)
            let token = try await phone.verify(api, authenticated: true)
            var fields: [String: Any] = ["phone": phone.phone, "verification_token": token, "password": password, "identity_grant": identity.grant ?? ""]
            if hasPhone {
                let oldGrant = try await old.verify(api, authenticated: true)
                fields["old_verification_token"] = oldGrant
                if account?.has_password == false { fields["identity_grant"] = oldGrant }
            }
            let r = try await api.accountJSON("/coach/api/phone_bind", fields, authenticated: true)
            guard r.cookie != nil else { throw APIError.decode("绑定响应缺少会话") }
            result = r
            if r.recovery_key == nil { await finishBinding() }
        } catch { self.error = errText(error) }
    }
    private func confirmOld() async {
        busy = true; error = nil
        defer { busy = false }
        do { _ = try await old.verify(API(session), authenticated: true); message = T("account.phone.old_verified", "旧号码已验证，可以获取新号码验证码") }
        catch { self.error = errText(error) }
    }
    private func finishBinding() async {
        if let cookie = result?.cookie { session.coachCookie = cookie }
        result = nil; saved = false; phone.invalidate(); old.invalidate(); identity.invalidate(); password = ""
        message = T("account.phone.bound", "手机号已更新，原有业务数据保留；其他设备需要重新登录。")
        await load()
    }
    private func setPassword() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let r = try await API(session).accountJSON("/coach/api/password_set", ["new_password": newPassword, "identity_grant": identity.grant ?? ""], authenticated: true)
            if let cookie = r.cookie { session.coachCookie = cookie }
            newPassword = ""; repeated = ""; identity.invalidate()
            message = T("account.phone.password_set", "密码已设置，其他设备需要重新登录。")
            await load()
        } catch { self.error = errText(error) }
    }
}
