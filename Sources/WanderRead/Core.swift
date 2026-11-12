import Foundation

enum ReadingState: String, Codable, CaseIterable { case inbox, resting, archived }
enum Energy: Int, Codable, CaseIterable {
    case light = 1, steady, deep
    var title: String { ["轻松一点", "状态不错", "想钻进去"][rawValue - 1] }
}
struct ReadingItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var target: String
    var note = ""
    var tags: [String] = []
    var minutes = 15
    var difficulty = 2
    var interest = 3.0
    var createdAt = Date()
    var lastShown: Date?
    var lastChosen: Date?
    var impressions = 0
    var choices = 0
    var snoozedUntil: Date?
    var state = ReadingState.inbox
    var bookmark = ""
    var isDemo = false
    var metricValues: [String: Double]?
    var priorityOverride: Double?
    var priorityLocked: Bool?
    var prioritySource: String?
    var trashedAt:Date?
    var importBatchID:UUID?
    var importBatchLabel:String?
    var researchNoteURL:String?
    var pdfReading: PDFReadingState?
    var textReading: TextReadingState?
    var zotero: ZoteroReference?
    var notebookDeliveries: [NotebookDelivery]?
    var canReadInside: Bool { canSendToResearch || zotero?.pdfKey != nil || ReadingFile.textCandidate(target) }
    var canSendToResearch:Bool {
        let url=target.hasPrefix("/") ? URL(fileURLWithPath:target):URL(string:target)
        return url?.isFileURL == true && url?.pathExtension.lowercased()=="pdf"
    }
    var source: String {
        if zotero != nil { return "Zotero" }
        if target.hasPrefix("obsidian:") { return "Obsidian" }
        if target.hasPrefix("/") || target.hasPrefix("file:") { return (target as NSString).pathExtension.lowercased() == "pdf" ? "本地 PDF" : "本地文件" }
        return URL(string: target)?.host?.replacingOccurrences(of: "www.", with: "") ?? "链接"
    }
    var primaryTag: String { tags.first ?? "未分类" }

    var resumeThought: String? {
        if let pdf = pdfReading, let cursor = pdf.cursor {
            return pdf.marks.last {
                $0.revision == cursor.revision && $0.location.page == cursor.location.page && !$0.note.isEmpty
            }?.note
        }
        guard let text = textReading, let offset = text.offset, offset >= 0 else { return nil }
        return text.excerpts.last {
            $0.revision == text.revision && $0.range.location >= 0 &&
                $0.range.location <= offset && offset - $0.range.location <= 600 && !$0.note.isEmpty
        }?.note
    }
}
struct ReadingSession: Identifiable, Codable {
    var id = UUID()
    var itemID: UUID
    var title: String
    var startedAt: Date
    var stoppedAt: Date?
    var seconds: Double = 0
    var runningSince: Date?
    var outcome: String?
    var tagsSnapshot: [String]?
    var sourceSnapshot: String?
    var isDemoSnapshot: Bool?
    var strategyName: String?
    var wasRecommended: Bool?
    var usefulness: String?
    var reflection: String?
    var inReader: Bool?
    func elapsed(at now: Date) -> Double { seconds + max(0, runningSince.map { now.timeIntervalSince($0) } ?? 0) }
}
struct Preferences: Codable {
    var shareProfile:ShareProfile?
    var appTheme:String?
    var readingWordEmphasis: Bool?
    var focusLayout: FocusLayout?
    var pdfFoldUnit: PDFFoldUnit?
    var pdfFoldPages: Int?
    var glance: GlancePreferences?
    var notebookExport: NotebookExportSettings?
    var energy = Energy.steady
    var slice = 15
    var exploration = 0.35
    var tagAffinity: [String: Double] = [:]
    var tagUpdatedAt: [String: Date]?
    var metrics: [MetricDefinition]?
    var strategies: [ReadingStrategy]?
    var strategyID: String?
    var metricDefinitions: [MetricDefinition] { metrics ?? MetricDefinition.defaults }
    var allStrategies: [ReadingStrategy] { strategies ?? ReadingStrategy.defaults }
    var strategy: ReadingStrategy { allStrategies.first(where:{$0.id == strategyID}) ?? allStrategies[0] }
}
struct Library: Codable {
    var version = 2
    var items: [ReadingItem] = []
    var sessions: [ReadingSession] = []
    var preferences = Preferences()
    var unlocks: [MilestoneUnlock]?
    var exposures: [ExposureEvent]?
    var exposureLogStartedAt: Date?
    var alignmentUndo: [PriorityAdjustment]?
    var researchEvents:[ResearchSavedEvent]?
    var linkRepairUndo:[LinkRepair]?
    var registeredLinkMigration:Int?
    var roamingQueue: RoamingQueue?
}
enum InputError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let s) = self { return s }; return nil }
}
enum Targets {
    static let schemes = Set(["https", "http", "file", "obsidian", "zotero", "siyuan", "x-devonthink-item", "marginnote3app"])
    static func normalize(_ value: String) throws -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("/") { return URL(fileURLWithPath: text).standardizedFileURL.path }
        let escaped = text.addingPercentEncoding(withAllowedCharacters:.urlFragmentAllowed)
        guard let url = URL(string: text) ?? escaped.flatMap({ URL(string:$0) }), let scheme = url.scheme?.lowercased(), schemes.contains(scheme) else {
            throw InputError.invalid("请使用完整的网址、本地文件路径或 Obsidian 等阅读工具的链接。")
        }
        if ["http", "https"].contains(scheme), url.host?.isEmpty != false { throw InputError.invalid("网址缺少域名。") }
        if scheme == "file" { return url.standardizedFileURL.path }
        return url.absoluteString
    }
    static func key(_ value: String) -> String {
        guard var c = URLComponents(string: value), ["http", "https"].contains(c.scheme?.lowercased() ?? "") else { return value }
        c.scheme = c.scheme?.lowercased(); c.host = c.host?.lowercased(); c.fragment = nil
        c.queryItems = c.queryItems?.filter { !$0.name.lowercased().hasPrefix("utm_") && !["share_code", "utm_psn"].contains($0.name.lowercased()) }
        if c.queryItems?.isEmpty == true { c.queryItems = nil }
        return c.string ?? value
    }
}
enum CaptureLink {
    static func parse(_ url: URL) throws -> (title: String, target: String) {
        guard url.scheme?.lowercased() == "wanderread", url.host == "add", let c=URLComponents(url:url,resolvingAgainstBaseURL:false), let raw=c.queryItems?.first(where:{$0.name == "url"})?.value else { throw InputError.invalid("这个收藏入口不完整。") }
        let target=try Targets.normalize(raw)
        let title=c.queryItems?.first(where:{$0.name == "title"})?.value?.trimmingCharacters(in:.whitespacesAndNewlines)
        return ((title?.isEmpty == false ? title : nil) ?? URL(string:target)?.host ?? target, target)
    }
}
enum LibraryIO {
    static func encode(_ library: Library) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(library)
    }
    static func decode(_ data: Data) throws -> Library {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var l = try decoder.decode(Library.self, from: data)
        guard (1...2).contains(l.version) else { throw InputError.invalid("这个数据版本暂不支持，原有内容没有改动。") }
        guard Set(l.items.map(\.id)).count == l.items.count else { throw InputError.invalid("备份里存在重复的条目。") }
        guard l.preferences.exploration.isFinite, (0...1).contains(l.preferences.exploration), (1...120).contains(l.preferences.slice), l.preferences.tagAffinity.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw InputError.invalid("备份中的偏好设置不完整。") }
        for i in l.items.indices {
            let item = l.items[i]
            guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (1...600).contains(item.minutes), (1...3).contains(item.difficulty), item.interest.isFinite, (1...5).contains(item.interest), item.impressions >= 0, item.choices >= 0 else { throw InputError.invalid("备份里有无效的条目数据。") }
            l.items[i].target = try Targets.normalize(item.target)
            if let note=item.researchNoteURL {guard let url=URL(string:note),url.scheme=="obsidian",url.host=="pfr-excerpt" else {throw InputError.invalid("摘录返回入口无效。")}}
            guard (item.metricValues ?? [:]).values.allSatisfy({$0.isFinite && (0...10).contains($0)}), item.priorityOverride.map({$0.isFinite && (0...10).contains($0)}) ?? true else { throw InputError.invalid("文献指标或手动优先级越界。") }
        }
        guard Set(l.items.map { Targets.key($0.target) }).count == l.items.count else { throw InputError.invalid("备份里存在重复的入口。") }
        let ids = Set(l.items.map(\.id))
        let events=l.researchEvents ?? []
        guard Set(events.map(\.id)).count==events.count,events.allSatisfy({UUID(uuidString:$0.id) != nil && ids.contains($0.itemID) && URL(string:$0.noteURL)?.scheme=="obsidian" && URL(string:$0.noteURL)?.host=="pfr-excerpt"}) else {throw InputError.invalid("摘录通信记录无效。")}
        guard Set(l.sessions.map(\.id)).count == l.sessions.count, l.sessions.filter({ $0.stoppedAt == nil }).count <= 1, l.sessions.allSatisfy({ ids.contains($0.itemID) && $0.seconds.isFinite && $0.seconds >= 0 && $0.seconds <= 31_536_000 && ($0.stoppedAt == nil || $0.runningSince == nil) }) else { throw InputError.invalid("备份中的停留记录无效。") }
        try PriorityEngine.validate(l.preferences)
        guard Set((l.unlocks ?? []).map(\.id)).count == (l.unlocks ?? []).count, (l.exposures ?? []).allSatisfy({ids.contains($0.itemID)}) else { throw InputError.invalid("里程或展示记录不完整。") }
        l.version = 2
        l.preferences.metrics = l.preferences.metricDefinitions
        l.preferences.strategies = l.preferences.allStrategies
        l.preferences.strategyID = l.preferences.strategy.id
        if l.preferences.tagUpdatedAt == nil { l.preferences.tagUpdatedAt = l.preferences.tagAffinity.mapValues { _ in Date() } }
        return l
    }
}
struct Recommendation: Identifiable {
    var item: ReadingItem
    var reason: String
    var branch = "兴趣匹配"
    var strategyName: String?
    var id: UUID { item.id }
}

