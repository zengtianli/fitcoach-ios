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
    let growth: [StudentGrowthView]      // v3：给家长看的成长展示
}


// ── 成长数据（schema v3）────────────────────────────────────────────────────
// 字段名逐字照 domain.py 的 dataclass：Metric / Measurement / MetricProgress /
// GrowthPoint / StudentGrowthView / Attendance。禁猜、禁改名。
//
// ⚠ 判据不在这一侧：「进步了没有」要过 higher_is_better（50 米跑变快 = 数值变小），
// 那个判断**只在 domain._progress 里有一份**，结论经 `improved` 送过来。
// 客户端一律读 `improved`，**禁止**在任何地方写 `delta > 0` 这种第二实现。

struct Metric: Codable, Hashable, Identifiable {
    let id: Int
    let name: String
    let unit: String
    let higher_is_better: Int
    let sort_order: Int
    let is_active: Int
}

struct Measurement: Codable, Hashable, Identifiable {
    let id: Int
    let student_id: Int
    let metric_id: Int
    let metric_name: String
    let unit: String
    let taken_on: String
    let value: Double
    let note: String          // 教练自用，学员端结构上拿不到
}

struct GrowthPoint: Codable, Hashable, Identifiable {
    var id: String { taken_on }
    let taken_on: String
    let value: Double
}

struct MetricProgress: Codable, Hashable, Identifiable {
    var id: Int { metric_id }
    let metric_id: Int
    let name: String
    let unit: String
    let higher_is_better: Int
    let n_points: Int
    let first_on: String
    let first_value: Double
    let latest_on: String
    let latest_value: Double
    let delta: Double         // latest - first（原始差，带符号）
    let improved: Bool?       // nil = 只测过一次，还没有「变化」可言
    let pct: Double?          // 相对首测的变化幅度（%）；首测为 0 时 nil
    let best_value: Double
    let best_on: String
}

struct Attendance: Codable, Hashable {
    let total: Int
    let completed: Int
    let no_show: Int
    let cancelled: Int
    let rate: Int             // 到课率 %，无分母时 100
}

struct GrowthResp: Codable {
    let metrics: [Metric]
    let progress: [MetricProgress]
    let series: [String: [GrowthPoint]]   // 键 = metric_id 的字符串形式
    let measurements: [Measurement]
    let attendance: Attendance
    let today: String
}

struct MetricsResp: Codable {
    let today: String
    let metrics: [Metric]                 // 含停用项（停用不删）
}

/// 学员端（家长）看到的成长条目。窄 dataclass —— **没有 note 字段**，
/// 教练备注在结构上进不来（后端 INV-7 的延伸）。要加字段先改 domain 那侧。
struct StudentGrowthView: Codable, Hashable, Identifiable {
    var id: String { name }
    let name: String
    let unit: String
    let latest_value: Double
    let latest_on: String
    let delta: Double
    let improved: Bool?
    let n_points: Int
    let points: [GrowthPoint]
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
