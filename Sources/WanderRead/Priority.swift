import Foundation

// Independently implemented from the upstream metric / normalized priority concept.
// Upstream mapping and numerical conformance examples: References/PRIORITY-PARITY.md.
enum MetricDirection: String, Codable, CaseIterable { case higher, lower
    var title: String { self == .higher ? "越高越优先" : "越低越优先" }
}
struct MetricDefinition: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var defaultValue: Double = 5
    var direction = MetricDirection.higher
    static let defaults = [
        MetricDefinition(id:"importance",name:"重要性"), MetricDefinition(id:"relevance",name:"问题相关"),
        MetricDefinition(id:"interest",name:"兴趣"), MetricDefinition(id:"evidence",name:"证据价值"),
        MetricDefinition(id:"urgency",name:"紧迫性"), MetricDefinition(id:"difficulty",name:"挑战程度")
    ]
}
enum SamplingMode: String, Codable, CaseIterable {
    case adaptive, upstream, uniform
    var title: String { switch self { case .adaptive:return "结合当下状态"; case .upstream:return "按优先级轮盘抽取"; case .uniform:return "均匀随机对照" } }
}
struct ReadingStrategy: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var weights: [String:Double]
    var exploration = 0.35
    var absoluteProbability = 0.0
    var semanticBlend = 0.25
    var mode = SamplingMode.adaptive
    var scopeTag = ""
    var question = ""
    static let defaults = [
        ReadingStrategy(id:"wander",name:"自由漫游",weights:["interest":40,"importance":25,"relevance":20,"evidence":10,"urgency":5]),
        ReadingStrategy(id:"research",name:"专题研究",weights:["importance":25,"relevance":30,"evidence":25,"interest":10,"urgency":10],exploration:0.2,semanticBlend:0.45),
        ReadingStrategy(id:"original",name:"原项目指标",weights:["importance":40,"urgency":30,"difficulty":30],exploration:0,semanticBlend:0,mode:.upstream),
        ReadingStrategy(id:"random",name:"随机对照",weights:["interest":100],exploration:1,semanticBlend:0,mode:.uniform)
    ]
}
struct PriorityTerm: Identifiable {
    var id: String
    var name: String
    var value: Double
    var weight: Double
    var contribution: Double
    var isDefault: Bool
}
struct PriorityAdjustment: Codable {
    var itemID: UUID
    var previous: Double?
    var applied: Double
}
struct PriorityExplanation {
    var score: Double
    var computed: Double
    var terms: [PriorityTerm]
    var isManual: Bool
}
enum PriorityEngine {
    static func validate(_ p: Preferences) throws {
        let defs=p.metricDefinitions, profiles=p.allStrategies
        guard (1...8).contains(defs.count), Set(defs.map(\.id)).count == defs.count,
              defs.allSatisfy({!$0.id.isEmpty && !$0.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.defaultValue.isFinite && (0...10).contains($0.defaultValue)}),
              !profiles.isEmpty, profiles.count <= 20, Set(profiles.map(\.id)).count == profiles.count,
              p.strategyID == nil || profiles.contains(where:{$0.id == p.strategyID}) else {throw InputError.invalid("指标或策略设置不完整。")}
        let ids=Set(defs.map(\.id))
        for s in profiles {
            guard !s.id.isEmpty, !s.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                  s.weights.allSatisfy({ids.contains($0.key) && $0.value.isFinite && (0...100).contains($0.value)}),
                  s.weights.values.reduce(0,+) > 0,
                  [s.exploration,s.absoluteProbability,s.semanticBlend].allSatisfy({$0.isFinite && (0...1).contains($0)}) else {throw InputError.invalid("“\(s.name)”需要至少一个正权重，比例须在 0—100% 之间。")}
        }
    }
    static func normalized(_ weights: [String:Double]) -> [String:Double] {
        let total=weights.values.reduce(0,+)
        guard total > 0 else {return weights}
        return weights.mapValues {$0 / total * 100}
    }
    static func rawValue(_ item: ReadingItem, metric: MetricDefinition) -> (Double,Bool) {
        if let explicit=item.metricValues?[metric.id] {return (explicit,false)}
        if metric.id == "interest" {return (item.interest*2,false)}
        if metric.id == "difficulty" {return (Double(item.difficulty-1)*5,false)}
        return (metric.defaultValue,true)
    }
    static func explain(_ item: ReadingItem, preferences p: Preferences) -> PriorityExplanation {
        let weights=normalized(p.strategy.weights)
        let terms=p.metricDefinitions.compactMap { metric -> PriorityTerm? in
            let w=weights[metric.id] ?? 0
            guard w > 0 else {return nil}
            let (raw,isDefault)=rawValue(item,metric:metric)
            let effective=metric.direction == .higher ? raw : 10-raw
            return PriorityTerm(id:metric.id,name:metric.name,value:raw,weight:w,contribution:effective*w/100,isDefault:isDefault)
        }
        let computed=terms.map(\.contribution).reduce(0,+)
        return PriorityExplanation(score:item.priorityOverride ?? computed,computed:computed,terms:terms,isManual:item.priorityOverride != nil)
    }
    static func inScope(_ item: ReadingItem, preferences p: Preferences) -> Bool {
        item.trashedAt == nil && (p.strategy.scopeTag.isEmpty || item.tags.contains(p.strategy.scopeTag))
    }
    static func acceptsAlignment(_ item:ReadingItem,preferences p:Preferences)->Bool {
        inScope(item,preferences:p) && item.state != .archived && item.priorityLocked != true && item.priorityOverride == nil && (item.metricValues ?? [:]).isEmpty
    }
}

