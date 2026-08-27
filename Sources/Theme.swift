import SwiftUI

// ── 设计 token ──────────────────────────────────────────────────────────────
// 全 app **唯一**一份色彩 / 圆角 / 间距定义。任何界面里出现第二个字面量 hex 或
// 第二组 cornerRadius 数字，就是这层没被消费 —— 改主题时会漏掉那一处（铁律 #5：
// 散在 ≥2 处需手动同步的同一属性必须先建 SSOT 让所有点派生）。
//
// 亮色主题是**产品约束**不是默认值：App.swift 钉了 .preferredColorScheme(.light)，
// 所以这里的颜色可以是固定值，不需要 dark 变体。别加 dark 分支。

enum Theme {

    // 底色：页面比卡片略深，卡片才「浮」得起来。iOS 系统灰偏冷，这里往暖里挪一点。
    static let pageBG    = Color(red: 0.945, green: 0.949, blue: 0.961)
    static let cardBG    = Color.white
    static let cardBGAlt = Color(red: 0.973, green: 0.976, blue: 0.984)

    // 主色：偏靛的蓝。系统蓝在大面积填充时偏艳，压一点饱和更像「工具」不像「玩具」。
    static let accent    = Color(red: 0.184, green: 0.400, blue: 0.945)
    static let accentSoft = Color(red: 0.902, green: 0.929, blue: 1.0)

    // 语义色。与 StatusTag / BucketTag 共用，别在视图里另取近似色。
    static let ok      = Color(red: 0.086, green: 0.639, blue: 0.352)
    static let okSoft  = Color(red: 0.894, green: 0.969, blue: 0.925)
    static let warn    = Color(red: 0.910, green: 0.541, blue: 0.098)
    static let warnSoft = Color(red: 0.996, green: 0.949, blue: 0.878)
    static let danger  = Color(red: 0.859, green: 0.235, blue: 0.235)
    static let dangerSoft = Color(red: 0.996, green: 0.914, blue: 0.914)
    static let violet  = Color(red: 0.482, green: 0.318, blue: 0.878)
    static let violetSoft = Color(red: 0.937, green: 0.925, blue: 0.996)

    // 文字层级：三档就够。再多一档人眼分不出，只会让「哪个更重要」变模糊。
    static let ink     = Color(red: 0.078, green: 0.094, blue: 0.145)
    static let ink2    = Color(red: 0.376, green: 0.404, blue: 0.467)
    static let ink3    = Color(red: 0.576, green: 0.604, blue: 0.667)
    static let hairline = Color(red: 0.898, green: 0.906, blue: 0.925)

    // 圆角：卡片 16 / 内嵌块 12 / 徽标胶囊。
    static let rCard: CGFloat = 16
    static let rInner: CGFloat = 12

    /// 语义色 → (前景, 背景) 对。徽标、统计块、空态图标共用同一张表，
    /// 保证「橙色在这里和那里是同一个橙」。
    static func pair(_ tone: Tone) -> (Color, Color) {
        switch tone {
        case .accent: return (accent, accentSoft)
        case .ok:     return (ok, okSoft)
        case .warn:   return (warn, warnSoft)
        case .danger: return (danger, dangerSoft)
        case .violet: return (violet, violetSoft)
        case .neutral: return (ink2, Color(red: 0.925, green: 0.933, blue: 0.949))
        }
    }

    enum Tone { case accent, ok, warn, danger, violet, neutral }
}

// ── 卡片 ────────────────────────────────────────────────────────────────────

/// 统一的卡片外壳。阴影刻意很轻 —— 移动端一屏十几张卡，重阴影会糊成一片脏灰。
struct CardBox<Content: View>: View {
    var padding: CGFloat = 14
    var tint: Color? = nil          // 左侧强调条颜色，nil = 不要条
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            if let t = tint {
                Rectangle().fill(t).frame(width: 4)
            }
            // 内容必须撑满卡片宽度：否则内容窄的卡（如「下一节课」只有一行时间）
            // 会缩成半张，和同屏其它卡右边缘对不齐（2026-08-28 学员端截图实证）。
            content
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: Theme.rCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.rCard, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.045), radius: 6, x: 0, y: 2)
    }
}

