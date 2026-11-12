import SwiftUI
import AppKit
import UniformTypeIdentifiers
struct ProfileEditor:View {
    @ObservedObject var store:ReadingStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft=ShareProfile()
    @State private var failure=""
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            Text("你的阅读名片").font(.system(size:26,weight:.medium,design:.serif))
            Text("保存在本机，只有打开“显示个人名片”时才出现在分享图里。").font(.system(size:12)).foregroundColor(Palette.muted)
            HStack(spacing:18) {if let data=draft.avatar,let image=NSImage(data:data) {Image(nsImage:image).resizable().scaledToFill().frame(width:72,height:72).clipShape(Circle())} else {Image(systemName:"person.crop.circle").font(.system(size:55)).foregroundColor(Palette.muted)};Button("选择头像…",action:avatar).buttonStyle(ActionStyle());Button("移除头像") {draft.avatar=nil}.buttonStyle(.plain)}
            Text("昵称 · 最多 32 字").font(.system(size:12));TextField("你希望如何署名",text:$draft.nickname).textFieldStyle(.roundedBorder)
            Text("简介 · 最多 100 字").font(.system(size:12));TextEditor(text:$draft.bio).frame(height:90)
            Toggle("在分享图中显示个人名片",isOn:$draft.visible).toggleStyle(.checkbox)
            if !failure.isEmpty {Text(failure).foregroundColor(.red).font(.system(size:12))}
            HStack {Button("取消") {dismiss()}.buttonStyle(ActionStyle());Spacer();Button("保存名片") {if store.saveProfile(draft) {dismiss()} else {failure=store.error ?? "未能保存"}}.buttonStyle(ActionStyle(primary:true))}
        }.padding(28).frame(width:580).background(Palette.paper).foregroundColor(Palette.ink).onAppear {draft=store.library.preferences.shareProfile ?? ShareProfile()}
    }
    func avatar() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[.png,.jpeg,.heic];guard panel.runModal() == .OK,let url=panel.url else{return}
        do {
            let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
            guard size<=15_000_000,let image=NSImage(contentsOf:url),image.size.width>0,image.size.height>0 else {throw InputError.invalid("请选一张小于 15 MB 的有效图片。")}
            let output=NSImage(size:NSSize(width:256,height:256));output.lockFocus()
            let edge=min(image.size.width,image.size.height)
            image.draw(in:NSRect(x:0,y:0,width:256,height:256),from:NSRect(x:(image.size.width-edge)/2,y:(image.size.height-edge)/2,width:edge,height:edge),operation:.copy,fraction:1)
            output.unlockFocus();guard let tiff=output.tiffRepresentation,let rep=NSBitmapImageRep(data:tiff),let png=rep.representation(using:.png,properties:[:]) else {throw InputError.invalid("头像未能生成。")};draft.avatar=png;failure=""
        } catch {failure=error.localizedDescription}
    }
}
