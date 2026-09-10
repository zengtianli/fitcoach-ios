import SwiftUI

struct LoginView: View {
    @EnvironmentObject var session: Session
    @State private var mode = 0
    @State private var email = ""
    @State private var password = ""
    @State private var remember = true
    @State private var link = ""
    @State private var busy = false
    @State private var err: String?
    @State private var showServer = false
    @State private var showRegister = false
    @FocusState private var focused: Field?
    private enum Field { case email, password, link }

    init(initialMode: Int = 0) { _mode = State(initialValue: initialMode) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 10) {
                        Image(systemName: "figure.strengthtraining.traditional")
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 64, height: 64)
                            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 20))
                        Text(AppIdentity.displayName).font(.title2.bold()).foregroundStyle(Theme.ink)
                        Text("轻松排课，记录每一次进步")
                            .font(.subheadline).foregroundStyle(Theme.ink2)
                    }.padding(.top, 12)
                    Picker("登录身份", selection: $mode) {
                        Text("教练登录").tag(0)
                        Text("学员查看").tag(1)
                    }.pickerStyle(.segmented)
                    if let err { ErrorBar(text: err) }
                    if mode == 0 { coachForm } else { studentForm }
                    Button("服务器设置") { focused = nil; showServer = true }
                        .font(.footnote).foregroundStyle(Theme.ink3)
                    PrivacySupportLinks().padding(.bottom, 12)
                }
                .frame(maxWidth: 440)
                .padding(.horizontal, 24).padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.pageBG)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showServer) { ServerSheet() }
            .sheet(isPresented: $showRegister, onDismiss: restore) { RegisterView() }
            .task { restore() }
            .onChange(of: session.baseURL) { _, _ in restore() }
            .onChange(of: mode) { _, _ in focused = nil; err = nil }
        }
    }

    private var coachForm: some View {
        VStack(spacing: 18) {
            if session.coachCookie != nil {
                VStack(spacing: 8) {
                    Text(session.coachEmail ?? "教练账号已登录")
                        .font(.subheadline).foregroundStyle(Theme.ink2)
                    Button("进入已登录的教练端") { session.returnToCoach() }
                        .buttonStyle(.bordered)
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                Text("账号").font(.subheadline.weight(.medium))
                TextField("邮箱", text: $email)
                    .textContentType(.username).keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focused, equals: .email)
                    .submitLabel(.next).onSubmit { focused = .password }
                Divider()
                Text("密码").font(.subheadline.weight(.medium))
                SecureField("输入密码", text: $password)
                    .textContentType(.password).focused($focused, equals: .password)
                    .submitLabel(.go).onSubmit { if canLogin { Task { await doLogin() } } }
            }
            .padding(20).background(Color.white, in: RoundedRectangle(cornerRadius: 20))
            Toggle("记住账号和密码", isOn: $remember)
                .font(.subheadline)
                .onChange(of: remember) { _, enabled in
                    if !enabled {
                        do { try SavedLogin.remove(server: session.baseURL) }
                        catch { err = errText(error) }
                    }
                }
            Button { Task { await doLogin() } } label: {
                HStack {
                    Spacer()
                    if busy { ProgressView().tint(.white) } else { Text("登录").bold() }
                    Spacer()
                }.padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).disabled(!canLogin)
            Button("还没有账号？立即注册") { focused = nil; showRegister = true }
                .font(.subheadline)
        }.disabled(busy)
    }

    private var studentForm: some View {
        VStack(spacing: 18) {
            if session.studentToken != nil {
                Button("进入已登录的学员端") {
                    if let token = session.studentToken { session.enterStudent(token) }
                }.buttonStyle(.bordered)
            }
            TextField("粘贴教练发来的链接或口令", text: $link, axis: .vertical)
                .lineLimit(2...4).textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($focused, equals: .link)
                .padding(20).background(Color.white, in: RoundedRectangle(cornerRadius: 20))
            Text("粘贴链接后会验证是否有效。教练账号保持登录，不受影响。")
                .font(.footnote).foregroundStyle(Theme.ink2)
            Button { Task { await doStudent() } } label: {
                HStack {
                    Spacer()
                    if busy { ProgressView().tint(.white) } else { Text("查看我的课时").bold() }
                    Spacer()
                }.padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(busy || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var canLogin: Bool { !busy && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty }
    private func restore() {
        email = ""; password = ""; err = nil
        do {
            if let saved = try SavedLogin.load(server: session.baseURL) {
                email = saved.email; password = saved.password; remember = true
            }
        } catch { err = errText(error) }
    }
    private func doLogin() async {
        guard canLogin else { return }
        busy = true; err = nil; focused = nil
        defer { busy = false }
        let server = session.baseURL
        let account = email.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let cookie = try await API(session).login(email: account, password: password)
            guard session.baseURL == server else { return }
            if remember { try SavedLogin.save(.init(email: account, password: password), server: server) }
            else { try SavedLogin.remove(server: server) }
            password = ""
            session.studentMode = false
            session.coachEmail = account
            session.coachCookie = cookie
            session.showingLogin = false
        } catch { err = errText(error) }
    }
    private func doStudent() async {
        busy = true; err = nil; focused = nil
        defer { busy = false }
        let token = Session.extractToken(link)
        let server = session.baseURL
        guard !token.isEmpty else { err = "没认出链接里的口令"; return }
        do {
            let _: StudentView = try await API(session, studentToken: token).get("/s/api/view", student: true)
            guard session.baseURL == server else { return }
            session.enterStudent(token)
        } catch APIError.gone { err = "这条链接已失效，请向教练确认链接是否正确。" }
        catch { err = errText(error) }
    }
}
