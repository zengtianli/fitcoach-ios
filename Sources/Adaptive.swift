import SwiftUI

/// 宽屏与窄屏的**唯一判定入口**，由 RootView 往下传。
///
/// 宽屏 = iPad 全屏 / 宽分屏、Mac、Vision Pro：侧栏式 TabView（RegularHomeView）+ 日程看板。
/// 窄屏 = iPhone（含 Pro Max 横屏）和 iPad 窄分屏：原来的底部 TabView，一个像素都不动 ——
/// App Store 的截图与预览就是这套布局。
struct WideLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var wideLayout: Bool {
        get { self[WideLayoutKey.self] }
        set { self[WideLayoutKey.self] = newValue }
    }
}

extension Notification.Name {
    /// 日程拉到了新数据（含改状态、排课之后的重拉）。看板右栏的课时余额、手表快照据此刷新。
    static let fitcoachScheduleLoaded = Notification.Name("fitcoach.scheduleLoaded")
    /// 宽屏工具栏的「刷新」（⌘R）：Mac 没有下拉刷新手势，日程与余额各自收到后重拉。
    static let fitcoachReload = Notification.Name("fitcoach.reload")
}

extension View {
    /// 宽屏时把一列内容收在 `width` 以内并居中，两侧铺页面底色；窄屏传 nil，原样返回（不留一层空 frame）。
    @ViewBuilder
    func contentWidth(_ width: CGFloat?) -> some View {
        if let width {
            self.frame(maxWidth: width).frame(maxWidth: .infinity).pageFill()
        } else {
            self
        }
    }

    /// 页面底色。iPhone / iPad / Mac 铺 Theme.pageBG；Vision Pro 不铺 —— 窗口本身是玻璃，
    /// 盖一层不透明底色就把它变成了一块平板。
    @ViewBuilder
    func pageFill() -> some View {
        #if os(visionOS)
        self
        #else
        self.background(Theme.pageBG.ignoresSafeArea())
        #endif
    }
}

#if os(visionOS)
// visionOS 没有「滚动收起软键盘」：SwiftUI 把 scrollDismissesKeyboard 标成 unavailable（LoginView 首撞）。
// 同名 no-op，调用点不改 —— 与总部 PlatformCompat 的替身同一做法。这条缺口应归总部
// （~/Dev/tools/dev/lib/tools/macapp/swift-shared/PlatformCompat.swift 的 #if os(visionOS) 段），本轮只改本仓，
// 总部补上后删掉这段，否则两份会撞成歧义。
enum ScrollDismissesKeyboardMode { case automatic, immediately, interactively, never }
extension View {
    func scrollDismissesKeyboard(_ mode: ScrollDismissesKeyboardMode) -> some View { self }
}
#endif
