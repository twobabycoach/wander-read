import Foundation
extension ReadingStore {
    @discardableResult func trashItems(_ ids:Set<UUID>)->Bool {
        guard !ids.isEmpty else{return false}
        guard activeItem.map({!ids.contains($0.id)}) ?? true else {error="请先为正在阅读的材料收尾，再移入回收站。";return false}
        let saved=commit {l in for i in l.items.indices where ids.contains(l.items[i].id) {l.items[i].trashedAt=Date()}}
        if saved {fillQueueIfNeeded();message="已移入回收站，可随时恢复。原文件保持不变。"};return saved
    }
    @discardableResult func restoreTrash(_ ids:Set<UUID>)->Bool {
        let saved=commit {l in for i in l.items.indices where ids.contains(l.items[i].id) {l.items[i].trashedAt=nil}}
        if saved {fillQueueIfNeeded();message="已恢复收藏和原有阅读记录。"};return saved
    }
    @discardableResult func purgeTrash(_ ids:Set<UUID>)->Bool {
        let doomed=Set(library.items.filter {$0.trashedAt != nil && ids.contains($0.id)}.map(\.id))
        guard !doomed.isEmpty else{return false}
        do {
            let folder=dataURL.deletingLastPathComponent().appendingPathComponent("cleanup-backups")
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            try LibraryIO.encode(library).write(to:folder.appendingPathComponent("before-cleanup-\(UUID().uuidString).json"),options:.atomic)
        } catch {self.error="清理前备份未能保存，已停止清理。";return false}
        let saved=commit {l in
            l.items.removeAll {doomed.contains($0.id)};l.sessions.removeAll {doomed.contains($0.itemID)}
            l.exposures?.removeAll {doomed.contains($0.itemID)};l.researchEvents?.removeAll {doomed.contains($0.itemID)};l.alignmentUndo?.removeAll {doomed.contains($0.itemID)};l.linkRepairUndo?.removeAll {doomed.contains($0.id)}
        }
        if saved {fillQueueIfNeeded();message="已清理所选回收站记录，清理前完整备份已保留。原文件没有删除。"};return saved
    }
}
