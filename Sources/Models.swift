import Foundation

// 本文件的每个结构体都**逐字对应** fitcoach 后端 domain.py 的 dataclass 字段名。
// 后端出 JSON 走 dataclasses.asdict()，键名 = 字段名（含 `date_` 这种尾下划线）。
// 改这里之前先看 ~/Apps/fitcoach/service/domain.py —— 禁按「我以为它长这样」猜字段。

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

struct ScheduleResp: Codable, UICarrier {
    let range: String
    let date: String
    let title: String
    let prev_date: String
    let next_date: String
    let today: String
    let now: String
    let days: [DayGroup]
    let warnings: [CoachWarning]
    /// 后台覆盖项（词表、说明文字、阈值）；旧后端不带。解不开只丢这一段，课表照常。
    var ui: Lenient<FeedUI>? = nil
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

struct SessionFormResp: Codable, UICarrier {
    let today: String
    let session: SessionRow?
    let students: [NamedRef]
    let packages: [PackagePick]
    let default_package_id: Int?
    let locations: [NamedRef]
    let windows: [[String]]          // [["09:00","12:00"], …]
    let windows_reason: String?
    var ui: Lenient<FeedUI>? = nil
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
    let created: Int?           // /coach/api/metrics/seed：本次导入的项目数
}


// ── 词表：后端说了算，这里只留兜底 ──────────────────────────────────────────
//
// 课次状态与理由分类的名称、先后由后端在 `ui` 段里给（ping / schedule / session-form 三个读端点，
// 后端取自 domain.STATUSES / status_label / REASON_CODES 与网页端模板的 REASON_CODE_LABELS）。
// 下面 `bundled…` 是没拿到时的兜底：旧后端、还没联上网的首次启动、覆盖项写坏。
// 改名字改后端，不改这里、不发版。键：`status.<码>` `status_short.<码>` `reason.<码>` `bucket.<码>`。

/// 带着后台覆盖项（`ui`）的响应。`API.get` 解到这类响应就把它交给 `Remote.ui`。
protocol UICarrier {
    var ui: Lenient<FeedUI>? { get }
}

enum Vocab {
    private static let bundledStatuses = ["scheduled", "completed", "no_show", "cancelled"]

    private static let bundledStatusLabels: [String: String] = [
        "scheduled": "已排课",
        "completed": "已上课",
        "no_show": "未到（已扣课时）",
        "cancelled": "已取消（未扣课时）",
    ]

    private static let bundledStatusShort: [String: String] = [
        "scheduled": "已排课", "completed": "已上课", "no_show": "未到", "cancelled": "已取消",
    ]

    private static let bundledReasons: [(String, String)] = [
        ("mistake", "记错了"),
        ("student_leave", "学员请假"),
        ("student_injury", "学员伤病"),
        ("coach_reason", "教练原因"),
        ("venue_weather", "场地 / 天气"),
        ("goodwill", "通融"),
        ("other", "其它"),
    ]

    private static let bundledBuckets: [String: String] = [
        "active": "可用", "lapsed": "已过期", "exhausted": "已用完", "voided": "已作废",
    ]

    /// 后台 `ui.order` 里某一类词（按前缀）的先后，去掉前缀；没下发为空。
    private static func remoteOrder(_ prefix: String) -> [String] {
        Remote.order([]).filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    /// 自带词表盖上后台给的名称；后台多给的码（自带表里没有）也认。
    private static func labels(_ prefix: String, _ bundled: [String: String]) -> [String: String] {
        guard let vocab = Remote.ui?.vocab else { return bundled }
        var out = bundled
        for (key, word) in vocab where key.hasPrefix(prefix) {
            if let label = word.label, !label.isEmpty { out[String(key.dropFirst(prefix.count))] = label }
        }
        return out
    }

    /// 可选的课次状态。先后听后台的；码的全集仍是这四个（客户端按它们画颜色与按钮），
    /// 后台漏给的补在后面 —— 写错顺序也不会让某个状态选不到。
    static var statuses: [String] {
        let remote = remoteOrder("status.").filter(bundledStatuses.contains)
        return remote + bundledStatuses.filter { !remote.contains($0) }
    }

    static var statusLabels: [String: String] { labels("status.", bundledStatusLabels) }

    /// 徽标上的短名。后端没有这张表的常量，只在 ui.json 的 `status_short.<码>` 里改。
    static var statusShort: [String: String] { labels("status_short.", bundledStatusShort) }

    /// 理由分类（码，名称）。后台给了就完全按后台的码与先后（后端新增、下架理由都不用发版）；
    /// 没给用自带的七个，与 templates/_macros.html 的 REASON_CODE_LABELS 同序。
    static var reasonCodes: [(String, String)] {
        let bundled = Dictionary(uniqueKeysWithValues: bundledReasons)
        let remote = remoteOrder("reason.")
        guard !remote.isEmpty else {
            return bundledReasons.map { ($0.0, Remote.label("reason.\($0.0)", $0.1)) }
        }
        return remote.map { ($0, Remote.label("reason.\($0)", bundled[$0] ?? $0)) }
    }

    static func reasonLabel(_ code: String?) -> String {
        guard let c = code else { return "" }
        return reasonCodes.first { $0.0 == c }?.1 ?? c
    }

    /// 课包分类。后端没有这张表的常量，只在 ui.json 的 `bucket.<码>` 里改。
    static var bucketLabels: [String: String] { labels("bucket.", bundledBuckets) }

    /// 后端规则（domain.needs_reason）：源状态非 scheduled 的改动必须填理由。
    /// 客户端据此**提前**把理由框标成必填；服务端仍是唯一判据，这里只做 UX 提示。
    static func needsReason(from: String) -> Bool { from != "scheduled" }
}
