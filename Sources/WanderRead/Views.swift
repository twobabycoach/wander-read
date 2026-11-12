import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size:14,weight:.medium)).padding(.horizontal,18).padding(.vertical,12)
            .foregroundColor(primary ? .white : Palette.ink)
            .background(primary ? Palette.accent : Palette.surface.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius:10)).opacity(!enabled ? 0.4 : configuration.isPressed ? 0.7 : 1)
    }
}

struct ReadingIconButton: View {
    let title: String
    let systemImage: String
    var size: CGFloat = 28
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
    }
}

struct OrbitMark: View {
    var size: CGFloat = 36
    var body: some View {
        ZStack {
            Circle().stroke(Palette.green.opacity(0.5),lineWidth:1)
            Ellipse().stroke(Palette.green,lineWidth:1.3).frame(width:size*0.42,height:size*0.98).rotationEffect(.degrees(38))
            Circle().fill(Palette.green).frame(width:size*0.15,height:size*0.15).offset(x:size*0.30,y: -size*0.32)
        }.frame(width:size,height:size).accessibilityHidden(true)
    }
}
struct MainView: View {
    @ObservedObject var store: ReadingStore
    @State private var managing = false
    @State private var zoteroImport = false
    @State private var notebookSetup = false
    @State private var related = false
    @State private var adding = false
    @State private var editItem: ReadingItem?
    @State private var finishing = false
    @State private var filter = "全部"
    @State private var search = ""
    @State private var metricItem: ReadingItem?
    @State private var sharingMilestone=false
    @FocusState private var previewFocus: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if let reader = store.pdfReader { PDFReaderView(reader: reader, store: store).id(ObjectIdentifier(reader)) }
            else if let reader = store.textReader { TextReaderView(reader: reader, store: store).id(ObjectIdentifier(reader)) }
            else { libraryView }
        }
        .foregroundColor(Palette.ink).frame(minWidth:1020,minHeight:740)
        .preferredColorScheme(Palette.theme.isDark ? .dark:.light)
        .sheet(item: $store.inspection) { ReadingInspectionView(store: store, request: $0) }
        .alert("需要留意一下",isPresented:Binding(get:{store.error != nil},set:{ if !$0 {store.error = nil} })) { Button("知道了") { store.error = nil } } message:{ Text(store.error ?? "") }
    }
    var libraryView: some View {
        HStack(spacing:0) {
            sidebar
            VStack(spacing:0) {
                topbar
                ScrollView {
                    Group {
                        if store.page == "发现" { discovery }
                        else if store.page == "收藏" { collection }
                        else if store.page == "足迹" { history }
                        else if store.page == "策略" { StrategyView(store:store) }
                        else if store.page == "回顾" { JourneyView(store:store) }
                        else if store.page == "里程" { MilestoneView(store:store) }
                        else { preferences }
                    }.padding(.horizontal,44).padding(.top,28).padding(.bottom,32).frame(maxWidth:1100)
                        .frame(maxWidth:.infinity)
                }
                if let milestone=store.latestMilestone {
                    HStack(spacing:10) {Image(systemName:milestone.symbol); Text("留下了「\(milestone.title)」").font(.system(size:12,weight:.medium)); Spacer(); Button("生成纪念图") {store.latestMilestone=nil; sharingMilestone=true}.buttonStyle(.plain).font(.system(size:12)); Button {store.latestMilestone=nil} label:{Image(systemName:"xmark")}.buttonStyle(.plain).accessibilityLabel("收起里程提示")}.padding(14).background(Palette.card).foregroundColor(Palette.green)
                }
                if store.readerOpening != nil {
                    ProgressView("正在打开原文…").controlSize(.small).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                } else if let message = store.message {
                    HStack { Image(systemName:"checkmark.circle"); Text(message); Spacer(); Button { store.message = nil } label:{ Image(systemName:"xmark") }.buttonStyle(.plain).accessibilityLabel("关闭提示") }
                        .font(.system(size:12)).padding(12).background(Palette.side)
                }
            }.background(Palette.paper)
        }
            .sheet(isPresented:$managing) {DataManager(store:store)}
            .sheet(isPresented: $zoteroImport) { ZoteroImportView(store: store) }
            .sheet(isPresented: $notebookSetup) { NotebookExportEditor(store: store) }
            .sheet(isPresented: $related) { RelatedReadingView(store: store) }
            .sheet(isPresented:$adding) { ItemForm(store:store, item:nil) }
            .sheet(item:$editItem) { ItemForm(store:store,item:$0) }
            .sheet(isPresented:$finishing) { FinishView(store:store) }
            .sheet(item:$metricItem) {MetricEditor(store:store,item:$0)}
            .sheet(isPresented:$sharingMilestone) {ShareStudio(store:store,initialTemplate:.milestone)}
            .onDrop(of:[UTType.fileURL,UTType.url],isTargeted:nil,perform:drop)
            .onReceive(NotificationCenter.default.publisher(for:Notification.Name("WanderAdd"))) { _ in adding = true }
            .onReceive(NotificationCenter.default.publisher(for:Notification.Name("WanderRefresh"))) { _ in if store.page == "发现" && store.activeSession == nil { store.refresh() } }
    }
    var sidebar: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:12) { OrbitMark(); VStack(alignment:.leading,spacing:3) { Text("漫读").font(.system(size:24,weight:.semibold,design:.serif)); Text("阅读注意力管理").font(.system(size:11)).foregroundColor(Palette.muted) } }.padding(.top,35).padding(.bottom,36)
            ForEach([("发现","sparkle"),("收藏","tray"),("策略","slider.horizontal.3"),("回顾","chart.xyaxis.line"),("里程","seal")],id:\.0) { name, icon in
                Button { store.page = name } label: { HStack(spacing:12) { Image(systemName:icon).frame(width:20); Text(name); Spacer(); if store.page == name { Circle().fill(Palette.green).frame(width:5,height:5) } }.padding(.horizontal,14).padding(.vertical,14).background(store.page == name ? Palette.surface.opacity(0.65) : .clear).cornerRadius(10) }.buttonStyle(.plain).padding(.bottom,6)
            }
            Spacer()
            VStack(alignment:.leading,spacing:8) { Text("不必全都读完。").font(.system(size:13,weight:.medium)); Text("愿意停留的那一篇，\n就从这里开始。").font(.system(size:12)).foregroundColor(Palette.muted).lineSpacing(5) }.padding(.horizontal,10).padding(.bottom,30)
            Divider().overlay(Palette.line)
            Button { store.page = "偏好" } label: { Label("偏好与数据",systemImage:"slider.horizontal.3").font(.system(size:13)).padding(.vertical,20) }.buttonStyle(.plain)
            Label("保存在这台 Mac",systemImage:"internaldrive").font(.system(size:10)).foregroundColor(Palette.muted).padding(.bottom,22)
        }.padding(.horizontal,20).frame(width:204).background(Palette.side)
    }
    var topbar: some View {
        HStack {
            Text(store.isPreview ? "独立示例预览 · 不写入个人资料" : store.page == "发现" ? "留一点时间，给意料之外" : store.page).font(.system(size:12)).foregroundColor(Palette.muted)
            Spacer()
            if store.activeSession == nil && (store.page == "发现" || store.page == "收藏") {
                Button { related = true } label: { Label("相似度榜", systemImage: "list.number") }
                    .buttonStyle(ActionStyle())
            }
            if store.page == "发现" && store.activeSession == nil && !store.previousRecommendations.isEmpty {
                Button("上一批", action: store.returnToPreviousBatch).buttonStyle(ActionStyle())
            }
            if store.page == "发现" && store.activeSession == nil && !store.recommendations.isEmpty {
                Button { withAnimation(reduceMotion ? nil : .easeOut(duration:0.18)) { store.refresh() } } label:{ Label(store.viewingPreviousBatch ? "下一批" : "换一批",systemImage:"arrow.triangle.2.circlepath") }.buttonStyle(ActionStyle()).keyboardShortcut("r",modifiers:.command)
            }
            Menu { Button("添加本地文件…",action:store.pickFiles); Button("从 Obsidian 仓库收录…",action:store.importObsidian); Button("从 Zotero 收录…") { zoteroImport = true } } label: { Image(systemName:"square.and.arrow.down").font(.system(size:16)) }.menuStyle(.borderlessButton).frame(width:30).help("收录本地内容")
            Button { adding = true } label:{ Label("收下一篇",systemImage:"plus") }.buttonStyle(ActionStyle()).keyboardShortcut("n",modifiers:.command)
        }.padding(.horizontal,36).padding(.vertical,16).overlay(alignment:.bottom) { Rectangle().fill(Palette.line.opacity(0.6)).frame(height:1) }
    }
    var discovery: some View {
        VStack(alignment:.leading,spacing:20) {
            if store.activeSession != nil { activeVisit }
            else {
                VStack(alignment:.leading,spacing:10) {
                    Text("随 心 遇 见").font(.system(size:11,weight:.semibold)).foregroundColor(Palette.green)
                    Text("今天，什么让你好奇？").font(.system(size:34,weight:.medium,design:.serif))
                    Text("随便看看。遇到想读的，再停下来。").font(.system(size:14)).foregroundColor(Palette.muted)
                }
                if let item = store.latestReadingToResume {
                    HStack(spacing: 14) {
                        Image(systemName: "bookmark").foregroundColor(Palette.green)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.title).lineLimit(1).font(.system(size: 14, weight: .medium))
                            Text(item.pdfReading?.cursor.map { "上次停在 PDF 第 \($0.location.page + 1) 页" } ?? "上次的阅读位置")
                                .font(.system(size: 12)).foregroundColor(Palette.muted)
                            if let thought = item.resumeThought {
                                Text(thought).lineLimit(1).font(.system(size: 12)).foregroundColor(Palette.muted)
                                    .accessibilityLabel("上次记下的想法：\(thought)")
                            }
                        }
                        Spacer()
                        Button("接着读") { store.openInReader(item) }.buttonStyle(ActionStyle())
                    }.padding(12).background(Palette.side.opacity(0.7)).cornerRadius(10)
                }
                HStack(spacing:20) {
                    HStack(spacing:6) { Image(systemName:"sun.haze").foregroundColor(Palette.muted); Picker("此刻的状态",selection:Binding(get:{store.library.preferences.energy},set:{ v in store.updatePreferences({$0.energy=v},redraw:true) })) { ForEach(Energy.allCases,id:\.self) { Text($0.title).tag($0) } }.labelsHidden().frame(width:140) }
                    Rectangle().fill(Palette.line).frame(width:1,height:20)
                    HStack { Text("先留").font(.system(size:12)).foregroundColor(Palette.muted); Picker("这次想停留多久",selection:Binding(get:{store.library.preferences.slice},set:{v in store.updatePreferences({$0.slice=v},redraw:true)})) { ForEach([5,15,30],id:\.self) { Text("\($0) 分钟").tag($0) } }.labelsHidden().frame(width:100) }
                    Spacer()
                    Text("随时可以改变主意").font(.system(size:11)).foregroundColor(Palette.muted)
                }
                HStack(spacing:8) {
                    Picker("推荐策略",selection:Binding(get:{store.library.preferences.strategy.id},set:{store.selectStrategy($0)})) {ForEach(store.library.preferences.allStrategies) {Text($0.name).tag($0.id)}}.frame(width:205)
                    if !store.library.preferences.strategy.scopeTag.isEmpty {Text("范围："+store.library.preferences.strategy.scopeTag).font(.system(size:11)).foregroundColor(Palette.muted)}
                    Spacer(); Button("调整策略与范围") {store.page="策略"}.buttonStyle(.plain).font(.system(size:11)).foregroundColor(Palette.green)
                }
                if let first = store.recommendations.first {
                    hero(first)
                    if store.recommendations.count > 1 {
                        Text("也许，你想往另一个方向走").font(.system(size:12)).foregroundColor(Palette.muted)
                        VStack(spacing:0) { ForEach(Array(store.recommendations.dropFirst())) { r in alternative(r); if r.id != store.recommendations.last?.id { Divider().overlay(Palette.line.opacity(0.5)) } } }
                    }
                    HStack {
                        Text("随手换一批。跳过不代表不喜欢。").font(.system(size:11)).foregroundColor(Palette.muted)
                        Spacer()
                    }
                } else { emptyDiscovery }
                if store.unavailableCount > 0 {
                    Text("已略过 \(store.unavailableCount) 个暂时打不开的入口，收藏里仍可检查和修复。")
                        .font(.system(size: 12)).foregroundColor(Palette.muted)
                }
            }
        }
        .background(alignment: .topLeading) {
            if store.activeSession == nil, let first = store.recommendations.first {
                DiscoveryPreviewKey {
                    guard store.page == "发现", store.inspection == nil, store.readerOpening == nil else { return false }
                    store.inspectCandidate(store.recommendations.first(where: { $0.id == previewFocus })?.item ?? first.item)
                    return store.inspection != nil
                }.frame(width: 0, height: 0).accessibilityHidden(true)
            }
        }
    }
    func hero(_ r: Recommendation) -> some View {
        VStack(alignment:.leading,spacing:16) {
            HStack { Text(r.item.primaryTag).font(.system(size:11,weight:.medium)).padding(.horizontal,10).padding(.vertical,5).background(Palette.surface.opacity(0.6)).clipShape(Capsule()); Spacer(); Button("优先级 "+String(format:"%.1f",PriorityEngine.explain(r.item,preferences:store.library.preferences).score)) {metricItem=r.item}.buttonStyle(.plain).font(.system(size:11)).foregroundColor(Palette.green); Text(r.item.isDemo ? "示例入口" : "一次偶遇").font(.system(size:11)).foregroundColor(Palette.muted); Image(systemName:"arrow.up.right").font(.system(size:15)) }
            HStack(alignment:.top,spacing:25) {
                VStack(alignment:.leading,spacing:14) {
                    Text(r.item.title).font(.system(size:29,weight:.medium,design:.serif)).lineSpacing(5).fixedSize(horizontal:false,vertical:true)
                    Text(r.item.note.isEmpty ? "收藏时留住的好奇，现在还想往下看看吗？" : r.item.note).font(.system(size:13)).foregroundColor(Palette.muted).lineSpacing(5).lineLimit(3)
                }.frame(maxWidth:.infinity,alignment:.leading)
                OrbitMark(size:72).padding(12).opacity(0.45)
            }
            HStack(spacing:8) { Text(r.item.source); Text("·"); Text(r.item.minutes > store.library.preferences.slice ? "长文也可以只读 \(store.library.preferences.slice) 分钟" : "约 \(r.item.minutes) 分钟"); if !r.item.bookmark.isEmpty { Text("· 有上次的位置") } }.font(.system(size:11)).foregroundColor(Palette.muted)
            HStack {
                Button { store.choose(r.item) } label:{ Label("就读这个",systemImage:"arrow.up.right") }.buttonStyle(ActionStyle(primary:true))
                Button("先看看") { store.inspectCandidate(r.item) }
                    .buttonStyle(.borderless).focused($previewFocus, equals: r.id).help("预览候选 · 空格")
                if r.item.canSendToResearch || r.item.zotero?.pdfKey != nil, let mark = r.item.pdfReading?.marks.last(where: { !$0.quote.isEmpty && $0.kind == .annotation }) {
                    Button("读上次划线") {
                        if r.item.zotero?.pdfKey != nil { store.openZoteroPDF(r.item, markID: mark.id) }
                        else { store.openPDF(r.item, markID: mark.id) }
                    }
                        .buttonStyle(.plain).font(.system(size:12)).padding(.leading,8)
                }
                Button("先放一放") { store.snooze(r.id) }.buttonStyle(.plain).font(.system(size:12)).padding(.leading,10)
                Spacer()
                Image(systemName:"sparkle").font(.system(size:11)); Text(r.reason).font(.system(size:11))
            }.foregroundColor(Palette.green)
        }.padding(24).background(Palette.card).clipShape(RoundedRectangle(cornerRadius:18))
    }
    func alternative(_ r: Recommendation) -> some View {
        HStack(spacing:18) {
            Image(systemName:r.item.target.hasPrefix("obsidian:") ? "link" : "text.alignleft").font(.system(size:20,weight:.light)).foregroundColor(Palette.green).frame(width:42,height:48).background(Palette.side.opacity(0.65)).cornerRadius(8)
            VStack(alignment:.leading,spacing:7) { Text(r.item.title).font(.system(size:15,weight:.medium)).lineLimit(2); Text("\(r.item.primaryTag)  ·  \(r.item.source)  ·  约 \(r.item.minutes) 分钟").font(.system(size:11)).foregroundColor(Palette.muted) }
            Spacer(minLength:12)
            Button("先看看") { store.inspectCandidate(r.item) }
                .font(.system(size: 12)).buttonStyle(.borderless).focused($previewFocus, equals: r.id)
                .accessibilityLabel("先看看 \(r.item.title)")
            Button { store.choose(r.item) } label:{ Image(systemName:"arrow.up.right").frame(width:42,height:42) }.buttonStyle(.plain).help("就读这个：\(r.item.title)").accessibilityLabel("打开 \(r.item.title)")
            Menu { Button("先放一放") { store.snooze(r.id) }; Button("指标与优先级") {metricItem=r.item}; Button("编辑") { editItem = r.item }; Button("放入归档") { store.archive(r.id) } } label:{ Image(systemName:"ellipsis") }.menuStyle(.borderlessButton).frame(width:24).accessibilityLabel("更多操作：\(r.item.title)")
        }.padding(.vertical,14)
    }
    var emptyDiscovery: some View {
        VStack(alignment:.leading,spacing:20) {
            OrbitMark(size:60).padding(.bottom,12)
            Text(store.library.items.isEmpty ? "把想读的，先放在这里。" : "这一轮，先逛到这里。").font(.system(size:27,weight:.medium,design:.serif))
            Text(store.library.items.isEmpty ? "网址、PDF、Obsidian 笔记都可以。\n不必整理成计划，等下一次好奇来找你。" : "没有必须完成的数量。可以重新偶遇，\n也可以带着刚才的发现离开。").font(.system(size:14)).foregroundColor(Palette.muted).lineSpacing(6)
            HStack(spacing:12) {
                if store.library.items.isEmpty { Button("收下第一篇") { adding = true }.buttonStyle(ActionStyle(primary:true)); Button("用示例逛一逛",action:store.loadDemo).buttonStyle(ActionStyle()) }
                else if store.hasUnseenCandidates { Button("继续漫游") { store.refresh() }.buttonStyle(ActionStyle(primary:true)) }
                else if store.eligibleCount > 0 { Button("重新偶遇") { store.refresh(restart:true) }.buttonStyle(ActionStyle(primary:true)) }
                else if store.unavailableCount > 0 { Button("重新检查入口") { store.refresh(restart: true) }.buttonStyle(ActionStyle(primary:true)) }
                else { Button("去收藏里看看") { store.page = "收藏" }.buttonStyle(ActionStyle()) }
            }
        }.frame(maxWidth:.infinity,alignment:.leading).padding(36).frame(minHeight:350).background(Palette.surface.opacity(0.5)).cornerRadius(16)
    }
    var activeVisit: some View {
        VStack(alignment:.leading,spacing:26) {
            Text("这次，是你自己选的").font(.system(size:12)).foregroundColor(Palette.green)
            Text("在这里，多停留一会儿。").font(.system(size:34,weight:.medium,design:.serif))
            if let item = store.activeItem, let session = store.activeSession {
                VStack(alignment:.leading,spacing:22) {
                    Text(item.primaryTag).font(.system(size:12)).foregroundColor(Palette.green)
                    Text(item.title).font(.system(size:28,weight:.medium,design:.serif)).fixedSize(horizontal:false,vertical:true)
                    if !item.bookmark.isEmpty { Label("上次停在：\(item.bookmark)",systemImage:"bookmark").font(.system(size:14)) }
                    Text(session.inReader == true ? "这一篇还留在上次的位置，随时可以接着读。" : "原文已经在你的阅读工具中打开。\n读一点也可以，想换方向时就回来。").font(.system(size:14)).foregroundColor(Palette.muted).lineSpacing(6)
                    TimelineView(.periodic(from:.now,by:1)) { context in
                        Text(session.runningSince == nil ? "停留记录已暂停" : "本次停留  \(Int(session.elapsed(at:context.date)/60)) 分钟").font(.system(size:13)).foregroundColor(Palette.green)
                    }
                    HStack {
                        if item.canReadInside {
                            Button("在漫读里接着读") { store.openInReader(item) }.buttonStyle(ActionStyle(primary:true))
                        }
                        Button("读到这里，收个尾") { finishing = true }.buttonStyle(ActionStyle(primary:true))
                        Button(session.runningSince == nil ? "继续记录停留" : "暂停记录",action:store.pauseResume).buttonStyle(ActionStyle())
                        Button("回到原文") { openAgain(item) }.buttonStyle(.plain).font(.system(size:12))
                    }
                    HStack {if item.canSendToResearch {Button("交给研贴摘录") {store.sendToResearch(item)}.buttonStyle(ActionStyle())}; if item.researchNoteURL != nil {Button("查看已存摘录") {store.openResearchNote(item)}.buttonStyle(ActionStyle()); Button("在 Obsidian 复习") {store.openResearchNote(item,review:true)}.buttonStyle(.plain).font(.system(size:12))}}
                }.padding(32).frame(maxWidth:.infinity,alignment:.leading).background(Palette.card).cornerRadius(18)
                Text("停留按打开后的经过时间记录，可随时暂停；不监测你是否正在阅读。退出应用会暂停，重新打开后由你继续。").font(.system(size:12)).foregroundColor(Palette.muted).lineSpacing(5)
            }
        }
    }
    func openAgain(_ item: ReadingItem) { store.openExternal(item) }

    var filteredItems: [ReadingItem] {
        store.library.items.filter { i in
            let resting = i.snoozedUntil.map { $0 > Date() } ?? false
            let match = filter == "全部" || (filter == "可遇见" && i.state != .archived && !resting) || (filter == "休息中" && i.state != .archived && resting) || (filter == "已归档" && i.state == .archived)
            return i.trashedAt == nil && match && (search.isEmpty || (i.title + i.note + i.tags.joined(separator:" ")).localizedCaseInsensitiveContains(search))
        }.sorted { $0.createdAt > $1.createdAt }
    }
    var collection: some View {
        VStack(alignment:.leading,spacing:24) {
            Text("把好奇留下来。").font(.system(size:32,weight:.medium,design:.serif))
            Text("这里是可以回来找的地方，不是一份待办清单。").font(.system(size:14)).foregroundColor(Palette.muted)
            HStack {Button("批量管理") {managing=true}.buttonStyle(ActionStyle()); Picker("收藏状态",selection:$filter) { ForEach(["全部","可遇见","休息中","已归档"],id:\.self) { Text($0).tag($0) } }.pickerStyle(.segmented).frame(maxWidth:370); Spacer(); TextField("搜索标题、主题",text:$search).textFieldStyle(.roundedBorder).frame(width:210) }
            if store.importing { ProgressView("正在收录笔记位置…") }
            if filteredItems.isEmpty { Text(search.isEmpty ? "这里还没有内容。用右上角的“收下一篇”开始。" : "没有找到相关内容。").foregroundColor(Palette.muted).padding(.vertical,40) }
            LazyVStack(spacing:0) { ForEach(filteredItems) { item in
                HStack(alignment:.center,spacing:16) {
                    VStack(alignment:.leading,spacing:8) {
                        Text(item.title).font(.system(size:16,weight:.medium)).fixedSize(horizontal:false,vertical:true)
                        Text("\(item.primaryTag)  ·  \(item.source)  ·  \(item.state == .archived ? "已归档" : (item.snoozedUntil ?? .distantPast) > Date() ? "休息中" : "可遇见")\(item.isDemo ? "  ·  示例" : "")").font(.system(size:11)).foregroundColor(Palette.muted)
                        if !item.bookmark.isEmpty { Text("停在：\(item.bookmark)").font(.system(size:12)).foregroundColor(Palette.muted) }
                    }; Spacer()
                    Button("打开") { store.choose(item) }.buttonStyle(ActionStyle())
                    Menu { if item.canReadInside {Button("用原应用打开") {store.choose(item, external: true)}}; if item.canSendToResearch {Button("交给研贴摘录") {store.sendToResearch(item)}}; if item.researchNoteURL != nil {Button("查看已存摘录") {store.openResearchNote(item)}; Button("在 Obsidian 复习") {store.openResearchNote(item,review:true)}}; Button("指标与优先级") {metricItem=item}; Button("编辑资料") { editItem = item }; if item.state == .archived || (item.snoozedUntil ?? .distantPast) > Date() { Button("放回可遇见") { store.restore(item.id) } }; if item.state != .archived { Button("先放一放") { store.snooze(item.id) }; Button("放入归档") { store.archive(item.id) } } } label: { Image(systemName:"ellipsis").frame(width:24,height:36) }.menuStyle(.borderlessButton).frame(width:30).accessibilityLabel("管理 \(item.title)")
                }.padding(.vertical,20)
                Divider().overlay(Palette.line.opacity(0.5))
            } }
        }
    }
    var history: some View {
        VStack(alignment:.leading,spacing:22) {
            Text("你曾在这里停留。").font(.system(size:32,weight:.medium,design:.serif))
            Text("只记下主动选择过的内容。没有目标，也没有欠下的进度。").font(.system(size:14)).foregroundColor(Palette.muted)
            if store.library.sessions.isEmpty { Text("遇到想读的那一篇，足迹就从那里开始。").foregroundColor(Palette.muted).padding(.vertical,60) }
            LazyVStack(alignment:.leading,spacing:0) { ForEach(store.library.sessions.reversed()) { s in
                HStack(alignment:.top,spacing:24) {
                    Text(s.startedAt,format:.dateTime.month().day()).font(.system(size:12)).foregroundColor(Palette.muted).frame(width:55,alignment:.leading)
                    VStack(alignment:.leading,spacing:8) { Text(s.title).font(.system(size:16,weight:.medium)); Text(s.outcome ?? "还在这一段里").font(.system(size:12)).foregroundColor(Palette.muted) }; Spacer()
                    Text(s.stoppedAt == nil ? "进行中" : s.seconds < 60 ? "停留不足 1 分钟" : "停留 \(Int(s.seconds/60)) 分钟").font(.system(size:12)).foregroundColor(Palette.muted)
                }.padding(.vertical,22); Divider()
            } }
            Text("停留时长来自经过时间，仅供回看，不能代表实际阅读时长。").font(.system(size:11)).foregroundColor(Palette.muted)
        }
    }
    var preferences: some View {
        VStack(alignment:.leading,spacing:26) {
            Text("留一点余地。").font(.system(size:32,weight:.medium,design:.serif))
            Text("让推荐贴近此刻，也保留走向陌生内容的机会。").font(.system(size:14)).foregroundColor(Palette.muted)
            ThemeChooser(store:store)
            GlanceSettings(store: store).padding(24).background(Palette.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment:.leading,spacing:16) {
                HStack { Text("探索的份量").font(.system(size:16,weight:.medium)); Spacer(); Text("\(Int(store.library.preferences.exploration*100))%").monospacedDigit().foregroundColor(Palette.green) }
                Slider(value:Binding(get:{store.library.preferences.exploration},set:{v in store.updatePreferences { $0.exploration = v }}),in:0...1,step:0.05).tint(Palette.green).accessibilityLabel("随机探索比例")
                HStack { Text("顺着兴趣走"); Spacer(); Text("多些意料之外") }.font(.system(size:12)).foregroundColor(Palette.muted)
                Text("探索时减少兴趣权重，让不熟悉的内容也有机会出现。每一轮不重复，换一批不会降低兴趣。精力与时间只是推荐参考，长文仍可以被选中。").font(.system(size:13)).foregroundColor(Palette.muted).lineSpacing(5).fixedSize(horizontal:false,vertical:true)
            }.padding(24).background(Palette.surface.opacity(0.55)).cornerRadius(14)
            VStack(alignment:.leading,spacing:14) {
                Text("把现有的阅读工具接进来").font(.system(size:17,weight:.medium))
                Text("PDF、Markdown、纯文本、HTML 和 RTF 可以直接读。也可从收藏用原应用打开。").font(.system(size:13)).foregroundColor(Palette.muted).lineSpacing(5).fixedSize(horizontal:false,vertical:true)
                HStack { Button("收录本地文件…",action:store.pickFiles).buttonStyle(ActionStyle()); Button("收录 Obsidian 仓库…",action:store.importObsidian).buttonStyle(ActionStyle()).disabled(store.importing); Button("从 Zotero 收录…") { zoteroImport = true }.buttonStyle(ActionStyle()) }
                Button("Obsidian 收件与模板…") { notebookSetup = true }.buttonStyle(ActionStyle())
                Button("复制浏览器收藏脚本") {
                    let script = "javascript:(()=>{location.href='wanderread://add?url='+encodeURIComponent(location.href)+'&title='+encodeURIComponent(document.title)})()"
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(script,forType:.string); store.message = "已复制。新建浏览器书签，把脚本粘到网址栏；浏览网页时点这个书签即可收下。"
                }.buttonStyle(.plain).font(.system(size:12)).foregroundColor(Palette.green)
                Text("Obsidian 请选择仓库根目录；笔记新增后可再次收录，会自动跳过重复位置。移动或改名的笔记需更新入口。").font(.system(size:11)).foregroundColor(Palette.muted)
            }
            Divider()
            VStack(alignment:.leading,spacing:14) {
                Text("资料由你保管").font(.system(size:17,weight:.medium))
                Button("管理导入与回收站…") {managing=true}.buttonStyle(ActionStyle())
                Text("导错的内容可按批次或逐篇移入回收站，随时恢复；不会删除原文件或 Obsidian 笔记。").font(.system(size:12)).foregroundColor(Palette.muted)
                HStack { Button("导出备份…",action:store.exportBackup).buttonStyle(ActionStyle()); Button("从备份恢复…",action:store.importBackup).buttonStyle(ActionStyle()); Button("查看资料文件") { NSWorkspace.shared.activateFileViewerSelecting([store.dataURL]) }.buttonStyle(.plain).font(.system(size:12)) }
                Text("离线可用，无账号。收藏和偏好保存在 ~/Library/Application Support/WanderRead/library.json，每次保存保留上一版 .bak。").font(.system(size:11)).foregroundColor(Palette.muted).textSelection(.enabled).lineSpacing(5)
                HStack { Button("加入示例入口",action:store.loadDemo).buttonStyle(.plain); if store.library.items.contains(where:{$0.isDemo}) { Button("移除示例及其足迹",action:store.removeDemo).buttonStyle(.plain).disabled(store.activeItem?.isDemo == true) } }.font(.system(size:12)).foregroundColor(Palette.green)
            }
            Text("漫读 0.9.0  ·  从收藏接上原文与想法。").font(.system(size:11)).foregroundColor(Palette.muted)
        }
    }
    func drop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier:UTType.fileURL.identifier,options:nil) { item,_ in
                    let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation:$0,relativeTo:nil) }
                    if let url = url { DispatchQueue.main.async { store.importFiles([url]) } }
                }
            } else { provider.loadItem(forTypeIdentifier:UTType.url.identifier,options:nil) { item,_ in
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation:$0,relativeTo:nil) }
                if let url = url { DispatchQueue.main.async { _ = store.add(title:url.host ?? url.absoluteString,target:url.absoluteString,note:"",tags:"",minutes:15,difficulty:2,interest:3) } }
            } }
        }
        return true
    }
}

