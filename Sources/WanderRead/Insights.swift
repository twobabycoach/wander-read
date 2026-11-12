import Foundation

struct ExposureEvent: Codable, Identifiable {
    var id=UUID()
    var itemID: UUID
    var date: Date
    var source: String
    var isDemo: Bool
    var strategyName: String
    var branch: String
}
struct MilestoneUnlock: Codable, Identifiable, Equatable {
    var id: String
    var earnedAt: Date
}
struct MilestoneDefinition: Identifiable {
    var id: String
    var title: String
    var detail: String
    var symbol: String
    var gift: String
    static let all = [
        MilestoneDefinition(id:"first",title:"好奇启程",detail:"第一次主动打开自己的收藏",symbol:"sparkle",gift:"解锁「夜航」分享配色"),
        MilestoneDefinition(id:"return",title:"旧页重逢",detail:"隔天再次选择同一篇收藏",symbol:"arrow.uturn.backward",gift:"解锁「陶土」分享配色"),
        MilestoneDefinition(id:"topics",title:"走向别处",detail:"在至少三篇材料里遇见三个主题",symbol:"point.3.connected.trianglepath.dotted",gift:"解锁「晨光」分享配色"),
        MilestoneDefinition(id:"pause",title:"从容收尾",detail:"五次由自己决定读到这里",symbol:"leaf",gift:"留下一枚从容收尾印章"),
        MilestoneDefinition(id:"reflection",title:"留下一句话",detail:"主动记下一句自己的想法",symbol:"quote.bubble",gift:"留下一枚个人思考印章")
    ]
}
enum JourneyPeriod: Int, CaseIterable, Identifiable {
    case week=7, month=30, quarter=90
    var id: Int {rawValue}
    var title: String {"最近 \(rawValue) 天"}
}
struct TopicTotal: Identifiable {
    var name: String
    var value: Double
    var id: String {name}
}
struct DayActivity: Identifiable {
    var date: Date
    var count: Int
    var id: Date {date}
}
struct SourceTotal: Identifiable {
    var name: String
    var choices: Int
    var exposures: Int
    var id: String {name}
}
struct StrategyTotal: Identifiable {
    var name: String
    var choices: Int
    var helpful: Int
    var feedback: Int
    var id: String {name}
}
struct JourneySummary {
    var sessions: [ReadingSession]
    var days: [DayActivity]
    var topics: [TopicTotal]
    var sources: [SourceTotal]
    var strategies: [StrategyTotal]
    var uniqueItems: Int
    var activeDays: Int
    var returns: Int
    var closed: Int
    var recordedSeconds: Double
}
enum JourneyAnalytics {
    static func realSessions(_ l: Library) -> [ReadingSession] {
        var items:[UUID:ReadingItem]=[:]
        for item in l.items {items[item.id]=item}
        var sessions:[ReadingSession]=[]
        for s in l.sessions {let demo=s.isDemoSnapshot ?? items[s.itemID]?.isDemo ?? false; if !demo && items[s.itemID]?.trashedAt == nil {sessions.append(s)}}
        return sessions
    }
    static func summary(_ l: Library, days: Int, now: Date=Date(), calendar: Calendar = .current) -> JourneySummary {
        let today=calendar.startOfDay(for:now)
        let start=calendar.date(byAdding:.day,value:1-days,to:today)!
        var items:[UUID:ReadingItem]=[:]
        for item in l.items {items[item.id]=item}
        var all:[ReadingSession]=[]
        for s in realSessions(l) where s.startedAt <= now {all.append(s)}
        all.sort {$0.startedAt < $1.startedAt}
        var sessions:[ReadingSession]=[]
        for s in all where s.startedAt >= start {sessions.append(s)}
        var dayCounts:[Date:Int]=[:], topicCounts:[String:Double]=[:], sourceChoices:[String:Int]=[:], sourceExposures:[String:Int]=[:]
        for s in sessions {
            dayCounts[calendar.startOfDay(for:s.startedAt),default:0] += 1
            let ts=Set(s.tagsSnapshot ?? items[s.itemID]?.tags ?? [])
            let tags=ts.isEmpty ? Set(["未分类"]) : ts
            for tag in tags {topicCounts[tag,default:0] += 1/Double(tags.count)}
            sourceChoices[s.sourceSnapshot ?? items[s.itemID]?.source ?? "其他",default:0] += 1
        }
        for e in l.exposures ?? [] where !e.isDemo && items[e.itemID]?.trashedAt == nil && e.date >= start && e.date <= now {sourceExposures[e.source,default:0] += 1}
        var heat:[DayActivity]=[]
        for offset in 0..<days {let date=calendar.date(byAdding:.day,value:offset,to:start)!; heat.append(DayActivity(date:date,count:dayCounts[date] ?? 0))}
        var topics:[TopicTotal]=[]
        for (name,value) in topicCounts {topics.append(TopicTotal(name:name,value:value))}
        topics.sort {a,b in if a.value == b.value {return a.name < b.name}; return a.value > b.value}
        let sourceNames:Set<String>=Set(sourceChoices.keys).union(Set(sourceExposures.keys))
        var sources:[SourceTotal]=[]
        for name in sourceNames {sources.append(SourceTotal(name:name,choices:sourceChoices[name] ?? 0,exposures:sourceExposures[name] ?? 0))}
        sources.sort {a,b in if a.choices == b.choices {return a.name < b.name}; return a.choices > b.choices}
        var strategyMap:[String:StrategyTotal]=[:]
        for s in sessions where s.wasRecommended == true {
            guard let name=s.strategyName else {continue}
            var value=strategyMap[name] ?? StrategyTotal(name:name,choices:0,helpful:0,feedback:0)
            value.choices += 1
            if s.usefulness != nil {value.feedback += 1}
            if s.usefulness == "有帮助" {value.helpful += 1}
            strategyMap[name]=value
        }
        let strategies:[StrategyTotal]=strategyMap.values.sorted {$0.name < $1.name}
        var seen=Set<UUID>(); var returns=0
        for s in all {if seen.contains(s.itemID) && s.startedAt >= start {returns += 1}; seen.insert(s.itemID)}
        var closed=0, seconds=0.0
        for s in sessions where s.stoppedAt != nil {closed += 1; seconds += s.seconds}
        let uniqueItems=Set(sessions.map(\.itemID)).count
        return JourneySummary(sessions:sessions,days:heat,topics:topics,sources:sources,strategies:strategies,uniqueItems:uniqueItems,activeDays:dayCounts.count,returns:returns,closed:closed,recordedSeconds:seconds)
    }
    static func earned(_ l: Library) -> [MilestoneUnlock] {
        let sessions=realSessions(l).sorted {$0.startedAt < $1.startedAt}
        var earned:[MilestoneUnlock]=[]
        if let first=sessions.first {earned.append(MilestoneUnlock(id:"first",earnedAt:first.startedAt))}
        let items=Dictionary(uniqueKeysWithValues:l.items.map {($0.id,$0)})
        var firsts:[UUID:Date]=[:], topics=Set<String>(), ids=Set<UUID>()
        for s in sessions {
            if let old=firsts[s.itemID], Calendar.current.startOfDay(for:s.startedAt) > Calendar.current.startOfDay(for:old), !earned.contains(where:{$0.id == "return"}) {earned.append(MilestoneUnlock(id:"return",earnedAt:s.startedAt))}
            if firsts[s.itemID] == nil {firsts[s.itemID]=s.startedAt}
            topics.formUnion(s.tagsSnapshot ?? items[s.itemID]?.tags ?? []); ids.insert(s.itemID)
            if topics.count >= 3 && ids.count >= 3 && !earned.contains(where:{$0.id == "topics"}) {earned.append(MilestoneUnlock(id:"topics",earnedAt:s.startedAt))}
        }
        let closed=sessions.compactMap(\.stoppedAt).sorted()
        if closed.count >= 5 {earned.append(MilestoneUnlock(id:"pause",earnedAt:closed[4]))}
        if let s=sessions.first(where:{!($0.reflection ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}) {earned.append(MilestoneUnlock(id:"reflection",earnedAt:s.stoppedAt ?? s.startedAt))}
        return earned
    }
    static func retainUnlocks(_ library: inout Library) {
        var unlocks=library.unlocks ?? []
        for item in earned(library) where !unlocks.contains(where:{$0.id == item.id}) {unlocks.append(item)}
        library.unlocks=unlocks.sorted {$0.earnedAt < $1.earnedAt}
    }
}

enum PreviewJourney {
    static func populate(_ l: inout Library) {
        // Synthetic history is created ONLY by --preview; never mixes into user data.
        let now=Date(), calendar=Calendar.current
        for i in l.items.indices {l.items[i].isDemo=false; l.items[i].metricValues=["importance":Double(4+i%6),"relevance":Double(3+(i*3)%8),"evidence":Double(3+(i*2)%8)]}
        for n in 0..<36 {
            guard !l.items.isEmpty else {break}
            let item=l.items[n%l.items.count]
            let date=calendar.date(byAdding:.day,value:-(n*2%76),to:now)!
            let duration=Double(180+(n*71)%1500)
            var s=ReadingSession(itemID:item.id,title:item.title,startedAt:date.addingTimeInterval(-duration),stoppedAt:date,seconds:duration,outcome:n%3 == 0 ? "想接着读" : "暂时放一放")
            s.tagsSnapshot=item.tags; s.sourceSnapshot=item.source; s.isDemoSnapshot=false; s.strategyName=n%3 == 0 ? "专题研究" : "自由漫游"; s.wasRecommended=true
            s.usefulness=n%5 == 0 ? "还说不准" : "有帮助"; s.reflection=n == 4 ? "有些问题值得从另一个方向重新看。" : nil
            l.sessions.append(s)
        }
        JourneyAnalytics.retainUnlocks(&l)
    }
}
