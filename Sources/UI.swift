import SwiftUI

// ── 状态徽标 ────────────────────────────────────────────────────────────────

struct StatusTag: View {
    let status: String
    var label: String? = nil

    private var color: Color {
        switch status {
        case "completed": return .green
        case "no_show": return .orange
        case "cancelled": return .secondary
        default: return .blue
        }
    }

    var body: some View {
        Text(label ?? Vocab.statusShort[status] ?? status)
            .font(.caption2).bold()
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.14))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

struct BucketTag: View {
    let bucket: String
    private var color: Color {
        switch bucket {
        case "active": return .green
        case "lapsed": return .orange
        case "voided": return .red
        default: return .secondary
        }
    }
    var body: some View {
        Text(Vocab.bucketLabels[bucket] ?? bucket)
            .font(.caption2).bold()
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.14))
            .foregroundStyle(color)
            .clipShape(Capsule())
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
        Text(text).font(.subheadline).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 18)
    }
}

struct ErrorBar: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(text).font(.footnote).foregroundStyle(.red)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// 教练端顶部的告警条（domain.coach_warnings）。红=过时未处理，橙/黄=余额或到期。
struct WarningRow: View {
    let w: CoachWarning
    private var color: Color {
        switch w.level {
        case "red": return .red
        case "orange": return .orange
        default: return .yellow
        }
    }
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(w.text).font(.footnote)
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
