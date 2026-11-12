import SwiftUI

struct SectionIntro: View {
    var eyebrow: String
    var title: String
    var subtitle: String
    var body: some View {VStack(alignment:.leading,spacing:10) {
        Text(eyebrow).font(.system(size:11,weight:.semibold)).foregroundColor(Palette.green)
        Text(title).font(.system(size:32,weight:.medium,design:.serif))
        Text(subtitle).font(.system(size:13)).foregroundColor(Palette.muted).lineSpacing(5).fixedSize(horizontal:false,vertical:true)
    }}
}
struct StrategyView: View {
    @ObservedObject var store: ReadingStore
    @State private var editing=false
    @State private var metricItem: ReadingItem?
    @State private var question=""
    @State private var scope=""
    @State private var search=""
    @State private var aligning=false
    var sorted: [ReadingItem] {store.library.items.filter {
        $0.state != .archived && PriorityEngine.inScope($0,preferences:store.library.preferences) && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search))
    }.map {($0,PriorityEngine.explain($0,preferences:store.library.preferences).score)}.sorted {$0.1 > $1.1}.map {$0.0}}
    var body: some View {
        VStack(alignment:.leading,spacing:26) {
            let entries=sorted
            SectionIntro(eyebrow:"由你掌握推荐",title:"让重要的，保有位置。",subtitle:"先决定什么值得读，再决定现在适合读什么。指标、权重和选择方式都可以调整。")
            HStack {
                Picker("正在使用",selection:Binding(get:{store.library.preferences.strategy.id},set:{store.selectStrategy($0); sync()})) {ForEach(store.library.preferences.allStrategies) {Text($0.name).tag($0.id)}}.frame(maxWidth:300)
                Spacer(); Button("编辑指标与权重") {editing=true}.buttonStyle(ActionStyle(primary:true))
            }
            VStack(alignment:.leading,spacing:16) {
                Text("这次，想围绕什么逛逛？").font(.system(size:17,weight:.medium))
                HStack {
                    Picker("范围",selection:$scope) {Text("全部主题").tag(""); ForEach(Array(Set(store.library.items.flatMap(\.tags))).sorted(),id:\.self) {Text($0).tag($0)}}.frame(width:210)
                    TextField("研究问题或关键词（可选）",text:$question).textFieldStyle(.roundedBorder)
                    Button("应用") {store.setScope(tag:scope,question:question)}.buttonStyle(ActionStyle())
                }
                Text("范围只决定候选；关键词关联只读取标题、主题和收藏理由，不读取 PDF 或笔记正文。").font(.system(size:11)).foregroundColor(Palette.muted).fixedSize(horizontal:false,vertical:true)
            }.padding(22).background(Palette.surface.opacity(0.6)).cornerRadius(14)
            HStack(alignment:.top,spacing:26) {
                VStack(alignment:.leading,spacing:14) {
                    Text("当前策略的分量").font(.system(size:17,weight:.medium))
                    WeightRadar(metrics:store.library.preferences.metricDefinitions,weights:store.library.preferences.strategy.weights).frame(height:205)
                    Text("各轴 0—100% · 精确数值见右侧").font(.system(size:10)).foregroundColor(Palette.muted)
                }.frame(width:260)
                VStack(alignment:.leading,spacing:14) {
                    Text(store.library.preferences.strategy.mode.title).font(.system(size:17,weight:.medium))
                    let weights=PriorityEngine.normalized(store.library.preferences.strategy.weights)
                    ForEach(store.library.preferences.metricDefinitions.filter {(weights[$0.id] ?? 0)>0}) {m in
                        HStack {Text(m.name).frame(width:75,alignment:.leading); GeometryReader {g in Capsule().fill(Palette.line.opacity(0.5)).overlay(alignment:.leading){Capsule().fill(Palette.green.opacity(0.7)).frame(width:g.size.width*(weights[m.id] ?? 0)/100)}}.frame(height:7); Text(String(format:"%.0f%%",weights[m.id] ?? 0)).monospacedDigit().frame(width:36,alignment:.trailing)}.font(.system(size:12))
                    }
                    Text("探索 \(Int(store.library.preferences.exploration*100))%  ·  优先级顺序 \(Int(store.library.preferences.strategy.absoluteProbability*100))%").font(.system(size:11)).foregroundColor(Palette.muted)
                    Text("未标注的指标会明确使用中性默认值，不把默认值当作内容分析结果。").font(.system(size:11)).foregroundColor(Palette.muted).fixedSize(horizontal:false,vertical:true)
                }.frame(maxWidth:.infinity,alignment:.leading)
            }.padding(22).background(Palette.side.opacity(0.6)).cornerRadius(14)
            VStack(alignment:.leading,spacing:16) {
                HStack {Text("文献优先级分布").font(.system(size:19,weight:.medium,design:.serif)); Spacer(); if !(store.library.alignmentUndo ?? []).isEmpty {Button("撤销对齐",action:store.undoAlignment).buttonStyle(.plain).font(.system(size:12))}; Button("预览关键词对齐") {aligning=true}.buttonStyle(ActionStyle())}
                PriorityPlot(items:entries,preferences:store.library.preferences) {id,value in store.setPriority(id,value:value)}.frame(height:140)
                Text("横向拖动圆点可手动指定优先级；也可在下方逐篇编辑。图中最多显示优先级最高的 300 篇，完整条目在下方。明确评分、锁定和手动优先级均受批量对齐保护。").font(.system(size:11)).foregroundColor(Palette.muted).fixedSize(horizontal:false,vertical:true)
            }
            HStack {Text("逐篇查看与调整").font(.system(size:16,weight:.medium)); Spacer(); TextField("筛选标题",text:$search).textFieldStyle(.roundedBorder).frame(width:230)}
            if entries.isEmpty {Text("这个范围还没有材料。可更换范围，或先收下一篇。").foregroundColor(Palette.muted).padding(.vertical,20)}
            LazyVStack(spacing:0) {ForEach(entries) {item in
                HStack(spacing:14) {
                    Text(String(format:"%.1f",PriorityEngine.explain(item,preferences:store.library.preferences).score)).font(.system(size:25,weight:.light,design:.serif)).foregroundColor(Palette.green).frame(width:48)
                    VStack(alignment:.leading,spacing:5) {Text(item.title).font(.system(size:14,weight:.medium)); Text(item.priorityOverride != nil ? "\(item.prioritySource == "alignment" ? "关键词对齐" : "手动指定") · \(item.primaryTag)" : "按指标计算 · \(item.primaryTag)").font(.system(size:11)).foregroundColor(Palette.muted)}
                    Spacer()
                    if item.priorityLocked == true {Image(systemName:"lock").foregroundColor(Palette.muted).accessibilityLabel("已锁定批量调整")}
                    Button("指标与解释") {metricItem=item}.buttonStyle(ActionStyle())
                }.padding(.vertical,14); Divider()
            }}
        }.onAppear(perform:sync)
            .sheet(isPresented:$editing) {StrategyEditor(store:store)}
            .sheet(item:$metricItem) {MetricEditor(store:store,item:$0)}
            .sheet(isPresented:$aligning) {AlignmentView(store:store)}
    }
    func sync() {question=store.library.preferences.strategy.question; scope=store.library.preferences.strategy.scopeTag}
}

