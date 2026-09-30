import Foundation
import Combine

private struct CheckFailure: Error { let label: String }

@main
struct RecoveryAcceptance {
    @MainActor
    static func require(_ condition: Bool, _ label: String) throws {
        guard condition else { throw CheckFailure(label: label) }
        print("PASS: \(label)")
    }

    @MainActor
    static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let backend = env["FC_BASE"], let fixture = env["FC_FAULT_BASE"],
              backend.hasPrefix("http://127.0.0.1:"), fixture.hasPrefix("http://127.0.0.1:") else {
            throw CheckFailure(label: "acceptance must use isolated loopback targets")
        }
        // The shared runner uses a unique executable name, so this preference domain
        // cannot overlap the installed iOS app or another acceptance process.
        let domain = ProcessInfo.processInfo.processName
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let session = Session()
        session.baseURL = backend
        session.coachCookie = nil
        session.studentToken = nil
        let api = API(session)
        let email = "recovery@example.test"
        let password = "Recovery-Passw0rd!234"
        session.coachCookie = try await api.register(email: email, password: password, displayName: "Recovery fixture")
        let cookie = session.coachCookie
        try require(try await api.ping().ok, "fresh local account authenticates")

        let studentID = try await api.post("/coach/api/students", ["name": "Recovery learner", "note": "isolated fixture"]).id ?? 0
        let packageID = try await api.post("/coach/api/packages", [
            "student_id": String(studentID), "total_sessions": "3", "unit_price_yuan": "100",
            "purchased_on": TZ.dateString(Date()), "expires_on": "", "note": "",
        ]).id ?? 0
        try require(studentID > 0 && packageID > 0, "persistent test data created through production API")

        let past = TZ.dateString(TZ.calendar.date(byAdding: .day, value: -1, to: Date())!)
        var fields = ["package_id": String(packageID), "start_at": "\(past) 10:00", "end_at": "\(past) 11:00", "status": "scheduled", "content": "Recovery session"]
        do {
            try await api.post("/coach/api/sessions", fields)
            throw CheckFailure(label: "missing availability must require confirmation")
        } catch APIError.needsForce(let warnings) {
            try require(!warnings.isEmpty && warnings.allSatisfy { !$0.blocking }, "409 exposes nonblocking warnings for explicit confirmation")
        }
        let before: StudentDetailResp = try await api.get("/coach/api/students/\(studentID)")
        try require(before.sessions.isEmpty && before.buckets["active"]?.first?.bookable == 3, "unconfirmed 409 leaves persisted sessions and balance unchanged")
        fields["force"] = "on"
        let sessionID = try await api.post("/coach/api/sessions", fields).id ?? 0
        let confirmed: StudentDetailResp = try await api.get("/coach/api/students/\(studentID)")
        try require(sessionID > 0 && confirmed.sessions.count == 1 && confirmed.sessions.first?.id == sessionID && confirmed.buckets["active"]?.first?.bookable == 2, "explicit force retry persists exactly one session")

        let future = TZ.dateString(TZ.calendar.date(byAdding: .day, value: 7, to: Date())!)
        do {
            try await api.post("/coach/api/sessions", ["package_id": String(packageID), "start_at": "\(future) 10:00", "end_at": "\(future) 11:00", "status": "completed", "force": "on"])
            throw CheckFailure(label: "hard rejection must fail even with force")
        } catch APIError.rejected {
            try require(true, "400 hard rejection stays distinct from force confirmation")
        }
        let rejected: StudentDetailResp = try await api.get("/coach/api/students/\(studentID)")
        try require(rejected.sessions.count == 1 && rejected.buckets["active"]?.first?.bookable == 2, "hard rejection preserves persistent data")

        do {
            _ = try await api.login(email: email, password: "incorrect-password")
            throw CheckFailure(label: "incorrect password must fail")
        } catch APIError.unauthorized {
            try require(session.coachCookie == cookie, "401 login failure does not overwrite an existing credential")
        }
        session.coachCookie = "invalid-fixture-cookie"
        do {
            _ = try await api.ping()
            throw CheckFailure(label: "invalid credential must fail")
        } catch APIError.gone {
            session.signOut()
            try require(session.coachCookie == nil && session.showingLogin, "expired credential supports real signOut recovery path")
        }
        session.coachCookie = try await api.login(email: email, password: password)
        session.showingLogin = false
        try require(try await api.ping().ok, "fresh login restores requests after invalid session")

        let recoveredCookie = session.coachCookie
        session.baseURL = fixture
        for path in ["/malformed", "/wrong-shape"] {
            do {
                let _: API.Ping = try await api.get(path)
                throw CheckFailure(label: "invalid payload must not be accepted")
            } catch APIError.decode {
                try require(true, "\(path) is reported as a decoding failure")
            }
            let healthy: API.Ping = try await api.get("/healthy")
            try require(healthy.ok && session.coachCookie == recoveredCookie, "valid response succeeds after \(path) without losing credential")
        }
        do {
            let _: API.Ping = try await api.get("/unavailable")
            throw CheckFailure(label: "503 must fail")
        } catch APIError.server(let status, _) {
            // 5xx 是服务端临时故障（可重试），与 400 硬拒 `.rejected` 分开（2026-09-30 起）
            try require(status == 503, "503 is surfaced as a retryable server failure, not a hard rejection")
        }
        do {
            let _: API.Ping = try await api.get("/disconnect")
            throw CheckFailure(label: "disconnected connection must fail")
        } catch APIError.transport {
            try require(true, "connection loss is surfaced as a transport failure")
        }
        let healthy: API.Ping = try await api.get("/healthy")
        try require(healthy.ok && session.coachCookie == recoveredCookie, "requests recover after service and connection failures")
        session.baseURL = backend
        let final: StudentDetailResp = try await api.get("/coach/api/students/\(studentID)")
        try require(final.sessions.count == 1 && final.sessions.first?.id == sessionID && final.buckets["active"]?.first?.bookable == 2, "restored real backend retains the exact pre-fault state")
        print("PASS: recovery acceptance; production API and Session, local backend/faults; no UI or device claim")
    }

    static func main() async {
        do { try await run() }
        catch let error as CheckFailure { fputs("FAIL: \(error.label)\n", stderr); exit(1) }
        catch { fputs("FAIL: unexpected recovery error (\(type(of: error))); no credentials logged\n", stderr); exit(1) }
    }
}
