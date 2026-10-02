import Foundation
#if os(iOS)
import WatchConnectivity
#endif

/// 从教练端两份现成的响应拼出手表快照（只读，见 WatchSnapshot.swift 的取舍）。
/// 纯 Foundation，不碰界面：tests 里拿后端真实 JSON 喂它（Tests/check-watch-snapshot.sh）。
enum WatchSnapshotBuilder {
    static func make(schedule: ScheduleResp, students: StudentsResp, at now: Date = Date()) -> WatchSnapshot {
        let left = Dictionary((students.rows + students.inactive).map { ($0.id, $0.available_total) },
                              uniquingKeysWith: { a, _ in a })
        let lessons = schedule.days.filter { $0.date_ == schedule.today }
            .flatMap(\.sessions)
            .sorted { ($0.start_at, $0.id) < ($1.start_at, $1.id) }
            .map { s in
                WatchSnapshot.Lesson(id: s.id, startAt: s.start_at, endAt: s.end_at, studentId: s.student_id,
                                     student: s.student_name, place: s.location_name, content: s.content,
                                     status: s.status, remaining: left[s.student_id])
            }
        let balances = students.rows.filter { $0.n_packages > 0 }
            .sorted { ($0.available_total, $0.name) < ($1.available_total, $1.name) }
            .map { WatchSnapshot.Balance(id: $0.id, name: $0.name, remaining: $0.available_total,
                                         lapsed: $0.lapsed_total, expiringSoon: $0.expiring_soon) }
        return WatchSnapshot(day: schedule.today, generatedAt: now, lessons: lessons, balances: balances)
    }
}

/// iPhone → Apple Watch 的「今天」快照转交。
///
/// 只在**配了手表、手表上装了本 app** 时才去拉数据（两个 GET），其余情况一个请求都不发 —— 没有手表的教练零成本。
/// 走 `updateApplicationContext`：只保留最新一份，手表下次打开就读到，iPhone 不用开着；表盘上挂了复杂功能时
/// 再用 `transferCurrentComplicationUserInfo` 推一份（系统每天给的次数有限，内容没变就不推）。
/// 手表打开时若快照旧了，会经 sendMessage 来要一份（iPhone 在后台也会被唤起），这里拉完直接回给它。
/// 退出登录 / 换服务器时递一份「已退出」，手表随即清空。
///
/// 凭证从不离开 iPhone：每次取数用一个只读的 `Session()`（init 不写 UserDefaults），与界面上那个会话同源。
/// iPad、Mac、Vision Pro 上整个类都是空操作。
@MainActor
final class WatchLink: NSObject {
    static let shared = WatchLink()

    #if os(iOS)
    private var lastSent: WatchSnapshot?
    private var lastSignedOut = false
    private var lastPublish = Date.distantPast
    private var inFlight = false
    private var againAfterFlight = false     // 拉取途中数据又变了（刚改完状态）：这一轮结束后再拉一次
    private var wantAfterActivation = false
    private var observer: NSObjectProtocol?

    func activate() {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        s.delegate = self
        if s.activationState != .activated { s.activate() }
        if observer == nil {
            // 日程每次拉到新数据（含改状态之后的重拉）都试一次：内容没变不会真发
            observer = NotificationCenter.default.addObserver(forName: .fitcoachScheduleLoaded, object: nil,
                                                              queue: .main) { _ in
                MainActor.assumeIsolated { WatchLink.shared.publish(force: true) }
            }
        }
    }

    /// 有手表才干活。`force` = 刚改过数据，不受 20 秒节流。
    func publish(force: Bool = false) {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        guard s.activationState == .activated else {
            wantAfterActivation = true
            activate()
            return
        }
        guard s.isPaired, s.isWatchAppInstalled else { return }
        guard !inFlight else {
            if force { againAfterFlight = true }
            return
        }
        guard force || Date().timeIntervalSince(lastPublish) > 20 else { return }
        lastPublish = Date()
        inFlight = true
        Task {
            let ctx = await context()
            send(ctx)
            inFlight = false
            if againAfterFlight {
                againAfterFlight = false
                publish(force: true)
            }
        }
    }

    /// 当前该给手表的上下文：已登录 = 快照，未登录 = 「已退出」。取数失败返回 nil（手表保留上一份）。
    private func context() async -> [String: Any]? {
        let session = Session()              // 只读：init 不触发 didSet，不写 UserDefaults
        guard session.coachCookie != nil else {
            return [WatchSnapshot.Key.signedOut: true, WatchSnapshot.Key.at: Date().timeIntervalSince1970]
        }
        do {
            let api = API(session)
            let schedule: ScheduleResp = try await api.get("/coach/api/schedule", query: ["range": "today"])
            let students: StudentsResp = try await api.get("/coach/api/students")
            let snap = WatchSnapshotBuilder.make(schedule: schedule, students: students)
            guard let data = snap.encoded() else { return nil }
            if snap.sameContent(as: lastSent) && !lastSignedOut { return nil }
            lastSent = snap
            return [WatchSnapshot.Key.snapshot: data, WatchSnapshot.Key.schema: WatchSnapshot.schema,
                    WatchSnapshot.Key.at: Date().timeIntervalSince1970]
        } catch APIError.gone {
            return [WatchSnapshot.Key.signedOut: true, WatchSnapshot.Key.at: Date().timeIntervalSince1970]
        } catch {
            return nil                       // 断网 / 5xx：手表留着上一份，下次再说
        }
    }

    private func send(_ ctx: [String: Any]?) {
        guard let ctx else { return }
        let s = WCSession.default
        guard s.activationState == .activated, s.isPaired, s.isWatchAppInstalled else { return }
        let signedOut = ctx[WatchSnapshot.Key.signedOut] != nil
        if signedOut && lastSignedOut { return }
        lastSignedOut = signedOut
        if signedOut { lastSent = nil }
        // 没配对手表、或手表上没装本 app 时 WatchConnectivity 会抛错：这是常态，不是故障
        try? s.updateApplicationContext(ctx)
        if s.isComplicationEnabled && s.remainingComplicationUserInfoTransfers > 0 {
            s.transferCurrentComplicationUserInfo(ctx)
        }
    }

    /// 手表来要：拉一份新的直接回给它（同时更新上下文），失败回空字典 —— 手表据此知道「问过了，没拿到」。
    fileprivate func answer(_ reply: @escaping ([String: Any]) -> Void) {
        Task {
            lastSent = nil                   // 手表手里那份可能是旧的：这次无论如何都给
            let ctx = await context()
            reply(ctx ?? [:])
            send(ctx)
        }
    }

    fileprivate func activated() {
        if wantAfterActivation {
            wantAfterActivation = false
            publish(force: true)
        }
    }
    #else
    func activate() {}
    func publish(force: Bool = false) {}
    #endif
}

#if os(iOS)
extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        guard state == .activated else { return }
        Task { @MainActor in WatchLink.shared.activated() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// 换了一块手表：旧会话失效，重新激活才能给新手表发
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    /// 配对或装上手表 app 之后，补发一次
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in WatchLink.shared.publish(force: true) }
    }

    /// 手表打开时快照旧了，来要一份新的
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        guard message[WatchSnapshot.Key.want] != nil else { return replyHandler([:]) }
        nonisolated(unsafe) let reply = replyHandler
        Task { @MainActor in WatchLink.shared.answer(reply) }
    }
}
#endif
