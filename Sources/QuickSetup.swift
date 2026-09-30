import Foundation

/// 「快速开始」的编排：App 的 QuickSetupView 与命令行 `fitcoach setup` 共用这一份。
/// 只经现有 API 补齐空白项（上课地点、常用体测项目、每周 09:00–18:00 档期），不写演示业务记录。
///
/// 只 import Foundation（命令行工具与 App 一起编它）。**可重入**：每一步都从服务端现状推算
/// 还差什么，中途失败后再跑一次只补剩下的 —— 不靠某个进程内存里记着的「还剩哪几天」，
/// 所以换一个进程（命令行重跑、App 重开）也能接着补完。
enum QuickSetup {
    static let startTime = "09:00"
    static let endTime = "18:00"

    /// 上课日模板；weekday 与后端一致：0 = 周日 … 6 = 周六（strftime %w）。
    enum Days: String, CaseIterable {
        case weekdays, daily, weekend

        var weekdays: [Int] {
            switch self {
            case .weekdays: return Array(1...5)
            case .daily: return Array(0...6)
            case .weekend: return [0, 6]
            }
        }
    }

    struct Outcome: Codable {
        /// 新建的地点 id；已有任何地点（含停用）时为 nil。
        var createdLocationId: Int?
        /// 本次导入的常用体测项目数；已有项目时为 0（后端同样只在一个都没有时灌）。
        var seededMetrics: Int
        /// 本次补上的星期（0 = 周日）。
        var addedWeekdays: [Int]
        /// 已有教练自己配过的档期（别的时段 / 别的星期 / 任何例外），档期保持原样没动。
        var keptExistingAvailability: Bool
    }

    /// 还要补哪几天。空白，或只有本流程建过的 09:00–18:00 规则（中途失败留下的）时才补；
    /// 已有其它时段、所选以外的星期或任何例外 = 教练自己配过，返回 nil 表示不动档期。
    static func pendingWeekdays(_ availability: AvailabilityResp, weekdays: [Int]) -> [Int]? {
        guard availability.exceptions.isEmpty else { return nil }
        let wanted = Set(weekdays)
        var covered = Set<Int>()
        for (key, rules) in availability.rules_by_wd {
            for rule in rules {
                guard let day = Int(key), wanted.contains(day),
                      rule.start_time == startTime, rule.end_time == endTime else { return nil }
                covered.insert(day)
            }
        }
        return weekdays.filter { !covered.contains($0) }
    }

    @MainActor
    static func run(api: API, location: String, weekdays: [Int]) async throws -> Outcome {
        var outcome = Outcome(createdLocationId: nil, seededMetrics: 0, addedWeekdays: [],
                              keptExistingAvailability: false)
        let places: LocationsResp = try await api.get("/coach/api/locations")
        if places.locations.isEmpty {
            let created = try await api.post("/coach/api/locations", ["name": location, "address": ""])
            outcome.createdLocationId = created.id
        }
        let metrics: MetricsResp = try await api.get("/coach/api/metrics")
        if metrics.metrics.isEmpty {
            let seeded = try await api.post("/coach/api/metrics/seed", [:])
            outcome.seededMetrics = seeded.created ?? 0
        }
        let availability: AvailabilityResp = try await api.get("/coach/api/availability")
        guard let pending = pendingWeekdays(availability, weekdays: weekdays) else {
            outcome.keptExistingAvailability = true
            return outcome
        }
        for day in pending {
            try await api.post("/coach/api/availability/rules", [
                "weekday": String(day), "start_time": startTime, "end_time": endTime,
            ])
            outcome.addedWeekdays.append(day)
        }
        return outcome
    }
}
