// 契约对账 harness —— **复用 app 自己的 Sources/Models.swift + Sources/API.swift**，
// 不另写一份「我以为后端长这样」的解析器（铁律 #2：验证必须走生产的同一构造路径）。
//
// 跑法见 ./run。任一断言不过即非零退出，不打印「大致没问题」。
import Foundation
import Combine

let base = ProcessInfo.processInfo.environment["FC_BASE"] ?? "http://127.0.0.1:8799"
let email = ProcessInfo.processInfo.environment["FC_EMAIL"] ?? "t@e.com"
let pass = ProcessInfo.processInfo.environment["FC_PASS"] ?? "Passw0rd!234"

/// 学员端公开面的**放宽探针**：只在 harness 里用，故意比 Sources/Models.swift 的
/// StudentGrowthView 宽一格（多一个可选的 note）。作用是让「后端有没有多发字段」
/// 变成一条会红的断言 —— 拿窄模型去编码再 grep 是恒真的，验不出任何东西。
struct StudentGrowthProbe: Codable {
    let name: String
    let unit: String?
    let note: String?
}
struct StudentViewProbe: Codable {
    let growth: [StudentGrowthProbe]
}

var failures: [String] = []
var checks = 0

func ok(_ name: String, _ cond: Bool, _ detail: String = "") {
    checks += 1
    if cond { print("  ✅ \(name)") }
    else { print("  ❌ \(name) \(detail)"); failures.append(name) }
}

