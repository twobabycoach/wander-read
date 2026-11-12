import Foundation

func runVersionTwoChecks() throws {
    var p=Preferences(); p.strategyID="original"; p.exploration=0
    var item=ReadingItem(title:"原项目数值对照",target:"https://example.com/parity")
    item.metricValues=["importance":0,"urgency":10,"difficulty":5]
    check(abs(PriorityEngine.explain(item,preferences:p).score-4.5)<0.00001,"原项目加权均值对照：0×40%+10×30%+5×30%=4.5")
    check(PriorityEngine.explain(item,preferences:p).terms.first(where:{$0.id == "importance"})?.value == 0,"明确零分不被默认五分替换")
    let normalized=PriorityEngine.normalized(["a":2,"b":3])
    check(abs((normalized["a"] ?? 0)-40)<0.00001,"权重按比例归一化")
    item.metricValues=["urgency":0,"difficulty":0]
    check(PriorityEngine.explain(item,preferences:p).score == 2,"缺失重要性使用默认五分，显式零分仍生效")
    item.priorityOverride=0
    check(PriorityEngine.explain(item,preferences:p).score == 0,"手动零优先级有效")
    var custom=p; custom.metrics=[MetricDefinition(id:"effort",name:"负担",direction:.lower)]; custom.strategies=[ReadingStrategy(id:"custom",name:"自定",weights:["effort":100])]; custom.strategyID="custom"
    item.priorityOverride=nil; item.metricValues=["effort":2]
    check(PriorityEngine.explain(item,preferences:custom).score == 8,"反向指标按十减原值参与计算")
    var invalid=custom; invalid.strategies?[0].weights=["effort":0]
    rejects({_ = try PriorityEngine.validate(invalid)},"全零权重不能保存")
    invalid=custom; let duplicate=invalid.metricDefinitions[0]; invalid.metrics?.append(duplicate)
    rejects({_ = try PriorityEngine.validate(invalid)},"重复指标标识拒绝")
    invalid=custom; invalid.strategyID="absent"
    rejects({_ = try PriorityEngine.validate(invalid)},"失效的当前策略拒绝")
    let longTerm=PriorityEngine.explain(item,preferences:custom).score
    custom.energy = .deep; custom.slice=5
    check(PriorityEngine.explain(item,preferences:custom).score == longTerm,"当下精力和时间不改写长期优先级")

    var high=ReadingItem(title:"高",target:"https://example.com/high-v2",tags:["研究"]); high.priorityOverride=10
    var low=ReadingItem(title:"低",target:"https://example.com/low-v2",tags:["其他"]); low.priorityOverride=0
    var absolute=ReadingStrategy.defaults[2]; absolute.absoluteProbability=1
    p.strategies=[absolute]; p.strategyID=absolute.id
    let date=Date()
    check(AttentionEngine.draw(items:[low,high],preferences:p,excluding:[],count:1,now:date,random:{0.99}).first?.id == high.id,"绝对优先级模式选择最高项")
    high.snoozedUntil=date.addingTimeInterval(3600)
    check(AttentionEngine.draw(items:[low,high],preferences:p,excluding:[],count:1,now:date,random:{0}).first?.id == low.id,"最高优先级也不能绕过休息期")
    high.snoozedUntil=nil
    p.strategies?[0].absoluteProbability=0
    check(AttentionEngine.draw(items:[low,high],preferences:p,excluding:[],count:1,now:date,random:{0}).first?.id == high.id,"轮盘抽样不给零权重分配概率")
    high.priorityOverride=0
    check(AttentionEngine.draw(items:[low,high],preferences:p,excluding:[],now:date,random:{0.5}).count == 2,"所有优先级为零时回退到均匀无放回")
    p.strategies?[0].scopeTag="研究"
    check(AttentionEngine.draw(items:[low,high],preferences:p,excluding:[],now:date).map(\.id) == [high.id],"研究范围是严格边界")
    p.strategies=[ReadingStrategy.defaults[3]]; p.strategyID="random"
    var hits=0
    high.priorityOverride=10
    for _ in 0..<3000 {if AttentionEngine.draw(items:[low,high],preferences:p,excluding:[],count:1,now:date,random:random).first?.id == high.id {hits += 1}}
    check((1300...1700).contains(hits),"均匀随机对照忽略优先级差异")
    let labour=ReadingItem(title:"劳动自由与劳动关系",target:"https://example.com/labour",note:"劳动制度、自由时间与社会关系",tags:["理论"])
    let space=ReadingItem(title:"星云天体与宇宙",target:"https://example.com/space",note:"恒星与星际气体")
    let sims=SemanticIndex.similarities(items:[labour,space],question:"劳动自由")
    check((sims[labour.id] ?? 0) > (sims[space.id] ?? 0),"中文双字关键词关联区分研究主题")
    check(SemanticIndex.similarities(items:[labour,space],question:"").isEmpty,"无问题和主动选择锚点时不编造语义关联")
    let recent = (1...3).map { days in
        ReadingItem(title: "天体星云", target: "https://example.com/recent/\(days)",
                    lastChosen: date.addingTimeInterval(Double(-days) * 86400), choices: 1)
    }
    var frequent = labour
    frequent.id = UUID()
    frequent.target = "https://example.com/frequent"
    frequent.lastChosen = date.addingTimeInterval(-100 * 86400)
    frequent.choices = 20
    let mixed = SemanticIndex.similarities(items: [labour, frequent] + recent, question: "")
    check((mixed[labour.id] ?? 0) > 0, "较早但高频主动选择的资料仍能贡献关联锚点")
    check(SemanticIndex.tokens("FSRS7 劳动自由").contains("劳动"),"中英文混合索引")
    var affinity=Preferences(); affinity.tagAffinity=["研究":1]; affinity.tagUpdatedAt=["研究":date.addingTimeInterval(-86400*365)]
    check(AttentionEngine.components(high,preferences:affinity,now:date).affinity < 0.51,"旧兴趣随时间回归中性，避免永久固化")

    let root=FileManager.default.temporaryDirectory.appendingPathComponent("wander-v2-\(UUID().uuidString)")
    let store=ReadingStore(directory:root)
    var a=labour, b=space, locked=labour, manual=space, rated=labour
    locked.id=UUID(); locked.target="https://example.com/locked"; locked.priorityLocked=true
    manual.id=UUID(); manual.target="https://example.com/manual"; manual.priorityOverride=8
    rated.id=UUID();rated.target="https://example.com/rated";rated.metricValues=["importance":0]
    check(store.commit {$0.items=[a,b,locked,manual,rated]},"新指标可以保存与恢复")
    store.refresh(restart:true); let builds=store.semanticIndexBuildCount
    store.refresh(restart:true)
    check(store.semanticIndexBuildCount == builds,"单纯换一批复用本地关键词索引")
    store.setScope(tag:"",question:"劳动自由")
    store.refresh()
    check(store.semanticIndexBuildCount == builds+1,"研究问题改变后，下一批重建关键词索引")
    store.applyAlignment([(a.id,8),(b.id,6),(locked.id,1),(manual.id,1)])
    check(store.library.items[2].priorityOverride == nil && store.library.items[3].priorityOverride == 8,"批量对齐保护锁定和人工优先级")
    check(store.library.alignmentUndo?.count == 2,"对齐只记录实际变化的可撤销快照")
    store.setPriority(a.id,value:7)
    store.undoAlignment()
    check(store.library.items[0].priorityOverride == 7 && store.library.items[1].priorityOverride == nil,"撤销对齐恢复未改动项，保留后续人工修改")
    check(store.startVisit(a.id),"主动选择建立唯一停留会话")
    check(!store.startVisit(b.id),"未收尾前不能重复建立会话")
    check(store.activeSession?.tagsSnapshot == a.tags && store.activeSession?.sourceSnapshot == a.source,"选择时冻结主题与来源快照")
    store.finish(outcome:"暂时放一放",bookmark:"第二节",usefulness:"不合适",reflection:"我需要先澄清这里的前提。")
    check(store.library.preferences.tagAffinity[a.primaryTag] ?? 0.5 < 0.5,"只有明确不合适反馈才降低主题偏好")
    check(store.library.unlocks?.contains(where:{$0.id == "reflection"}) == true,"真实的一句个人想法可以解锁纪念")
    let resumed=ReadingStore(directory:root)
    check(resumed.library.items.first(where:{$0.id==rated.id})?.metricValues?["importance"] == 0,"重启保留逐篇零分")
    check(resumed.library.sessions.last?.reflection == "我需要先澄清这里的前提。","重启保留自愿反馈和想法")
    check(resumed.library.unlocks?.contains(where:{$0.id == "first"}) == true,"里程解锁落盘保留")

    let migration=FileManager.default.temporaryDirectory.appendingPathComponent("wander-upgrade-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at:migration,withIntermediateDirectories:true)
    var old=Library(); old.version=1; old.items=[labour]
    var json=try JSONSerialization.jsonObject(with:LibraryIO.encode(old)) as! [String:Any]
    json["unlocks"]=nil; json["exposures"]=nil; json["alignmentUndo"]=nil
    let v1=try JSONSerialization.data(withJSONObject:json,options:.sortedKeys)
    try v1.write(to:migration.appendingPathComponent("library.json"))
    let upgraded=ReadingStore(directory:migration)
    check(upgraded.library.version == 2 && upgraded.library.items.count == 1,"旧版资料升级不丢收藏")
    let original=migration.appendingPathComponent("library-v1-before-upgrade.json")
    check(try Data(contentsOf:original) == v1,"首次升级保留完整旧版原件")
    upgraded.updatePreferences {$0.energy = .deep}
    check(try Data(contentsOf:original) == v1,"日常保存不覆盖升级前原件")
    check(try LibraryIO.decode(Data(contentsOf:upgraded.dataURL)).preferences.allStrategies.count == 4,"旧备份获得完整默认策略")

    var l=Library(); l.items=[labour,space,ReadingItem(title:"方法",target:"https://example.com/method",tags:["方法"])]
    l.items[0].tags=["理论","概念"]; l.items[1].tags=["科学"]
    var cal=Calendar(identifier:.gregorian); cal.timeZone=TimeZone(secondsFromGMT:0)!
    let today=cal.startOfDay(for:date)
    for n in 0..<5 {
        let i=n%3, time=cal.date(byAdding:.day,value:n-4,to:today)!.addingTimeInterval(100)
        var s=ReadingSession(itemID:l.items[i].id,title:l.items[i].title,startedAt:time,stoppedAt:time.addingTimeInterval(30),seconds:30,outcome:"暂时放一放")
        s.tagsSnapshot=l.items[i].tags; s.sourceSnapshot="原来源"; s.wasRecommended=n<4; s.strategyName="专题研究"; s.usefulness=n == 0 ? "有帮助":nil; s.reflection=n == 2 ? "这里有一个新问题。":nil
        l.sessions.append(s)
    }
    var demo=l.sessions[0]; demo.id=UUID(); demo.isDemoSnapshot=true; l.sessions.append(demo)
    let stats=JourneyAnalytics.summary(l,days:7,now:today.addingTimeInterval(3600),calendar:cal)
    check(stats.sessions.count == 5 && stats.uniqueItems == 3,"回顾去除示例，区分选择次数和材料数量")
    check(stats.days.count == 7 && stats.days.map(\.count).reduce(0,+) == 5,"日历按日期归集，空白不产生负数")
    check(abs(stats.topics.map(\.value).reduce(0,+)-5)<0.00001,"多主题均分一次选择，合计不超过总数")
    check(stats.returns == 2 && stats.closed == 5 && stats.recordedSeconds == 150,"重新拾起、收尾和经过时长分别统计")
    check(stats.strategies.first?.choices == 4 && stats.strategies.first?.feedback == 1,"策略比较排除手选，不把未反馈当失败")
    l.items[0].tags=["改名后"]; l.items[0].target="https://new.example.com"
    let frozen=JourneyAnalytics.summary(l,days:7,now:today.addingTimeInterval(3600),calendar:cal)
    check(!frozen.topics.contains(where:{$0.name == "改名后"}) && frozen.sources.allSatisfy({$0.name == "原来源"}),"修改收藏不重写历史主题和来源")
    JourneyAnalytics.retainUnlocks(&l)
    check(Set((l.unlocks ?? []).map(\.id)).count == 5,"五种里程均可由可验证的真实事件达成")
    let earned=l.unlocks
    l.sessions=[]; JourneyAnalytics.retainUnlocks(&l)
    check(l.unlocks == earned,"离开或清理记录不会撤销已获得里程")
    var demoOnly=Library(); demoOnly.items=[labour]; var ds=ReadingSession(itemID:labour.id,title:"示例",startedAt:date); ds.isDemoSnapshot=true; demoOnly.sessions=[ds]
    check(JourneyAnalytics.earned(demoOnly).isEmpty,"示例记录不能解锁真实里程")
    check(JourneyAnalytics.summary(Library(),days:90).days.count == 90,"空库仍能呈现真实的空白回顾")
}
