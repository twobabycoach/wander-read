import SwiftUI
import AppKit
struct LinkRepairView:View {
    @ObservedObject var store:ReadingStore
    @Environment(\.dismiss) private var dismiss
    @State private var plans:[LinkRepair]=[]
    @State private var location="尚未选择仓库"
    @State private var failure=""
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Text("把笔记入口接回来").font(.system(size:25,weight:.medium,design:.serif))
            Text("选择真正的 Obsidian 仓库。只修复能够唯一定位到现有文件的入口，保留评分、阅读历史和收藏身份；原笔记不变。").font(.system(size:13)).foregroundColor(Palette.muted)
            Button("选择仓库，预览修复…",action:choose).buttonStyle(ActionStyle())
            Text(location).font(.system(size:11)).foregroundColor(Palette.muted).lineLimit(2)
            ScrollView {VStack(alignment:.leading,spacing:14) {ForEach(plans) {p in VStack(alignment:.leading,spacing:5) {Text(store.library.items.first(where:{$0.id==p.id})?.title ?? "笔记");Text((URLComponents(string:p.after)?.queryItems?.first(where:{$0.name=="path"})?.value) ?? p.after).font(.system(size:11)).foregroundColor(Palette.muted)}}}}.frame(height:240)
            Text(failure.isEmpty ? "可修复 \(plans.count) 个。未定位、路径冲突和已有绝对路径的入口保持原样。" : failure).font(.system(size:12)).foregroundColor(Palette.muted)
            HStack {Button("取消") {dismiss()}.buttonStyle(ActionStyle());Spacer();Button("修复这 \(plans.count) 个入口") {store.applyRepairs(plans);dismiss()}.buttonStyle(ActionStyle(primary:true)).disabled(plans.isEmpty)}
        }.padding(28).frame(width:720).background(Palette.paper).foregroundColor(Palette.ink)
    }
    func choose() {
        let p=NSOpenPanel();p.canChooseFiles=false;p.canChooseDirectories=true;p.message="选择包含这些笔记的 Obsidian 仓库，或其内部文件夹。"
        guard p.runModal() == .OK,let url=p.url else{return}
        do {let root=try ObsidianLinks.root(containing:url);location=root.path;plans=store.repairPreview(root:root);failure=""} catch {failure=error.localizedDescription}
    }
}
