import SwiftUI
import AppKit
struct ThemeChooser:View {
    @ObservedObject var store:ReadingStore
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Text("换一种心情").font(.system(size:19,weight:.medium,design:.serif))
            Text("应用外观随时切换，全部可用；分享图配色另行选择。").font(.system(size:12)).foregroundColor(Palette.muted)
            HStack(spacing:12) {ForEach(AppTheme.allCases) {theme in
                Button {store.selectTheme(theme)} label:{VStack(alignment:.leading,spacing:9) {
                    HStack(spacing:4) {RoundedRectangle(cornerRadius:4).fill(theme.color(1)).frame(width:20);RoundedRectangle(cornerRadius:4).fill(theme.color(6))}.frame(height:38).padding(7).background(theme.color(0)).cornerRadius(8)
                    HStack {Text(theme.title).font(.system(size:13,weight:.medium));Spacer();if (store.library.preferences.appTheme ?? "paper")==theme.rawValue {Image(systemName:"checkmark.circle.fill").foregroundColor(Palette.green)}}
                    Text(theme.detail).font(.system(size:10)).foregroundColor(Palette.muted)
                }.padding(10).frame(maxWidth:.infinity).background(Palette.surface).cornerRadius(12)}.buttonStyle(.plain)
            }}
        }
    }
}
struct DataManager:View {
    @ObservedObject var store:ReadingStore
    @Environment(\.dismiss) private var dismiss
    @State private var repairing=false
    @State private var trash=false
    @State private var search=""
    @State private var selected=Set<UUID>()
    @State private var batch="全部"
    var batches:[String] {Array(Set(store.library.items.filter {$0.trashedAt == nil}.compactMap {i in i.importBatchID.map {_ in batchKey(i)}})).sorted()}
    func batchKey(_ item:ReadingItem)->String {(item.importBatchLabel ?? "导入")+" · "+item.createdAt.formatted(.dateTime.month().day().hour().minute())+" · "+String(item.importBatchID?.uuidString.prefix(6) ?? "")}
    var entries:[ReadingItem] {store.library.items.filter {i in (i.trashedAt != nil)==trash && (batch=="全部" || batchKey(i)==batch) && (search.isEmpty || (i.title+" "+i.target).localizedCaseInsensitiveContains(search))}.sorted {$0.createdAt>$1.createdAt}}
    var visibleIDs:Set<UUID> {Set(entries.map(\.id))}
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {Text("把收藏理一理").font(.system(size:26,weight:.medium,design:.serif));Spacer();Button("完成") {dismiss()}.buttonStyle(ActionStyle())}
            HStack {Button("修复 Obsidian 入口…") {repairing=true}.buttonStyle(.plain);if !(store.library.linkRepairUndo ?? []).isEmpty {Button("撤销链接修复",action:store.undoRepairs).buttonStyle(.plain)}}.font(.system(size:12)).foregroundColor(Palette.green)
            Text("这里只清理漫读中的入口。PDF、Obsidian 笔记和卡片不会被删除。").font(.system(size:12)).foregroundColor(Palette.muted)
            Picker("查看",selection:$trash) {Text("收藏").tag(false);Text("回收站").tag(true)}.pickerStyle(.segmented).onChange(of:trash) {_ in selected=[];batch="全部"}
            HStack {TextField("搜索标题或路径",text:$search).textFieldStyle(.roundedBorder);if !trash {Picker("导入批次",selection:$batch) {Text("全部").tag("全部");ForEach(batches,id:\.self) {Text($0).tag($0)}}.frame(width:300)}}
            HStack {
                Toggle("全选当前结果（\(entries.count) 篇）",isOn:Binding(get:{!visibleIDs.isEmpty && visibleIDs.isSubset(of:selected)},set:{if $0 {selected.formUnion(visibleIDs)} else {selected.subtract(visibleIDs)}})).toggleStyle(.checkbox)
                Button("全选全部") {search="";batch="全部";selected=Set(store.library.items.filter {($0.trashedAt != nil)==trash}.map(\.id))}.buttonStyle(ActionStyle())
                Button("取消全选") {selected=[]}.buttonStyle(.plain);Spacer();Text("已选 \(selected.intersection(visibleIDs).count) 篇").foregroundColor(Palette.muted)
            }.font(.system(size:12))
            ScrollView {LazyVStack(alignment:.leading,spacing:0) {ForEach(entries) {item in
                HStack {Toggle(isOn:Binding(get:{selected.contains(item.id)},set:{if $0 {selected.insert(item.id)} else {selected.remove(item.id)}})) {VStack(alignment:.leading,spacing:5) {Text(item.title).font(.system(size:14));Text(item.importBatchLabel ?? "已有收藏 · 可按标题或路径筛选").font(.system(size:11)).foregroundColor(Palette.muted);Text(item.target).font(.system(size:10)).foregroundColor(Palette.muted).lineLimit(1)}}.toggleStyle(.checkbox);Spacer()}.padding(.vertical,12);Divider()
            };if entries.isEmpty {Text("这里是空的。").foregroundColor(Palette.muted).padding(.vertical,40)}}}.frame(height:300)
            HStack {
                if trash {Button("恢复所选") {if store.restoreTrash(selected.intersection(visibleIDs)) {selected=[]}}.buttonStyle(ActionStyle(primary:true));Button("永久清理所选…") {confirmPurge()}.buttonStyle(ActionStyle())}
                else {Button("移入回收站") {if store.trashItems(selected.intersection(visibleIDs)) {selected=[]}}.buttonStyle(ActionStyle(primary:true))}
                Spacer()
            }.disabled(selected.intersection(visibleIDs).isEmpty)
            if let error=store.error {Text(error).font(.system(size:12)).foregroundColor(.red)}
            Text(trash ? "永久清理会移除相关阅读记录；先自动保留完整备份，已解锁里程保留。":"导入错了：选中对应批次，再选择当前结果并移入回收站。旧版导入没有批次，可按标题或路径筛选。").font(.system(size:11)).foregroundColor(Palette.muted).fixedSize(horizontal:false,vertical:true)
        }.padding(28).frame(width:820).background(Palette.paper).foregroundColor(Palette.ink).sheet(isPresented:$repairing) {LinkRepairView(store:store)}
    }
    func confirmPurge() {
        let ids=selected.intersection(visibleIDs)
        let alert=NSAlert();alert.messageText="永久清理这 \(ids.count) 篇记录？";alert.informativeText="将移除漫读中的入口及相关阅读记录。清理前保存完整备份；原文件、笔记和卡片不受影响。";alert.addButton(withTitle:"取消");alert.addButton(withTitle:"永久清理")
        if alert.runModal() == .alertSecondButtonReturn,store.purgeTrash(ids) {selected=[]}
    }
}
