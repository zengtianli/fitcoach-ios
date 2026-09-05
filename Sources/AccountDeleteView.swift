import SwiftUI

/// 注销账号：POST /coach/api/account/delete（password）。
/// 后端验密码后把这位教练的学员 / 课包 / 课程 / 地点 / 档期 / 体测 / 变更记录连同账号整体真删。
/// App Store 5.1.1(v) 要求「能在 app 内注册就必须能在 app 内删号」—— 这一屏就是为它存在的，
/// 别把它做成「发邮件申请」或「跳网页」。
struct AccountDeleteView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var confirm = false
    @State private var busy = false
    @State private var err: String?

    var body: some View {
        Form {
            if let e = err { Section { ErrorBar(text: e) } }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("这个操作不可恢复", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.danger)
                    Text("将删除：账号本身、全部学员与课包、已排与已完成的课程、地点、档期、体测记录和变更记录。已发给学员的查看链接同时失效。服务器不保留副本。")
                        .font(.footnote).foregroundStyle(Theme.ink2)
                }
                .padding(.vertical, 4)
            }
            Section {
                SecureField("输入当前密码确认", text: $password).textContentType(.password)
            } footer: {
                Text("只凭登录状态不允许删号 —— 手机借出去一次不该等于账号被清空。")
            }
            Section {
                Button(role: .destructive) { confirm = true } label: {
                    HStack { Spacer()
                        if busy { ProgressView() } else { Text("永久删除账号").bold() }
                        Spacer() }
                }
                .disabled(busy || password.isEmpty)
            }
        }
        .navigationTitle("注销账号")
        .navigationBarTitleDisplayMode(.inline)
        .alert("确定永久删除？", isPresented: $confirm) {
            Button("删除", role: .destructive) { Task { await submit() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后邮箱可以重新注册，但数据不会回来。")
        }
    }

    private func submit() async {
        busy = true; err = nil
        defer { busy = false }
        do {
            try await API(session).deleteAccount(password: password)
            password = ""
            session.signOut()                  // 本地 cookie 值在 UserDefaults，服务端清不到，必须自己清
        } catch {
            err = errText(error)               // 密码错 → 400，后端文案原样
        }
    }
}
