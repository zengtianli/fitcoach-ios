import Foundation

// fitcoach —— 上门体育 · At-Home Sports 的命令行（给智能体用；GUI 给人用）。
// 与 App 一起编译同一份 Sources/Models.swift + TimeKit.swift + API.swift + QuickSetup.swift，
// 打同一套后端 /coach/api/*：业务判据全部在后端 domain.py，这里零业务判断。
// 构建：cli/build.sh（产物 build/cli/fitcoach，--link 再链到 ~/.local/bin/fitcoach）。

let cliVersion = "1.0.0"

@MainActor
struct Context {
    let base: String
    let store: CredentialStore

    /// 带本机保存的教练凭证；没登录就是退出码 3。
    func coach() throws -> API {
        guard let credential = store.load(base) else { throw Failure.signedOut }
        return API(Session(baseURL: base, coachCookie: credential.cookie))
    }

    func anonymous() -> API { API(Session(baseURL: base)) }
}

struct Spec {
    var values: [String] = []
    var flags: [String] = []
    let run: @MainActor (Args, Context) async throws -> Void
}

@MainActor
enum Registry {
    static let groups: [String: [String: Spec]] = [
        "phone": [
            "hints": Spec(run: PhoneCommands.hints),
            "account": Spec(run: PhoneCommands.account),
            "send": Spec(values: ["purpose", "phone", "request-id", "identity-grant-file"], flags: ["confirm-send", "password-stdin"], run: PhoneCommands.send),
            "verify": Spec(values: ["challenge"], flags: ["code-stdin", "authenticated"], run: PhoneCommands.verify),
            "register": Spec(values: ["grant-file", "display-name"], flags: ["agreed", "password-stdin"], run: PhoneCommands.register),
            "login": Spec(values: ["grant-file"], flags: ["ownership-stdin"], run: PhoneCommands.login),
            "recover": Spec(values: ["grant-file"], flags: ["secrets-stdin"], run: PhoneCommands.recover),
            "bind": Spec(values: ["phone", "grant-file", "old-grant-file", "identity-grant-file"], flags: ["password-stdin"], run: PhoneCommands.bind),
            "set-password": Spec(values: ["identity-grant-file"], flags: ["password-stdin"], run: PhoneCommands.setPassword),
        ],
        "students": [
            "list": Spec(values: ["find"], run: Commands.studentsList),
            "show": Spec(run: Commands.studentsShow),
            "link": Spec(flags: ["reveal"], run: Commands.studentsLink),
            "add": Spec(values: ["name", "note"], run: Commands.studentsAdd),
            "update": Spec(values: ["name", "note"], flags: ["active", "inactive"], run: Commands.studentsUpdate),
            "issue-link": Spec(flags: ["replace", "reveal"], run: Commands.studentsIssueLink),
            "revoke-link": Spec(values: ["reason"], run: Commands.studentsRevokeLink),
        ],
        "sessions": [
            "options": Spec(values: ["student", "session", "date"], run: Commands.sessionsOptions),
            "show": Spec(run: Commands.sessionsShow),
            "add": Spec(values: ["package", "start", "end", "minutes", "location", "content", "status",
                                 "reason", "reason-code"], flags: ["force"], run: Commands.sessionsAdd),
            "edit": Spec(values: ["package", "start", "end", "minutes", "location", "content", "reason"],
                         flags: ["no-location", "force"], run: Commands.sessionsEdit),
            "status": Spec(values: ["to", "reason", "reason-code"], flags: ["force"], run: Commands.sessionsStatus),
        ],
        "packages": [
            "add": Spec(values: ["student", "total", "price-yuan", "purchased", "expires", "note"],
                        run: Commands.packagesAdd),
            "edit": Spec(values: ["student", "total", "price-yuan", "purchased", "expires", "note", "reason",
                                  "reason-code"], flags: ["no-expiry"], run: Commands.packagesEdit),
            "void": Spec(values: ["reason", "reason-code", "student"], flags: ["undo", "yes", "dry-run"],
                         run: Commands.packagesVoid),
        ],
        "locations": [
            "list": Spec(run: Commands.locationsList),
            "add": Spec(values: ["name", "address"], run: Commands.locationsAdd),
            "update": Spec(values: ["name", "address"], flags: ["active", "inactive"], run: Commands.locationsUpdate),
        ],
        "availability": [
            "show": Spec(run: Commands.availabilityShow),
            "add-rule": Spec(values: ["weekday", "start", "end"], run: Commands.availabilityAddRule),
            "rm-rule": Spec(run: Commands.availabilityRemoveRule),
            "add-exception": Spec(values: ["date", "kind", "start", "end", "reason"],
                                  run: Commands.availabilityAddException),
            "rm-exception": Spec(run: Commands.availabilityRemoveException),
        ],
        "metrics": [
            "list": Spec(run: Commands.metricsList),
            "add": Spec(values: ["name", "unit", "sort"], flags: ["higher-is-better", "lower-is-better"],
                        run: Commands.metricsAdd),
            "update": Spec(values: ["name", "unit", "sort"],
                           flags: ["higher-is-better", "lower-is-better", "active", "inactive"],
                           run: Commands.metricsUpdate),
            "seed": Spec(run: Commands.metricsSeed),
        ],
        "measurements": [
            "add": Spec(values: ["student", "metric", "date", "value", "note"], run: Commands.measurementsAdd),
            "rm": Spec(values: ["student"], flags: ["yes", "dry-run"], run: Commands.measurementsRemove),
        ],
        "account": [
            "delete": Spec(values: ["confirm"], flags: ["dry-run"], run: Commands.accountDelete),
        ],
    ]

