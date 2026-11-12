import Foundation

struct GlancePreferences: Codable, Equatable {
    var menuBar = true
    var island = false
    var activity = true
    var counts = true
    var actions = true
    var ink = true
}

struct GlanceCounts: Equatable {
    let choices: Int
    let pending: Int
    let seconds: Double

    init(_ library: Library, now: Date = Date(), calendar: Calendar = .current) {
        let start = calendar.startOfDay(for: now)
        let today = JourneyAnalytics.realSessions(library).filter { $0.startedAt >= start && $0.startedAt <= now }
        choices = today.count
        seconds = today.reduce(0) { $0 + $1.elapsed(at: now) }
        let active = library.sessions.last { $0.stoppedAt == nil }?.itemID
        pending = library.items.filter { item in
            !item.isDemo && item.id != active && AttentionEngine.eligible(item, now: now) &&
                library.roamingQueue?.unavailableTargets?[item.id] != item.target
        }.count
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let mins = Int(min(seconds / 60, Double(Int32.max)))
        if mins == 0 && seconds > 0 { return "<1 分" }
        if mins < 60 { return "\(mins) 分" }
        return "\(mins / 60) 小时 \(mins % 60) 分"
    }
}
