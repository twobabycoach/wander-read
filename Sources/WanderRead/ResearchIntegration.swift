import Foundation
import AppKit

struct ResearchSavedEvent:Codable,Identifiable {
    var id:String
    var itemID:UUID
    var date:Date
    var noteURL:String
}
extension ReadingStore {
    func sendToResearch(_ item:ReadingItem) {
        do {
            let pdf=item.target.hasPrefix("/") ? URL(fileURLWithPath:item.target) : URL(string:item.target)
            guard let pdf=pdf,pdf.isFileURL else {throw InputError.invalid("请先收录这篇文献的本地 PDF，再交给研贴。网页和 Obsidian 笔记仍用原来的应用打开。")}
            let link=try ResearchLink.enqueue(itemID:item.id,title:item.title,pdf:pdf)
            guard NSWorkspace.shared.open(link) else {throw InputError.invalid("没有找到支持通信的研贴。请运行随本版提供的研贴新版，再重试。")}
            message="请求已送出，等待研贴实际准备 PDF。"
        } catch {self.error=error.localizedDescription}
    }
    func pollResearchLink(root:URL=ResearchLink.root) {
        for (file,update) in ResearchLink.updates(root:root) {
            guard let id=UUID(uuidString:update.itemID),library.items.contains(where:{$0.id == id}) else {continue}
            if update.status == "saved",let note=update.noteURL,URL(string:note)?.scheme=="obsidian" {
                if (library.researchEvents ?? []).contains(where:{$0.id == update.id}) {try? FileManager.default.removeItem(at:file);continue}
                if commit({l in
                    if l.researchEvents == nil {l.researchEvents=[]}
                    l.researchEvents?.append(ResearchSavedEvent(id:update.id,itemID:id,date:update.created,noteURL:note))
                    if let i=l.items.firstIndex(where:{$0.id == id}) {l.items[i].researchNoteURL=note}
                }) {try? FileManager.default.removeItem(at:file);message="Obsidian 已确认保存摘录，可直接返回对应笔记。"}
            } else if update.status == "ready" {message="研贴已准备好这份 PDF。摘录仍由你选择，保存成功后再返回笔记入口。";try? FileManager.default.removeItem(at:file)}
            else if update.status == "error" {error="研贴未能准备 PDF："+(update.error ?? "请在研贴中检查来源。");try? FileManager.default.removeItem(at:file)}
        }
    }
    func openResearchNote(_ item:ReadingItem,review:Bool=false) {
        guard let raw=item.researchNoteURL,var components=URLComponents(string:raw) else {error="这篇材料还没有收到 Obsidian 的保存回执。";return}
        if review {components.host="pfr-review"}
        if let url=components.url,!NSWorkspace.shared.open(url) {error="未能打开 Obsidian，请先启用研贴接收与复习组件。"}
    }
}