    static let singles: [String: Spec] = [
        "login": Spec(values: ["email"], flags: ["password-stdin"], run: Commands.login),
        "logout": Spec(run: Commands.logout),
        "status": Spec(run: Commands.status),
        "register": Spec(values: ["email", "display-name"], flags: ["password-stdin"], run: Commands.register),
        "password": Spec(flags: ["stdin"], run: Commands.password),
        "schedule": Spec(values: ["range", "date"], run: Commands.schedule),
        "growth": Spec(values: ["metric"], run: Commands.growth),
        "audit": Spec(values: ["student"], flags: ["all"], run: Commands.audit),
        "student-view": Spec(flags: ["token-stdin"], run: Commands.studentView),
        "setup": Spec(values: ["location", "days"], run: Commands.setup),
    ]
}

@main
struct FitCoachCLI {
    @MainActor
    static func main() async {
        let argv = Array(CommandLine.arguments.dropFirst())
        Out.json = argv.contains("--json")
        let wantsHelp = argv.contains("--help") || argv.contains("-h")
        // 命令名之前允许出现通用参数（--json、--base URL / --base=URL）；它们原样交给命令自己的参数解析。
        var leading: [String] = []
        var index = 0
        while index < argv.count, argv[index].hasPrefix("-") {
            leading.append(argv[index])
            if argv[index] == "--base", index + 1 < argv.count {
                leading.append(argv[index + 1])
                index += 1
            }
            index += 1
        }
        let head = index < argv.count ? argv[index] : nil

        if argv.contains("--version") && head == nil {
            print("fitcoach \(cliVersion)")
            exit(0)
        }
        if wantsHelp {
            print(head.flatMap { Help.groups[$0] } ?? Help.overview)
            exit(0)
        }
        guard let head else {
            if Out.json { Out.fail(.usage("缺少命令（见 fitcoach --help）")) }
            FileHandle.standardError.write(Data((Help.overview + "\n").utf8))
            exit(ExitCode.usage.rawValue)
        }

        // config / update / app：读写的是 Mac 版 App 自己保存的东西，转给 App 的可执行文件（cli/AppRelay.swift）。
        if AppRelay.verbs.contains(head) {
            AppRelay.run(Array(argv[index...]) + (leading.contains("--json") ? ["--json"] : []) + leading.filter { $0 == "--base" || $0.hasPrefix("--base=") })
        }

        var rest = Array(argv[(index + 1)...])
        let phoneSubcommand = head == "phone" ? rest.first : nil
        let spec: Spec
        if let table = Registry.groups[head] {
            guard let sub = rest.first, !sub.hasPrefix("-") else {
                Out.fail(.usage("\(head) 需要子命令：\(table.keys.sorted().joined(separator: " · "))（见 fitcoach \(head) --help）"))
            }
            guard let found = table[sub] else {
                Out.fail(.usage("\(head) 没有子命令 \(sub)：\(table.keys.sorted().joined(separator: " · "))"))
            }
            spec = found
            rest.removeFirst()
        } else if let found = Registry.singles[head] {
            spec = found
        } else {
            Out.fail(.usage("没有命令 \(head)（见 fitcoach --help）"))
        }
        rest = leading + rest

        let args: Args
        do {
            args = try Args(rest, values: Set(spec.values + ["base"]), flags: Set(spec.flags + ["json"]))
        } catch {
            Out.fail(await classify(error, api: nil))
        }
        let context = Context(base: resolveBase(args.value("base")), store: .standard())
        do {
            try await spec.run(args, context)
            exit(ExitCode.ok.rawValue)
        } catch {
            // 公共短信核验/登录失败不能清掉另一枚仍有效的本地教练会话。
            let authenticated = head != "phone"
                || ["account", "bind", "set-password"].contains(phoneSubcommand ?? "")
                || (phoneSubcommand == "verify" && args.has("authenticated"))
                || (phoneSubcommand == "send" && ["bind", "change_old", "change_new", "identity"].contains(args.value("purpose") ?? ""))
            if authenticated, case APIError.unauthorized = error { _ = try? context.store.remove(context.base) }
            Out.fail(await classify(error, api: try? context.coach()))
        }
    }

