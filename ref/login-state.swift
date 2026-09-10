import Foundation

@main struct LoginStateChecks {
    @MainActor static func main() throws {
        let server = "https://login-check-\(UUID().uuidString).example.com"
        defer { try? SavedLogin.remove(server: server) }
        let first = SavedLogin.Credentials(email: "coach@example.com", password: "OnlyATest123!")
        try SavedLogin.save(first, server: server)
        let restored = try SavedLogin.load(server: " \(server)/ ")
        precondition(restored == first, "重启后可读取同一服务器账号，末尾斜线等价")
        let other = try SavedLogin.load(server: server + "/other")
        precondition(other == nil, "另一服务器不能取到密码")
        let updated = SavedLogin.Credentials(email: first.email, password: "UpdatedTest123!")
        try SavedLogin.save(updated, server: server)
        let back = try SavedLogin.load(server: server)
        precondition(back == updated, "更新而非重复插入")
        try SavedLogin.remove(server: server)
        let removed = try SavedLogin.load(server: server)
        precondition(removed == nil, "取消记忆后不再读取密码")
        try SavedLogin.remove(server: server)

        let defaults = UserDefaults.standard
        let keys = ["fitcoach.coachCookie", "fitcoach.studentToken", "fitcoach.studentMode", "fitcoach.coachEmail"]
        let prior = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, prior) { defaults.set(value, forKey: key) } }
        let session = Session()
        session.signOut()
        session.coachCookie = "test-coach-cookie"
        precondition(session.isCoach && !session.isStudent)
        session.enterStudent("test-student-one")
        precondition(session.isStudent && !session.isCoach && session.coachCookie == "test-coach-cookie")
        session.openLogin(student: true)
        precondition(session.showingLogin && session.loginMode == 1)
        precondition(session.coachCookie == "test-coach-cookie" && session.studentToken == "test-student-one", "打开登录页不退出任何账号")
        let reopened = Session()
        precondition(reopened.isStudent && reopened.coachCookie == "test-coach-cookie", "重启保留双身份")
        session.returnToCoach()
        precondition(session.isCoach && !session.showingLogin && session.studentToken == "test-student-one")
        session.signOut()
        precondition(session.coachCookie == nil && session.studentToken == "test-student-one", "仅退出教练，保留学员")
        session.coachCookie = "test-coach-cookie"
        session.enterStudent("test-student-two")
        precondition(session.isStudent && session.studentToken == "test-student-two")
        session.leaveStudent()
        precondition(session.isCoach && session.studentToken == nil)
        session.signOut()
        precondition(!session.isCoach && !session.isStudent)
        print("PASS: 钥匙串保存/更新/隔离/清除；教练与多学员切换、重启恢复与退出")
    }
}
