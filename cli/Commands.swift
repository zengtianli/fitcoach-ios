import Foundation

// 每条命令 = App 里同一个动作打同一条 /coach/api/*，字段集照抄对应 View 的提交（见各处注释里的出处）。
// 业务判据（余额、状态机、档期、硬拒、理由必填）全在后端 domain.py；这里只做参数格式检查、
// 「先读现值再整条提交」的合并（后端更新端点缺字段 = 清空 / 停用），以及输出。

@MainActor
enum Commands {

    // ── 共用小工具 ──────────────────────────────────────────────────────────

    /// GET 一次：同一份字节既解码成 App 的模型（文本渲染用），又原样转成字典（--json 用）。
    static func fetch<T: Decodable>(_ api: API, _ path: String, _ query: [String: String] = [:],
                                    as type: T.Type) async throws -> (T, [String: Any]) {
        let data = try await api.getRaw(path, query: query)
        let model: T
        do { model = try JSONDecoder().decode(T.self, from: data) }
        catch { throw APIError.decode("\(path)：\(error)") }
        return (model, try jsonDictionary(data))
    }

    /// POST 一次：返回 App 的 MutationResp 与原始字典。
    static func send(_ api: API, _ path: String, _ fields: [String: String]) async throws
        -> (MutationResp, [String: Any]) {
        let data = try await api.postRaw(path, fields)
        let model: MutationResp
        do { model = try JSONDecoder().decode(MutationResp.self, from: data) }
        catch { throw APIError.decode("\(path)：\(error)") }
        return (model, try jsonDictionary(data))
    }

    static func on(_ flag: Bool) -> String { flag ? "on" : "" }

    /// 体测方向显式发 "1"/"0"（同网页下拉框）。新建端点默认值是 "1"，FastAPI 把空串当没填、套默认值：
    /// 发 "" 会把「越小越好」存成「越大越好」。
    static func direction(_ higher: Bool) -> String { higher ? "1" : "0" }

    /// YYYY-MM-DD，且必须是真实日期（2026-02-30 这类直接拒）。
    static func dateArg(_ a: Args, _ name: String) throws -> String? {
        guard let raw = a.value(name) else { return nil }
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard let date = TZ.dateFmt.date(from: text), TZ.dateString(date) == text else {
            throw Failure.usage("--\(name) 须是 YYYY-MM-DD：\(raw)")
        }
        return text
    }

    static func timeArg(_ a: Args, _ name: String) throws -> String? {
        guard let raw = a.value(name) else { return nil }
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard let time = TZ.timeFmt.date(from: text), TZ.timeString(time) == text else {
            throw Failure.usage("--\(name) 须是 HH:MM：\(raw)")
        }
        return text
    }