    @MainActor
    static func resolveBase(_ flag: String?) -> String {
        let env = ProcessInfo.processInfo.environment["FITCOACH_BASE"]
        var base = (flag ?? env ?? Session.defaultBaseURL).trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = Session.defaultBaseURL }
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }
}

enum Help {
    static let overview = """
    用法：fitcoach <命令> [参数]      每个命令都有 --help；加 --json 输出一行 JSON（形状见下）

    与「上门体育」App、网页 fit.tianli.cyou、小程序同一套 /coach/api/*、同一份数据；业务判据全在后端。
    教练端：
      login          登录并在本机保存凭证：--email E --password-stdin（密码只从 stdin 或终端读）
      logout         删掉本机凭证；服务端数据保留
      status         读回：命令行版本、所连服务器、登录态与账号、服务端今天/现在
      schedule       日程与预警：[--range today|week|overdue] [--date YYYY-MM-DD]
      students       学员：list [--find 关键字] · show ID · link ID [--reveal] · add · update ID · issue-link ID · revoke-link ID
      sessions       课次：options · show ID · add · edit ID · status ID --to S
      packages       课包：add · edit ID · void ID --yes [--dry-run] · void ID --undo
      locations      地点：list · add · update ID
      availability   档期：show · add-rule · rm-rule ID · add-exception · rm-exception ID
      metrics        体测项目：list · add · update ID · seed
      growth         学员成长：growth STUDENT_ID [--metric ID]
      measurements   测量：add · rm ID --yes [--dry-run]
      audit          变更记录：[--all] [--student ID]
      setup          快速开始（与 App 同一套编排）：[--location 名称] [--days weekdays|daily|weekend]
      password       改密码：--stdin（第 1 行旧密码，第 2 行新密码）
      register       注册新教练：--email E --display-name N --password-stdin
      account        注销账号（整个租户真删、不可恢复）：account delete --confirm delete-account [--dry-run]
      phone          手机账号：hints · account · send · verify · register · login · recover · bind · set-password
    学员端：
      student-view   用学员链接读只读视图：--token-stdin（链接或口令只从 stdin 读，不进命令行参数）
    Mac 版 App 自己保存的东西（转给已装的 Mac 版「上门体育」的可执行文件去做，不开窗口；各有 --help）：
      config         「配置与更新」里的配置：status · export -o FILE · import FILE --yes · sync on|off --yes
      update         「配置与更新」里的更新：check · install --yes [--dry-run]
      app            App 的登录：saved-login status · saved-login clear --yes [--all] · logout --yes

    读命令（只读，不改服务器数据；本机凭证只在服务端回 401 判定会话失效时被清掉）：
      status · schedule · students list|show|link · sessions options|show · locations list · availability show
      metrics list · growth · audit · student-view · phone hints|account
      config status · update check · app saved-login status（读 Mac 版 App 自己保存的；update install --dry-run 是演练）
      演练：packages void --dry-run · measurements rm --dry-run · account delete --dry-run
    写命令：
      本机凭证  login · logout（只动本机凭证文件）· register（同时在服务器新建账号）
      业务数据  students add|update|issue-link|revoke-link · sessions add|edit|status · packages add|edit|void
                locations add|update · availability add-rule|rm-rule|add-exception|rm-exception
                metrics add|update|seed · measurements add|rm · setup
      账号      password · account delete · phone send|verify|register|login|recover|bind|set-password
                （phone send 会发真实短信并计费，须带 --confirm-send）
      Mac 版 App  config export（只写你指定的那个文件）· config import · config sync · update install
                app saved-login clear · app logout（都要 --yes；改的是 App 那一份，命令行凭证不动）

    通用参数：--json  --base URL（默认 https://fit.tianli.cyou；或环境变量 FITCOACH_BASE）  --help  --version
    凭证：~/Library/Application Support/FitCoach/cli/credentials.json（0600，按服务器分条；FITCOACH_CLI_HOME 改目录）

    --json 输出（stdout 一行，键按字母序）：
      成功  {"ok": true, …}        读命令是后端该接口的原字段再加 ok；写命令给新建或改动对象的 id 等
      失败  {"ok": false, "code": "稳定的英文短码", "error": "给人看的原因"[, "warnings": [{"code": …, "message": …}]]}
            同时退出码非零；warnings 只在 409 软警告时出现
      code  usage · signed_out · link_invalid · not_found · rejected · needs_force · needs_confirm
            auth_failed · login_refused · transport · server_error · decode · failure

            config / update / app 是共用命令层的形状（多行）：成功 {"ok": true, "command": "config status", …}；
            失败 {"ok": false, "command": …, "error": {"code", "message"}}，字段见各自 --help

    退出码：
      0  成功（查无结果也算成功）
      1  网络 / 服务端 5xx（可稍后重试）/ 响应解析 / 本机写凭证失败
      2  用法错误
      3  未登录或登录已失效；学员链接无效或已吊销
      4  后端拒绝（400，--force 也不放行；直接写入时 id 不存在「…不存在」也在这里）
      5  需要确认：后端 409 软警告加 --force，或本机要求 --yes / --confirm
      6  登录失败（401）或尝试过于频繁（429）
      7  要读的记录不存在（读取、先读后改的 update / edit、--dry-run）
      config / update / app 只用三个：0 成功 · 1 未完成（原因在 error.code）· 2 用法错误或缺 --yes

    示例：
      printf '%s\\n' "$PASSWORD" | fitcoach login --email coach@example.com --password-stdin
      fitcoach schedule --range week --json
      fitcoach sessions add --package 3 --start '2026-10-08 10:00' --minutes 60 --location 1 --json
      fitcoach sessions status 42 --to completed --json

    仅在窗口中（命令不做；括号里是原因或命令行的对应做法）：
      勾选「记住账号和密码」并登录（要真人在登录窗口输密码；读回与清除有命令：app saved-login status / clear）
      进入已登录的教练端 / 学员端、切换账号（只是窗口显示哪一端；命令行两端各有命令）
      隐私政策、联系支持（打开网页）
      下拉刷新与刷新按钮（命令每次都现读）
      复制学员链接（写剪贴板；students link ID --reveal 输出到 stdout）
      分享学员链接（系统分享面板）
      趋势图（图形；数据点在 growth 的 series）
      选择 iCloud Drive 更新目录（Mac 版，系统文件选择器授权，要真人选）
      日期、时间选择器与常用值按钮（命令行直接给 --date / --start / --end / --minutes 等参数）
    暂无命令（登记在 project.yaml 的 sop.agent_cli）：
      手表上快照的更新时间与过期提示（只在手表本机）
      手机、平板、Vision 上的「配置与更新」、记住的账号密码与登录态（只在那台设备本机；上面 config / update / app 管的是这台 Mac 上的 Mac 版）
    """

