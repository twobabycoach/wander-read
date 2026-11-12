import Foundation
import AppKit
struct LinkRepair:Codable,Identifiable {
    var id:UUID
    var before:String
    var after:String
}
struct RegisteredVault {
    var id:String
    var root:URL
}
enum ObsidianLinks {
    static func registeredVaults(at url:URL?=nil)->[RegisteredVault] {
        let file=url ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("obsidian/obsidian.json")
        guard let data=try? Data(contentsOf:file),let json=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let vaults=json["vaults"] as? [String:[String:Any]] else {return []}
        return vaults.compactMap {id,value in guard let path=value["path"] as? String,path.hasPrefix("/") else{return nil};return RegisteredVault(id:id,root:URL(fileURLWithPath:path))}
    }
    static func resolveLegacy(_ target:String,vaults:[RegisteredVault])->String? {
        guard let c=URLComponents(string:target),c.scheme=="obsidian",c.host=="open",let name=c.queryItems?.first(where:{$0.name=="vault"})?.value else{return nil}
        let explicit=vaults.filter {$0.id==name || $0.root.lastPathComponent==name}
        let roots=explicit.isEmpty ? vaults:explicit
        let matches=Set(roots.compactMap {repair(target,root:$0.root)})
        return matches.count==1 ? matches.first:nil
    }
    static func root(containing selected:URL) throws -> URL {
        var folder=selected.standardizedFileURL
        while folder.path != "/" {
            if FileManager.default.fileExists(atPath:folder.appendingPathComponent(".obsidian").path) {return folder}
            folder=folder.deletingLastPathComponent()
        }
        throw InputError.invalid("这里没有找到 Obsidian 仓库。请选择包含 .obsidian 的仓库，或它内部的文件夹。")
    }
    static func encode(_ value:String)->String {value.addingPercentEncoding(withAllowedCharacters:CharacterSet(charactersIn:"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))!}
    static func strict(_ input:URLComponents)->String {
        var c=input;c.percentEncodedQuery=(input.queryItems ?? []).map {encode($0.name)+"="+encode($0.value ?? "")}.joined(separator:"&")
        return c.url!.absoluteString
    }
    static func uri(file:URL)->String {
        var c=URLComponents();c.scheme="obsidian";c.host="open";c.queryItems=[URLQueryItem(name:"path",value:file.standardizedFileURL.path)]
        return strict(c)
    }
    static func checkedURL(_ target:String,vaults:[RegisteredVault]?=nil) throws -> URL {
        var resolved=target
        if let c=URLComponents(string:target),c.scheme=="obsidian",c.host=="open",c.queryItems?.contains(where:{$0.name=="path"}) != true,c.queryItems?.contains(where:{$0.name=="file"}) == true {
            guard let found=resolveLegacy(target,vaults:vaults ?? registeredVaults()) else {throw InputError.invalid("这条旧入口未能在已注册仓库中唯一定位。原笔记可能已移动或删除；请在“批量管理 → 修复 Obsidian 入口”检查位置。没有记作阅读选择。")}
            resolved=found
        }
        let url=resolved.hasPrefix("/") ? URL(fileURLWithPath:resolved):URL(string:resolved)
        guard let url=url else {throw InputError.invalid("这个入口无法解析，请编辑资料。")}
        if url.isFileURL,!FileManager.default.fileExists(atPath:url.path) {throw InputError.invalid("原文件已移动或不存在，请在收藏中更新路径。")}
        if let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "obsidian", c.host == "open",
           let pathItem = c.queryItems?.first(where: { $0.name == "path" }) {
            guard let path = pathItem.value, path.hasPrefix("/") else {
                throw InputError.invalid("Obsidian 入口缺少有效的文件路径，请编辑资料。")
            }
            let manager = FileManager.default
            let file = manager.fileExists(atPath: path) ? path : (path.components(separatedBy: "#").first ?? path)
            var directory: ObjCBool = false
            guard manager.fileExists(atPath: file, isDirectory: &directory), !directory.boolValue else {
                throw InputError.invalid("这篇笔记已移动或不存在，请更新入口。")
            }
        }
        return url
    }
    static func repair(_ target:String,root:URL)->String? {
        guard let c=URLComponents(string:target),c.scheme=="obsidian",c.host=="open",let q=c.queryItems else{return nil}
        if q.contains(where:{$0.name=="path"}) {return nil}
        guard let relative=q.first(where:{$0.name=="file"})?.value,!relative.hasPrefix("/"),!relative.split(separator:"/").contains("..") else{return nil}
        let parts=relative.split(separator:"#",maxSplits:1,omittingEmptySubsequences:false)
        guard let first = parts.first, !first.isEmpty else { return nil }
        let name=String(first);let suffix=parts.count>1 ? "#"+parts[1]:""
        let filename=name.lowercased().hasSuffix(".md") ? name:name+".md"
        let old=q.first(where:{$0.name=="vault"})?.value ?? ""
        var candidates=[root.appendingPathComponent(filename)]
        if !old.isEmpty,old != root.lastPathComponent,!old.contains("/"),old != ".." {candidates.append(root.appendingPathComponent(old).appendingPathComponent(filename))}
        let base=root.resolvingSymlinksInPath().path+"/"
        let matches=Set(candidates.filter {u in u.resolvingSymlinksInPath().path.hasPrefix(base) && FileManager.default.fileExists(atPath:u.path)}.map(\.standardizedFileURL))
        guard matches.count==1,let found=matches.first else{return nil}
        var output=URLComponents(string:uri(file:found))!
        output.queryItems=[URLQueryItem(name:"path",value:found.path+suffix)]+q.filter {!["vault","file","path"].contains($0.name)}
        return strict(output)
    }
}
extension ReadingStore {
    @discardableResult func autoRepairLegacyLinks(vaults:[RegisteredVault])->Int {
        guard library.registeredLinkMigration != 1,!recoveryRequired else{return 0}
        var keys=Set(library.items.map {Targets.key($0.target)})
        var plans:[LinkRepair]=[]
        for item in library.items where item.trashedAt==nil {
            guard let after=ObsidianLinks.resolveLegacy(item.target,vaults:vaults),after != item.target,!keys.contains(Targets.key(after)) else {continue}
            keys.insert(Targets.key(after));plans.append(LinkRepair(id:item.id,before:item.target,after:after))
        }
        guard !plans.isEmpty else{return 0}
        do {
            let folder=dataURL.deletingLastPathComponent().appendingPathComponent("link-repair-backups")
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let original=try Data(contentsOf:dataURL)
            try original.write(to:folder.appendingPathComponent("before-auto-repair-\(UUID().uuidString).json"),options:.atomic)
        } catch {self.error="旧入口修复前备份未能保存，已保留原资料。";return 0}
        let positions=Dictionary(uniqueKeysWithValues:library.items.enumerated().map {($0.element.id,$0.offset)})
        if commit({l in l.linkRepairUndo=plans;l.registeredLinkMigration=1;for plan in plans {if let i=positions[plan.id] {l.items[i].target=plan.after}}}) {message="已自动接回 \(plans.count) 个旧笔记入口，保留独立备份，可在批量管理中撤销。";return plans.count}
        return 0
    }
    func repairPreview(root:URL)->[LinkRepair] {
        library.items.filter {$0.trashedAt==nil}.compactMap {item in
            guard let target=ObsidianLinks.repair(item.target,root:root),target != item.target else{return nil}
            return LinkRepair(id:item.id,before:item.target,after:target)
        }
    }
    func applyRepairs(_ plans:[LinkRepair]) {
        var keys=Set(library.items.map {Targets.key($0.target)})
        let valid=plans.filter {plan in
            guard library.items.contains(where:{$0.id==plan.id && $0.target==plan.before}),!keys.contains(Targets.key(plan.after)) else{return false}
            keys.insert(Targets.key(plan.after));return true
        }
        guard !valid.isEmpty else {message="没有可修复的变化，原链接保持不变。";return}
        if commit({l in l.linkRepairUndo=valid;for plan in valid {if let i=l.items.firstIndex(where:{$0.id==plan.id}) {l.items[i].target=plan.after}}}) {fillQueueIfNeeded();message="已修复 \(valid.count) 个入口，可撤销；原笔记未改动。"}
    }
    func undoRepairs() {
        if commit({l in for plan in l.linkRepairUndo ?? [] {if let i=l.items.firstIndex(where:{$0.id==plan.id && $0.target==plan.after}) {l.items[i].target=plan.before}};l.linkRepairUndo=[]}) {fillQueueIfNeeded();message="已撤销链接修复，后续手动改动保留。"}
    }
}
