import Foundation

// Decode the complete wire response, including fields absent from production's
// narrow student model. Re-encoding that narrow model would hide server leaks.
private enum WireJSON: Decodable {
    case object([String: WireJSON]), array([WireJSON]), string(String), scalar
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let object = try? value.decode([String: WireJSON].self) { self = .object(object) }
        else if let array = try? value.decode([WireJSON].self) { self = .array(array) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if value.decodeNil() || (try? value.decode(Double.self)) != nil || (try? value.decode(Bool.self)) != nil { self = .scalar }
        else { throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid JSON") }
    }
    var keys: Set<String> {
        switch self {
        case .object(let values): return Set(values.keys).union(values.values.reduce(into: Set<String>()) { $0.formUnion($1.keys) })
        case .array(let values): return values.reduce(into: Set<String>()) { $0.formUnion($1.keys) }
        default: return []
        }
    }
    var strings: Set<String> {
        switch self {
        case .object(let values): return values.values.reduce(into: Set<String>()) { $0.formUnion($1.strings) }
        case .array(let values): return values.reduce(into: Set<String>()) { $0.formUnion($1.strings) }
        case .string(let value): return [value]
        default: return []
        }
    }
}

private struct CheckFailure: Error {}

@main
private struct PrivacyCheck {
    @MainActor static var count = 0
    @MainActor static func check(_ label: String, _ value: Bool) throws {
        guard value else { print("FAIL: \(label)"); throw CheckFailure() }
        count += 1
        print("PASS: \(label)")
    }
    @MainActor static func gone(_ label: String, _ action: () async throws -> Void) async throws {
        do { try await action() }
        catch APIError.gone { try check(label, true); return }
        try check(label, false)
    }
    @MainActor static func denied(_ label: String, _ action: () async throws -> Void) async throws {
        do { try await action() }
        catch APIError.gone { try check(label, true); return }
        catch APIError.rejected { try check(label, true); return }
        try check(label, false)
    }
    @MainActor static func main() async {
        do { try await run(); print("PASS: privacy \(count) assertions; no UI/device coverage") }
        catch {
            // Never stringify API payloads, cookies, student links, or environment.
            print("FAIL: privacy acceptance stopped (response details redacted)")
            exit(1)
        }
    }
    @MainActor static func run() async throws {
        guard let base = ProcessInfo.processInfo.environment["FC_BASE"],
              URLComponents(string: base)?.host == "127.0.0.1" else { throw CheckFailure() }
        let a = Session(); a.baseURL = base; a.coachCookie = nil; a.studentToken = nil
        let apiA = API(a)
        a.coachCookie = try await apiA.register(email: "privacy-a@example.test", password: "PrivacyPassw0rd!234", displayName: "隐私甲")
        let b = Session(); b.baseURL = base; b.coachCookie = nil; b.studentToken = nil
        let apiB = API(b)
        b.coachCookie = try await apiB.register(email: "privacy-b@example.test", password: "PrivacyPassw0rd!234", displayName: "隐私乙")
        let guest = Session(); guest.baseURL = base; guest.coachCookie = nil; guest.studentToken = nil
        let anonymous = API(guest)
        try await gone("anonymous coach read denied") { let _: StudentsResp = try await anonymous.get("/coach/api/students") }
        try await gone("anonymous coach write denied") { try await anonymous.post("/coach/api/students", ["name": "unauthorized"]) }
        try await gone("anonymous student view denied") { let _: StudentView = try await anonymous.get("/s/api/view", student: true) }

        let privateNote = "private-note-sentinel"
        guard let sidA = try await apiA.post("/coach/api/students", ["name": "学员甲", "note": privateNote]).id,
              let sidB = try await apiB.post("/coach/api/students", ["name": "学员乙", "note": "tenant-b-note"]).id,
              let pkg = try await apiA.post("/coach/api/packages", ["student_id": String(sidA), "total_sessions": "8", "unit_price_yuan": "321", "purchased_on": TZ.dateString(Date()), "expires_on": "", "note": privateNote]).id
        else { throw CheckFailure() }
        try check("isolated fixtures created", pkg > 0 && sidA != sidB)
        let listA: StudentsResp = try await apiA.get("/coach/api/students")
        let listB: StudentsResp = try await apiB.get("/coach/api/students")
        try check("tenant lists isolated in both directions", listA.rows.map(\.id) == [sidA] && listB.rows.map(\.id) == [sidB])
        try await gone("foreign student detail denied") { let _: StudentDetailResp = try await apiB.get("/coach/api/students/\(sidA)") }
        try await gone("foreign student link denied") { let _: LinkResp = try await apiB.get("/coach/api/students/\(sidA)/link") }
        try await denied("foreign student write denied") { try await apiB.post("/coach/api/students/\(sidA)", ["name": "changed", "note": "changed", "is_active": "on"]) }
        let owner: StudentDetailResp = try await apiA.get("/coach/api/students/\(sidA)")
        try check("denied write preserved owner data", owner.student.name == "学员甲" && owner.student.note == privateNote)

        try await apiA.post("/coach/api/metrics/seed", [:])
        let metrics: MetricsResp = try await apiA.get("/coach/api/metrics")
        guard let metric = metrics.metrics.first else { throw CheckFailure() }
        try await apiA.post("/coach/api/students/\(sidA)/measurements", ["metric_id": String(metric.id), "taken_on": TZ.dateString(Date()), "value": "10", "note": privateNote])
        let growth: GrowthResp = try await apiA.get("/coach/api/students/\(sidA)/growth")
        try check("sensitive growth fixture exists on coach response", growth.measurements.contains { $0.note == privateNote })
        guard let link = try await apiA.post("/coach/api/students/\(sidA)/token", ["action": "rotate", "reason": "acceptance"]).link_url else { throw CheckFailure() }
        let token = Session.extractToken(link)
        let student = API(guest, studentToken: token)
        let view: StudentView = try await student.get("/s/api/view", query: ["student_id": String(sidB)], student: true)
        try check("student token binds own identity despite foreign query", view.student_name == "学员甲" && view.available_total == 8 && view.growth.count == 1)
        let raw: WireJSON = try await student.get("/s/api/view", student: true)
        try check("wire privacy probe has real nested content", raw.strings.contains("学员甲") && raw.strings.contains(metric.unit) && raw.keys.contains("remaining"))
        let forbidden: Set<String> = ["token", "note", "coach_id", "unit_price_cents", "unit_price_yuan", "price", "audit", "reason", "reason_code"]
        try check("student wire has no private fields or sentinel values", raw.keys.isDisjoint(with: forbidden) && !raw.strings.contains(privateNote) && !raw.strings.contains("学员乙") && !raw.strings.contains(token))
        let rawOwner: WireJSON = try await apiA.get("/coach/api/students/\(sidA)")
        try check("coach detail wire hides bearer token while probe detects note", rawOwner.strings.contains(privateNote) && !rawOwner.strings.contains(token) && !rawOwner.keys.contains("token"))
        try await gone("student header cannot read coach endpoint") { let _: StudentsResp = try await student.get("/coach/api/students", student: true) }
        try await gone("coach cookie cannot read student endpoint") { let _: StudentView = try await apiA.get("/s/api/view") }
        let mixed = API(a, studentToken: token)
        try await gone("student request never carries saved coach cookie") { let _: StudentsResp = try await mixed.get("/coach/api/students", student: true) }
        try await gone("coach request never carries student override") { let _: StudentView = try await mixed.get("/s/api/view") }

        guard let nextLink = try await apiA.post("/coach/api/students/\(sidA)/token", ["action": "rotate", "reason": "acceptance"]).link_url else { throw CheckFailure() }
        try await gone("rotation immediately invalidates previous link") { let _: StudentView = try await student.get("/s/api/view", student: true) }
        let rotated = API(guest, studentToken: Session.extractToken(nextLink))
        let rotatedView: StudentView = try await rotated.get("/s/api/view", student: true)
        try check("rotated link reads same student", rotatedView.student_name == "学员甲")
        try await apiA.post("/coach/api/students/\(sidA)/token", ["action": "revoke", "reason": "acceptance"])
        try await gone("explicit revoke immediately denies student link") { let _: StudentView = try await rotated.get("/s/api/view", student: true) }
        guard let finalLink = try await apiA.post("/coach/api/students/\(sidA)/token", ["action": "rotate", "reason": "acceptance"]).link_url else { throw CheckFailure() }
        let finalStudent = API(guest, studentToken: Session.extractToken(finalLink))
        try await apiA.deleteAccount()
        try await gone("deleted account cookie denied") { _ = try await apiA.ping() }
        try await gone("deleted account student token denied") { let _: StudentView = try await finalStudent.get("/s/api/view", student: true) }
        try check("other tenant survives account deletion", try await apiB.ping().ok)
        let remaining: StudentsResp = try await apiB.get("/coach/api/students")
        try check("other tenant data survives account deletion", remaining.rows.map(\.id) == [sidB])
    }
}
