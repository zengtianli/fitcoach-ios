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
                    Text("强度要求由服务器判定。注册即表示同意隐私政策：账号仅存邮箱、称呼与你录入的排课数据，可随时在「更多 → 注销账号」里整体删除。")
                }
                Section {
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
            pw1 = ""; pw2 = ""
            session.coachCookie = cookie      // RootView 据此切到教练端，sheet 随登录页一起消失
            dismiss()
        } catch {
            err = errText(error)               // 400 的后端文案原样呈现（邮箱已注册 / 密码太短 / 名额满）
        }
    }
}
