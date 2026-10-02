import Foundation
import WatchConnectivity
import WidgetKit

/// 手表这头的「今天」：收 iPhone 递来的快照（发送端 Sources/WatchLink.swift），存进本机钥匙串给表盘复杂功能读。
///
/// 手表自己不联网、不拿教练 cookie。快照旧了（不是今天的，或超过 10 分钟）且 iPhone 就在旁边时，
/// 发一条一次性消息问它要（sendMessage + reply，iPhone 在后台也会被唤起），不留任何长连接。
/// iPhone 说「已退出」就清空，回到「去 iPhone 上登录」。
@MainActor
final class WatchModel: NSObject, ObservableObject {
    static let shared = WatchModel()

    @Published private(set) var snapshot: WatchSnapshot?
    @Published private(set) var asking = false
    /// 上一次去 iPhone 要数据没要到（iPhone 不在旁边 / 没登录 / 断网）
    @Published private(set) var askFailed = false

    /// 截图与模拟器验收：`-fitcoach.watchDemo 1` 用占位假数据（WatchSnapshot.demo），
    /// 不碰 WatchConnectivity、不写钥匙串 —— 真实教练的数据一条都不会出现在验收图里。
    let demo = UserDefaults.standard.bool(forKey: "fitcoach.watchDemo")

    private enum Incoming: Sendable {
        case snapshot(WatchSnapshot)
        case signedOut
        case nothing
    }

    override init() {
        super.init()
        snapshot = demo ? WatchSnapshot.demo() : SnapshotStore.load()
        guard !demo, WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func refreshIfStale(now: Date = Date()) {
        guard !demo, !asking else { return }
        if let s = snapshot, s.isToday(now), now.timeIntervalSince(s.generatedAt) < 600 { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        asking = true
        session.sendMessage([WatchSnapshot.Key.want: "today"], replyHandler: { reply in
            let incoming = Self.parse(reply)
            Task { @MainActor in
                self.asking = false
                if case .nothing = incoming { self.askFailed = true } else { self.askFailed = false }
                self.apply(incoming)
            }
        }, errorHandler: { _ in
            Task { @MainActor in
                self.asking = false
                self.askFailed = true
            }
        })
    }

    /// 系统为表盘复杂功能的推送在后台叫醒手表 app 时（.backgroundTask(.watchConnectivity)）：
    /// 等 WatchConnectivity 把积压的内容递完再交还，最多 15 秒。
    func drainPending() async {
        guard !demo, WCSession.isSupported() else { return }
        let session = WCSession.default
        if session.activationState != .activated { session.activate() }
        for _ in 0..<30 {
            if session.activationState == .activated && !session.hasContentPending { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    nonisolated private static func parse(_ ctx: [String: Any]) -> Incoming {
        if ctx[WatchSnapshot.Key.signedOut] != nil { return .signedOut }
        // 快照格式变了（iPhone 版本更新、手表还是旧版）就不认，宁可空着也不画错
        guard (ctx[WatchSnapshot.Key.schema] as? Int) == WatchSnapshot.schema,
              let data = ctx[WatchSnapshot.Key.snapshot] as? Data,
              let snap = WatchSnapshot.decode(data) else { return .nothing }
        return .snapshot(snap)
    }

    private func apply(_ incoming: Incoming) {
        guard !demo else { return }
        switch incoming {
        case .nothing:
            return
        case .signedOut:
            SnapshotStore.clear()
            snapshot = nil
        case .snapshot(let snap):
            if let cur = snapshot, cur.generatedAt > snap.generatedAt { return }     // 晚到的旧快照不覆盖新的
            snapshot = snap
            SnapshotStore.save(snap)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
}

extension WatchModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        guard state == .activated else { return }
        let incoming = Self.parse(session.receivedApplicationContext)
        Task { @MainActor in
            self.apply(incoming)
            self.refreshIfStale()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext ctx: [String: Any]) {
        let incoming = Self.parse(ctx)
        Task { @MainActor in self.apply(incoming) }
    }

    /// 表盘复杂功能那条推送（transferCurrentComplicationUserInfo）走这里，内容与上下文同形
    nonisolated func session(_ session: WCSession, didReceiveUserInfo info: [String: Any] = [:]) {
        let incoming = Self.parse(info)
        Task { @MainActor in self.apply(incoming) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor in self.refreshIfStale() }
    }
}