struct WeightRadar: View {
    var metrics: [MetricDefinition]
    var weights: [String:Double]
    var body: some View {
        let ms=Array(metrics.prefix(8)), values=PriorityEngine.normalized(weights)
        Canvas {context,size in
            guard ms.count >= 3 else {return}
            let center=CGPoint(x:size.width/2,y:size.height/2), radius=min(size.width/2-43,size.height/2-27)
            func point(_ i:Int,_ fraction:Double)->CGPoint {let a=Double(i)*2*Double.pi/Double(ms.count)-Double.pi/2; return CGPoint(x:center.x+cos(a)*radius*fraction,y:center.y+sin(a)*radius*fraction)}
            for level in 1...4 {
                var ring=Path(); ring.move(to:point(0,Double(level)/4)); for i in 1..<ms.count {ring.addLine(to:point(i,Double(level)/4))}; ring.closeSubpath(); context.stroke(ring,with:.color(Palette.line),lineWidth:0.8)
            }
            for i in ms.indices {var line=Path(); line.move(to:center); line.addLine(to:point(i,1)); context.stroke(line,with:.color(Palette.line),lineWidth:0.6); context.draw(Text(ms[i].name).font(.system(size:10)).foregroundColor(Palette.muted),at:point(i,1.3))}
            var area=Path(); area.move(to:point(0,(values[ms[0].id] ?? 0)/100)); for i in 1..<ms.count {area.addLine(to:point(i,(values[ms[i].id] ?? 0)/100))}; area.closeSubpath()
            context.fill(area,with:.color(Palette.green.opacity(0.18))); context.stroke(area,with:.color(Palette.green),lineWidth:2)
            for i in ms.indices {let p=point(i,(values[ms[i].id] ?? 0)/100); context.fill(Path(ellipseIn:CGRect(x:p.x-3,y:p.y-3,width:6,height:6)),with:.color(Palette.green))}
        }.accessibilityLabel("策略权重雷达图。各轴范围 0 到 100%；精确数值见旁边的条形列表。")
    }
}
struct PriorityPlot: View {
    var items:[ReadingItem]
    var preferences: Preferences
    var onMove:(UUID,Double)->Void
    @State private var dragged: UUID?
    @State private var value:Double=0
    var body: some View {
        GeometryReader {g in
            let shown=Array(items.prefix(300)), width=max(1,g.size.width-32)
            Canvas {context,size in
                for n in 0...10 {let x=16+width*Double(n)/10; var line=Path(); line.move(to:CGPoint(x:x,y:12)); line.addLine(to:CGPoint(x:x,y:105)); context.stroke(line,with:.color(Palette.line.opacity(0.6)),lineWidth:0.6); context.draw(Text("\(n)").font(.system(size:10)).foregroundColor(Palette.muted),at:CGPoint(x:x,y:125))}
                for (i,item) in shown.enumerated() {
                    let score=dragged == item.id ? value : PriorityEngine.explain(item,preferences:preferences).score
                    let point=CGPoint(x:16+width*score/10,y:25+Double(i*31%70))
                    let r:Double=item.priorityLocked == true ? 5:4
                    context.fill(Path(ellipseIn:CGRect(x:point.x-r,y:point.y-r,width:2*r,height:2*r)),with:.color(item.priorityOverride != nil ? Color(red:0.66,green:0.40,blue:0.25) : Palette.green.opacity(0.65)))
                }
            }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance:5).onChanged {event in
                if dragged == nil {let nearest=shown.enumerated().min {a,b in
                    func distance(_ e:EnumeratedSequence<[ReadingItem]>.Element)->Double {let x=16+width*PriorityEngine.explain(e.element,preferences:preferences).score/10; let y=25+Double(e.offset*31%70); return pow(x-event.startLocation.x,2)+pow(y-event.startLocation.y,2)}
                    return distance(a)<distance(b)
                }
                    if let nearest=nearest {let x=16+width*PriorityEngine.explain(nearest.element,preferences:preferences).score/10; let y=25+Double(nearest.offset*31%70); if hypot(x-event.startLocation.x,y-event.startLocation.y)<=20 {dragged=nearest.element.id}}
                }
                guard dragged != nil else {return}
                value=min(10,max(0,(event.location.x-16)/width*10))
            }.onEnded {_ in if let id=dragged {onMove(id,(value*10).rounded()/10)}; dragged=nil})
            if let id=dragged, let item=items.first(where:{$0.id == id}) {Text("\(item.title) · \(String(format:"%.1f",value))").font(.system(size:11)).padding(6).background(Palette.paper).offset(x:16,y:0)}
        }.accessibilityLabel("优先级分布图，0 到 10 分。拖动修改，或使用逐篇指标编辑。最多显示优先级最高的 300 篇。")
    }
}