struct ItemForm: View {
    @ObservedObject var store: ReadingStore
    var item: ReadingItem?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var target = ""
    @State private var note = ""
    @State private var tags = ""
    @State private var minutes = 15
    @State private var difficulty = 2
    @State private var interest = 3.0
    @State private var validation = ""
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            Text(item == nil ? "先收下，等好奇回来。" : "留下更合适的入口。").font(.system(size:25,weight:.medium,design:.serif))
            Text("只需标题和入口，其他都可以以后再说。").font(.system(size:13)).foregroundColor(Palette.muted)
            VStack(alignment:.leading,spacing:7) { Text("标题"); TextField("下次看到时，能认出它",text:$title).textFieldStyle(.roundedBorder) }
            VStack(alignment:.leading,spacing:7) { Text("网址、文件路径或应用链接"); TextField("https://… 或 obsidian://open?…",text:$target).textFieldStyle(.roundedBorder); Button("选择本地文件…") { let p=NSOpenPanel(); if p.runModal() == .OK, let u=p.url { target=u.path; if title.isEmpty { title=u.deletingPathExtension().lastPathComponent } } }.buttonStyle(.plain).font(.system(size:12)).foregroundColor(Palette.green).padding(.top,4) }
            VStack(alignment:.leading,spacing:7) { Text("为什么想读（可选）"); TextField("给未来的自己留一点好奇",text:$note).textFieldStyle(.roundedBorder) }
            VStack(alignment:.leading,spacing:7) { Text("主题（可选，用逗号分隔）"); TextField("哲学，生活，偶然发现",text:$tags).textFieldStyle(.roundedBorder) }
            HStack(spacing:24) { Stepper("大约 \(minutes) 分钟",value:$minutes,in:1...600,step:5).frame(width:180); Picker("深浅",selection:$difficulty) { Text("轻松").tag(1); Text("适中").tag(2); Text("烧脑").tag(3) }.frame(width:210) }
            HStack { Text("此刻的兴趣"); Slider(value:$interest,in:1...5,step:1).tint(Palette.green); Text("\(Int(interest))/5").monospacedDigit() }
            if !validation.isEmpty { Text(validation).font(.system(size:12)).foregroundColor(.red) }
            HStack { Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(ActionStyle()); Spacer(); if item == nil { Button("从剪贴板粘贴链接") { if let s=NSPasteboard.general.string(forType:.string) { target=s; if title.isEmpty { title=URL(string:s)?.host ?? "" } } }.buttonStyle(.plain).font(.system(size:12)).foregroundColor(Palette.green) }; Button("收下") {
                if store.add(title:title,target:target,note:note,tags:tags,minutes:minutes,difficulty:difficulty,interest:interest,editing:item?.id) { dismiss() } else { validation=store.error ?? "未能保存"; store.error=nil }
            }.keyboardShortcut(.defaultAction).buttonStyle(ActionStyle(primary:true)) }
        }.font(.system(size:13)).padding(32).frame(width:540).background(Palette.paper).foregroundColor(Palette.ink).onAppear {
            if let i=item { title=i.title; target=i.target; note=i.note; tags=i.tags.joined(separator:"，"); minutes=i.minutes; difficulty=i.difficulty; interest=i.interest }
        }
    }
}
struct FinishView: View {
    @ObservedObject var store: ReadingStore
    @Environment(\.dismiss) private var dismiss
    @State private var outcome = "想接着读"
    @State private var bookmark = ""
    @State private var usefulness="未反馈"
    @State private var reflection=""
    var body: some View {
        VStack(alignment:.leading,spacing:24) {
            Text("这一段，感觉怎么样？").font(.system(size:27,weight:.medium,design:.serif))
            Text("读了多少都可以。你决定下次要不要再遇见。").foregroundColor(Palette.muted)
            ForEach(["想接着读","暂时放一放","读到这里就够了"],id:\.self) { option in
                Button { outcome=option } label:{ HStack { Image(systemName:outcome == option ? "largecircle.fill.circle" : "circle"); VStack(alignment:.leading,spacing:5) { Text(option).font(.system(size:15,weight:.medium)); Text(option == "想接着读" ? "保留好奇，2 小时后可以再遇见" : option == "暂时放一放" ? "休息 18 小时，不降低你的兴趣" : "放入归档，随时可以找回来").font(.system(size:12)).foregroundColor(Palette.muted) }; Spacer() }.padding(14).background(outcome == option ? Palette.card : Palette.surface.opacity(0.5)).cornerRadius(10) }.buttonStyle(.plain)
            }
            VStack(alignment:.leading,spacing:8) { Text("停在哪里（可选）"); TextField("例如：第 23 页 / 第二节",text:$bookmark).textFieldStyle(.roundedBorder) }
            HStack {Text("这次帮上忙了吗（可选）"); Picker("反馈",selection:$usefulness) {ForEach(["未反馈","有帮助","还说不准","不合适"],id:\.self) {Text($0).tag($0)}}.labelsHidden()}
            VStack(alignment:.leading,spacing:8) {Text("留一句自己的想法（可选）"); TextField("有一点收获，或者一个新的问题",text:$reflection).textFieldStyle(.roundedBorder)}
            HStack { Button("再读一会儿") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(ActionStyle()); Spacer(); Button("就到这里") { store.finish(outcome:outcome,bookmark:bookmark,usefulness:usefulness == "未反馈" ? nil:usefulness,reflection:reflection); if store.activeSession == nil { dismiss() } }.buttonStyle(ActionStyle(primary:true)).keyboardShortcut(.defaultAction) }
        }.font(.system(size:13)).padding(32).frame(width:500).background(Palette.paper).foregroundColor(Palette.ink).onAppear { bookmark=store.activeItem?.bookmark ?? "" }
    }
}
