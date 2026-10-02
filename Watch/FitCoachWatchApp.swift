import SwiftUI

/// Apple Watch 版：教练抬腕看的**只读**一面 —— 今天的课按时间排（时间 / 学员 / 地点 / 剩几节）、
/// 学员课时余额，表盘上挂「下一节」。
///
/// 数据全由 iPhone 递来（Watch/WatchModel.swift），手表不联网、没有登录框。改状态（记已上课）留在 iPhone：
/// 后端没有离线队列，手表上点了而 iPhone 不在身边时只能失败。
///
/// 验证通道（与 iPhone 的 -fitcoach.tab 同一条路子，只为模拟器截图）：
///   -fitcoach.watchDemo 1                       占位假数据（WatchSnapshot.demo），不碰 WatchConnectivity
///   -fitcoach.watchScreen balances|lesson|complications   直接落到余额页 / 第一节课详情 / 表盘复杂功能预览
@main
struct FitCoachWatchApp: App {
    @StateObject private var model = WatchModel.shared

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(model)
        }
        // 表盘复杂功能的推送会在后台叫醒本 app：把积压的递完再交还
        .backgroundTask(.watchConnectivity) {
            await WatchModel.shared.drainPending()
        }
    }
}

struct WatchRootView: View {
    @EnvironmentObject var model: WatchModel
    @Environment(\.scenePhase) private var scenePhase
    private let screen = UserDefaults.standard.string(forKey: "fitcoach.watchScreen") ?? ""

    var body: some View {
        Group {
            if screen == "complications" {
                ComplicationGallery(snapshot: model.snapshot)
            } else if let s = model.snapshot {
                WatchHomeView(snapshot: s, startPage: screen == "balances" ? 1 : 0, openFirst: screen == "lesson")
            } else {
                WatchSignedOutView(asking: model.asking)
            }
        }
        .task {
            LaneSignal.applyOrientation()
            LaneSignal.applyWindowFrame()
            model.refreshIfStale()
        }
        // 抬腕回到前台：快照旧了就问 iPhone 要一份（一次性消息，不留长连接）
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshIfStale() }
        }
    }
}

/// 没有快照：只说一句话，指向 iPhone。手表上不放输入框。
struct WatchSignedOutView: View {
    let asking: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Color.accentColor)
            Text("在 iPhone 上打开\n上门体育")
                .font(.headline)
                .multilineTextAlignment(.center)
            if asking {
                ProgressView().controlSize(.small)
            } else {
                Text("登录教练账号后，今天的课会同步到手表")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 6)
        .onAppear { LaneSignal.ready("watch-signed-out") }
    }
}
