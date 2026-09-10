import SwiftUI

/// 注销账号：登录状态下确认删除，后端将该教练的数据整体删除。
/// App Store 5.1.1(v) 要求「能在 app 内注册就必须能在 app 内删号」—— 这一屏就是为它存在的，
/// 别把它做成「发邮件申请」或「跳网页」。
struct AccountDeleteView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss

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
                    Text("将删除账号及其全部学员、课包、课程、地点、档期、体测和变更记录。学员查看链接也会失效。")
                        .font(.footnote).foregroundStyle(Theme.ink2)
                    Text("上述范围为当前业务数据库。既有离线备份的删除需联系支持核验，不会因本次操作立即清除。")
                        .font(.footnote).foregroundStyle(Theme.ink2)
                    PrivacySupportLinks()
                }
                .padding(.vertical, 4)
            }
            Section {
                Button(role: .destructive) { confirm = true } label: {
                    HStack { Spacer()
                        if busy { ProgressView() } else { Text("永久删除账号").bold() }
                        Spacer() }
                }
                .disabled(busy)
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
            try await API(session).deleteAccount()
            if let saved = try? SavedLogin.load(server: session.baseURL), saved.email == session.coachEmail {
                try? SavedLogin.remove(server: session.baseURL)
            }
            session.studentToken = nil
            session.signOut()                  // 本地 cookie 值在 UserDefaults，服务端清不到，必须自己清
        } catch {
            err = errText(error)
        }
    }
}