struct StrategyEditor: View {
    @ObservedObject var store:ReadingStore
    @Environment(\.dismiss) private var dismiss
    @State private var metrics:[MetricDefinition]=[]
    @State private var profiles:[ReadingStrategy]=[]
    @State private var selected="wander"
    @State private var newName=""
    @State private var validation=""
    var index:Int {profiles.firstIndex(where:{$0.id == selected}) ?? 0}
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {Text("指标与权重，由你定义。").font(.system(size:24,weight:.medium,design:.serif)); Spacer(); Button("完成编辑") {save()}.buttonStyle(ActionStyle(primary:true))}
            if !profiles.isEmpty {
                HStack {Picker("编辑策略",selection:$selected) {ForEach(profiles) {Text($0.name).tag($0.id)}}; Button("复制为新策略") {guard profiles.count<20 else{return}; var copy=profiles[index]; copy.id=UUID().uuidString; copy.name += " · 自定"; profiles.append(copy); selected=copy.id}.buttonStyle(ActionStyle()).disabled(profiles.count>=20)}
                HStack {Text("名称"); TextField("策略名称",text:$profiles[index].name).textFieldStyle(.roundedBorder); Picker("抽样方式",selection:$profiles[index].mode) {ForEach(SamplingMode.allCases,id:\.self) {Text($0.title).tag($0)}}.frame(width:220)}
                ScrollView {
                    VStack(alignment:.leading,spacing:14) {
                        HStack {Text("指标").frame(width:105,alignment:.leading); Text("方向").frame(width:138,alignment:.leading); Text("权重（保存时归一化到 100%）"); Spacer()}.font(.system(size:11)).foregroundColor(Palette.muted)
                        ForEach(Array(metrics.enumerated()),id:\.element.id) {i,m in
                            VStack(alignment:.leading,spacing:6) {
                            HStack(spacing:10) {
                                TextField("指标名称",text:$metrics[i].name).textFieldStyle(.roundedBorder).frame(width:105)
                                Picker("方向",selection:$metrics[i].direction) {ForEach(MetricDirection.allCases,id:\.self) {Text($0.title).tag($0)}}.labelsHidden().frame(width:138)
                                Slider(value:Binding(get:{profiles[index].weights[m.id] ?? 0},set:{profiles[index].weights[m.id]=$0.rounded()}),in:0...100).tint(Palette.green)
                                Text("\(Int(profiles[index].weights[m.id] ?? 0))").monospacedDigit().frame(width:28)
                                Button {metrics.removeAll {$0.id == m.id}; for j in profiles.indices {profiles[j].weights.removeValue(forKey:m.id)}} label:{Image(systemName:"minus.circle")}.buttonStyle(.plain).help("删除指标，也会从其他策略中移除对应权重").disabled(metrics.count<=1)
                            }
                            HStack {Stepper(value:$metrics[i].defaultValue,in:0...10,step:0.5) {Text("未标注默认 \(String(format:"%.1f",metrics[i].defaultValue)) 分")}.font(.system(size:10)).frame(width:195); Spacer(); Text("归一化权重 \(String(format:"%.1f",PriorityEngine.normalized(profiles[index].weights)[m.id] ?? 0))%").font(.system(size:10)).foregroundColor(Palette.muted)}
                            }
                        }
                        if metrics.count<8 {HStack {TextField("添加一个自定义指标",text:$newName).textFieldStyle(.roundedBorder); Button("添加") {let name=newName.trimmingCharacters(in:.whitespacesAndNewlines); guard !name.isEmpty else{return}; metrics.append(MetricDefinition(id:"custom-"+UUID().uuidString,name:name)); newName=""}.buttonStyle(ActionStyle())}}
                        Text("未标注时使用各指标的默认值，兴趣和挑战程度沿用收藏设置。名称、方向与指标列表影响全部策略，权重各自保存；逐篇原始值仍保留在数据中。").font(.system(size:11)).foregroundColor(Palette.muted).fixedSize(horizontal:false,vertical:true)
                        Divider()
                        ratio("探索的机会",value:$profiles[index].exploration)
                        ratio("按最高优先级顺序选择的机会",value:$profiles[index].absoluteProbability)
                        ratio("关键词关联的影响",value:$profiles[index].semanticBlend)
                        Text("顺序选择先于随机分支。探索和关键词只用于“结合当下状态”模式；原项目指标模式直接按优先级抽样。均匀随机忽略这些权重，用于体验对照。").font(.system(size:11)).foregroundColor(Palette.muted).fixedSize(horizontal:false,vertical:true)
                    }.padding(.vertical,6)
                }
            }
            if !validation.isEmpty {Text(validation).font(.system(size:12)).foregroundColor(.red)}
            HStack {Button("取消") {dismiss()}.buttonStyle(ActionStyle()).keyboardShortcut(.cancelAction); Button("载入预设") {metrics=MetricDefinition.defaults; profiles=ReadingStrategy.defaults; selected="wander"}.buttonStyle(.plain).font(.system(size:12)); Button("删除当前策略") {guard profiles.count>1 else{return}; profiles.remove(at:index); selected=profiles[0].id}.buttonStyle(.plain).font(.system(size:12)).disabled(profiles.count<=1); Spacer(); Text("保存后启用当前策略").font(.system(size:11)).foregroundColor(Palette.muted)}
        }.padding(28).frame(width:730,height:660).background(Palette.paper).foregroundColor(Palette.ink).onAppear {metrics=store.library.preferences.metricDefinitions; profiles=store.library.preferences.allStrategies; selected=store.library.preferences.strategy.id}
    }
    func ratio(_ name:String,value:Binding<Double>)->some View {HStack {Text(name).font(.system(size:12)).frame(width:225,alignment:.leading); Slider(value:value,in:0...1,step:0.05).tint(Palette.green); Text("\(Int(value.wrappedValue*100))%").font(.system(size:12)).monospacedDigit().frame(width:40)}}
    func save() {if store.applyStrategies(metrics:metrics,profiles:profiles,selected:selected) {dismiss()} else {validation=store.error ?? "保存失败"; store.error=nil}}
}

