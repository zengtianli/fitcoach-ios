import SwiftUI

/// 修改密码。POST /coach/api/password（old_password / new_password，Form 编码）
/// 判据全在后端 tenancy.change_password —— 这里不做任何强度校验，
/// 客户端多一份规则就会和后端漂移（后端放行的被本地拦下，或反过来）。
struct PasswordView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss

    @State private var old = ""
    @State private var new1 = ""
    @State private var new2 = ""
    @State private var busy = false
    @State private var err: String?
    @State private var done = false

    /// 只校验「两次输入是否一致」—— 这不是密码规则，是输入法层面的防手滑，
    /// 后端根本收不到第二个字段，没法替我们判。
    private var mismatch: Bool { !new2.isEmpty && new1 != new2 }

    var body: some View {
        Form {
            if let e = err { Section { ErrorBar(text: e) } }
            if done {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.ok)
                        Text("密码已修改").font(.subheadline.weight(.semibold))
                    }
                }
            }

            Section("当前密码") {
                SecureField("现在的密码", text: $old).textContentType(.password)
            }

            Section {
                SecureField("新密码", text: $new1).textContentType(.newPassword)
                SecureField("再输一次", text: $new2).textContentType(.newPassword)
                if mismatch {
                    Text("两次输入不一致").font(.caption).foregroundStyle(Theme.danger)
                }
            } header: {
                Text("新密码")
            } footer: {
                Text("与网页端是同一个账号，改完两边都用新密码。强度要求由服务器判定。")
            }

            Section {
                Button {
                    Task { await submit() }
                } label: {
                    HStack { Spacer()
                        if busy { ProgressView() } else { Text("修改密码").bold() }
                        Spacer() }
                }
                .disabled(busy || old.isEmpty || new1.isEmpty || new1 != new2)
            } footer: {
                Text("改密码**不会**让已经发出去的学员链接失效 —— 那是另一套凭证，怀疑外泄要逐个学员重新签发。")
            }
        }
        .navigationTitle("修改密码")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func submit() async {
        busy = true; err = nil; done = false
        defer { busy = false }
        do {
            try await API(session).post("/coach/api/password", [
                "old_password": old, "new_password": new1,
            ])
            old = ""; new1 = ""; new2 = ""
            done = true
        } catch {
            // 旧密码错 / 新密码太弱都是 400，后端文案原样呈现
            err = errText(error)
        }
    }
}