    static let groups: [String: String] = [
        "config": """
        用法：fitcoach config [status] [--json]
              fitcoach config export -o <file.json> [--force] [--json]
              fitcoach config import <file.json> --yes [--json]
              fitcoach config sync on|off --yes [--dry-run] [--json]
        Mac 版「上门体育」里「配置与更新」面板的配置一组，与面板读写同一份设置。由已装的 Mac 版 App 自己的可执行文件执行
        （偏好在 App 的沙盒容器里，iCloud 键值存储的同步只有 App 自己能跑）；不开窗口、不抢焦点、不弹框。
        可迁移的配置只有一项：fitcoach.baseURL（App 连哪台服务器，即登录页「服务器设置」）。
          读它      config status --json 的 keys[] 里是 defaults.fitcoach.baseURL（没改过默认服务器时不出现）；值在 config export -o - 输出的 values 里
          改它      把导出文件 values 里的 defaults.fitcoach.baseURL 改好，再 config import <file> --yes（必须是 https 地址，否则回到默认服务器）。
                    服务器换了，App 里的登录态随之清掉（登录属于签发它的那台服务器），要重新登录
          区别      --base / FITCOACH_BASE 只管命令行自己这一次连哪台，不读也不改 App 这一份；这三组命令不接受 --base
        读（不写任何文件或状态）:
          config status              「使用 iCloud 记住配置」开关、开关下面那句同步状态、当前可迁移的配置项、App 是否在运行
        写:
          config export -o <file>    导出配置：与面板「导出配置」同一份文件；不改设置，只写你指定的那个文件（--force 覆盖；-o - 输出到标准输出，不写文件）
          config import <file> --yes 导入配置：先备份原配置再覆盖，与面板「导入配置」相同
          config sync on|off --yes   拨动「使用 iCloud 记住配置」（--dry-run 只看会不会变；用 fitcoach config status 回读）
        --json：成功 {"ok": true, "command": "config status", …}；失败 {"ok": false, "command": …, "error": {"code", "message"}}，退出码非零。
          config status  → has_settings, sync_enabled, sync_status{text, at, from, live}, keys[], app_running, problem
          config export  → path, bytes, keys[]
          config import  → imported, path, sync_enabled, app_running, sync{completed, status}（仅同步开着时）
          config sync    → action, changed, sync_enabled, status, app_running, check_with；--dry-run 给 would_change
        退出码与 error.code：
          0  成功
          1  操作未完成：not_found（没有这个文件）· import_rejected（导入被拒，原配置保留）· export_failed（导出未完成）·
             sync_incomplete（开关已打开，首次同步未完成）· no_settings · app_missing（没装 Mac 版）· app_outdated（装着的 Mac 版没有命令入口）· failed
          2  用法错误或缺确认参数：usage · confirmation_required（import、sync 缺 --yes）· file_exists（导出目标已存在，缺 --force）
        仅在窗口中：打开「配置与更新」面板；用系统文件面板选导出位置或要导入的文件（命令直接给路径）
        """,
        "update": """
        用法：fitcoach update check [--json]
              fitcoach update install --yes [--dry-run] [--json]
        Mac 版「上门体育」里「配置与更新」面板的更新一组。由已装的 Mac 版 App 自己的可执行文件执行：发行记录在 iCloud Drive 的
        私有更新目录里，目录的访问授权只在 App 手里（第一次要真人在面板里用系统文件选择器选一次目录，命令替不了）。
        读（不写任何文件或状态）:
          update check               检查更新：当前版本、此渠道最新版本、有没有新版、怎么升级
          update install --dry-run   只看会做什么
        写:
          update install --yes       升级到新版：与面板「打开发行包」同一条路做到打开之前——核对发行包身份、大小与 SHA256，给出它的位置。
                                     沙盒里的 App 换不了自己，所以有新版时以 manual_install 结束（退出 1，package 是核对过的发行包）；
                                     不弹窗、不替换 App。没有新版时退出 0，installed 为 false
        --json：成功 {"ok": true, "command": "update check", …}；失败 {"ok": false, "command": …, "error": {"code", "message"}}。
          update check   → current{version, build}, source{kind, channel, access}, latest{version, build, channel, package, sha256, size_bytes, installation},
                           update_available, state（update_available | up_to_date | ahead_of_channel）, message, upgrade{in_app, button, how, download_url, command}, app_running
          update install → installed, state, message, current, latest, source, app_running；--dry-run 给 dry_run, would_install{from, to}, installation, will_quit_app, will_relaunch；
                           manual_install 时另有 package, package_verified
        退出码与 error.code：
          0  成功（update install 没有新版时也是 0）
          1  check_incomplete（没读到发行记录，或还没授权更新目录）· manual_install（发行包已核对，要手动安装）·
             upgrade_failed（发行包未通过核对，当前 App 未动）· app_missing · app_outdated · failed
          2  usage · confirmation_required（update install 缺 --yes）
        仅在窗口中：选择 iCloud Drive 更新目录（系统文件选择器授权，要真人选）；解开发行包并放进「应用程序」
        """,
        "app": """
        用法：fitcoach app saved-login status [--json]
              fitcoach app saved-login clear --yes [--all] [--json]
              fitcoach app logout --yes [--json]
        这台 Mac 上 Mac 版「上门体育」自己的登录：登录窗口「记住账号和密码」存进 App 钥匙串的那份，和 App 的登录态。
        由已装的 Mac 版 App 自己的可执行文件执行（钥匙串条目和沙盒偏好只有它读得到）；不开窗口、不弹框。任何输出都不带密码。
        与命令行自己的凭证是两份、互不读取：fitcoach login / logout 只管命令行凭证文件，动不了 App；这里的命令只管 App，动不了命令行凭证。
        读:
          app saved-login status         当前服务器有没有记住、各服务器记的是哪个账号（只有服务器与账号名）
        写:
          app saved-login clear --yes    清掉当前服务器记住的账号和密码（--all 清所有服务器）；登录态不动，下次登录窗口不再自动填
          app logout --yes               退出 App 的教练登录（窗口里「退出」的同一件事）；服务器数据、学员链接、记住的账号密码都不动。
                                         App 开着时窗口随即回到登录页
        --json：成功 {"ok": true, "command": "app logout", …}；失败 {"ok": false, "command": …, "error": {"code", "message"}}。
          app saved-login status → server, saved, entries[{server, email}], count, password_shown（恒为 false）, app_running
          app saved-login clear  → cleared[], count, remaining, server, app_running, check_with
          app logout             → logged_out, had_session, session_left, student_link_kept, app_running
        退出码与 error.code：
          0  成功（本来就没有记住 / 没有登录也是 0，未改动）
          1  keychain_unavailable（读不到 App 钥匙串）· app_missing · app_outdated · failed
          2  usage · confirmation_required（clear、logout 缺 --yes）
        仅在窗口中：登录（要真人输密码或验证码；勾选「记住账号和密码」后由登录窗口存入）
        """,
        "phone": """
        用法：fitcoach phone <子命令> [参数] [--json]
          hints / account              公共短信提示 / 当前账号安全状态
          send --purpose P [--phone N] --request-id ID --confirm-send [--password-stdin] [--identity-grant-file FILE]
                                       P: register|login|recover|bind|change_old|change_new|identity；发送会计费；未知结果重用同一个 ID，禁自动重发
          verify --challenge ID --code-stdin [--authenticated]
                                       验证码只从 stdin 第一行读取；返回 0600 授权文件路径，绑定用途需 --authenticated
          register --grant-file FILE --agreed [--display-name N] [--password-stdin]
          login --grant-file FILE [--ownership-stdin]
                                       风险验证从 stdin JSON 读 password / recovery_key；失败保留授权文件
          recover --grant-file FILE --secrets-stdin
                                       stdin JSON: new_password + recovery_key 或原 password；找回始终要求独立归属证明。成功清本机会话，重新登录
          bind --phone N --grant-file FILE [--old-grant-file FILE] [--identity-grant-file FILE] [--password-stdin]
                                       换绑先验证旧、新号码；密码账号要原密码。保持 coach_id 和业务数据
          set-password --identity-grant-file FILE --password-stdin
                                       手机新户验证 identity 后设密码；成功更新当前设备 cookie
          授权、恢复密钥只存命令行私有目录 0600 文件，不输出明文；恢复密钥文件路径只在首次注册/绑定返回，请备份到密码管理器。
        """,
        "login": """
        用法：fitcoach login --email E [--password-stdin] [--base URL] [--json]
          POST /api/login（与 App 同一端点），凭证存本机 0600 文件，不写 App 的登录。
          密码从 stdin 第一行读（--password-stdin），终端里不带该参数时不回显提示输入；绝不收命令行参数里的密码。
          失败退出 6：密码错（401）或尝试过于频繁（429，每账号 15 分钟 5 次失败、每 IP 20 次）。
        """,
        "logout": """
        用法：fitcoach logout [--base URL] [--json]
          删掉本机这台服务器的凭证。账号版本变化（改密、换绑或找回）使旧会话失效；普通退出不删除业务数据。
        """,
        "status": """
        用法：fitcoach status [--base URL] [--json]
          读回命令，只读。GET /coach/api/ping：确认登录有效，给出命令行版本、所连服务器、登录邮箱、凭证保存时间、
          服务端今天/现在（--json：version base email saved_at today now）。未登录或已失效退出 3（code signed_out）。
        """,
        "register": """
        用法：fitcoach register --email E --display-name N [--password-stdin] [--json]
          POST /api/register（与 App 注册页同一端点）：在服务器上新建一个教练账号并登录。对外写操作，只在测试后端验证。
        """,
        "password": """
        用法：fitcoach password --stdin [--json]
          POST /coach/api/password。stdin 第 1 行旧密码、第 2 行新密码；终端里不带 --stdin 时逐项不回显输入。
          成功更新当前命令行的会话；其他设备的旧会话失效，需要重新登录。
        """,
        "account": """
        用法：fitcoach account delete --confirm delete-account [--dry-run] [--json]
          POST /coach/api/account/delete：整个教练租户（学员、课包、课次、审计）真删，不可恢复。
          必须带字面量 --confirm delete-account；--dry-run 只核对登录与目标账号，不删。成功后清掉本机凭证。
        """,
        "schedule": """
        用法：fitcoach schedule [--range today|week|overdue] [--date YYYY-MM-DD] [--json]
          GET /coach/api/schedule：与 App「日程」、网页 /coach/schedule 同源（days + warnings 预警条）。
          --range 默认 today；overdue = 过时未处理。
        """,
        "students": """
        用法：fitcoach students <子命令> [参数] [--json]
          list [--find 关键字]          在读 / 停用两组，含余额、到期预警、是否有链接；
                                        --find 按姓名筛选（不分大小写的包含，同 App「找学员」，本地筛选）
          show ID                       合计、课包三桶（可用/已过期/已用完/已作废）、上课记录
          link ID [--reveal]            学员链接状态；链接本身是凭证，默认只报 has_link，--reveal 才输出 URL
          add --name N [--note T]       新建学员
          update ID [--name N] [--note T] [--active|--inactive]
                                        先读现值再整条提交（后端缺 is_active 会静默停用并吊销链接）；
                                        停用会同时吊销学员链接
          issue-link ID [--replace] [--reveal]
                                        没有链接时签发（同 App）；已有链接时不动，加 --replace 才换发（旧链接立即失效）
          revoke-link ID --reason R     吊销学员链接（同网页/小程序，写审计）
        """,
        "sessions": """
        用法：fitcoach sessions <子命令> [参数] [--json]
          options [--student ID] [--session ID] [--date YYYY-MM-DD]
                                        排课表单选项：学员、FEFO 排序课包、地点、当天可排时段
          show ID                       课次详情 + 这一节的变更记录（审计接口上限 300 行，超出时 history_complete=false）
          add --package ID --start 'YYYY-MM-DD HH:MM' (--end HH:MM | --minutes N) [--location ID] [--content T]
              [--status scheduled|completed|no_show|cancelled] [--reason R] [--reason-code C] [--force]
                                        排课 / 补录；409 软警告（冲突、超排、不在档期）退出 5，确认后加 --force；
                                        400 硬拒（课包已作废、未来的课标已上课）退出 4，--force 也不放行
          edit ID [--package ID] [--start …] [--end …|--minutes N] [--location ID|--no-location] [--content T]
               [--reason R] [--force]  先读现值再整条提交；只改 --start 时保持原时长
          status ID --to scheduled|completed|no_show|cancelled [--reason R] [--reason-code C] [--force]
                                        改状态 / 扣课时；从非「已排课」改出必须带 --reason（后端判）
          reason-code：mistake student_leave student_injury coach_reason venue_weather goodwill other
        """,
        "packages": """
        用法：fitcoach packages <子命令> [参数] [--json]
          add --student ID --total N [--price-yuan X] [--purchased YYYY-MM-DD] [--expires YYYY-MM-DD] [--note T]
                                        购买日默认今天（Asia/Shanghai），不给 --expires 即不过期
          edit ID [--student SID] [--total N] [--price-yuan X] [--purchased D] [--expires D|--no-expiry] [--note T]
               [--reason R] [--reason-code C]
                                        先读现值再整条提交（后端缺字段会清掉到期日/单价/备注）；改节数或到期日须带理由
          void ID --yes [--reason R] [--reason-code C]
                                        作废会把包内已排未上的课一并取消（不扣课时），与 App 作废页一样须确认：
                                        不带 --yes 退出 5（needs_confirm）
          void ID --dry-run [--student SID] [--undo]
                                        只读：报出课包现状与将被取消的已排节数（would_cancel），不写
          void ID --undo [--reason R]   撤销作废（不需要 --yes）；被取消的课不会自动恢复
        """,
        "locations": """
        用法：fitcoach locations <子命令> [参数] [--json]
          list                          含停用项
          add --name N [--address A]
          update ID [--name N] [--address A] [--active|--inactive]   先读现值再整条提交；停用不删
        """,
        "availability": """
        用法：fitcoach availability <子命令> [参数] [--json]
          show                          每周规则、例外、未来两周实际可排时段
          add-rule --weekday 0-6 --start HH:MM --end HH:MM      0 = 周日 … 6 = 周六
          rm-rule ID                    删除每周规则（档期不写审计；输出被删的规则，便于重建）
          add-exception --date YYYY-MM-DD --kind open|block [--start HH:MM --end HH:MM] [--reason R]
                                        block 不给时段 = 整天停排
          rm-exception ID               删除例外（输出被删的例外）
        """,
        "metrics": """
        用法：fitcoach metrics <子命令> [参数] [--json]
          list                          含停用项
          add --name N [--unit U] (--higher-is-better | --lower-is-better) [--sort N]
                                        方向必须显式二选一：写反会把进步报成退步
          update ID [--name N] [--unit U] [--higher-is-better|--lower-is-better] [--sort N] [--active|--inactive]
                                        先读现值再整条提交（后端缺字段会把方向归 0、排序归 0）
          seed                          一键导入常用项目（只在一个都没有时生效，重复运行不重复导入）
        """,
        "growth": """
        用法：fitcoach growth STUDENT_ID [--metric ID] [--json]
          GET /coach/api/students/{id}/growth：首测、最新、最好、变化、是否进步（判据只在后端 higher_is_better）、到课率。
          --metric 是本地筛选（后端不收这个参数）。趋势图只在 App 里。
        """,
        "measurements": """
        用法：fitcoach measurements <子命令> [参数] [--json]
          add --student ID --metric ID --value V [--date YYYY-MM-DD] [--note T]
                                        同一学员同一项目同一天再记会覆盖；--value 必填，数值合法性由后端判
          rm ID --yes                   删除一条测量（App 里先弹「删除这条测量？」；不带 --yes 退出 5）
          rm ID --dry-run [--student SID]
                                        只读：报出将被删的那条测量（would_delete），不写
        """,
        "audit": """
        用法：fitcoach audit [--all] [--student ID] [--json]
          变更记录，默认只列纠错 / 通融 / 补录；--all 全部。后端每次最多 300 行（capped=true 表示可能被截断）。
        """,
        "student-view": """
        用法：fitcoach student-view --token-stdin [--json]
          GET /s/api/view（学员端只读视图，同 App 学员模式与 /s/<口令> 网页）。stdin 给整条链接或口令；
          链接无效或已吊销退出 3。例：fitcoach students link 3 --reveal | fitcoach student-view --token-stdin --json
        """,
        "setup": """
        用法：fitcoach setup [--location 名称] [--days weekdays|daily|weekend] [--json]
          与 App「快速开始」同一份编排（Sources/QuickSetup.swift）：没有地点就建一个（默认「健身房」），
          没有体测项目就导入常用项目，档期按所选日子补 09:00–18:00。只补空白、不改不删：已有规则全是所选日子上的
          09:00–18:00（包括上次中途失败留下的）时，只补还缺的那几天；有别的时段、所选以外的星期或任何例外 = 自配过档期，
          档期一项不动（kept_existing_availability=true）。可重复运行。
        """,
    ]
}
