import SwiftUI

// ── 状态徽标 ────────────────────────────────────────────────────────────────
// 颜色一律从 Theme.pair 取 —— 这里曾经各写各的 .green/.orange，与卡片、空态、
// 统计块的同名色对不上（同一个「橙」有三个值）。别再写字面量色。

struct StatusTag: View {
    let status: String
    var label: String? = nil

    static func tone(_ status: String) -> Theme.Tone {
        switch status {
        case "completed": return .ok
        case "no_show":   return .warn
        case "cancelled": return .neutral
        default:          return .accent
        }
    }

    var body: some View {
        Pill(text: label ?? Vocab.statusShort[status] ?? status,
             tone: Self.tone(status))
    }
}

struct BucketTag: View {
    let bucket: String

    static func tone(_ bucket: String) -> Theme.Tone {
        switch bucket {
        case "active": return .ok
        case "lapsed": return .warn
        case "voided": return .danger
        default:       return .neutral
        }
    }

    var body: some View {
        Pill(text: Vocab.bucketLabels[bucket] ?? bucket, tone: Self.tone(bucket))
    }
}

// ── 载入 / 错误 / 空态 ──────────────────────────────────────────────────────

struct Loading: View {
    var body: some View {
        HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 24)
    }
}

struct EmptyHint: View {
    let text: String
    var body: some View {
        Text(text).font(.subheadline).foregroundStyle(Theme.ink3)
            .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 18)
    }
}

struct ErrorBar: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.danger).font(.footnote)
            Text(text).font(.footnote).foregroundStyle(Theme.danger)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Theme.dangerSoft)
        .clipShape(RoundedRectangle(cornerRadius: Theme.rInner, style: .continuous))
    }
}

/// 教练端顶部的告警条（domain.coach_warnings）。红=过时未处理，橙/黄=余额或到期。
struct WarningRow: View {
    let w: CoachWarning
    private var tone: Theme.Tone {
        switch w.level {
        case "red": return .danger
        case "orange": return .warn
        default: return .accent
        }
    }
    var body: some View {
        let (fg, bg) = Theme.pair(tone)
        HStack(spacing: 9) {
            ZStack {
                Circle().fill(bg).frame(width: 24, height: 24)
                Image(systemName: w.level == "red" ? "exclamationmark" : "bell.fill")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(fg)
            }
            Text(w.text).font(.footnote).foregroundStyle(Theme.ink)
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.ink3)
        }
    }
}

// ── 理由 / 强制覆盖：状态改写与纠错的公共输入块 ─────────────────────────────

struct ReasonFields: View {
    @Binding var reason: String
    @Binding var reasonCode: String
    var required: Bool
    var showForce: Bool = false
    @Binding var force: Bool

    var body: some View {
        Section {
            Picker("原因分类", selection: $reasonCode) {
                Text("不填").tag("")
                ForEach(Vocab.reasonCodes, id: \.0) { Text($0.1).tag($0.0) }
            }
            TextField(required ? "理由（必填）" : "理由（可不填）", text: $reason, axis: .vertical)
                .lineLimit(1...4)
            if showForce {
                // 每次渲染都是未勾选 —— 与网页端同约束，刻意不回填，防形成条件反射
                Toggle("强制覆盖（忽略冲突/档期/超排警告）", isOn: $force)
            }
        } header: {
            Text("理由")
        } footer: {
            if required {
                Text("从「已上课 / 未到 / 已取消」改出去属纠错或通融，后端强制要求填理由。")
            }
        }
    }
}

/// 409 软警告的确认弹窗内容
struct WarnConfirm: View {
    let warns: [Warn]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(warns) { w in
                Text("• " + w.message).font(.footnote)
            }
        }
    }
}

extension View {
    /// 统一的 .task 错误呈现方式：把 APIError 拍成一句话
    func mapError(_ error: Error) -> String {
        (error as? APIError)?.errorDescription ?? error.localizedDescription
    }
}

func errText(_ error: Error) -> String {
    (error as? APIError)?.errorDescription ?? error.localizedDescription
}
