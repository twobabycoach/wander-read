import Foundation

func runAlignmentProtectionChecks() throws {
    let path=FileManager.default.temporaryDirectory.appendingPathComponent("wander-alignment-\(UUID().uuidString)")
    let store=ReadingStore(directory:path)
    let a=ReadingItem(title:"劳动自由",target:"https://example.com/alignment/a",tags:["研究"])
    let b=ReadingItem(title:"劳动与社会发展",target:"https://example.com/alignment/b",tags:["研究"])
    var zero=a;zero.id=UUID();zero.target="https://example.com/alignment/zero";zero.metricValues=["importance":0]
    var important=a;important.id=UUID();important.target="https://example.com/alignment/important";important.metricValues=["importance":10]
    var custom=a;custom.id=UUID();custom.target="https://example.com/alignment/custom";custom.metricValues=["evidence":8]
    var locked=b;locked.id=UUID();locked.target="https://example.com/alignment/locked";locked.priorityLocked=true
    check(store.commit {$0.items=[a,b,zero,important,custom,locked]},"对齐保护测试使用独立收藏")
    store.setScope(tag:"研究",question:"劳动自由")
    let preview=store.alignPreview()
    check(!preview.isEmpty,"有关键词差异的自动文献可预览对齐")
    check(preview.allSatisfy {$0.0.id==a.id || $0.0.id==b.id},"对齐预览跳过明确评分和锁定文献")
    let original=PriorityEngine.explain(important,preferences:store.library.preferences).score
    store.applyAlignment([(a.id,8),(b.id,6),(zero.id,9),(important.id,1),(custom.id,1),(locked.id,1)])
    check(store.library.items.first(where:{$0.id==zero.id})?.priorityOverride==nil,"明确重要性为零也不能被对齐覆盖")
    check(PriorityEngine.explain(store.library.items.first(where:{$0.id==important.id})!,preferences:store.library.preferences).score==original,"明确重要性继续参与原指标优先级")
    check(store.library.items.first(where:{$0.id==custom.id})?.priorityOverride==nil,"自定义维度的明确评分同样受到保护")
    check(store.library.alignmentUndo?.count==2,"对齐只保存实际可调整文献的撤销快照")
    store.applyAlignment([(zero.id,8),(important.id,2),(custom.id,2)])
    check(store.library.alignmentUndo?.count==2,"全部受保护时保留上一次有效撤销")
    let resumed=ReadingStore(directory:path)
    check(resumed.library.alignmentUndo?.count==2,"重启仍保留上一次对齐的撤销")
    check(resumed.setMetrics(a.id,values:[:],priority:8,locked:true),"对齐后可以保护关键文献")
    resumed.undoAlignment()
    check(resumed.library.items.first(where:{$0.id==a.id})?.priorityOverride==8 && resumed.library.items.first(where:{$0.id==b.id})?.priorityOverride==nil,"撤销恢复其余文献，保留后续锁定项")
    resumed.setScope(tag:"研究",question:"劳动自由")
    let planned=resumed.alignPreview()
    check(planned.contains(where:{$0.0.id==b.id}),"明确评分前文献仍可进入预览")
    check(resumed.setMetrics(b.id,values:["importance":7],priority:nil,locked:false),"预览后允许明确补充重要性")
    resumed.applyAlignment(planned.map {($0.0.id,$0.1)})
    check(resumed.library.items.first(where:{$0.id==b.id})?.priorityOverride==nil,"应用时再次校验，保护预览后新增评分")

    var p=Preferences();p.exploration=0
    var profiles=p.allStrategies;let selected=p.strategy.id
    for i in profiles.indices where profiles[i].id==selected {profiles[i].semanticBlend=0;profiles[i].absoluteProbability=0}
    p.strategies=profiles
    var first=a,second=a;second.id=UUID();second.target="https://example.com/alignment/contrast"
    let date=Date(timeIntervalSince1970:1_793_000_000)
    first.createdAt=date;second.createdAt=date
    let scores=[first.id:1.0,second.id:0.0]
    let baseline=AttentionEngine.draw(items:[first,second],preferences:p,excluding:[],count:1,now:date,similarityScores:scores,random:{0.6})
    for i in profiles.indices where profiles[i].id==selected {profiles[i].semanticBlend=1}
    p.strategies=profiles
    let related=AttentionEngine.draw(items:[first,second],preferences:p,excluding:[],count:1,now:date,similarityScores:scores,random:{0.6})
    check(baseline.first?.id==second.id && related.first?.id==first.id,"相似度真正改变推荐抽样，非仅展示关联标签")
    check(first.priorityOverride==nil && first.metricValues==nil,"相似度参与推荐不改写用户指标")
}