extension View {
    /// List 里放卡片的标准三件套：去掉系统行背景、去掉分隔线、给出卡片间距。
    /// 少任何一件都会露出系统 List 的白底或细线，卡片就「贴」在一起了。
    func cardRow(top: CGFloat = 5, bottom: CGFloat = 5) -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: top, leading: 16, bottom: bottom, trailing: 16))
    }

    /// 页面级：换掉 List 的系统底色，铺 Theme.pageBG。
    func pageBackground() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.pageBG)
    }
}

// ── 分区标题 ────────────────────────────────────────────────────────────────

/// 卡片流里的分组标题。用它替代 Section("…") —— insetGrouped 的系统标题
/// 会连带把系统的行背景/圆角一起带回来，那正是这次要去掉的东西。
struct GroupTitle: View {
    let text: String
    var trailing: String? = nil
    var icon: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let i = icon {
                Image(systemName: i).font(.caption).foregroundStyle(Theme.ink3)
            }
            Text(text)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.ink2)
            Spacer()
            if let t = trailing {
                Text(t).font(.caption).monospacedDigit().foregroundStyle(Theme.ink3)
            }
        }
    }
}

// ── 数字块 ──────────────────────────────────────────────────────────────────

/// 「一个数 + 一句说明」的统计块。数字一律 monospacedDigit：
/// 比例字距下数字宽度会跳，一列数字排下来边缘是锯齿状的。
struct StatBlock: View {
    let value: String
    let label: String
    var tone: Theme.Tone = .neutral
    var big: Bool = false

    var body: some View {
        let (fg, bg) = Theme.pair(tone)
        return VStack(spacing: 3) {
            Text(value)
                .font(big ? .system(size: 30, weight: .bold, design: .rounded)
                          : .system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(fg)
            Text(label).font(.caption2).foregroundStyle(Theme.ink3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(bg.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: Theme.rInner, style: .continuous))
    }
}

/// 行内小徽标（「补录」「过期未用 3」这类）。与 StatusTag 同一套形态语言。
struct Pill: View {
    let text: String
    var tone: Theme.Tone = .neutral
    var icon: String? = nil

    var body: some View {
        let (fg, bg) = Theme.pair(tone)
        return HStack(spacing: 3) {
            if let i = icon { Image(systemName: i).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.caption2.weight(.semibold)).monospacedDigit()
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(bg)
        .foregroundStyle(fg)
        .clipShape(Capsule())
    }
}

// ── 空态 ────────────────────────────────────────────────────────────────────

/// 像样的空态：一个圈起来的 SF Symbol + 一句主文案 + 一句解释。
/// 替代原来的一行灰字 —— 一行灰字看起来像「加载失败」，人会去反复下拉刷新。
struct EmptyState: View {
    let icon: String
    let title: String
    var detail: String? = nil
    var tone: Theme.Tone = .neutral
    var action: (label: String, run: () -> Void)? = nil

    var body: some View {
        let (fg, bg) = Theme.pair(tone)
        return VStack(spacing: 10) {
            ZStack {
                Circle().fill(bg).frame(width: 66, height: 66)
                Image(systemName: icon)
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(fg)
            }
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
            if let d = detail {
                Text(d).font(.caption).foregroundStyle(Theme.ink3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let a = action {
                Button(a.label, action: a.run)
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26).padding(.horizontal, 20)
    }
}

// ── 数值呈现 ────────────────────────────────────────────────────────────────

enum Num {
    /// 体测值是 Double，直接插值会印出 "63.900000000000006" 这种。
    /// 整数就不带小数点（引体向上 9 个），否则最多一位（体重 63.9、50 米跑 8.2）。
    static func s(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }

    /// 带符号的变化量：+8 / −4.6。用真正的减号 U+2212，不用连字符 —— 等宽数字下
    /// 连字符比减号窄，一列变化量排下来符号会左右跳。
    static func signed(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        if r == 0 { return "±0" }
        return (r > 0 ? "+" : "−") + s(abs(r))
    }

    /// 相对首测的变化幅度。后端 pct 已经是百分数（-7.86 = 降了 7.86%），
    /// 这里只负责印，别再乘 100。
    static func pct(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        if r == 0 { return "±0%" }
        return (r > 0 ? "+" : "−") + String(format: "%.1f", abs(r)) + "%"
    }
}