struct MetricEditor: View {
    @ObservedObject var store:ReadingStore
    var item:ReadingItem
    @Environment(\.dismiss) private var dismiss
    @State private var values:[String:Double]=[:]
    @State private var manual=false
    @State private var priority=5.0
    @State private var locked=false
    var draft:ReadingItem {var copy=item; copy.metricValues=values; copy.priorityOverride=manual ? priority:nil; return copy}
    var explanation:PriorityExplanation {PriorityEngine.explain(draft,preferences:store.library.preferences)}
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            Text(item.title).font(.system(size:23,weight:.medium,design:.serif)).lineLimit(2)
            HStack(alignment:.firstTextBaseline) {Text(String(format:"%.2f",explanation.score)).font(.system(size:44,weight:.light,design:.serif)); Text("长期优先级 / 10").font(.system(size:12)).foregroundColor(Palette.muted); Spacer(); if manual {Text("手动指定").font(.system(size:12)).foregroundColor(Palette.green)}}
            ScrollView {VStack(spacing:15) {ForEach(store.library.preferences.metricDefinitions) {m in
                HStack(spacing:10) {
                    Toggle(m.name,isOn:Binding(get:{values[m.id] != nil},set:{if $0 {values[m.id]=PriorityEngine.rawValue(item,metric:m).0} else {values.removeValue(forKey:m.id)}})).toggleStyle(.checkbox).frame(width:130,alignment:.leading)
                    Slider(value:Binding(get:{values[m.id] ?? PriorityEngine.rawValue(item,metric:m).0},set:{values[m.id]=$0}),in:0...10,step:0.5).tint(Palette.green)
                    Text(String(format:"%.1f",values[m.id] ?? PriorityEngine.rawValue(item,metric:m).0)).monospacedDigit().font(.system(size:12)).frame(width:30)
                }
            }}}.frame(maxHeight:245)
            Text("勾选表示明确评分；未勾选时沿用原设置或默认值。零分会完整保留。明确评分后，批量对齐不会覆盖此文献的优先级。").font(.system(size:11)).foregroundColor(Palette.muted).fixedSize(horizontal:false,vertical:true)
            HStack {Toggle("手动指定优先级",isOn:$manual).toggleStyle(.checkbox); if manual {Slider(value:$priority,in:0...10,step:0.1).tint(Palette.green); Text(String(format:"%.1f",priority)).monospacedDigit()}}
            Toggle("保护此文献，批量对齐时保持不变",isOn:$locked).toggleStyle(.checkbox).font(.system(size:12))
            Text("指标计算："+explanation.terms.map {"\($0.name) \(String(format:"%.0f",$0.weight))%\($0.isDefault ? "（默认值）" : "")"}.joined(separator:" · ")+" → "+String(format:"%.2f",explanation.computed)).font(.system(size:11)).foregroundColor(Palette.muted).fixedSize(horizontal:false,vertical:true)
            HStack {Button("取消") {dismiss()}.buttonStyle(ActionStyle()).keyboardShortcut(.cancelAction); Spacer(); Button("保存") {if store.setMetrics(item.id,values:values,priority:manual ? priority:nil,locked:locked) {dismiss()}}.buttonStyle(ActionStyle(primary:true)).keyboardShortcut(.defaultAction)}
        }.padding(28).frame(width:620).background(Palette.paper).foregroundColor(Palette.ink).onAppear {values=item.metricValues ?? [:]; manual=item.priorityOverride != nil; priority=item.priorityOverride ?? explanation.computed; locked=item.priorityLocked ?? false}
    }
}
struct AlignmentView:View {
    @ObservedObject var store:ReadingStore
    @Environment(\.dismiss) private var dismiss
    @State private var changes:[(ReadingItem,Double)]=[]
    var body:some View {VStack(alignment:.leading,spacing:20) {
        Text("先看变化，再决定。").font(.system(size:25,weight:.medium,design:.serif))
        Text("根据当前范围的标题、主题与收藏理由做 TF-IDF 关键词关联，将有差异的正相关分数映射到 1—9。只调整未明确评分的自动优先级；明确评分（包括重要性为零）、锁定或手动指定的文献均会跳过。这不是内容质量评价。").font(.system(size:12)).foregroundColor(Palette.muted).fixedSize(horizontal:false,vertical:true)
        if changes.isEmpty {Text("暂时没有可对齐的差异。先设置研究关键词，或主动选择一些材料作为关联锚点。").foregroundColor(Palette.muted).padding(.vertical,30)}
        ScrollView {LazyVStack {ForEach(changes,id:\.0.id) {item,new in HStack {Text(item.title).font(.system(size:13)); Spacer(); Text(String(format:"%.1f → %.1f",PriorityEngine.explain(item,preferences:store.library.preferences).score,new)).monospacedDigit().font(.system(size:12))}.padding(.vertical,8)}}}.frame(height:280)
        HStack {Button("取消") {dismiss()}.buttonStyle(ActionStyle()); Spacer(); Button("应用 \(changes.count) 篇的调整") {store.applyAlignment(changes.map {($0.0.id,$0.1)}); dismiss()}.buttonStyle(ActionStyle(primary:true)).disabled(changes.isEmpty)}
    }.padding(28).frame(width:660).background(Palette.paper).foregroundColor(Palette.ink).onAppear {changes=store.alignPreview()}}
}
