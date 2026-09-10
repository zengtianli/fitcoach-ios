import SwiftUI

/// 用邮箱注册教练账号。POST /api/register → cookie 值 → 直接进入教练端。
/// 规则（邮箱格式 / 密码强度 / 名额上限 / 邮箱已注册）全在后端 tenancy.register，
/// 这里只做「两次密码是否一致」这种后端收不到第二个字段、没法替我们判的检查。
struct RegisterView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var name = ""
    @State private var pw1 = ""
    @State private var pw2 = ""
    @State private var busy = false
    @State private var err: String?
    @State private var remember = true

    private var mismatch: Bool { !pw2.isEmpty && pw1 != pw2 }

    var body: some View {
        NavigationStack {
            Form {
                if let e = err { Section { ErrorBar(text: e) } }
                Section {
                    TextField("邮箱", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("怎么称呼你（可选）", text: $name)
                        .textContentType(.name)
                } header: {
                    Text("账号")
                } footer: {
                    Text("邮箱就是登录名，网页端 \(session.baseURL) 用同一个账号。")
                }
                Section {
                    SecureField("密码", text: $pw1).textContentType(.newPassword)
                    SecureField("再输一次", text: $pw2).textContentType(.newPassword)
                    if mismatch {
                        Text("两次输入不一致").font(.caption).foregroundStyle(Theme.danger)
                    }
                } header: {
                    Text("密码")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("密码强度由服务器判定。注册即表示同意隐私政策：服务保存账号信息及你录入的学员、课包、课程、地点、体测和变更记录，可在「更多 → 注销账号」删除当前业务数据。既有离线备份的删除需联系支持核验。")
                        PrivacySupportLinks()
                    }
                }
                Section {
                    Toggle("记住账号和密码", isOn: $remember)
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack { Spacer()
                            if busy { ProgressView() } else { Text("注册并登录").bold() }
                            Spacer() }
                    }
                    .disabled(busy || email.isEmpty || pw1.isEmpty || pw1 != pw2)
                }
            }
            .navigationTitle("邮箱注册")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
    }

    private func submit() async {
        busy = true; err = nil
        defer { busy = false }
        do {
            let cookie = try await API(session).register(
                email: email.trimmingCharacters(in: .whitespaces), password: pw1,
                displayName: name.trimmingCharacters(in: .whitespaces))
            if remember {
                // 账号已创建成功；本机记忆失败不应让用户重复注册。
                try? SavedLogin.save(.init(email: email.trimmingCharacters(in: .whitespaces), password: pw1), server: session.baseURL)
            }
            pw1 = ""; pw2 = ""
            session.studentMode = false
            session.coachEmail = email.trimmingCharacters(in: .whitespaces)
            session.coachCookie = cookie      // RootView 据此切到教练端，sheet 随登录页一起消失
            session.showingLogin = false
            dismiss()
        } catch {
            err = errText(error)               // 400 的后端文案原样呈现（邮箱已注册 / 密码太短 / 名额满）
        }
    }
}
