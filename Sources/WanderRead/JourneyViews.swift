import SwiftUI

struct JourneyView: View {
    @ObservedObject var store:ReadingStore
    @State private var period=JourneyPeriod.month
    @State private var sharing=false
    var summary:JourneySummary {JourneyAnalytics.summary(store.library,days:period.rawValue)}
    var body:some View {
        VStack(alignment:.leading,spacing:28) {
            HStack(alignment:.top) {
                SectionIntro(eyebrow:"你的注意力，留下了轨迹",title:"好奇，正在往哪里去？",subtitle:"回看主动做出的选择。没有需要填满的日历，也没有欠下的进度。")
                Spacer(); Button {sharing=true} label:{Label("生成分享图",systemImage:"square.and.arrow.up")}.buttonStyle(ActionStyle(primary:true))
            }
            Picker("回顾范围",selection:$period) {ForEach(JourneyPeriod.allCases) {Text($0.title).tag($0)}}.pickerStyle(.segmented).frame(width:320)
            HStack(spacing:0) {
                JourneyNumber(value:"\(summary.sessions.count)",label:"次主动选择")
                JourneyNumber(value:"\(summary.uniqueItems)",label:"篇不同材料")
                JourneyNumber(value:"\(summary.returns)",label:"次重新拾起")
                JourneyNumber(value:"\(summary.activeDays)",label:"天留下记录")
            }.padding(.vertical,24).background(Palette.side.opacity(0.65)).cornerRadius(16)
            VStack(alignment:.leading,spacing:16) {
                HStack {Text("日历里的偶遇").font(.system(size:21,weight:.medium,design:.serif)); Spacer(); Text("最近 90 天").font(.system(size:11)).foregroundColor(Palette.muted)}
                ActivityHeatmap(days:JourneyAnalytics.summary(store.library,days:90).days).frame(height:150)
                HStack(spacing:6) {Text("未记录"); ForEach(0..<5) {n in RoundedRectangle(cornerRadius:2).fill(Palette.green.opacity(n == 0 ? 0.07 : 0.16+Double(n)*0.17)).frame(width:11,height:11)}; Text("1 · 2 · 3 · 4+ 次选择"); Spacer(); Text("空白也可以是休息")} .font(.system(size:10)).foregroundColor(Palette.muted)
            }
            VStack(alignment:.leading,spacing:18) {
                Text("最近，常常走向这些主题").font(.system(size:21,weight:.medium,design:.serif))
                if summary.topics.isEmpty {empty("主动选择一篇材料后，这里会开始留下主题轨迹。")} else {
                    TopicBars(topics:summary.topics,total:Double(summary.sessions.count))
                    Text("一篇材料有多个主题时，会均分这次选择；比例合计 100%。主题沿用选择时的快照，旧版记录使用当前标签。").font(.system(size:11)).foregroundColor(Palette.muted).fixedSize(horizontal:false,vertical:true)
                }
            }
            VStack(alignment:.leading,spacing:16) {
                Text("哪些来源值得继续遇见").font(.system(size:21,weight:.medium,design:.serif))
                if summary.sources.isEmpty {empty("尚无来源记录。示例入口不会计入个人回顾。")} else {
                    HStack {Text("来源"); Spacer(); Text("出现").frame(width:65); Text("主动选择").frame(width:65)}.font(.system(size:11)).foregroundColor(Palette.muted)
                    ForEach(Array(summary.sources.prefix(12))) {source in HStack {Text(source.name).font(.system(size:13)); Spacer(); Text("\(source.exposures)").monospacedDigit().frame(width:65); Text("\(source.choices)").monospacedDigit().frame(width:65)}.font(.system(size:12)); Divider()}
                    Text("出现记录从 0.2 版开始。收藏中手动打开也计入选择，因此不把两列相除当作点击率。").font(.system(size:11)).foregroundColor(Palette.muted).fixedSize(horizontal:false,vertical:true)
                }
            }
            VStack(alignment:.leading,spacing:16) {
                Text("策略有没有帮上忙？").font(.system(size:21,weight:.medium,design:.serif))
                if summary.strategies.isEmpty {empty("从推荐中主动选择，并在收尾时自愿反馈，这里才会有记录。")} else {
                    ForEach(summary.strategies) {s in HStack {Text(s.name).font(.system(size:13)); Spacer(); Text("选择 \(s.choices) 次 · \(s.feedback) 次反馈中 \(s.helpful) 次有帮助").font(.system(size:11)).foregroundColor(Palette.muted)}}
                }
                Text("这是使用记录，不是因果实验。手动挑选和旧版缺少策略快照的记录不参与比较；停留越久不被视为推荐越好。").font(.system(size:11)).foregroundColor(Palette.muted).fixedSize(horizontal:false,vertical:true)
            }
            Divider()
            VStack(alignment:.leading,spacing:16) {
                Text("最近停留过的地方").font(.system(size:21,weight:.medium,design:.serif))
                ForEach(Array(summary.sessions.sorted {$0.startedAt > $1.startedAt}.prefix(20))) {s in
                    HStack(alignment:.top,spacing:18) {
                        Text(s.startedAt,format:.dateTime.month().day()).font(.system(size:11)).foregroundColor(Palette.muted).frame(width:55,alignment:.leading)
                        VStack(alignment:.leading,spacing:6) {Text(s.title).font(.system(size:14,weight:.medium)); if let line=s.reflection,!line.isEmpty {Text(line).font(.system(size:12)).foregroundColor(Palette.muted).lineLimit(2)}}
                        Spacer(); Text(s.outcome ?? "停留中").font(.system(size:11)).foregroundColor(Palette.muted)
                    }.padding(.vertical,8)
                }
                Text("已收尾 \(summary.closed) 次，记录停留约 \(Int(summary.recordedSeconds/60)) 分钟。停留按经过时间计算，不代表实际阅读或完成数量。").font(.system(size:11)).foregroundColor(Palette.muted).fixedSize(horizontal:false,vertical:true)
            }
        }.sheet(isPresented:$sharing) {ShareStudio(store:store)}
    }
    func empty(_ text:String)->some View {Text(text).font(.system(size:13)).foregroundColor(Palette.muted).padding(.vertical,20)}
}
struct JourneyNumber:View {
    var value:String
    var label:String
    var body:some View {VStack(alignment:.leading,spacing:8) {Text(value).font(.system(size:42,weight:.light,design:.serif)); Text(label).font(.system(size:11)).foregroundColor(Palette.muted)}.frame(maxWidth:.infinity)}
}
struct ActivityHeatmap:View {
    var days:[DayActivity]
    var color:Color=Palette.green
    var body:some View {
        let calendar=Calendar.current
        let padding=days.first.map {(calendar.component(.weekday,from:$0.date)+5)%7} ?? 0
        let weeks=max(1,Int(ceil(Double(days.count+padding)/7)))
        HStack(alignment:.top,spacing:7) {
            VStack(spacing:0) {ForEach(["一","二","三","四","五","六","日"],id:\.self) {Text($0).font(.system(size:9)).foregroundColor(Palette.muted).frame(maxHeight:.infinity)}}.frame(width:12)
            ForEach(0..<weeks,id:\.self) {week in VStack(spacing:5) {ForEach(0..<7,id:\.self) {day in
                let index=week*7+day-padding
                if days.indices.contains(index) {let d=days[index]; RoundedRectangle(cornerRadius:3).fill(color.opacity(d.count == 0 ? 0.07 : 0.16+Double(min(4,d.count))*0.17)).help(d.date.formatted(date:.abbreviated,time:.omitted)+" · "+(d.count == 0 ? "未记录主动选择" : "\(d.count) 次主动选择")).accessibilityLabel(d.date.formatted(date:.abbreviated,time:.omitted)+"，\(d.count) 次选择")}
                else {RoundedRectangle(cornerRadius:3).fill(.clear)}
            }}.frame(maxWidth:.infinity)}
        }
    }
}
struct TopicBars:View {
    var topics:[TopicTotal]
    var total:Double
    var color:Color=Palette.green
    var body:some View {
        VStack(spacing:14) {
            ForEach(Array(topics.prefix(7))) {t in HStack(spacing:18) {
                Text(t.name).font(.system(size:12)).frame(width:100,alignment:.leading).lineLimit(1)
                GeometryReader {g in Capsule().fill(color.opacity(0.08)).overlay(alignment:.leading) {Capsule().fill(color.opacity(0.75)).frame(width:g.size.width*t.value/max(1,total))}}.frame(height:9)
                Text(String(format:"%.0f%%",t.value/max(1,total)*100)).font(.system(size:12)).monospacedDigit().frame(width:40,alignment:.trailing)
            }.accessibilityElement(children:.combine)}
            if topics.count>7 {Text("另有 \(topics.count-7) 个主题，合计 \(String(format:"%.0f",topics.dropFirst(7).map(\.value).reduce(0,+)/max(1,total)*100))%").font(.system(size:11)).foregroundColor(Palette.muted).frame(maxWidth:.infinity,alignment:.trailing)}
        }
    }
}
struct MilestoneView:View {
    @ObservedObject var store:ReadingStore
    @State private var sharing=false
    var body:some View {
        VStack(alignment:.leading,spacing:28) {
            HStack(alignment:.top) {SectionIntro(eyebrow:"慢慢走，也有值得纪念的时刻",title:"把这段经历，留作纪念。",subtitle:"里程累计保留，停一阵也不会归零。每枚勋章附达成条件、日期与纪念编号；是本机记录，不是专业资质或第三方认证。")
                Spacer(); Button("制作个人分享图") {sharing=true}.buttonStyle(ActionStyle(primary:true))}
            ForEach(MilestoneDefinition.all) {m in
                let earned=store.library.unlocks?.first(where:{$0.id == m.id})
                HStack(alignment:.center,spacing:24) {
                    ZStack {Circle().fill(earned != nil ? Palette.card : Palette.side.opacity(0.4)); Circle().stroke(Palette.line,lineWidth:1).padding(5); Image(systemName:m.symbol).font(.system(size:29,weight:.light)).foregroundColor(earned != nil ? Palette.green : Palette.muted.opacity(0.6))}.frame(width:80,height:80)
                    VStack(alignment:.leading,spacing:8) {Text(m.title).font(.system(size:24,weight:.medium,design:.serif)); Text(m.detail).font(.system(size:13)).foregroundColor(Palette.muted); Text(m.gift).font(.system(size:11)).foregroundColor(Palette.green)}
                    Spacer()
                    if let earned=earned {VStack(alignment:.trailing,spacing:7) {Label("纪念勋章 · 已达成",systemImage:"checkmark.seal").font(.system(size:12)); Text(earned.earnedAt,format:.dateTime.year().month().day()).font(.system(size:11)).foregroundColor(Palette.muted);Text(earned.certificate).font(.system(size:9,design:.monospaced)).foregroundColor(Palette.muted)}}
                    else {Text("还没发生，也不用赶").font(.system(size:11)).foregroundColor(Palette.muted)}
                }.padding(24).background(earned != nil ? Palette.surface.opacity(0.6) : .clear).cornerRadius(18)
            }
            Text("示例入口不解锁个人里程。基础分享始终可用；解锁带来配色与纪念印章，不会影响阅读、推荐或数据功能。").font(.system(size:12)).foregroundColor(Palette.muted).fixedSize(horizontal:false,vertical:true)
        }.sheet(isPresented:$sharing) {ShareStudio(store:store)}
    }
}