struct QueuedRecommendation: Codable, Equatable {
    let id: UUID
    let reason: String
    let branch: String
    let strategyName: String?

    init(_ recommendation: Recommendation) {
        id = recommendation.id
        reason = recommendation.reason
        branch = recommendation.branch
        strategyName = recommendation.strategyName
    }
}

struct RoamingQueue: Codable, Equatable {
    var seen: Set<UUID> = []
    var current: [QueuedRecommendation] = []
    var previous: [QueuedRecommendation] = []
    var showingPrevious = false
    var unavailableTargets: [UUID: String]?

    mutating func reconcile(items: [ReadingItem], preferences: Preferences, active: UUID?, now: Date) {
        let ids = Set(items.map(\.id))
        seen.formIntersection(ids)
        if let unavailable = unavailableTargets {
            unavailableTargets = Dictionary(uniqueKeysWithValues: items.compactMap { item in
                unavailable[item.id] == item.target ? (item.id, item.target) : nil
            })
        }
        let unavailable = unavailableTargets ?? [:]
        let candidateIDs = Set(items.lazy.filter {
            $0.id != active && unavailable[$0.id] == nil &&
            AttentionEngine.eligible($0, now: now) && PriorityEngine.inScope($0, preferences: preferences)
        }.map(\.id))
        var retained = Set<UUID>()
        current = Array(current.filter { candidateIDs.contains($0.id) && retained.insert($0.id).inserted }.prefix(3))
        previous = Array(previous.filter { candidateIDs.contains($0.id) && retained.insert($0.id).inserted }.prefix(3))
        seen.formUnion(retained)
        if previous.isEmpty { showingPrevious = false }
    }
}
enum AttentionEngine {
    static func eligible(_ item: ReadingItem, now: Date) -> Bool {
        item.trashedAt == nil && item.state != .archived && (item.snoozedUntil == nil || item.snoozedUntil! <= now)
    }
    static func components(_ item: ReadingItem, preferences p: Preferences, now: Date) -> (fit: Double, fresh: Double, affinity: Double) {
        let energy = exp(-0.75 * Double(abs(item.difficulty - p.energy.rawValue)))
        // A slice is an invitation to start. Long works stay eligible.
        let duration = item.minutes <= p.slice ? 1.0 : max(0.45, Double(p.slice) / Double(item.minutes))
        let affinity = item.tags.isEmpty ? 0.5 : item.tags.map { tag -> Double in
            let days=max(0,now.timeIntervalSince(p.tagUpdatedAt?[tag] ?? now)/86400)
            return 0.5 + ((p.tagAffinity[tag] ?? 0.5)-0.5)*exp(-days/60)
        }.reduce(0,+) / Double(item.tags.count)
        let hours = item.lastShown.map { max(0, now.timeIntervalSince($0)/3600) } ?? 168
        let fresh = 0.12 + 0.88 * (1 - exp(-hours / 18))
        let fit = 0.5*energy + 0.3*duration + 0.2*affinity
        return (fit, fresh, affinity)
    }
    static func weight(_ item: ReadingItem, preferences: Preferences, now: Date, selectedTags: Set<String> = []) -> Double {
        let c = components(item, preferences: preferences, now: now)
        let overlap = !selectedTags.isDisjoint(with: item.tags)
        let priority=PriorityEngine.explain(item,preferences:preferences).score/10
        return max(0.0001, (0.05 + priority) * (0.55+0.45*c.fit) * c.fresh * (overlap ? 0.38 : 1))
    }
    static func draw(items: [ReadingItem], preferences p: Preferences, excluding: Set<UUID>, count: Int = 3, now: Date, similarityScores: [UUID:Double]? = nil, random: () -> Double = { Double.random(in: 0..<1) }) -> [Recommendation] {
        var pool = items.filter { eligible($0, now: now) && PriorityEngine.inScope($0,preferences:p) && !excluding.contains($0.id) }
        let profile=p.strategy
        let similarities=profile.mode == .adaptive && profile.semanticBlend > 0 ? similarityScores ?? SemanticIndex.similarities(items:items.filter {PriorityEngine.inScope($0,preferences:p)},question:profile.question) : [:]
        var result: [Recommendation] = []; var tags = Set<String>()
        while !pool.isEmpty && result.count < count {
            let absolute=profile.mode != .uniform && profile.absoluteProbability > 0 && random() < profile.absoluteProbability
            let exploring = profile.mode == .adaptive && random() < p.exploration
            let weights = pool.map { item -> Double in
                if profile.mode == .uniform {return 1}
                if profile.mode == .upstream {return PriorityEngine.explain(item,preferences:p).score}
                let fit=components(item,preferences:p,now:now).fit
                if exploring { return components(item, preferences: p, now: now).fresh * (0.55+0.45*fit) * (tags.isDisjoint(with: item.tags) ? 1 : 0.38) }
                return weight(item, preferences: p, now: now, selectedTags: tags) * (1+profile.semanticBlend*(similarities[item.id] ?? 0))
            }
            let safeWeights=weights.reduce(0,+) > 0 ? weights : weights.map {_ in 1.0}
            let threshold = min(0.999999999, max(0, random())) * safeWeights.reduce(0,+)
            var sum = 0.0; var index = pool.count - 1
            if absolute {index=pool.indices.max {PriorityEngine.explain(pool[$0],preferences:p).score < PriorityEngine.explain(pool[$1],preferences:p).score} ?? 0}
            else {for i in pool.indices { sum += safeWeights[i]; if threshold < sum { index = i; break } }}
            let item = pool.remove(at: index)
            let c = components(item, preferences: p, now: now)
            let reason: String
            if profile.mode == .uniform {reason="均匀随机遇见，作为推荐对照"}
            else if absolute {reason="这次按你设置的长期优先级选择"}
            else if profile.mode == .upstream {reason="按多维优先级加权，轮盘随机抽取"}
            else if exploring { reason = "换个方向，或许会感兴趣" }
            else if (similarities[item.id] ?? 0) > 0.08 {reason="标题与收藏理由有相关关键词"}
            else if item.lastChosen != nil { reason = "上次的好奇，可以接着往下走" }
            else if c.affinity > 0.6 { reason = "与你最近主动选择的主题有关" }
            else if item.difficulty == p.energy.rawValue { reason = "深浅刚好，适合现在的状态" }
            else { reason = "收藏时的好奇，值得再遇见" }
            let branch=profile.mode == .uniform ? "随机对照" : absolute ? "优先级顺序" : exploring ? "探索" : "优先级抽样"
            result.append(Recommendation(item: item, reason: reason,branch:branch,strategyName:profile.name)); tags.formUnion(item.tags)
        }
        return result
    }
}

