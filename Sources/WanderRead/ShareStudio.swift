import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum PosterTheme:String,CaseIterable,Identifiable {
    case forest, night, clay, dawn
    var id:String {rawValue}
    var title:String {switch self {case .forest:return "林间"; case .night:return "夜航"; case .clay:return "陶土"; case .dawn:return "晨光"}}
    var milestone:String? {switch self {case .forest:return nil; case .night:return "first"; case .clay:return "return"; case .dawn:return "topics"}}
    var paper:Color {switch self {case .forest:return Color(red:0.955,green:0.958,blue:0.92);case .night:return Color(red:0.10,green:0.16,blue:0.21);case .clay:return Color(red:0.97,green:0.93,blue:0.87);case .dawn:return Color(red:0.98,green:0.94,blue:0.92)}}
    var ink:Color {switch self {case .forest:return Color(red:0.16,green:0.21,blue:0.18);case .night:return Color(red:0.94,green:0.94,blue:0.86);case .clay:return Color(red:0.36,green:0.18,blue:0.13);case .dawn:return Color(red:0.27,green:0.22,blue:0.34)}}
    var accent:Color {switch self {case .forest:return Color(red:0.20,green:0.34,blue:0.26);case .night:return Color(red:0.75,green:0.80,blue:0.62);case .clay:return Color(red:0.65,green:0.34,blue:0.22);case .dawn:return Color(red:0.51,green:0.39,blue:0.58)}}
    func available(_ l:Library)->Bool {milestone == nil || (l.unlocks ?? []).contains {$0.id == milestone}}
}
enum PosterLayout:String,CaseIterable,Identifiable {
    case portrait, square, wide
    var id:String {rawValue}
    var title:String {switch self {case .portrait:return "竖版";case .square:return "方形";case .wide:return "横版"}}
    var size:CGSize {switch self {case .portrait:return CGSize(width:900,height:1200);case .square:return CGSize(width:1000,height:1000);case .wide:return CGSize(width:1400,height:900)}}
}
enum PosterTemplate:String,CaseIterable,Identifiable {
    case calendar, topics, milestone, cloud
    var id:String {rawValue}
    var title:String {switch self {case .calendar:return "阅读足迹";case .topics:return "主题地图";case .milestone:return "里程纪念";case .cloud:return "主题词云"}}
}
struct PosterView:View {
    var library:Library
    var period:JourneyPeriod = .month
    var theme:PosterTheme = .forest
    var layout:PosterLayout = .portrait
    var template:PosterTemplate = .calendar
    var profile:ShareProfile?
    var displayName=""
    var showTopics=false
    var now=Date()
    var isPreview=false
    var summary:JourneySummary {JourneyAnalytics.summary(library,days:period.rawValue,now:now)}
    var body:some View {
        let wide=layout == .wide
        let size=layout.size
        ZStack(alignment:.topTrailing) {
            theme.paper
            ZStack {
                ForEach(0..<4) {n in Ellipse().stroke(theme.accent.opacity(0.12),lineWidth:1).frame(width:Double(300+n*65),height:Double(560+n*40)).rotationEffect(.degrees(Double(25+n*18)))}
                Circle().fill(theme.accent.opacity(0.3)).frame(width:18,height:18).offset(x:128,y:-180)
            }.frame(width:440,height:570).offset(x:90,y:-80).accessibilityHidden(true)
            VStack(alignment:.leading,spacing:0) {
                HStack(alignment:.top) {
                    VStack(alignment:.leading,spacing:10) {Text(displayName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? "我的漫读足迹" : displayName).font(.system(size:19,weight:.medium)); Text((isPreview ? "示例资料 · " : "")+period.title+" · "+now.formatted(.dateTime.year().month().day())).font(.system(size:14)).opacity(0.7)}
                    if let p=profile,p.visible {
                        HStack(spacing:12) {
                            if let data=p.avatar,let image=NSImage(data:data) {Image(nsImage:image).resizable().scaledToFill().frame(width:56,height:56).clipShape(Circle())}
                            VStack(alignment:.leading,spacing:7) {Text(p.nickname.isEmpty ? "漫读者":p.nickname).font(.system(size:19,weight:.medium));if !p.bio.isEmpty {Text(p.bio).font(.system(size:12)).lineLimit(3).frame(maxWidth:240,alignment:.leading)}}
                        }
                    }
                    Spacer(); Text("漫读").font(.system(size:27,weight:.medium,design:.serif))
                }
                Spacer(minLength:30)
                VStack(alignment:.leading,spacing:20) {
                    Text(template == .topics ? "好奇心，\n也有自己的地图。" : template == .milestone ? "慢慢走，\n也留下了光。" : "让好奇，\n留下形状。").font(.system(size:wide ? 67:64,weight:.medium,design:.serif)).lineSpacing(10).fixedSize(horizontal:false,vertical:true)
                    Text("每一次停留，都从自己的选择开始。").font(.system(size:18)).opacity(0.72)
                }
                Spacer(minLength:30)
                if wide {HStack(alignment:.center,spacing:70) {numbers.frame(width:450); chart.frame(maxWidth:.infinity).frame(height:205)}}
                else {numbers; Spacer(minLength:36); chart.frame(height:layout == .portrait ? 220 : 190)}
                Spacer(minLength:30)
                Rectangle().fill(theme.ink.opacity(0.18)).frame(height:1)
                HStack(alignment:.bottom,spacing:24) {
                    VStack(alignment:.leading,spacing:9) {Text("不必全都读完。愿意停留，就从那里开始。").font(.system(size:17,weight:.medium,design:.serif)); Text("按主动打开记录 · 不代表读完或掌握 · 本地生成").font(.system(size:11)).opacity(0.65)}
                    Spacer()
                    if let last=library.unlocks?.last, let m=MilestoneDefinition.all.first(where:{$0.id == last.id}) {VStack(spacing:7) {Image(systemName:m.symbol).font(.system(size:24,weight:.light)); Text(m.title).font(.system(size:11))}.foregroundColor(theme.accent)}
                }.padding(.top,22)
            }.padding(wide ? 64:60)
        }.foregroundColor(theme.ink).frame(width:size.width,height:size.height).clipped().environment(\.colorScheme,.light)
    }
    var numbers:some View {
        HStack(alignment:.firstTextBaseline,spacing:48) {
            number(summary.sessions.count,"次主动选择")
            number(summary.uniqueItems,"篇不同材料")
            number(summary.returns,"次重新拾起")
        }
    }
    func number(_ value:Int,_ label:String)->some View {VStack(alignment:.leading,spacing:9) {Text("\(value)").font(.system(size:58,weight:.light,design:.serif)).monospacedDigit(); Text(label).font(.system(size:15)).opacity(0.72)}}
    @ViewBuilder var chart:some View {
        if template == .cloud {
            VStack(alignment:.leading,spacing:6) {
                Text(showTopics ? "好奇的词海":"主题词云 · 名称已隐藏").font(.system(size:15,weight:.medium))
                GeometryReader {g in
                    let words=TopicCloud.words(summary.topics,size:g.size,showNames:showTopics)
                    ZStack(alignment:.topLeading) {ForEach(words) {word in Text(word.name).font(.system(size:word.font,weight:.medium)).foregroundColor(theme.accent).position(x:word.rect.midX,y:word.rect.midY)}}
                }
                Text(summary.topics.isEmpty ? "还没有主动选择的主题记录":"按主题分布绘制 · 多主题均分一次选择 · 不分析全文词频").font(.system(size:10)).opacity(0.65)
            }
        } else if template == .milestone {
            let earned=(library.unlocks ?? []).compactMap {u in MilestoneDefinition.all.first(where:{$0.id == u.id})}
            HStack(spacing:30) {
                if earned.isEmpty {VStack(alignment:.leading,spacing:14) {Image(systemName:"leaf").font(.system(size:37,weight:.ultraLight)); Text("好奇尚在路上，\n这张图也可以从零开始。").font(.system(size:20,design:.serif)).lineSpacing(7)}}
                ForEach(earned) {m in VStack(spacing:14) {ZStack {Circle().stroke(theme.accent.opacity(0.4),lineWidth:1); Circle().stroke(theme.accent.opacity(0.16),lineWidth:1).padding(7); Image(systemName:m.symbol).font(.system(size:29,weight:.light))}.frame(width:82,height:82); Text(m.title).font(.system(size:14,design:.serif));if let unlock=library.unlocks?.first(where:{$0.id==m.id}) {Text(unlock.earnedAt.formatted(.dateTime.year().month().day())).font(.system(size:9));Text(unlock.certificate).font(.system(size:7)).lineLimit(1)}}.foregroundColor(theme.accent)}
            }.frame(maxWidth:.infinity,alignment:.leading)
        } else if template == .topics {
            VStack(alignment:.leading,spacing:19) {
                Text(showTopics ? "最近走向的主题" : "主题分布 · 名称已隐藏").font(.system(size:15,weight:.medium))
                if summary.topics.isEmpty {Text("还没有留下主题记录").font(.system(size:18,design:.serif)).opacity(0.65)}
                ForEach(Array(summary.topics.prefix(4).enumerated()),id:\.element.id) {i,t in HStack(spacing:18) {Text(showTopics ? t.name : "主题 \(i+1)").font(.system(size:15)).frame(width:140,alignment:.leading).lineLimit(1); GeometryReader {g in Capsule().fill(theme.accent.opacity(0.1)).overlay(alignment:.leading) {Capsule().fill(theme.accent.opacity(0.75)).frame(width:g.size.width*t.value/max(1,Double(summary.sessions.count)))}}.frame(height:9); Text(String(format:"%.0f%%",t.value/max(1,Double(summary.sessions.count))*100)).font(.system(size:14)).monospacedDigit().frame(width:45,alignment:.trailing)}}
                if summary.topics.count>4 {Text("其余 \(summary.topics.count-4) 个主题 · \(String(format:"%.0f",summary.topics.dropFirst(4).map(\.value).reduce(0,+)/max(1,Double(summary.sessions.count))*100))%").font(.system(size:11)).opacity(0.65)}
            }
        } else {
            VStack(alignment:.leading,spacing:18) {
                Text("留下记录的日子").font(.system(size:15,weight:.medium))
                posterHeatmap
                HStack(spacing:7) {Text("未记录"); ForEach(0..<5) {n in RoundedRectangle(cornerRadius:2).fill(theme.accent.opacity(n == 0 ? 0.07:0.16+Double(n)*0.17)).frame(width:12,height:12)}; Text("4+ 次选择"); Spacer(); Text("\(summary.activeDays) 天留下记录")}.font(.system(size:11)).opacity(0.7)
            }
        }
    }
    var posterHeatmap:some View {
        let start=summary.days.first?.date ?? now
        let pad=(Calendar.current.component(.weekday,from:start)+5)%7
        let weeks=max(1,Int(ceil(Double(summary.days.count+pad)/7)))
        return HStack(spacing:8) {ForEach(0..<weeks,id:\.self) {w in VStack(spacing:7) {ForEach(0..<7,id:\.self) {d in let i=w*7+d-pad; if summary.days.indices.contains(i) {let count=summary.days[i].count; RoundedRectangle(cornerRadius:3).fill(theme.accent.opacity(count == 0 ? 0.07 : 0.16+Double(min(4,count))*0.17))} else {RoundedRectangle(cornerRadius:3).fill(.clear)}}}.frame(maxWidth:.infinity)}}
    }
}
@MainActor enum ShareExporter {
    static func image(_ poster:PosterView) throws -> NSImage {
        let renderer=ImageRenderer(content:poster)
        renderer.scale=2
        renderer.proposedSize=ProposedViewSize(width:poster.layout.size.width,height:poster.layout.size.height)
        guard let image=renderer.nsImage else {throw InputError.invalid("分享图未能生成，请重试。")}; return image
    }
    static func copy(_ poster:PosterView,to board:NSPasteboard = .general) throws {
        let data=try png(poster)
        board.clearContents()
        guard board.setData(data,forType:.png) else {throw InputError.invalid("图片未能写入剪贴板，请重试。")}
    }
    static func png(_ poster:PosterView) throws -> Data {
        guard let tiff=try image(poster).tiffRepresentation, let rep=NSBitmapImageRep(data:tiff), let data=rep.representation(using:.png,properties:[:]) else {throw InputError.invalid("分享图未能编码。")}; return data
    }
}
struct ShareStudio:View {
    @ObservedObject var store:ReadingStore
    var initialTemplate:PosterTemplate = .calendar
    @Environment(\.dismiss) private var dismiss
    @State private var period=JourneyPeriod.month
    @State private var theme=PosterTheme.forest
    @State private var layout=PosterLayout.portrait
    @State private var template=PosterTemplate.calendar
    @State private var name=""
    @State private var showTopics=false
    @State private var editingProfile=false
    @State private var copied=false
    @State private var failure=""
    @State private var referenceDate=Date()
    @State private var sharePicker:NSSharingServicePicker?
    var poster:PosterView {PosterView(library:store.library,period:period,theme:theme,layout:layout,template:template,profile:store.library.preferences.shareProfile,displayName:name,showTopics:showTopics,now:referenceDate,isPreview:store.isPreview)}
    var body:some View {
        HStack(alignment:.top,spacing:30) {
            VStack(spacing:18) {
                let scale=min(440/layout.size.width,560/layout.size.height)
                poster.scaleEffect(scale,anchor:.topLeading).frame(width:layout.size.width*scale,height:layout.size.height*scale,alignment:.topLeading).shadow(color:.black.opacity(0.10),radius:15,x:0,y:8)
                Text(store.isPreview ? "独立示例预览 · 非个人真实记录" : "与导出使用同一份数据和版式").font(.system(size:11)).foregroundColor(Palette.muted)
            }.frame(width:440,height:600)
            VStack(alignment:.leading,spacing:18) {
                Group {
                HStack {Text("留作纪念").font(.system(size:27,weight:.medium,design:.serif)); Spacer(); Button {dismiss()} label:{Image(systemName:"xmark")}.buttonStyle(.plain).accessibilityLabel("关闭分享图")}
                Text("一张属于自己的阅读小传。").font(.system(size:13)).foregroundColor(Palette.muted)
                Picker("时间范围",selection:$period) {ForEach(JourneyPeriod.allCases) {Text($0.title).tag($0)}}
                Picker("版式",selection:$template) {ForEach(PosterTemplate.allCases) {Text($0.title).tag($0)}}
                Picker("尺寸",selection:$layout) {ForEach(PosterLayout.allCases) {Text($0.title).tag($0)}}.pickerStyle(.segmented)
                }
                Group {
                Divider()
                Text("选择配色").font(.system(size:13,weight:.medium))
                ForEach(PosterTheme.allCases) {t in
                    HStack(spacing:10) {
                        Button {if t.available(store.library) {theme=t}} label:{HStack {Circle().fill(t.accent).frame(width:16,height:16); Text(t.title); Spacer(); Image(systemName:theme == t ? "checkmark.circle.fill" : t.available(store.library) ? "circle" : "lock")}}.buttonStyle(.plain).disabled(!t.available(store.library))
                    }.font(.system(size:12))
                }
                Text("基础配色始终可用。里程解锁的新配色永久保留。").font(.system(size:11)).foregroundColor(Palette.muted).fixedSize(horizontal:false,vertical:true)
                }
                Group {
                HStack {Button("头像、昵称与简介…") {editingProfile=true}.buttonStyle(.plain).foregroundColor(Palette.green);Spacer();Toggle("显示名片",isOn:Binding(get:{store.library.preferences.shareProfile?.visible ?? false},set:{value in var p=store.library.preferences.shareProfile ?? ShareProfile();p.visible=value;_=store.saveProfile(p)})).toggleStyle(.checkbox)}.font(.system(size:11))
                TextField("这张图的标题（可留空）",text:$name).textFieldStyle(.roundedBorder)
                Toggle("显示研究主题名称",isOn:$showTopics).toggleStyle(.checkbox).font(.system(size:12))
                Text("图中不包含文件路径、原文或文献标题。主题名称默认隐藏。").font(.system(size:11)).foregroundColor(Palette.muted).fixedSize(horizontal:false,vertical:true)
                if !failure.isEmpty {Text(failure).font(.system(size:11)).foregroundColor(.red)}
                }
                Spacer(minLength:0)
                HStack {Button("保存 PNG…") {Task {@MainActor in save()}}.buttonStyle(ActionStyle(primary:true)); Button(copied ? "已复制":"复制图片") {Task {@MainActor in copyImage()}}.buttonStyle(ActionStyle()); Button("分享…") {Task {@MainActor in share()}}.buttonStyle(ActionStyle())}
                Text("高清导出 \(Int(layout.size.width*2)) × \(Int(layout.size.height*2))").font(.system(size:10)).foregroundColor(Palette.muted)
            }.frame(maxWidth:.infinity,alignment:.leading)
        }.padding(28).frame(width:920,height:700).background(Palette.paper).foregroundColor(Palette.ink).onAppear {template=initialTemplate}.sheet(isPresented:$editingProfile) {ProfileEditor(store:store)}
    }
    @MainActor func copyImage() {
        do {try ShareExporter.copy(poster);copied=true;failure="";store.message="分享图已复制，可直接粘贴到聊天或笔记。"}
        catch {failure=error.localizedDescription}
    }
    @MainActor func save() {
        let panel=NSSavePanel(); panel.allowedContentTypes=[.png]; panel.nameFieldStringValue="漫读-\(template.title)-\(Date().formatted(.dateTime.year().month().day())).png"
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do {try ShareExporter.png(poster).write(to:url,options:.atomic); failure=""; store.message="个人阅读分享图已保存。"} catch {failure=error.localizedDescription}
    }
    @MainActor func share() {
        do {let image=try ShareExporter.image(poster); guard let view=NSApp.keyWindow?.contentView else {return}; let picker=NSSharingServicePicker(items:[image]); sharePicker=picker; picker.show(relativeTo:NSRect(x:view.bounds.maxX-90,y:45,width:1,height:1),of:view,preferredEdge:.minY); failure=""} catch {failure=error.localizedDescription}
    }
}