@MainActor
func runContract() async {
    let s = Session()
    s.baseURL = base
    let api = API(s)

    print("── 登录 ──")
    do {
        s.coachCookie = try await api.login(email: email, password: pass)
        ok("POST /api/login 返回 cookie 值", s.coachCookie?.isEmpty == false)
    } catch { ok("登录", false, "\(error)"); report(); return }

    do {
        let p = try await api.ping()
        ok("GET /coach/api/ping 带 Cookie 头能过闸", p.ok)
    } catch { ok("ping", false, "\(error)") }

    // 未带凭证必须是 404（不是 401/403）—— 后端刻意不区分「未过闸」与「不存在」
    do {
        let anon = Session(); anon.baseURL = base; anon.coachCookie = nil
        let _: ScheduleResp = try await API(anon).get("/coach/api/schedule")
        ok("无凭证访问 /coach/api/* 应 404", false, "竟然成功了")
    } catch APIError.gone { ok("无凭证访问 /coach/api/* → 404", true) }
    catch { ok("无凭证访问 /coach/api/*", false, "\(error)") }

    print("── 注册 / 注销（App Store 5.1.1(v) 那两条）──")
    do {
        let tmp = Session(); tmp.baseURL = base
        let tapi = API(tmp)
        let stamp = Int(Date().timeIntervalSince1970)
        tmp.coachCookie = try await tapi.register(email: "probe\(stamp)@e.com",
                                                  password: "Passw0rd!234", displayName: "探针")
        ok("POST /api/register 返回 cookie 值", tmp.coachCookie?.isEmpty == false)
        ok("  注册即登录：ping 过闸", try await tapi.ping().ok)
        do {
            _ = try await tapi.register(email: "probe\(stamp)@e.com", password: "Passw0rd!234", displayName: "")
            ok("  重复注册应 400", false, "竟然成功了")
        } catch APIError.rejected { ok("  重复注册 → 400", true) }
        do {
            try await tapi.deleteAccount(password: "wrongwrongwrong")
            ok("  错密码注销应 400", false, "竟然删了")
        } catch APIError.rejected { ok("  错密码注销 → 400", true) }
        ok("  错密码后账号仍在", try await tapi.ping().ok)
        try await tapi.deleteAccount()
        ok("POST /coach/api/account/delete 成功", true)
        do { _ = try await tapi.ping(); ok("  删号后旧 cookie 应 404", false, "竟然还能过") }
        catch APIError.gone { ok("  删号后旧 cookie → 404", true) }
        do { _ = try await tapi.login(email: "probe\(stamp)@e.com", password: "Passw0rd!234")
             ok("  删号后登录应 401", false, "竟然登上了") }
        catch APIError.unauthorized { ok("  删号后登录 → 401", true) }
    } catch { ok("注册/注销链", false, "\(error)") }

    print("── 建数据（走 app 真实写路径）──")
    var locId = 0, stuId = 0, pkgId = 0, sesId = 0
    do {
        locId = try await api.post("/coach/api/locations",
                                   ["name": "城西店", "address": "城西路 128 号"]).id ?? 0
        ok("POST /coach/api/locations", locId > 0)
        stuId = try await api.post("/coach/api/students",
                                   ["name": "张三", "note": "测试"]).id ?? 0
        ok("POST /coach/api/students", stuId > 0)
        pkgId = try await api.post("/coach/api/packages", [
            "student_id": String(stuId), "total_sessions": "10",
            "unit_price_yuan": "300", "purchased_on": TZ.dateString(Date()),
            "expires_on": "", "note": "",
        ]).id ?? 0
        ok("POST /coach/api/packages", pkgId > 0)
    } catch { ok("建基础数据", false, "\(error)") }

    print("── 排课表单与写路径 ──")
    do {
        let f: SessionFormResp = try await api.get(
            "/coach/api/session-form", query: ["student_id": String(stuId)])
        ok("GET /coach/api/session-form 解码", true)
        ok("  课包 picker 非空", !f.packages.isEmpty)
        ok("  default_package_id 指向刚建的包", f.default_package_id == pkgId,
           "got \(String(describing: f.default_package_id))")
        ok("  locations 含刚建的地点", f.locations.contains { $0.id == locId })
    } catch { ok("session-form", false, "\(error)") }

    // ⚠ 排在**昨天**，不是今天。
    // 后端硬拒「把未来的课记成已上/未到」（force 也不放行），而「今天 10:00」在
    // 凌晨跑的时候仍是未来 —— 2026-08-28 00:34 实测，这条 harness 半夜必红，
    // 白天必绿。用相对当下的固定过去时刻，任何时刻跑结论都一样。
    let d = TZ.dateString(TZ.calendar.date(byAdding: .day, value: -1, to: Date())!)
    do {
        // 无档期规则时排课会有 no_availability 软警告 → 409（可 force）
        do {
            _ = try await api.post("/coach/api/sessions", [
                "package_id": String(pkgId), "start_at": "\(d) 10:00",
                "end_at": "\(d) 11:00", "location_id": String(locId),
                "content": "自由重量", "status": "scheduled",
            ])
            ok("软警告走 409（本轮无警告，跳过）", true)
        } catch APIError.needsForce(let w) {
            ok("软警告 → 409 needsForce", true, w.map(\.message).joined())
            ok("  409 的 warnings 全部 blocking=false",
               w.allSatisfy { !$0.blocking })
        }
        let r = try await api.post("/coach/api/sessions", [
            "package_id": String(pkgId), "start_at": "\(d) 10:00",
            "end_at": "\(d) 11:00", "location_id": String(locId),
            "content": "自由重量", "status": "scheduled", "force": "on",
        ])
        sesId = r.id ?? 0
        ok("force=on 后建课成功", sesId > 0)
    } catch { ok("建课", false, "\(error)") }

    // 硬拒必须是 400 而不是 409 —— 把它当成「可 force 重试」会让教练进死循环
    do {
        let future = TZ.dateString(TZ.calendar.date(byAdding: .day, value: 7, to: Date())!)
        _ = try await api.post("/coach/api/sessions", [
            "package_id": String(pkgId), "start_at": "\(future) 10:00",
            "end_at": "\(future) 11:00", "status": "completed", "force": "on",
        ])
        ok("未来时间标已上课应被硬拒", false, "竟然成功了")
    } catch APIError.rejected(let m) { ok("硬拒 → 400 rejected", true, m) }
    catch APIError.needsForce { ok("硬拒不该走 409", false) }
    catch { ok("硬拒", false, "\(error)") }

    print("── 读端点逐个解码 ──")
    do {
        let sch: ScheduleResp = try await api.get(
            "/coach/api/schedule", query: ["range": "today", "date": d])
        ok("GET schedule 解码", true)
        ok("  指定那天能看到刚排的课", sch.days.contains { $0.sessions.contains { $0.id == sesId } })
        let stus: StudentsResp = try await api.get("/coach/api/students")
        ok("GET students 解码", stus.rows.contains { $0.id == stuId })
        let det: StudentDetailResp = try await api.get("/coach/api/students/\(stuId)")
        ok("GET student detail 解码", det.student.id == stuId)
        ok("  剩余是算出来的：10 总 − 0 已用 = 10",
           det.buckets["active"]?.first?.remaining == 10)
        ok("  bookable 已扣掉已排的 1 节",
           det.buckets["active"]?.first?.bookable == 9,
           "got \(String(describing: det.buckets["active"]?.first?.bookable))")
        let link: LinkResp = try await api.get("/coach/api/students/\(stuId)/link")
        ok("GET student link 解码", link.has_link == false)
        let locs: LocationsResp = try await api.get("/coach/api/locations")
        ok("GET locations 解码", locs.locations.contains { $0.id == locId })
        let av: AvailabilityResp = try await api.get("/coach/api/availability")
        ok("GET availability 解码", av.wd_names.count == 7 && av.rules_by_wd.count == 7)
        ok("  preview 14 天", av.preview.count == 14, "got \(av.preview.count)")
    } catch { ok("读端点", false, "\(error)") }

    print("── 状态机与理由 ──")
    do {
        _ = try await api.post("/coach/api/sessions/\(sesId)/status",
                               ["to": "completed", "reason": "", "reason_code": ""])
        ok("scheduled → completed 免理由", true)
    } catch { ok("scheduled → completed", false, "\(error)") }

    do {
        _ = try await api.post("/coach/api/sessions/\(sesId)/status",
                               ["to": "cancelled", "reason": "", "reason_code": ""])
        ok("completed → cancelled 缺理由必须被拒", false, "竟然成功了")
    } catch APIError.rejected(let m) {
        ok("completed → 别的状态缺理由 → 400", m.contains("理由"), m)
    } catch { ok("缺理由", false, "\(error)") }

    ok("客户端 needsReason 与后端一致（scheduled 免、其余必填）",
       Vocab.needsReason(from: "scheduled") == false
       && Vocab.needsReason(from: "completed") == true
       && Vocab.needsReason(from: "cancelled") == true)

    do {
        _ = try await api.post("/coach/api/sessions/\(sesId)/status",
                               ["to": "cancelled", "reason": "记错了", "reason_code": "mistake"])
        ok("带理由后放行", true)
        let det: StudentDetailResp = try await api.get("/coach/api/students/\(stuId)")
        ok("cancelled 不扣课时（剩余回到 10）",
           det.buckets["active"]?.first?.remaining == 10)
    } catch { ok("带理由改状态", false, "\(error)") }

    do {
        // 放在状态改动**之后**才有行 —— 建学员/课包本身不写 audit
        let aud: AuditResp = try await api.get("/coach/api/audit", query: ["all": "1"])
        ok("GET audit 解码且有行", !aud.rows.isEmpty)
        ok("  纠错那条带 reason_code=mistake",
           aud.rows.contains { $0.reason_code == "mistake" })
        let corr: AuditResp = try await api.get("/coach/api/audit")
        ok("  默认只列纠错/通融（比 all 少）", corr.rows.count < aud.rows.count)
    } catch { ok("audit", false, "\(error)") }

    print("── 成长数据（schema v3）──")
    var runMetricId = 0
    do {
        // 一键灌默认项目 → 读回来。停用项也在列表里（停用不删）。
        _ = try await api.post("/coach/api/metrics/seed", [:])
        let mr: MetricsResp = try await api.get("/coach/api/metrics")
        ok("GET /coach/api/metrics 解码", !mr.metrics.isEmpty)
        // 「越低越好」的项目必须真的存在，否则下面那条判据验的是个恒真式
        guard let run = mr.metrics.first(where: { $0.higher_is_better == 0 }) else {
            ok("  默认项目里有『越低越好』的项", false, "一个都没有"); report(); return
        }
        runMetricId = run.id
        ok("  默认项目里有『越低越好』的项（\(run.name)）", true)

        // 成绩一次比一次小 = 越低越好的项目上「在进步」。
        // 这条是整个成长面唯一容易两处实现的判据（客户端若按 delta>0 判好坏就会反）。
        for (d, v) in [("2026-05-10", "9.8"), ("2026-06-14", "9.2"), ("2026-08-23", "8.6")] {
            _ = try await api.post("/coach/api/students/\(stuId)/measurements",
                                   ["metric_id": "\(runMetricId)", "taken_on": d,
                                    "value": v, "note": "harness"])
        }
        let g: GrowthResp = try await api.get("/coach/api/students/\(stuId)/growth")
        guard let pr = g.progress.first(where: { $0.metric_id == runMetricId }) else {
            ok("GET growth 里有该项目的 progress", false); report(); return
        }
        ok("GET /coach/api/students/{id}/growth 解码", true)
        ok("  越低越好：数值降了，delta 为负而 improved = true",
           pr.delta < 0 && pr.improved == true,
           "delta=\(pr.delta) improved=\(String(describing: pr.improved))")
        ok("  first/latest/best 三个值都对", pr.first_value == 9.8
           && pr.latest_value == 8.6 && pr.best_value == 8.6)
        ok("  n_points = 3 且序列点数一致", pr.n_points == 3
           && (g.series["\(runMetricId)"]?.count ?? 0) == 3)
        ok("  attendance 解码（到课率 0–100）", g.attendance.rate >= 0 && g.attendance.rate <= 100)
        ok("  measurements 带 metric_name / unit（列表直接可渲）",
           g.measurements.contains { $0.metric_id == runMetricId && !$0.metric_name.isEmpty })
    } catch { ok("成长数据", false, "\(error)") }

    print("── 学员端链接与只读面 ──")
    do {
        let r = try await api.post("/coach/api/students/\(stuId)/token",
                                   ["action": "rotate", "reason": ""])
        guard let url = r.link_url else { ok("签发链接", false); report(); return }
        ok("POST token rotate 返回链接", url.contains("/s/"))
        let token = Session.extractToken(url)
        ok("  extractToken 从整条 URL 取出口令", !token.isEmpty && !token.contains("/"))

        let sv: StudentView = try await API(s, studentToken: token)
            .get("/s/api/view", student: true)
        ok("GET /s/api/view 用 X-Student-Token 头解码", sv.student_name == "张三")
        ok("  9 键窄视图：可用合计 = 10", sv.available_total == 10)

        // 学员端成长：窄 dataclass，**结构上没有 note** —— 教练那条 note="harness"
        // 不能出现在公开面的任何角落（INV-7 的延伸，客户端只是不该把它变宽）。
        ok("  学员端 growth 有条目且带趋势点",
           sv.growth.contains { $0.n_points == 3 && $0.points.count == 3 })
        // 「公开面没有教练备注」必须验**后端到底发没发**，不能验客户端把它重新编码出来的
        // 结果 —— 客户端模型里本来就没有 note，编码出来当然没有，那种断言恒真、永远
        // 不会红（2026-08-28 变异实测：给 StudentGrowthView 加上 note 字段，那条仍全绿）。
        // 这里改用一个**故意放宽**的探针：note 声明成可选，能收到就说明后端漏了。
        // probeUnit 是同一探针打在一个后端确实会发的字段上，用来证明探针本身有效
        // —— 否则「note 是 nil」也可能只是探针根本没在解析。
        let probe: StudentViewProbe = try await API(s, studentToken: token)
            .get("/s/api/view", student: true)
        ok("  探针有效性：同结构能收到后端真发的 unit",
           probe.growth.contains { ($0.unit ?? "").isEmpty == false })
        ok("  学员端 growth 后端未下发 note（教练备注进不了公开面）",
           probe.growth.allSatisfy { $0.note == nil })

        // token 不进列表/详情响应 —— 结构性保护，验一次
        let det: StudentDetailResp = try await api.get("/coach/api/students/\(stuId)")
        let raw = String(data: try JSONEncoder().encode(det.student), encoding: .utf8) ?? ""
        ok("  学员详情 JSON 里没有 token 字段", !raw.contains(token))

        _ = try await api.post("/coach/api/students/\(stuId)/token",
                               ["action": "revoke", "reason": "测试"])
        do {
            let _: StudentView = try await API(s, studentToken: token)
                .get("/s/api/view", student: true)
            ok("吊销后旧 token 必须 404", false, "竟然还能看")
        } catch APIError.gone { ok("吊销后旧 token → 404", true) }
    } catch { ok("学员端", false, "\(error)") }

    // 手表不联网：iPhone 用这两个端点拼「今天」快照递过去（Sources/WatchLink.swift）。
    // 这里拿真后端的响应喂同一个 WatchSnapshotBuilder，验顺序、剩余课时与编解码往返；验完把这节课取消，不影响上面的数。
    print("── 手表快照（WatchSnapshotBuilder）──")
    do {
        let today = TZ.dateString(Date())
        let made = try await api.post("/coach/api/sessions", [
            "package_id": String(pkgId), "start_at": "\(today) 06:00", "end_at": "\(today) 06:45",
            "location_id": String(locId), "content": "手表快照", "status": "scheduled", "force": "on",
        ])
        let watchSes = made.id ?? 0
        let sch: ScheduleResp = try await api.get("/coach/api/schedule", query: ["range": "today"])
        let stus: StudentsResp = try await api.get("/coach/api/students")
        let snap = WatchSnapshotBuilder.make(schedule: sch, students: stus)
        ok("快照是今天的", snap.day == sch.today && snap.isToday())
        ok("  今天那节课进了快照", snap.lessons.contains { $0.id == watchSes })
        ok("  课按开始时间排", snap.lessons.map(\.startAt) == snap.lessons.map(\.startAt).sorted())
        let row = stus.rows.first { $0.id == stuId }
        ok("  每节课带的剩余课时 = 学员列表的 available_total",
           snap.lessons.first { $0.id == watchSes }?.remaining == row?.available_total,
           "got \(String(describing: snap.lessons.first { $0.id == watchSes }?.remaining))")
        ok("  余额按剩得少的在前", snap.balances.map(\.remaining) == snap.balances.map(\.remaining).sorted())
        let back = snap.encoded().flatMap(WatchSnapshot.decode)
        ok("  编码再解码不丢字段", back == snap)
        // 确定的纪元换算边界：2001 秒的 1 ULP 在 Unix 秒中不可表达。
        // 保留完整 Equatable 比较，不以时间容差掩盖任何字段变化。
        let precision = WatchSnapshot(day: snap.day,
            generatedAt: Date(timeIntervalSinceReferenceDate: 800_000_000.0000001),
            lessons: snap.lessons, balances: snap.balances)
        ok("  时间规范到既有 Unix Double 精度",
           precision.generatedAt.timeIntervalSinceReferenceDate == 800_000_000)
        ok("  精度边界完整快照严格往返相等",
           precision.encoded().flatMap(WatchSnapshot.decode) == precision)
        let legacyData = Data(#"{"day":"2026-10-04","generatedAt":1778307200.125,"lessons":[],"balances":[]}"#.utf8)
        let legacy = WatchSnapshot(day: "2026-10-04",
            generatedAt: Date(timeIntervalSince1970: 1_778_307_200.125), lessons: [], balances: [])
        ok("  旧 Unix seconds JSON 原协议可解码", WatchSnapshot.decode(legacyData) == legacy)
        _ = try await api.post("/coach/api/sessions/\(watchSes)/status",
                               ["to": "cancelled", "reason": "", "reason_code": ""])
    } catch { ok("手表快照", false, "\(error)") }

    // 后台覆盖项（热更新）：词表、说明文字、阈值由后端的 `ui` 段给，App 自带的只作兜底。
    // 全部走 API.get 这条生产解码路径。改覆盖文件的两条只在 ref/run 自己起的本地后端上跑（FC_UI_FILE）。
    print("── 后台覆盖项（ui 段）──")
    do {
        let env = ProcessInfo.processInfo.environment
        let emptyTitle = { T("schedule.empty.title", "这段时间还没有安排") }
        let reasons = { Vocab.reasonCodes.map { "\($0.0)=\($0.1)" } }

        // App 自带的兜底：把覆盖项拿掉看
        Remote.ui = nil
        let bundledStatuses = Vocab.statuses, bundledLabels = Vocab.statusLabels
        let bundledShort = Vocab.statusShort, bundledBuckets = Vocab.bucketLabels
        let bundledReasons = reasons(), bundledEmpty = emptyTitle()

        let p = try await api.ping()
        ok("ping 带 ui 段且解得开", p.ui?.value != nil)
        ok("  API.get 解到就交给 Remote.ui", Remote.ui != nil && Remote.ui == p.ui?.value)
        ok("  词表确实是后端给的", Remote.ui?.vocab?["status.no_show"]?.label == bundledLabels["no_show"]
            && Remote.ui?.vocab?["reason.venue_weather"]?.label == "场地 / 天气"
            && Remote.order([]).first == "status.scheduled")
        ok("  覆盖文件为空时：状态、短名、课包分类与自带逐字相同",
           Vocab.statuses == bundledStatuses && Vocab.statusLabels == bundledLabels
            && Vocab.statusShort == bundledShort && Vocab.bucketLabels == bundledBuckets)
        ok("  覆盖文件为空时：理由七码、先后、名称与自带逐字相同", reasons() == bundledReasons,
           "got \(reasons())")
        ok("  覆盖文件为空时：说明文字是自带的", emptyTitle() == bundledEmpty && (Remote.ui?.copy ?? [:]).isEmpty)

        // ③ 改动前的模型（没有 ui 字段）解新响应照常
        struct OldPing: Codable { let ok: Bool; let today: String; let now: String }
        let rawPing = try await api.getRaw("/coach/api/ping")
        ok("③ 改动前的模型解新响应照常", (try? JSONDecoder().decode(OldPing.self, from: rawPing))?.ok == true)

        if let uiFile = env["FC_UI_FILE"] {
            let url = URL(fileURLWithPath: uiFile)
            // ① 后台写一个键，客户端不改就变（后端每次请求重读，不用重启）
            try Data(#"""
            {"copy": {"schedule.empty.title": "今天没有课，歇一歇", "error.http": "服务器开小差了（{code}）"},
             "vocab": {"status_short.no_show": {"label": "爽约"}, "bucket.lapsed": {"label": "过期未用"},
                       "status.no_show": {"label": "想改名"}},
             "order": ["reason.other", "status.cancelled"],
             "limits": {"request.timeout.seconds": 999, "growth.attendance.good.percent": 80}}
            """#.utf8).write(to: url)
            let _: ScheduleResp = try await api.get("/coach/api/schedule", query: ["range": "today"])
            ok("① 后台写一个键 → 说明文字变了", emptyTitle() == "今天没有课，歇一歇")
            ok("  带变量的模板照样填", T("error.http", "请求失败（HTTP {code}）", ["code": "502"]) == "服务器开小差了（502）")
            ok("  短名与课包分类跟着变", Vocab.statusShort["no_show"] == "爽约" && Vocab.bucketLabels["lapsed"] == "过期未用")
            ok("  状态名只有后端常量一个定义处，覆盖文件改不了", Vocab.statusLabels == bundledLabels)
            ok("  状态先后听后台的，一个都不少",
               Vocab.statuses.first == "cancelled" && Set(Vocab.statuses) == Set(bundledStatuses))
            ok("  理由先后听后台的，七码都在",
               Vocab.reasonCodes.first?.0 == "other" && Set(reasons()) == Set(bundledReasons))
            ok("  数字夹在安全范围里", Remote.seconds("request.timeout.seconds", 20, in: 5...60) == 60
                && Remote.count("growth.attendance.good.percent", 90, in: 50...100) == 80)
            let form: SessionFormResp = try await api.get("/coach/api/session-form")
            ok("  session-form 也带同一份", form.ui?.value == Remote.ui && emptyTitle() == "今天没有课，歇一歇")

            // ② 覆盖文件写坏：说明文字回落，词表与数据照常
            try Data("{ not json".utf8).write(to: url)
            let sch: ScheduleResp = try await api.get("/coach/api/schedule", query: ["range": "today"])
            ok("② 覆盖文件写坏 → 课表照常解出", sch.range == "today" && sch.ui?.value != nil)
            ok("  说明文字回落自带", emptyTitle() == bundledEmpty)
            ok("  词表仍由后端常量给出", Vocab.statusLabels == bundledLabels && Vocab.statuses == bundledStatuses
                && reasons() == bundledReasons)

            try Data(#"{"copy": {}, "vocab": {}, "order": [], "limits": {}}"#.utf8).write(to: url)
            _ = try await api.ping()
            ok("  还原后回到默认", (Remote.ui?.copy ?? [:]).isEmpty && Vocab.statusShort == bundledShort)
        } else {
            print("  （没有 FC_UI_FILE：不是 ref/run 自己起的后端，跳过改覆盖文件的两条）")
        }

        if let stub = env["FC_STUB_BASE"] {
            // ② `ui` 段本身形状不对：只丢这一段，其余字段照常；全部回落自带
            Remote.ui = FeedUI(copy: ["schedule.empty.title": "上一份"])
            let stubAPI = API(Session(baseURL: stub, coachCookie: "stub"))
            let bad = try await stubAPI.ping()
            ok("② ui 段形状不对 → 其余字段照常解出", bad.ok && bad.today == "2026-10-06")
            ok("  整段回落：文字与词表都是自带", bad.ui != nil && bad.ui?.value == nil && Remote.ui == nil
                && emptyTitle() == bundledEmpty && Vocab.statusLabels == bundledLabels && reasons() == bundledReasons)
            // 不带 ui 键的响应（旧后端）不动上一份
            Remote.ui = FeedUI(copy: ["schedule.empty.title": "上一份"])
            let old: ScheduleResp = try await stubAPI.get("/coach/api/schedule")
            ok("  不带 ui 键的响应（旧后端）照常解出，且不动上一份", old.ui == nil && emptyTitle() == "上一份")
        } else {
            print("  （没有 FC_STUB_BASE：跳过 ui 段形状不对的那条）")
        }
        Remote.ui = nil
    } catch { ok("后台覆盖项", false, "\(error)") }

    report()
}

func report() {
    print("\n── 结果 ──")
    if failures.isEmpty {
        print("✅ \(checks) 项契约断言全过")
        exit(0)
    }
    print("❌ \(failures.count)/\(checks) 项不过：\(failures.joined(separator: ", "))")
    exit(1)
}

await runContract()
