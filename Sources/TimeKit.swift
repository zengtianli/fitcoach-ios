import Foundation

// ── 时间口径 ────────────────────────────────────────────────────────────────
// 后端把课程时间存**本地墙钟** TEXT 'YYYY-MM-DD HH:MM'，不做 UTC 转换；
// APP_TZ（db.py 单点定义，线上 Asia/Shanghai）只用于算「今天/本周/现在」。
// 客户端必须用同一个时区把 Date ↔ 字符串互转，否则手机在别的时区时，
// DatePicker 选的「今天」和服务器的「今天」会差一天 —— 这种错不报错，只是数据悄悄错位。
enum TZ {
    static let zone = TimeZone(identifier: "Asia/Shanghai") ?? .current

    private static func fmt(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = pattern
        return f
    }

    static let dateFmt = fmt("yyyy-MM-dd")
    static let stampFmt = fmt("yyyy-MM-dd HH:mm")
    static let timeFmt = fmt("HH:mm")

    static func dateString(_ d: Date) -> String { dateFmt.string(from: d) }
    static func stampString(_ d: Date) -> String { stampFmt.string(from: d) }
    static func timeString(_ d: Date) -> String { timeFmt.string(from: d) }

    static func date(fromDate s: String) -> Date { dateFmt.date(from: s) ?? Date() }
    static func date(fromStamp s: String) -> Date { stampFmt.date(from: s) ?? Date() }
    static func date(fromTime s: String) -> Date { timeFmt.date(from: s) ?? Date() }

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }

    static func shift(_ ymd: String, days: Int) -> String {
        let d = calendar.date(byAdding: .day, value: days, to: date(fromDate: ymd)) ?? Date()
        return dateString(d)
    }

    /// 'YYYY-MM-DD' → 'MM-DD'（分组标题用，年份在日程里是噪音）
    static func md(_ ymd: String) -> String {
        ymd.count >= 10 ? String(ymd.dropFirst(5).prefix(5)) : ymd
    }

    /// 'YYYY-MM-DD HH:MM' → 'HH:MM'
    static func hm(_ stamp: String) -> String {
        stamp.count >= 16 ? String(stamp.suffix(5)) : stamp
    }
    /// 'YYYY-MM-DD HH:MM' → 'MM-DD HH:MM'
    static func mdhm(_ stamp: String) -> String {
        stamp.count >= 16 ? String(stamp.dropFirst(5)) : stamp
    }
}
