import Foundation

// 本文件的每个结构体都**逐字对应** fitcoach 后端 domain.py 的 dataclass 字段名。
// 后端出 JSON 走 dataclasses.asdict()，键名 = 字段名（含 `date_` 这种尾下划线）。
// 改这里之前先看 ~/Dev/services/fitcoach/domain.py —— 禁按「我以为它长这样」猜字段。

struct Warn: Codable, Hashable, Identifiable {
    var id: String { code + message }
    let code: String        // conflict|off_hours|overbook|expired|past_time|no_availability|…
    let message: String
    let blocking: Bool      // true = 硬拒，force 也不放行
}

struct CoachWarning: Codable, Hashable, Identifiable {
    var id: String { level + text + href }
    let level: String       // red | orange | yellow
    let text: String
    let href: String
}

struct SessionRow: Codable, Hashable, Identifiable {
    let id: Int
    let package_id: Int
    let student_id: Int
    let student_name: String
    let start_at: String
    let end_at: String
    let duration_min: Int
    let location_id: Int?
    let location_name: String?
    let content: String
    let status: String
    let status_label: String
    let created_at: String
    let is_backfilled: Bool
}

struct DayGroup: Codable, Hashable, Identifiable {
    var id: String { date_ }
    let date_: String
    let wd_name: String
    let sessions: [SessionRow]
}

struct ScheduleResp: Codable {
    let range: String
    let date: String
    let title: String
    let prev_date: String
    let next_date: String
    let today: String
    let now: String
    let days: [DayGroup]
    let warnings: [CoachWarning]
}

struct StudentListRow: Codable, Hashable, Identifiable {
    let id: Int
    let name: String
    let available_total: Int
    let lapsed_total: Int
    let expiring_soon: Int
    let min_bookable: Int
    let has_link: Int
    let n_packages: Int
}

struct StudentsResp: Codable {
    let today: String
    let rows: [StudentListRow]
    let inactive: [StudentListRow]
}

/// `_student_public()` 的形状：token 已被剥掉，只留 has_link。
struct StudentPublic: Codable, Hashable, Identifiable {
    let id: Int
    let name: String
    let note: String
    let is_active: Int
    let coach_id: Int
    let has_link: Bool
}

struct Totals: Codable, Hashable {
    let available_total: Int
    let lapsed_total: Int
    let over_used: Int
}

struct PackageRow: Codable, Hashable, Identifiable {
    var id: Int { package_id }
    let package_id: Int
    let student_id: Int
    let total_sessions: Int
    let unit_price_cents: Int
    let purchased_on: String
    let expires_on: String?
    let note: String
    let voided_at: String?
    let void_reason: String
    let n_completed: Int
    let n_no_show: Int
    let n_cancelled: Int
    let booked: Int
    let used: Int
    let remaining: Int
    let bookable: Int
    let bucket: String      // active | lapsed | exhausted | voided
}

struct StudentDetailResp: Codable {
    let student: StudentPublic
    let totals: Totals
    let buckets: [String: [PackageRow]]
    let sessions: [SessionRow]
    let today: String
}

struct NamedRef: Codable, Hashable, Identifiable {
    let id: Int
    let name: String
}

struct PackagePick: Codable, Hashable, Identifiable {
    var id: Int { package_id }
    let package_id: Int
    let label: String
    let bookable: Int
    let expires_on: String?
    let selectable: Bool
}

struct SessionFormResp: Codable {
    let today: String
    let session: SessionRow?
    let students: [NamedRef]
    let packages: [PackagePick]
    let default_package_id: Int?
    let locations: [NamedRef]
    let windows: [[String]]          // [["09:00","12:00"], …]
    let windows_reason: String?
}

struct Location: Codable, Hashable, Identifiable {
    let id: Int
    let name: String
    let address: String
    let is_active: Int
}

struct LocationsResp: Codable {
    let today: String
    let locations: [Location]
}

struct AvailRule: Codable, Hashable, Identifiable {
    let id: Int
    let weekday: Int
    let start_time: String
    let end_time: String
}