    /// 'YYYY-MM-DD HH:MM'（Asia/Shanghai 墙钟，与后端存储口径一致）。
    static func stamp(_ raw: String, _ name: String) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard let date = TZ.stampFmt.date(from: text), TZ.stampString(date) == text else {
            throw Failure.usage("--\(name) 须是 'YYYY-MM-DD HH:MM'：\(raw)")
        }
        return text
    }

    static func addMinutes(_ start: String, _ minutes: Int) -> String {
        TZ.stampString(TZ.date(fromStamp: start).addingTimeInterval(TimeInterval(minutes * 60)))
    }

    /// --end 可给 HH:MM（与开始同一天，同 App 表单）或完整 'YYYY-MM-DD HH:MM'。
    static func endStamp(_ raw: String, start: String) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.count == 5 {
            guard let time = TZ.timeFmt.date(from: text), TZ.timeString(time) == text else {
                throw Failure.usage("--end 须是 HH:MM 或 'YYYY-MM-DD HH:MM'：\(raw)")
            }
            return String(start.prefix(10)) + " " + text
        }
        return try stamp(text, "end")
    }

    static func positiveMinutes(_ a: Args) throws -> Int? {
        guard let minutes = try a.int("minutes") else { return nil }
        guard minutes > 0 else { throw Failure.usage("--minutes 须是正整数：\(minutes)") }
        return minutes
    }

    static func statusArg(_ a: Args, required: Bool) throws -> String? {
        guard let value = a.value("to") ?? a.value("status") else {
            if required { throw Failure.usage("缺少 --to（\(Vocab.statuses.joined(separator: " | "))）") }
            return nil
        }
        guard Vocab.statuses.contains(value) else {
            throw Failure.usage("状态只能是 \(Vocab.statuses.joined(separator: " | "))：\(value)")
        }
        return value
    }

    static func reasonCodeArg(_ a: Args) throws -> String {
        guard let value = a.value("reason-code"), !value.isEmpty else { return "" }
        guard Vocab.reasonCodes.contains(where: { $0.0 == value }) else {
            throw Failure.usage("--reason-code 只能是 \(Vocab.reasonCodes.map(\.0).joined(separator: " "))：\(value)")
        }
        return value
    }

    /// 密码 / 口令：--xxx-stdin 从 stdin 第一行读；终端交互时不回显提示；其余情况报用法错。绝不收 argv。
    static func secret(_ a: Args, flag: String, prompt: String) throws -> String {
        if a.has(flag) {
            guard let first = readStdinLines().first, !first.isEmpty else {
                throw Failure.usage("--\(flag)：stdin 第一行为空")
            }
            return first
        }
        if let typed = promptSecret(prompt), !typed.isEmpty { return typed }
        throw Failure.usage("非终端运行须加 --\(flag)，并从 stdin 传入（不接受命令行参数里的明文）")
    }

    static func warningsText(_ warnings: [Warn]?) {
        for w in warnings ?? [] { Out.note("  注意 [\(w.code)] \(w.message)") }
    }

    static func requireSomeChange(_ a: Args, _ names: [String]) throws {
        let given = names.contains { a.value($0) != nil || a.has($0) }
        guard given else {
            throw Failure.usage("没有要改的字段：可给 \(names.map { "--" + $0 }.joined(separator: " "))")
        }
    }

    // ── 登录 / 账号 ────────────────────────────────────────────────────────

    /// App LoginView → API.login（POST /api/login）。凭证存本机命令行自己的文件，不碰 App 的登录。
    static func login(_ a: Args, _ c: Context) async throws {
        try a.noPositional()
        let email = try a.required("email").trimmingCharacters(in: .whitespaces)
        let password = try secret(a, flag: "password-stdin", prompt: "密码：")
        let cookie: String
        do {
            cookie = try await c.anonymous().login(email: email, password: password)
        } catch APIError.unauthorized(let message) {
            throw Failure(code: "auth_failed", message: message, exit: .authFailed)
        } catch APIError.rejected(let message) {
            // 429 过频（文案里带「请 N 秒后再试」）或其他拒绝；不自动重试
            throw Failure(code: "login_refused", message: message, exit: .authFailed)
        } catch APIError.gone {
            throw Failure(code: "no_login_endpoint", message: "该服务器没有教练账号登录接口（\(c.base)）", exit: .failure)
        }
        try c.store.save(c.base, Credential(cookie: cookie, email: email, saved_at: TZ.stampString(Date())))
        Out.success(["base": c.base, "email": email]) {
            Out.line("已登录 \(email) @ \(c.base)（凭证存于 \(c.store.file.path)）")
        }
    }

    static func logout(_ a: Args, _ c: Context) async throws {
        try a.noPositional()
        let removed = try c.store.remove(c.base)
        Out.success(["base": c.base, "removed": removed]) {
            Out.line(removed ? "已删掉本机凭证（\(c.base)）。服务端业务数据保留。"
                             : "本机没有这台服务器的凭证（\(c.base)）")
        }
    }

    /// App 启动时的 ping 探针 + 「更多」页的登录邮箱。
    static func status(_ a: Args, _ c: Context) async throws {
        try a.noPositional()
        guard let credential = c.store.load(c.base) else { throw Failure.signedOut }
        let ping = try await c.coach().ping()
        Out.success(["base": c.base, "email": credential.email as Any, "saved_at": credential.saved_at,
                     "today": ping.today, "now": ping.now]) {
            Out.line("已登录 \(credential.email ?? "（未记录邮箱）") @ \(c.base)")
            Out.line("服务端今天 \(ping.today)，现在 \(ping.now)")
        }
    }

    /// App RegisterView → API.register（POST /api/register）。对外写：只在测试后端验证。
    static func register(_ a: Args, _ c: Context) async throws {
        try a.noPositional()
        let email = try a.required("email").trimmingCharacters(in: .whitespaces)
        let name = try a.required("display-name")
        let password = try secret(a, flag: "password-stdin", prompt: "密码：")
        let cookie: String
        do {
            cookie = try await c.anonymous().register(email: email, password: password, displayName: name)
        } catch APIError.rejected(let message) {
            throw Failure(code: "rejected", message: message, exit: .rejected)
        }
        try c.store.save(c.base, Credential(cookie: cookie, email: email, saved_at: TZ.stampString(Date())))
        Out.success(["base": c.base, "email": email]) { Out.line("已注册并登录 \(email) @ \(c.base)") }
    }

    /// App PasswordView（POST /coach/api/password）。
    static func password(_ a: Args, _ c: Context) async throws {
        try a.noPositional()
        let api = try c.coach()
        let old: String, new: String
        if a.has("stdin") {
            let lines = readStdinLines()
            guard lines.count >= 2, !lines[0].isEmpty, !lines[1].isEmpty else {
                throw Failure.usage("--stdin：第 1 行旧密码、第 2 行新密码，都不能为空")
            }
            old = lines[0]; new = lines[1]
        } else {
            guard let o = promptSecret("旧密码："), let n1 = promptSecret("新密码："),
                  let n2 = promptSecret("再输一次新密码：") else {
                throw Failure.usage("非终端运行须加 --stdin（第 1 行旧密码、第 2 行新密码）")
            }
            guard n1 == n2 else { throw Failure.usage("两次输入的新密码不一致") }
            old = o; new = n1
        }
        let (_, result) = try await send(api, "/coach/api/password", ["old_password": old, "new_password": new])
        if let cookie = result["cookie"] as? String {
            try c.store.save(c.base, Credential(cookie: cookie, email: c.store.load(c.base)?.email, saved_at: TZ.stampString(Date())))
        }
        Out.success(["base": c.base]) { Out.line("密码已修改，当前设备会话已更新；其他设备需要重新登录。") }
    }

    /// App AccountDeleteView → API.deleteAccount()。整租户真删，不可恢复：字面量确认门。
    static func accountDelete(_ a: Args, _ c: Context) async throws {
        try a.noPositional()
        guard let credential = c.store.load(c.base) else { throw Failure.signedOut }
        let api = try c.coach()
        let ping = try await api.ping()
        let target: [String: Any] = ["base": c.base, "email": credential.email as Any, "today": ping.today]
        if a.has("dry-run") {
            Out.success(target.merging(["dry_run": true, "would_delete": true]) { $1 }) {
                Out.line("[dry-run] 将整租户删除 \(credential.email ?? "（未记录邮箱）") @ \(c.base)：学员、课包、课次、审计全部真删。未执行。")
            }
            return
        }
        guard a.value("confirm") == "delete-account" else {
            throw Failure(code: "needs_confirm",
                          message: "注销账号不可恢复：须带字面量 --confirm delete-account（先用 --dry-run 核对目标账号）",
                          exit: .needsConfirm)
        }
        try await api.deleteAccount()
        try c.store.remove(c.base)
        Out.success(target.merging(["deleted": true]) { $1 }) {
            Out.line("已注销 \(credential.email ?? "") @ \(c.base)，本机凭证已删除。")
        }
    }

    // ── 日程 ────────────────────────────────────────────────────────────────

    /// App ScheduleView / 网页 /coach/schedule（GET /coach/api/schedule）。
    static func schedule(_ a: Args, _ c: Context) async throws {
        try a.noPositional()
        var query = ["range": a.value("range") ?? "today"]
        if let date = try dateArg(a, "date") { query["date"] = date }
        let (resp, raw) = try await fetch(try c.coach(), "/coach/api/schedule", query, as: ScheduleResp.self)
        Out.success(raw) {
            Out.line("\(resp.title)（服务端今天 \(resp.today)，现在 \(resp.now)）")
            for w in resp.warnings { Out.line("  ! [\(w.level)] \(w.text)") }
            if resp.days.isEmpty { Out.line("  （没有课）") }
            for day in resp.days {
                Out.line("\(day.date_) \(day.wd_name)")
                for s in day.sessions { Out.line("  " + sessionLine(s)) }
            }
        }
    }

    static func sessionLine(_ s: SessionRow) -> String {
        var parts = ["#\(s.id)", "\(TZ.hm(s.start_at))–\(TZ.hm(s.end_at))", s.student_name, s.status_label]
        if let place = s.location_name { parts.append(place) }
        if !s.content.isEmpty { parts.append(s.content) }
        if s.is_backfilled { parts.append("补录") }
        parts.append("课包 #\(s.package_id)")
        return parts.joined(separator: " · ")
    }

    // ── 学员 ────────────────────────────────────────────────────────────────

    /// App StudentsView（GET /coach/api/students）：在读 rows + 停用 inactive。
    static func studentsList(_ a: Args, _ c: Context) async throws {
        try a.noPositional()
        let (resp, raw) = try await fetch(try c.coach(), "/coach/api/students", as: StudentsResp.self)
        Out.success(raw) {
            Out.line("在读（\(resp.rows.count)）")
            for r in resp.rows { Out.line("  " + studentLine(r)) }
            Out.line("停用（\(resp.inactive.count)）")
            for r in resp.inactive { Out.line("  " + studentLine(r)) }
        }
    }

    static func studentLine(_ r: StudentListRow) -> String {
        var parts = ["#\(r.id) \(r.name)", "可用 \(r.available_total) 节", "可排 \(r.min_bookable)"]
        if r.lapsed_total > 0 { parts.append("已过期 \(r.lapsed_total)") }
        if r.expiring_soon > 0 { parts.append("14 天内到期 \(r.expiring_soon)") }
        parts.append("课包 \(r.n_packages)")
        parts.append(r.has_link != 0 ? "有链接" : "无链接")
        return parts.joined(separator: " · ")
    }

    /// App StudentDetailView（GET /coach/api/students/{id}）。
    static func studentsShow(_ a: Args, _ c: Context) async throws {
        let id = try a.id("学员")
        let (resp, raw) = try await fetch(try c.coach(), "/coach/api/students/\(id)", as: StudentDetailResp.self)
        Out.success(raw) {
            let st = resp.student
            Out.line("#\(st.id) \(st.name)（\(st.is_active != 0 ? "在读" : "停用")，\(st.has_link ? "有链接" : "无链接")）")
            if !st.note.isEmpty { Out.line("备注：\(st.note)") }
            Out.line("合计：可用 \(resp.totals.available_total) · 已过期 \(resp.totals.lapsed_total) · 超用 \(resp.totals.over_used)")
            for bucket in ["active", "lapsed", "exhausted", "voided"] {
                let rows = resp.buckets[bucket] ?? []
                guard !rows.isEmpty else { continue }
                Out.line("\(Vocab.bucketLabels[bucket] ?? bucket)课包：")
                for p in rows {
                    var parts = ["#\(p.package_id)", "共 \(p.total_sessions) 节", "已用 \(p.used)", "剩 \(p.remaining)",
                                 "可排 \(p.bookable)", "购于 \(p.purchased_on)", "到期 \(p.expires_on ?? "不过期")",
                                 "单价 ¥\(Money.yuanShort(p.unit_price_cents))"]
                    if !p.note.isEmpty { parts.append(p.note) }
                    if p.voided_at != nil { parts.append("作废：\(p.void_reason)") }
                    Out.line("  " + parts.joined(separator: " · "))
                }
            }
            Out.line("上课记录（\(resp.sessions.count)）：")
            for s in resp.sessions { Out.line("  \(s.start_at) " + sessionLine(s)) }
        }
    }

    /// GET /coach/api/students/{id}/link。链接本身就是凭证：默认只报 has_link。
    static func studentsLink(_ a: Args, _ c: Context) async throws {
        let id = try a.id("学员")
        let (resp, raw) = try await fetch(try c.coach(), "/coach/api/students/\(id)/link", as: LinkResp.self)
        let reveal = a.has("reveal")
        var payload = raw
        if !reveal { payload.removeValue(forKey: "link_url") }
        payload["student_id"] = id
        Out.success(payload) {
            if reveal, let url = resp.link_url { Out.line(url) }
            else if resp.has_link { Out.line("有链接（加 --reveal 才输出 URL；链接即凭证）") }
            else { Out.line("还没有链接（fitcoach students issue-link \(id)）") }
        }
    }

    /// App StudentsView 新建（POST /coach/api/students，name + note）。
    static func studentsAdd(_ a: Args, _ c: Context) async throws {
        try a.noPositional()
        let name = try a.required("name")
        let (resp, _) = try await send(try c.coach(), "/coach/api/students", ["name": name, "note": a.value("note") ?? ""])
        Out.success(["id": resp.id as Any]) { Out.line("已新建学员 #\(resp.id.map(String.init) ?? "?") \(name)") }
    }

    /// App StudentsView 编辑：先读现值，再整条提交 name / note / is_active（后端缺 is_active = 停用并吊销链接）。
    static func studentsUpdate(_ a: Args, _ c: Context) async throws {
        let id = try a.id("学员")
        try requireSomeChange(a, ["name", "note", "active", "inactive"])
        let api = try c.coach()
        let (current, _) = try await fetch(api, "/coach/api/students/\(id)", as: StudentDetailResp.self)
        let active = try a.choice("active", "inactive") ?? (current.student.is_active != 0)
        let (resp, _) = try await send(api, "/coach/api/students/\(id)", [
            "name": a.value("name") ?? current.student.name,
            "note": a.value("note") ?? current.student.note,
            "is_active": on(active),
        ])
        Out.success(["id": id, "is_active": active, "revoked": resp.revoked ?? false,
                     "warning": resp.warning as Any]) {
            Out.line("已更新学员 #\(id)（\(active ? "在读" : "停用")）")
            if let w = resp.warning { Out.note("注意：\(w)") }
        }
    }

    /// App StudentDetailView.createLink：没有链接才签发；已有时不动，--replace 才换发（旧链接立即失效）。
    static func studentsIssueLink(_ a: Args, _ c: Context) async throws {
        let id = try a.id("学员")
        let api = try c.coach()
        let (current, _) = try await fetch(api, "/coach/api/students/\(id)/link", as: LinkResp.self)
        let reveal = a.has("reveal")
        if current.has_link && !a.has("replace") {
            var payload: [String: Any] = ["student_id": id, "issued": false, "has_link": true]
            if reveal { payload["link_url"] = current.link_url as Any }
            Out.success(payload) {
                if reveal, let url = current.link_url { Out.line(url) }
                else { Out.line("已有链接，未改动（要换发加 --replace，旧链接会立即失效）") }
            }
            return
        }
        let (resp, _) = try await send(api, "/coach/api/students/\(id)/token", ["action": "rotate", "reason": ""])
        var payload: [String: Any] = ["student_id": id, "issued": true, "replaced": current.has_link,
                                      "has_link": resp.link_url != nil]
        if reveal { payload["link_url"] = resp.link_url as Any }
        Out.success(payload) {
            if reveal, let url = resp.link_url { Out.line(url) }
            else { Out.line(current.has_link ? "已换发链接，旧链接已失效（加 --reveal 输出新 URL）" : "已签发链接（加 --reveal 输出 URL）") }
        }
    }

    /// 网页 / 小程序「吊销链接」（POST …/token action=revoke，写审计；理由由后端判必填）。
    static func studentsRevokeLink(_ a: Args, _ c: Context) async throws {
        let id = try a.id("学员")
        _ = try await send(try c.coach(), "/coach/api/students/\(id)/token",
                           ["action": "revoke", "reason": a.value("reason") ?? ""])
        Out.success(["student_id": id, "has_link": false]) { Out.line("已吊销学员 #\(id) 的链接，旧链接立即失效") }
    }

    // ── 课次 ────────────────────────────────────────────────────────────────

    /// App SessionFormView 的选项（GET /coach/api/session-form）。
    static func sessionsOptions(_ a: Args, _ c: Context) async throws {
        try a.noPositional()
        var query: [String: String] = [:]
        if let s = try a.int("student") { query["student_id"] = String(s) }
        if let s = try a.int("session") { query["session_id"] = String(s) }
        if let d = try dateArg(a, "date") { query["date"] = d }
        let (resp, raw) = try await fetch(try c.coach(), "/coach/api/session-form", query, as: SessionFormResp.self)
        Out.success(raw) {
            Out.line("学员：" + resp.students.map { "#\($0.id) \($0.name)" }.joined(separator: " · "))
            if query["student_id"] != nil || query["session_id"] != nil {
                Out.line("课包（FEFO，默认 #\(resp.default_package_id.map(String.init) ?? "无")）：")
                for p in resp.packages {
                    Out.line("  " + p.label + (p.selectable ? "" : " · 不可选"))
                }
            } else {
                Out.line("课包：加 --student ID 才列出")
            }
            Out.line("地点：" + resp.locations.map { "#\($0.id) \($0.name)" }.joined(separator: " · "))
            let windows = resp.windows.map { $0.joined(separator: "–") }.joined(separator: " ")
            Out.line("当天可排：" + (windows.isEmpty ? (resp.windows_reason ?? "无") : windows))
        }
    }

    /// 课次详情 + 这一节的变更记录（网页 session 编辑页的 audit_for_session；JSON 面没有单独端点，
    /// 这里从 /coach/api/audit?all=1&student_id= 按 entity=session、entity_id 筛）。
    static func sessionsShow(_ a: Args, _ c: Context) async throws {
        let id = try a.id("课次")
        let api = try c.coach()
        let (form, formRaw) = try await fetch(api, "/coach/api/session-form", ["session_id": String(id)], as: SessionFormResp.self)
        guard let session = form.session else { throw Failure.notFound }
        let (audit, auditRaw) = try await fetch(api, "/coach/api/audit",
                                                ["all": "1", "student_id": String(session.student_id)], as: AuditResp.self)
        let rawRows = auditRaw["rows"] as? [[String: Any]] ?? []
        let history = rawRows.filter { ($0["entity"] as? String) == "session" && ($0["entity_id"] as? Int) == id }
        let complete = audit.rows.count < auditRowCap
        Out.success(["session": formRaw["session"] as Any, "history": history, "history_complete": complete]) {
            Out.line(sessionLine(session))
            Out.line("\(session.start_at) – \(session.end_at)（\(session.duration_min) 分钟），创建于 \(session.created_at)")
            let rows = audit.rows.filter { $0.entity == "session" && $0.entity_id == id }
            Out.line("变更记录（\(rows.count)\(complete ? "" : "，可能不全")）：")
            for r in rows { Out.line("  " + auditLine(r)) }
        }
    }

    /// App SessionFormView 新建（POST /coach/api/sessions）。409 软警告 → 退出 5，确认后 --force；400 硬拒 → 退出 4。
    static func sessionsAdd(_ a: Args, _ c: Context) async throws {
        try a.noPositional()
        let package = try a.requiredInt("package")
        let start = try stamp(try a.required("start"), "start")
        let end: String
        switch (a.value("end"), try positiveMinutes(a)) {
        case let (raw?, nil): end = try endStamp(raw, start: start)
        case let (nil, minutes?): end = addMinutes(start, minutes)
        case (nil, nil): throw Failure.usage("缺少 --end HH:MM 或 --minutes N")
        default: throw Failure.usage("--end 与 --minutes 只能给一个")
        }
        var fields = [
            "package_id": String(package), "start_at": start, "end_at": end,
            "location_id": try a.int("location").map(String.init) ?? "",
            "content": a.value("content") ?? "",
            "status": try statusArg(a, required: false) ?? "scheduled",
            "reason": a.value("reason") ?? "",
            "reason_code": try reasonCodeArg(a),
        ]
        if a.has("force") { fields["force"] = "on" }
        let (resp, _) = try await send(try c.coach(), "/coach/api/sessions", fields)
        Out.success(["id": resp.id as Any, "start_at": start, "end_at": end,
                     "warnings": encodable(resp.warnings ?? [])]) {
            Out.line("已排课 #\(resp.id.map(String.init) ?? "?") \(start)–\(TZ.hm(end))")
            warningsText(resp.warnings)
        }
    }

    /// App SessionFormView 改课（POST /coach/api/sessions/{id}）：先读现值再整条提交
    /// （后端缺 location_id = 清空地点、缺 content = 清空内容）。本端点不改状态。
    static func sessionsEdit(_ a: Args, _ c: Context) async throws {
        let id = try a.id("课次")
        try requireSomeChange(a, ["package", "start", "end", "minutes", "location", "no-location", "content"])
        if a.value("location") != nil && a.has("no-location") {
            throw Failure.usage("--location 与 --no-location 只能给一个")
        }
        let api = try c.coach()
        let (form, _) = try await fetch(api, "/coach/api/session-form", ["session_id": String(id)], as: SessionFormResp.self)
        guard let cur = form.session else { throw Failure.notFound }
        let start = try a.value("start").map { try stamp($0, "start") } ?? cur.start_at
        let end: String
        switch (a.value("end"), try positiveMinutes(a)) {
        case let (raw?, nil): end = try endStamp(raw, start: start)
        case let (nil, minutes?): end = addMinutes(start, minutes)
        case (nil, nil): end = a.value("start") == nil ? cur.end_at : addMinutes(start, cur.duration_min)
        default: throw Failure.usage("--end 与 --minutes 只能给一个")
        }
        let location: String
        if a.has("no-location") { location = "" }
        else if let l = try a.int("location") { location = String(l) }
        else { location = cur.location_id.map(String.init) ?? "" }
        var fields = [
            "package_id": String(try a.int("package") ?? cur.package_id),
            "start_at": start, "end_at": end, "location_id": location,
            "content": a.value("content") ?? cur.content,
            "reason": a.value("reason") ?? "",
        ]
        if a.has("force") { fields["force"] = "on" }
        let (resp, _) = try await send(api, "/coach/api/sessions/\(id)", fields)
        Out.success(["id": id, "start_at": start, "end_at": end, "warnings": encodable(resp.warnings ?? [])]) {
            Out.line("已改课 #\(id) \(start)–\(TZ.hm(end))")
            warningsText(resp.warnings)
        }
    }

    /// App ScheduleView StatusSheet（POST /coach/api/sessions/{id}/status）：扣课时、未到、取消、改回已排。
    static func sessionsStatus(_ a: Args, _ c: Context) async throws {
        let id = try a.id("课次")
        let to = try statusArg(a, required: true)!
        _ = try await send(try c.coach(), "/coach/api/sessions/\(id)/status", [
            "to": to, "reason": a.value("reason") ?? "", "reason_code": try reasonCodeArg(a),
            "force": on(a.has("force")),
        ])
        Out.success(["id": id, "status": to]) { Out.line("课次 #\(id) → \(Vocab.statusLabels[to] ?? to)") }
    }

    // ── 课包 ────────────────────────────────────────────────────────────────

    /// App PackageFormView 新建（POST /coach/api/packages）。
    static func packagesAdd(_ a: Args, _ c: Context) async throws {
        try a.noPositional()
        let fields = [
            "student_id": String(try a.requiredInt("student")),
            "total_sessions": String(try a.requiredInt("total")),
            "unit_price_yuan": a.value("price-yuan") ?? "",
            "purchased_on": try dateArg(a, "purchased") ?? TZ.dateString(Date()),
            "expires_on": try dateArg(a, "expires") ?? "",
            "note": a.value("note") ?? "",
        ]
        let (resp, _) = try await send(try c.coach(), "/coach/api/packages", fields)
        Out.success(["id": resp.id as Any]) { Out.line("已新建课包 #\(resp.id.map(String.init) ?? "?")") }
    }

    /// 在学员详情的课包三桶里找这个课包（给了 --student 只查那一位，否则逐个学员查）。
    static func findPackage(_ api: API, _ id: Int, student: Int?) async throws -> PackageRow {
        var ids: [Int] = []
        if let student { ids = [student] } else {
            let (list, _) = try await fetch(api, "/coach/api/students", as: StudentsResp.self)
            ids = (list.rows + list.inactive).map(\.id)
        }
        for sid in ids {
            let (detail, _) = try await fetch(api, "/coach/api/students/\(sid)", as: StudentDetailResp.self)
            if let hit = detail.buckets.values.joined().first(where: { $0.package_id == id }) { return hit }
        }
        throw Failure.notFound
    }

    /// App PackageFormView 编辑（POST /coach/api/packages/{id}）：先读现值再整条提交
    /// （后端缺 expires_on = 取消到期、缺单价 = 0、缺备注 = 清空）。改节数 / 到期日的理由由后端判必填。
    static func packagesEdit(_ a: Args, _ c: Context) async throws {
        let id = try a.id("课包")
        try requireSomeChange(a, ["total", "price-yuan", "purchased", "expires", "no-expiry", "note"])
        if a.value("expires") != nil && a.has("no-expiry") {
            throw Failure.usage("--expires 与 --no-expiry 只能给一个")
        }
        let api = try c.coach()
        let cur = try await findPackage(api, id, student: try a.int("student"))
        let expires: String
        if a.has("no-expiry") { expires = "" }
        else { expires = try dateArg(a, "expires") ?? cur.expires_on ?? "" }
        let (resp, _) = try await send(api, "/coach/api/packages/\(id)", [
            "total_sessions": String(try a.int("total") ?? cur.total_sessions),
            "unit_price_yuan": a.value("price-yuan") ?? Money.yuan(cur.unit_price_cents),
            "purchased_on": try dateArg(a, "purchased") ?? cur.purchased_on,
            "expires_on": expires,
            "note": a.value("note") ?? cur.note,
            "reason": a.value("reason") ?? "",
            "reason_code": try reasonCodeArg(a),
        ])
        Out.success(["id": id, "student_id": cur.student_id, "warnings": encodable(resp.warnings ?? [])]) {
            Out.line("已修改课包 #\(id)")
            warningsText(resp.warnings)
        }
    }

    /// App PackageFormView 作废 / 撤销作废（POST …/void）。作废会一并取消包内已排的课，撤销作废不会把它们排回来，
    /// 所以作废与 App 的作废页一样要显式确认：--yes；--dry-run 只读出课包与将被取消的已排节数。
    static func packagesVoid(_ a: Args, _ c: Context) async throws {
        let id = try a.id("课包")
        let undo = a.has("undo")
        let api = try c.coach()
        if a.has("dry-run") {
            let cur = try await findPackage(api, id, student: try a.int("student"))
            let voiding = !undo
            let wouldCancel = voiding && cur.voided_at == nil ? cur.booked : 0
            Out.success(["dry_run": true, "id": id, "student_id": cur.student_id, "action": voiding ? "void" : "unvoid",
                         "already_voided": cur.voided_at != nil, "would_cancel": wouldCancel,
                         "bucket": cur.bucket, "remaining": cur.remaining]) {
                if voiding {
                    Out.line(cur.voided_at != nil ? "[dry-run] 课包 #\(id) 已作废，无事可做。未执行。"
                             : "[dry-run] 作废课包 #\(id)（学员 #\(cur.student_id)）会一并取消 \(wouldCancel) 节已排课，撤销作废也不会排回来。未执行。")
                } else {
                    Out.line("[dry-run] 撤销作废课包 #\(id)（学员 #\(cur.student_id)）；被取消的课不会自动恢复。未执行。")
                }
            }
            return
        }
        if !undo && !a.has("yes") {
            throw Failure(code: "needs_confirm",
                          message: "作废会一并取消包内已排的课，撤销作废也不会排回来：确认无误后加 --yes（可先用 --dry-run 看会取消几节）",
                          exit: .needsConfirm)
        }
        let (resp, _) = try await send(api, "/coach/api/packages/\(id)/void", [
            "action": undo ? "unvoid" : "void",
            "reason": a.value("reason") ?? "", "reason_code": try reasonCodeArg(a),
        ])
        Out.success(["id": id, "voided": !undo, "cancelled": resp.cancelled ?? 0, "warning": resp.warning as Any]) {
            Out.line(undo ? "已撤销作废课包 #\(id)（被取消的课不会自动恢复）" : "已作废课包 #\(id)")
            if let w = resp.warning { Out.note("注意：\(w)") }
        }
    }

    // ── 地点 ────────────────────────────────────────────────────────────────

    static func locationsList(_ a: Args, _ c: Context) async throws {
        try a.noPositional()
        let (resp, raw) = try await fetch(try c.coach(), "/coach/api/locations", as: LocationsResp.self)
        Out.success(raw) {
            if resp.locations.isEmpty { Out.line("（还没有地点）") }
            for l in resp.locations {
                Out.line("#\(l.id) \(l.name)\(l.address.isEmpty ? "" : " · \(l.address)")\(l.is_active != 0 ? "" : " · 停用")")
            }
        }
    }

    static func locationsAdd(_ a: Args, _ c: Context) async throws {
        try a.noPositional()
        let name = try a.required("name")
        let (resp, _) = try await send(try c.coach(), "/coach/api/locations",
                                       ["name": name, "address": a.value("address") ?? ""])
        Out.success(["id": resp.id as Any]) { Out.line("已新建地点 #\(resp.id.map(String.init) ?? "?") \(name)") }
    }

    /// App LocationsView 编辑：先读现值再整条提交（后端缺 address = 清空，缺 is_active = 停用）。
    static func locationsUpdate(_ a: Args, _ c: Context) async throws {
        let id = try a.id("地点")
        try requireSomeChange(a, ["name", "address", "active", "inactive"])
        let api = try c.coach()
        let (list, _) = try await fetch(api, "/coach/api/locations", as: LocationsResp.self)
        guard let cur = list.locations.first(where: { $0.id == id }) else { throw Failure.notFound }
        let active = try a.choice("active", "inactive") ?? (cur.is_active != 0)
        _ = try await send(api, "/coach/api/locations/\(id)", [
            "name": a.value("name") ?? cur.name, "address": a.value("address") ?? cur.address,
            "is_active": on(active),
        ])
        Out.success(["id": id, "is_active": active]) { Out.line("已更新地点 #\(id)（\(active ? "启用" : "停用")）") }
    }

    // ── 档期 ────────────────────────────────────────────────────────────────

    static func availabilityShow(_ a: Args, _ c: Context) async throws {
        try a.noPositional()
        let (resp, raw) = try await fetch(try c.coach(), "/coach/api/availability", as: AvailabilityResp.self)
        Out.success(raw) {
            Out.line("每周规则：")
            for wd in 0..<7 {
                let rules = resp.rules_by_wd[String(wd)] ?? []
                guard !rules.isEmpty else { continue }
                let name = wd < resp.wd_names.count ? resp.wd_names[wd] : String(wd)
                Out.line("  \(name)（\(wd)）：" + rules.map { "#\($0.id) \($0.start_time)–\($0.end_time)" }.joined(separator: " · "))
            }
            Out.line("例外：\(resp.exceptions.isEmpty ? "无" : "")")
            for e in resp.exceptions {
                let span = e.start_time.map { "\($0)–\(e.end_time ?? "")" } ?? "整天"
                Out.line("  #\(e.id) \(e.on_date) \(e.kind == "open" ? "加开" : "停排") \(span)\(e.reason.isEmpty ? "" : " · \(e.reason)")")
            }
            Out.line("未来两周可排：")
            for d in resp.preview {
                let windows = d.windows.map { $0.joined(separator: "–") }.joined(separator: " ")
                Out.line("  \(d.date_) \(d.wd_name) " + (windows.isEmpty ? (d.empty_reason ?? "无") : windows))
            }
        }
    }

    /// App AvailabilityView 新增每周规则（weekday 0 = 周日，与后端 strftime %w 一致）。
    static func availabilityAddRule(_ a: Args, _ c: Context) async throws {
        try a.noPositional()
        let weekday = try a.requiredInt("weekday")
        guard let start = try timeArg(a, "start"), let end = try timeArg(a, "end") else {
            throw Failure.usage("缺少 --start HH:MM 或 --end HH:MM")
        }
        let (resp, _) = try await send(try c.coach(), "/coach/api/availability/rules",
                                       ["weekday": String(weekday), "start_time": start, "end_time": end])
        Out.success(["id": resp.id as Any]) { Out.line("已新增每周规则 #\(resp.id.map(String.init) ?? "?")") }
    }

    /// 删除每周规则。档期不写审计，所以先把被删的那条读出来一并输出，便于重建。
    static func availabilityRemoveRule(_ a: Args, _ c: Context) async throws {
        let id = try a.id("规则")
        let api = try c.coach()
        let (_, raw) = try await fetch(api, "/coach/api/availability", as: AvailabilityResp.self)
        let rules = (raw["rules_by_wd"] as? [String: [[String: Any]]] ?? [:]).values.joined()
        let deleted = rules.first { ($0["id"] as? Int) == id }
        _ = try await send(api, "/coach/api/availability/rules/\(id)/delete", [:])
        Out.success(["id": id, "deleted": deleted as Any]) { Out.line("已删除每周规则 #\(id)") }
    }

    static func availabilityAddException(_ a: Args, _ c: Context) async throws {
        try a.noPositional()
        guard let date = try dateArg(a, "date") else { throw Failure.usage("缺少 --date YYYY-MM-DD") }
        let kind = try a.required("kind")
        let (resp, _) = try await send(try c.coach(), "/coach/api/availability/exceptions", [
            "on_date": date, "kind": kind,
            "start_time": try timeArg(a, "start") ?? "", "end_time": try timeArg(a, "end") ?? "",
            "reason": a.value("reason") ?? "",
        ])
        Out.success(["id": resp.id as Any]) { Out.line("已新增例外 #\(resp.id.map(String.init) ?? "?") \(date) \(kind)") }
    }

    static func availabilityRemoveException(_ a: Args, _ c: Context) async throws {
        let id = try a.id("例外")
        let api = try c.coach()
        let (_, raw) = try await fetch(api, "/coach/api/availability", as: AvailabilityResp.self)
        let deleted = (raw["exceptions"] as? [[String: Any]] ?? []).first { ($0["id"] as? Int) == id }
        _ = try await send(api, "/coach/api/availability/exceptions/\(id)/delete", [:])
        Out.success(["id": id, "deleted": deleted as Any]) { Out.line("已删除例外 #\(id)") }
    }

    // ── 体测项目 / 成长 / 测量 ──────────────────────────────────────────────

    static func metricsList(_ a: Args, _ c: Context) async throws {
        try a.noPositional()
        let (resp, raw) = try await fetch(try c.coach(), "/coach/api/metrics", as: MetricsResp.self)
        Out.success(raw) {
            if resp.metrics.isEmpty { Out.line("（还没有体测项目：fitcoach metrics seed 导入常用项目）") }
            for m in resp.metrics {
                Out.line("#\(m.id) \(m.name)\(m.unit.isEmpty ? "" : "（\(m.unit)）") · \(m.higher_is_better != 0 ? "越大越好" : "越小越好") · 排序 \(m.sort_order)\(m.is_active != 0 ? "" : " · 停用")")
            }
        }
    }

    /// App MetricsView 新建：方向必须显式二选一（写反会把进步报成退步），不给默认值。
    static func metricsAdd(_ a: Args, _ c: Context) async throws {
        try a.noPositional()
        let name = try a.required("name")
        guard let higher = try a.choice("higher-is-better", "lower-is-better") else {
            throw Failure.usage("须显式给出方向：--higher-is-better 或 --lower-is-better")
        }
        let (resp, _) = try await send(try c.coach(), "/coach/api/metrics", [
            "name": name, "unit": a.value("unit") ?? "", "higher_is_better": direction(higher),
            "sort_order": String(try a.int("sort") ?? 0),
        ])
        Out.success(["id": resp.id as Any]) { Out.line("已新建体测项目 #\(resp.id.map(String.init) ?? "?") \(name)") }
    }

    /// App MetricsView 编辑：先读现值再整条提交（后端缺方向 = 越小越好、缺排序 = 0、缺 is_active = 停用）。
    static func metricsUpdate(_ a: Args, _ c: Context) async throws {
        let id = try a.id("项目")
        try requireSomeChange(a, ["name", "unit", "sort", "higher-is-better", "lower-is-better", "active", "inactive"])
        let api = try c.coach()
        let (list, _) = try await fetch(api, "/coach/api/metrics", as: MetricsResp.self)
        guard let cur = list.metrics.first(where: { $0.id == id }) else { throw Failure.notFound }
        let higher = try a.choice("higher-is-better", "lower-is-better") ?? (cur.higher_is_better != 0)
        let active = try a.choice("active", "inactive") ?? (cur.is_active != 0)
        _ = try await send(api, "/coach/api/metrics/\(id)", [
            "name": a.value("name") ?? cur.name, "unit": a.value("unit") ?? cur.unit,
            "higher_is_better": direction(higher), "sort_order": String(try a.int("sort") ?? cur.sort_order),
            "is_active": on(active),
        ])
        Out.success(["id": id, "higher_is_better": higher, "is_active": active]) {
            Out.line("已更新体测项目 #\(id)（\(higher ? "越大越好" : "越小越好")，\(active ? "启用" : "停用")）")
        }
    }

    /// App MetricsView / GrowthView「导入常用项目」（只在一个都没有时生效）。
    static func metricsSeed(_ a: Args, _ c: Context) async throws {
        try a.noPositional()
        let (resp, _) = try await send(try c.coach(), "/coach/api/metrics/seed", [:])
        Out.success(["created": resp.created ?? 0]) {
            Out.line((resp.created ?? 0) > 0 ? "已导入 \(resp.created ?? 0) 个常用项目" : "已有体测项目，未导入")
        }
    }

    /// App 学员页「成长」（GET /coach/api/students/{id}/growth）。--metric 是本地筛选，后端不收这个参数。
    static func growth(_ a: Args, _ c: Context) async throws {
        let id = try a.id("学员")
        let (resp, raw) = try await fetch(try c.coach(), "/coach/api/students/\(id)/growth", as: GrowthResp.self)
        var payload = raw
        var progress = resp.progress
        if let metric = try a.int("metric") {
            let keep = { (row: Any) in ((row as? [String: Any])?["metric_id"] as? Int) == metric }
            payload["metrics"] = (raw["metrics"] as? [Any] ?? []).filter { ($0 as? [String: Any])?["id"] as? Int == metric }
            payload["progress"] = (raw["progress"] as? [Any] ?? []).filter(keep)
            payload["measurements"] = (raw["measurements"] as? [Any] ?? []).filter(keep)
            payload["series"] = (raw["series"] as? [String: Any] ?? [:]).filter { $0.key == String(metric) }
            payload["metric_filter"] = metric
            progress = progress.filter { $0.metric_id == metric }
        }
        Out.success(payload) {
            let att = resp.attendance
            Out.line("到课：共 \(att.total) · 上课 \(att.completed) · 未到 \(att.no_show) · 取消 \(att.cancelled) · 到课率 \(att.rate)%")
            if progress.isEmpty { Out.line("（还没有测量）") }
            for p in progress {
                let verdict = p.improved.map { $0 ? "进步" : "退步/持平" } ?? "只测过一次"
                let pct = p.pct.map { String(format: "（%+.1f%%）", $0) } ?? ""
                Out.line("#\(p.metric_id) \(p.name)：首测 \(number(p.first_value))\(p.unit)（\(p.first_on)）→ 最新 \(number(p.latest_value))\(p.unit)（\(p.latest_on)）· 最好 \(number(p.best_value)) · 变化 \(number(p.delta))\(pct) · \(verdict) · \(p.n_points) 次")
            }
        }
    }

    /// App GrowthView 记录测量（同一学员同一项目同一天 = 覆盖）。数值合法性由后端判，空值不当 0。
    static func measurementsAdd(_ a: Args, _ c: Context) async throws {
        try a.noPositional()
        let student = try a.requiredInt("student")
        let (resp, _) = try await send(try c.coach(), "/coach/api/students/\(student)/measurements", [
            "metric_id": String(try a.requiredInt("metric")),
            "taken_on": try dateArg(a, "date") ?? TZ.dateString(Date()),
            "value": try a.required("value").trimmingCharacters(in: .whitespaces),
            "note": a.value("note") ?? "",
        ])
        Out.success(["id": resp.id as Any]) { Out.line("已记录测量 #\(resp.id.map(String.init) ?? "?")") }
    }

    /// 在学员成长数据里找这条测量（给了 --student 只查那一位，否则逐个学员查）。只读。
    static func findMeasurement(_ api: API, _ id: Int, student: Int?) async throws -> Measurement {
        var ids: [Int] = []
        if let student { ids = [student] } else {
            let (list, _) = try await fetch(api, "/coach/api/students", as: StudentsResp.self)
            ids = (list.rows + list.inactive).map(\.id)
        }
        for sid in ids {
            let (growth, _) = try await fetch(api, "/coach/api/students/\(sid)/growth", as: GrowthResp.self)
            if let hit = growth.measurements.first(where: { $0.id == id }) { return hit }
        }
        throw Failure.notFound
    }

    /// App GrowthView 删除测量（先弹「删除这条测量？」）：命令行同样要显式 --yes；--dry-run 只读出这条测量。
    static func measurementsRemove(_ a: Args, _ c: Context) async throws {
        let id = try a.id("测量")
        let api = try c.coach()
        if a.has("dry-run") {
            let m = try await findMeasurement(api, id, student: try a.int("student"))
            Out.success(["dry_run": true, "id": id, "would_delete": encodable(m)]) {
                Out.line("[dry-run] 将删除测量 #\(id)：学员 #\(m.student_id) · \(m.metric_name) \(number(m.value))\(m.unit)（\(m.taken_on)）。未执行。")
            }
            return
        }
        guard a.has("yes") else {
            throw Failure(code: "needs_confirm",
                          message: "删除测量不可恢复：确认无误后加 --yes（可先用 --dry-run 看是哪一条）",
                          exit: .needsConfirm)
        }
        _ = try await send(api, "/coach/api/measurements/\(id)/delete", [:])
        Out.success(["id": id]) { Out.line("已删除测量 #\(id)") }
    }

    // ── 变更记录 ────────────────────────────────────────────────────────────

    /// 后端 domain.list_audit 每次最多返回的行数（无分页）。
    static let auditRowCap = 300

    /// App AuditView（GET /coach/api/audit）：默认只列纠错 / 通融 / 补录，--all 全部。
    static func audit(_ a: Args, _ c: Context) async throws {
        try a.noPositional()
        var query: [String: String] = [:]
        if a.has("all") { query["all"] = "1" }
        if let s = try a.int("student") { query["student_id"] = String(s) }
        let (resp, raw) = try await fetch(try c.coach(), "/coach/api/audit", query, as: AuditResp.self)
        var payload = raw
        payload["capped"] = resp.rows.count >= auditRowCap
        Out.success(payload) {
            Out.line("\(resp.show_all ? "全部变更" : "纠错 / 通融 / 补录")（\(resp.rows.count) 条\(resp.rows.count >= auditRowCap ? "，已到上限可能被截断" : "")）")
            for r in resp.rows { Out.line("  " + auditLine(r)) }
        }
    }

    static func auditLine(_ r: AuditRow) -> String {
        var parts = ["#\(r.id) \(r.at)", r.kind, "\(r.entity)#\(r.entity_id).\(r.field)",
                     "\(r.old_value ?? "∅") → \(r.new_value ?? "∅")"]
        if let name = r.student_name { parts.append(name) }
        if let code = r.reason_code { parts.append(Vocab.reasonLabel(code)) }
        if !r.reason.isEmpty { parts.append(r.reason) }
        if r.delta != 0 { parts.append("余额 \(r.delta > 0 ? "+" : "")\(r.delta)") }
        return parts.joined(separator: " · ")
    }

    // ── 学员端 ──────────────────────────────────────────────────────────────

    /// App 学员模式 / 网页 /s/<口令>（GET /s/api/view，X-Student-Token）。口令只从 stdin 读。
    static func studentView(_ a: Args, _ c: Context) async throws {
        try a.noPositional()
        let token = Session.extractToken(try secret(a, flag: "token-stdin", prompt: "学员链接或口令："))
        guard !token.isEmpty else { throw Failure.usage("没读到学员口令") }
        let api = API(Session(baseURL: c.base), studentToken: token)
        let data: Data
        do { data = try await api.getRaw("/s/api/view", student: true) }
        catch APIError.gone {
            throw Failure(code: "link_invalid", message: "学员链接无效或已吊销", exit: .signedOut)
        }
        let view: StudentView
        do { view = try JSONDecoder().decode(StudentView.self, from: data) }
        catch { throw APIError.decode("/s/api/view：\(error)") }
        Out.success(try jsonDictionary(data)) {
            Out.line("\(view.student_name)：可用 \(view.available_total) 节 · 已过期 \(view.lapsed_total) · 超用 \(view.over_used)")
            if let next = view.next_session {
                Out.line("下一节：\(next.start_at)–\(TZ.hm(next.end_at))\(next.location_name.map { " · \($0)" } ?? "")")
            } else { Out.line("下一节：无") }
            Out.line("上课记录 \(view.history.count) 条 · 即将取消 \(view.upcoming_cancelled.count) 条 · 成长项目 \(view.growth.count) 个")
        }
    }

    // ── 快速开始 ────────────────────────────────────────────────────────────

    /// 与 App「快速开始」同一份编排（Sources/QuickSetup.swift）：只补空白，可重复运行。
    static func setup(_ a: Args, _ c: Context) async throws {
        try a.noPositional()
        let location = (a.value("location") ?? "健身房").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !location.isEmpty else { throw Failure.usage("--location 不能为空") }
        let daysRaw = a.value("days") ?? QuickSetup.Days.weekdays.rawValue
        guard let days = QuickSetup.Days(rawValue: daysRaw) else {
            throw Failure.usage("--days 只能是 \(QuickSetup.Days.allCases.map(\.rawValue).joined(separator: " | "))：\(daysRaw)")
        }
        let outcome = try await QuickSetup.run(api: try c.coach(), location: location, weekdays: days.weekdays)
        var payload = encodable(outcome, snakeCase: true) as? [String: Any] ?? [:]
        payload["days"] = days.rawValue
        payload["created_location_id"] = outcome.createdLocationId as Any   // 没新建时显式 null，形状稳定
        Out.success(payload) {
            Out.line(outcome.createdLocationId.map { "新建地点 #\($0) \(location)" } ?? "已有地点，未新建")
            Out.line(outcome.seededMetrics > 0 ? "导入 \(outcome.seededMetrics) 个常用体测项目" : "已有体测项目，未导入")
            if outcome.keptExistingAvailability { Out.line("已有自配档期，保持原样") }
            else { Out.line(outcome.addedWeekdays.isEmpty ? "档期已齐，未新增" : "新增档期（星期 \(outcome.addedWeekdays.map(String.init).joined(separator: ","))）09:00–18:00") }
        }
    }
}
