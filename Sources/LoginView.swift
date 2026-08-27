import SwiftUI

struct LoginView: View {
    @EnvironmentObject var session: Session
    @State private var mode = 0            // 0 = 教练  1 = 学员
    @State private var email = ""
    @State private var password = ""
    @State private var link = ""
    @State private var busy = false
    @State private var err: String?
    @State private var showServer = false

    var body: some View {
        NavigationStack {
            Form {
                // 品牌头：登录页是唯一一屏没有数据可显示的地方，
                // 给个图标+一句话，比一张空表单像个产品
                Section {
                    VStack(spacing: 9) {
                        ZStack {
                            Circle().fill(Theme.accentSoft).frame(width: 68, height: 68)
                            Image(systemName: "figure.strengthtraining.traditional")
                                .font(.system(size: 30, weight: .medium))
                                .foregroundStyle(Theme.accent)
                        }
                        Text("私教课时").font(.title3.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        Text("课包余额 · 排课 · 成长记录")
                            .font(.caption).foregroundStyle(Theme.ink3)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .listRowBackground(Color.clear)
                }

                Picker("", selection: $mode) {
                    Text("教练登录").tag(0)
                    Text("学员查看").tag(1)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                if let e = err {
                    Section { ErrorBar(text: e).listRowBackground(Color.clear) }
                }

                if mode == 0 {
                    Section {
                        TextField("邮箱", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("密码", text: $password)
                            .textContentType(.password)
                    } footer: {
                        Text("与网页端 \(session.baseURL) 同一个账号。")
                    }
                    Section {
                        Button {
                            Task { await doLogin() }
                        } label: {
                            HStack { Spacer()
                                if busy { ProgressView() } else { Text("登录").bold() }
                                Spacer() }
                        }
                        .disabled(busy || email.isEmpty || password.isEmpty)
                    }
                } else {
                    Section {
                        TextField("粘贴教练发来的链接或口令", text: $link, axis: .vertical)
                            .lineLimit(1...3)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } footer: {
                        Text("形如 \(session.baseURL)/s/xxxxx。链接即凭证，只能查看自己的课时与预约，看不到价格与备注。")
                    }
                    Section {
                        Button {
                            Task { await doStudent() }
                        } label: {
                            HStack { Spacer()
                                if busy { ProgressView() } else { Text("查看我的课时").bold() }
                                Spacer() }
                        }
                        .disabled(busy || link.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Section {
                    Button("服务器：\(session.baseURL)") { showServer = true }
                        .font(.footnote)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showServer) { ServerSheet() }
        }
    }

    private func doLogin() async {
        busy = true; err = nil
        defer { busy = false }
        do {
            let cookie = try await API(session).login(
                email: email.trimmingCharacters(in: .whitespaces), password: password)
            password = ""
            session.coachCookie = cookie
        } catch {
            err = errText(error)
        }
    }

    /// 学员端：先拿 token 真打一次 /s/api/view，**验通过才存**。
    /// 存了再说「查不到」会让人以为是自己网络问题；这里当场验，错就当场说。
    private func doStudent() async {
        busy = true; err = nil
        defer { busy = false }
        let token = Session.extractToken(link)
        guard !token.isEmpty else { err = "没认出链接里的口令"; return }
        do {
            let _: StudentView = try await API(session, studentToken: token)
                .get("/s/api/view", student: true)
            session.studentToken = token
        } catch APIError.gone {
            err = "这条链接无效或已被教练吊销"
        } catch {
            err = errText(error)
        }
    }
}
