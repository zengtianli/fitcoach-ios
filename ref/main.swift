// 契约对账 harness —— **复用 app 自己的 Sources/Models.swift + Sources/API.swift**，
// 不另写一份「我以为后端长这样」的解析器（铁律 #2：验证必须走生产的同一构造路径）。
//
// 跑法见 ./run。任一断言不过即非零退出，不打印「大致没问题」。
import Foundation
import Combine

let base = ProcessInfo.processInfo.environment["FC_BASE"] ?? "http://127.0.0.1:8799"
let email = ProcessInfo.processInfo.environment["FC_EMAIL"] ?? "t@e.com"
let pass = ProcessInfo.processInfo.environment["FC_PASS"] ?? "Passw0rd!234"

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
