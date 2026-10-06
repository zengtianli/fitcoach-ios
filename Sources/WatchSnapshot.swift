import Foundation

/// iPhone 递给 Apple Watch 的「今天」：教练抬腕要看的全部内容，**只读**。
///
/// 手表不联网、不拿教练 cookie：iPhone 拉 `/coach/api/schedule?range=today` 与 `/coach/api/students`，
/// 经 WatchConnectivity 把这份快照递过去（Sources/WatchLink.swift → Watch/WatchSessionReceiver.swift）。
/// 凭证只留在 iPhone；手表上丢了也只是一天的课表。改状态（记已上课）不放手表：后端没有离线队列，
/// 手表上点了、iPhone 不在身边时只能失败，「上完课抬腕一点」的承诺兑现不了。
///
/// 字段不是 Models.swift 的原样转发，而是手表要画的那几样（时间、学员、地点、剩几节）——
/// 价格、备注、课包这些手表不需要的东西结构上就进不来。只 import Foundation：手表 app、表盘复杂功能、
/// iPhone 三处编同一份。
struct WatchSnapshot: Codable, Equatable {
    static let schema = 1

    struct Lesson: Codable, Hashable, Identifiable {
        let id: Int
        let startAt: String        // 'YYYY-MM-DD HH:MM'（Asia/Shanghai 墙钟，同后端）
        let endAt: String
        let studentId: Int
        let student: String
        let place: String?
        let content: String
        let status: String         // scheduled | completed | no_show | cancelled（Vocab.statuses）
        let remaining: Int?        // 这位学员现在还剩几节可用课时（available_total）
        /// 状态的短名，iPhone 按后台词表解好带过来（手表自己不联网，拿不到后台覆盖项）；旧快照没有 → 手表用自带的
        var statusLabel: String? = nil

        var start: String { TZ.hm(startAt) }
        var end: String { TZ.hm(endAt) }
        var startDate: Date { TZ.date(fromStamp: startAt) }
        var endDate: Date { TZ.date(fromStamp: endAt) }
        var isOpen: Bool { status == "scheduled" }
    }

    struct Balance: Codable, Hashable, Identifiable {
        let id: Int
        let name: String
        let remaining: Int         // available_total
        let lapsed: Int
        let expiringSoon: Int
    }

    let day: String                // 这份课表是哪天的（'YYYY-MM-DD'）
    let generatedAt: Date
    let lessons: [Lesson]          // 按开始时间
    let balances: [Balance]        // 在册且有课包的学员，剩得最少的在前

    init(day: String, generatedAt: Date, lessons: [Lesson], balances: [Balance]) {
        self.day = day
        // Date 内部以 2001 年为纪元；既有协议用 Unix seconds Double。
        // 两者在当前日期的浮点精度不同，构造时统一到线格式可表达的值，
        // 使完整快照严格往返相等；不更改 JSON 字段或旧数据解码方式。
        self.generatedAt = Date(timeIntervalSince1970: generatedAt.timeIntervalSince1970)
        self.lessons = lessons
        self.balances = balances
    }

    /// 「下一节」：还没上（scheduled）且没结束的第一节 —— 正在上的那节也算，教练要看的就是它。
    func next(after now: Date) -> Lesson? {
        lessons.first { $0.isOpen && $0.endDate > now }
    }

    /// 今天剩下的（含正在上的）课。
    func upcoming(after now: Date) -> [Lesson] {
        lessons.filter { $0.isOpen && $0.endDate > now }
    }

    func isToday(_ now: Date = Date()) -> Bool { day == TZ.dateString(now) }

    /// 表盘时间线的切换点：每节课结束的那一刻「下一节」就换人。
    func changeDates(after now: Date) -> [Date] {
        lessons.map(\.endDate).filter { $0 > now }.sorted()
    }

    /// 同一内容不重复发：generatedAt 每次都变，比的是其余字段。
    func sameContent(as other: WatchSnapshot?) -> Bool {
        guard let other else { return false }
        return day == other.day && lessons == other.lessons && balances == other.balances
    }
}

// MARK: - 编码（WatchConnectivity 的上下文只收 plist 类型：快照整份编成 Data）

extension WatchSnapshot {
    enum Key {
        static let snapshot = "snapshot"
        static let schema = "v"
        static let signedOut = "signedOut"
        static let at = "at"
        static let want = "want"
    }

    func encoded() -> Data? {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return try? e.encode(self)
    }

    static func decode(_ data: Data) -> WatchSnapshot? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return try? d.decode(WatchSnapshot.self, from: data)
    }
}

// MARK: - 演示数据（截图、手表模拟器验收；`-fitcoach.watchDemo 1`）

extension WatchSnapshot {
    /// 全是占位假名（同后端 seed.py 的张三 / 李四 / 王五），时间按「现在」排：两节已上、一节正在上、两节待上，
    /// 表盘与列表的每种状态都画得到。不联网，不读任何真实数据。
    static func demo(now: Date = Date()) -> WatchSnapshot {
        let cal = TZ.calendar
        // 以「现在」所在的整点为锚；夜里（课排不进当天）改锚在 14:00，课表仍落在今天
        let hour = cal.component(.hour, from: now)
        let base = cal.date(bySettingHour: (5...19).contains(hour) ? hour : 14, minute: 0, second: 0, of: now) ?? now
        func stamp(_ hours: Double) -> String {
            TZ.stampString(base.addingTimeInterval(hours * 3600))
        }
        let rows: [(Double, Int, String, String?, String, Int)] = [
            (-4, 3, "王五", "社区体育馆", "自重基础 · 髋铰链复习", 8),
            (-2.5, 1, "张三", "力量工作室（城西店）", "下肢日 · 深蹲进阶", 16),
            (-0.5, 4, "赵六", "社区体育馆", "体能测试 · 立定跳远", 3),
            (1.5, 5, "孙七", "力量工作室（城西店）", "上肢日 · 推拉平衡", 12),
            (3, 2, "李四", "力量工作室（城西店）", "赛前周期 · 收尾", 1),
        ].filter { cal.isDate(base.addingTimeInterval($0.0 * 3600), inSameDayAs: now) }
        let lessons = rows.enumerated().map { i, r in
            let end = base.addingTimeInterval((r.0 + 1) * 3600)
            return Lesson(id: 100 + i, startAt: stamp(r.0), endAt: stamp(r.0 + 1), studentId: r.1, student: r.2,
                          place: r.3, content: r.4, status: end <= now ? "completed" : "scheduled", remaining: r.5)
        }
        let balances = [Balance(id: 2, name: "李四", remaining: 1, lapsed: 0, expiringSoon: 0),
                        Balance(id: 4, name: "赵六", remaining: 3, lapsed: 0, expiringSoon: 0),
                        Balance(id: 3, name: "王五", remaining: 8, lapsed: 0, expiringSoon: 8),
                        Balance(id: 5, name: "孙七", remaining: 12, lapsed: 0, expiringSoon: 0),
                        Balance(id: 1, name: "张三", remaining: 16, lapsed: 4, expiringSoon: 0)]
        return WatchSnapshot(day: TZ.dateString(now), generatedAt: now.addingTimeInterval(-120),
                             lessons: lessons, balances: balances)
    }
}