// Local title / collection-reason TF-IDF. No PDF or note-body access occurs here.
enum SemanticIndex {
    static func tokens(_ text: String) -> [String] {
        var output:[String]=[], latin="", chinese:[String]=[]
        func flush() {
            if latin.count > 1 {output.append(latin)}; latin=""
            if chinese.count == 1 {output.append(chinese[0])}
            if chinese.count > 1 {for i in 0..<(chinese.count-1) {output.append(chinese[i]+chinese[i+1])}}
            chinese=[]
        }
        for scalar in text.lowercased().unicodeScalars.prefix(12000) {
            if (0x3400...0x9FFF).contains(scalar.value) {if !latin.isEmpty {flush()}; chinese.append(String(scalar))}
            else if CharacterSet.alphanumerics.contains(scalar) {if !chinese.isEmpty {flush()}; latin.append(String(scalar))}
            else {flush()}
        }
        flush()
        let stop=Set(["the","and","for","with","this","that","from","一个","我们","可以","什么","如何","以及"])
        return output.filter {!stop.contains($0)}
    }
    static func anchors(in items: [ReadingItem]) -> [UUID] {
        let recent = items.filter { $0.lastChosen != nil }.sorted {
            ($0.lastChosen ?? .distantPast) > ($1.lastChosen ?? .distantPast)
        }
        let frequent = recent.filter { $0.choices > 0 }.sorted { $0.choices > $1.choices }
        var ids = Set<UUID>()
        return (Array(recent.prefix(3)) + Array(frequent.prefix(2))).map(\.id).filter { ids.insert($0).inserted }
    }

    static func similarities(items: [ReadingItem], question: String,
                             body: [UUID: String] = [:], anchorIDs: [UUID]? = nil) -> [UUID:Double] {
        let chosen = anchorIDs ?? anchors(in: items)
        let hasQuestion = !question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
        guard hasQuestion || !chosen.isEmpty else {return [:]}
        var all:[[String]]=[]
        for item in items {
            let metadata = item.title + " " + item.note + " " + item.tags.joined(separator: " ")
            all.append(tokens(metadata + " " + (body[item.id] ?? "")))
        }
        if hasQuestion {all.append(tokens(question))}
        var df:[String:Int]=[:]
        for ts in all {for t in Set(ts) {df[t,default:0] += 1}}
        let vectors=all.map {ts -> [String:Double] in
            var counts:[String:Double]=[:]; for t in ts {counts[t,default:0] += 1}
            var v=counts.mapValues {$0 / Double(max(1,ts.count))}
            for key in counts.keys {v[key] = (v[key] ?? 0) * (log(Double(1+all.count)/Double(1+(df[key] ?? 0)))+1)}
            let norm=sqrt(v.values.map {$0*$0}.reduce(0,+)); return norm > 0 ? v.mapValues {$0/norm} : [:]
        }
        let positions=Dictionary(uniqueKeysWithValues:items.enumerated().map {($0.element.id,$0.offset)})
        let anchors:[Int] = hasQuestion ? [all.count-1] : chosen.compactMap { positions[$0] }
        var scores:[UUID:Double]=[:]
        for (i,item) in items.enumerated() {
            let others=anchors.filter {$0 != i}; guard !others.isEmpty else {continue}
            var sum=0.0
            for a in others {var dot=0.0; for (term,value) in vectors[i] {dot += value*(vectors[a][term] ?? 0)}; sum += dot}
            scores[item.id]=sum/Double(others.count)
        }
        return scores
    }
}