enum DemoLibrary {
    static func make() -> [ReadingItem] {
        let entries: [(String,String,String,[String],Int,Int)] = [
            ("把阅读的主动权，还给好奇心", "https://github.com/ebAobS/roaming-mode-incremental-reading", "为什么稍后阅读可以像散步，而不必像清理待办？从这个项目的想法开始，试着寻找自己的阅读节奏。", ["阅读与学习"], 8, 1),
            ("在熟悉的世界里，给偶然留一个入口", "https://en.wikipedia.org/wiki/Serendipity", "有些发现并不在计划之中。也许只需要一个与你平时不同的方向。", ["偶然发现", "思考"], 12, 2),
            ("走进公共领域的书架", "https://www.gutenberg.org/", "没有必须读完的书单。随便走走，看看哪本书让你愿意多停留一会儿。", ["文学"], 25, 1),
            ("一点点理解复杂系统", "https://www.complexityexplorer.org/", "从相互作用、涌现和反馈开始，看一个看似简单的问题如何打开新的世界。", ["科学", "思考"], 30, 3),
            ("一份开放的哲学地图", "https://plato.stanford.edu/", "从一个困扰过你的问题出发，顺着概念慢慢走。今天只读一小节也可以。", ["哲学"], 30, 3),
            ("看看今天的宇宙", "https://apod.nasa.gov/", "一张天文照片，以及它背后的故事。给注意力换一个尺度。", ["科学", "偶然发现"], 5, 1)
        ]
        return entries.map { ReadingItem(title:$0.0, target:$0.1, note:$0.2, tags:$0.3, minutes:$0.4, difficulty:$0.5, isDemo:true) }
    }
}