struct AvailException: Codable, Hashable, Identifiable {
    let id: Int
    let on_date: String
    let kind: String                 // block | open
    let start_time: String?
    let end_time: String?
    let reason: String
}

struct DayWindows: Codable, Hashable, Identifiable {
    var id: String { date_ }
    let date_: String
    let wd_name: String
    let windows: [[String]]
    let empty_reason: String?
}

struct AvailabilityResp: Codable {
    let today: String
    let wd_names: [String]
    let rules_by_wd: [String: [AvailRule]]
    let exceptions: [AvailException]
    let preview: [DayWindows]
}

struct AuditRow: Codable, Hashable, Identifiable {
    let id: Int
    let at: String
    let actor: String
    let entity: String
    let entity_id: Int
    let field: String
    let old_value: String?
    let new_value: String?
    let package_id: Int?
    let reason_code: String?
    let reason: String
    let student_name: String?
    let session_start_at: String?
    let kind: String                 // normal|correction|concession|backfill|admin
    let delta: Int
}

struct AuditResp: Codable {
    let today: String
    let show_all: Bool
    let student_id: Int?
    let rows: [AuditRow]
    let students: [NamedRef]
}

struct LinkResp: Codable {
    let has_link: Bool
    let link_url: String?
}

// ── 学员端（/s/api/view）：9 键窄视图，结构上没有价格/备注/审计（后端 INV-7）──

struct StudentPkgView: Codable, Hashable, Identifiable {
    var id: String { "\(remaining)-\(expires_on ?? "")-\(bucket)" }
    let remaining: Int
    let expires_on: String?
    let bucket: String               // active | lapsed
}

struct StudentSessionView: Codable, Hashable, Identifiable {
    var id: String { start_at + status }
    let start_at: String
    let end_at: String
    let duration_min: Int
    let location_name: String?
    let content: String
    let status: String
    let status_label: String
}

struct StudentView: Codable {
    let student_name: String
    let available_total: Int
    let lapsed_total: Int
    let over_used: Int
    let packages: [StudentPkgView]
    let next_session: StudentSessionView?
    let history: [StudentSessionView]
    let upcoming_cancelled: [StudentSessionView]
    let today: String
}

// ── 写路径的通用响应 ────────────────────────────────────────────────────────

struct MutationResp: Codable {
    let ok: Bool?
    let id: Int?
    let warnings: [Warn]?
    let warning: String?
    let error: String?
    let revoked: Bool?
    let cancelled: Int?
    let link_url: String?
}

// ── 词表：与 domain.REASON_CODES / _STATUS_LABELS 逐字一致 ──────────────────

enum Vocab {
    static let statuses = ["scheduled", "completed", "no_show", "cancelled"]

    static let statusLabels: [String: String] = [
        "scheduled": "已排课",
        "completed": "已上课",
        "no_show": "未到（已扣课时）",
        "cancelled": "已取消（未扣课时）",
    ]

    static let statusShort: [String: String] = [
        "scheduled": "已排课", "completed": "已上课", "no_show": "未到", "cancelled": "已取消",
    ]

    /// 顺序与 templates/_macros.html 的 REASON_CODE_LABELS 一致
    static let reasonCodes: [(String, String)] = [
        ("mistake", "记错了"),
        ("student_leave", "学员请假"),
        ("student_injury", "学员伤病"),
        ("coach_reason", "教练原因"),
        ("venue_weather", "场地 / 天气"),
        ("goodwill", "通融"),
        ("other", "其它"),
    ]

    static func reasonLabel(_ code: String?) -> String {
        guard let c = code else { return "" }
        return reasonCodes.first { $0.0 == c }?.1 ?? c
    }

    static let bucketLabels: [String: String] = [
        "active": "可用", "lapsed": "已过期", "exhausted": "已用完", "voided": "已作废",
    ]

    /// 后端规则（domain.needs_reason）：源状态非 scheduled 的改动必须填理由。
    /// 客户端据此**提前**把理由框标成必填；服务端仍是唯一判据，这里只做 UX 提示。
    static func needsReason(from: String) -> Bool { from != "scheduled" }
}
