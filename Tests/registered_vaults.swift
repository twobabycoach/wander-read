import Foundation
func runRegisteredVaultChecks() throws {
    let base=FileManager.default.temporaryDirectory.appendingPathComponent("wander-registered-\(UUID().uuidString)")
    let root=base.appendingPathComponent("Research"),other=base.appendingPathComponent("Other")
    let file=root.appendingPathComponent("Daily/2025/11/2025-11-08.md")
    try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
    try Data("note remains".utf8).write(to:file)
    let vaults=[RegisteredVault(id:"real-id",root:root)]
    let legacy="obsidian://open?vault=Daily&file=2025/11/2025-11-08"
    check(ObsidianLinks.resolveLegacy(legacy,vaults:vaults)==ObsidianLinks.uri(file:file),"已注册仓库自动解析截图中的 Daily 旧入口")
    check(try ObsidianLinks.checkedURL(legacy,vaults:vaults).absoluteString==ObsidianLinks.uri(file:file),"打开时即时解析旧入口，不再发出错误仓库名")
    rejects({_ = try ObsidianLinks.checkedURL("obsidian://open?vault=Daily&file=missing",vaults:vaults)},"未定位的旧入口在漫读内报错，阻止错误派发")
    let store=ReadingStore(directory:base.appendingPathComponent("data"))
    var item=ReadingItem(title:"原有收藏",target:legacy);item.metricValues=["importance":9];item.choices=4
    store.commit {$0.items=[item]}
    let original=try Data(contentsOf:store.dataURL)
    check(store.autoRepairLegacyLinks(vaults:vaults)==1,"自动升级接回原有收藏，无需用户另找修复入口")
    check(store.library.items[0].id==item.id && store.library.items[0].choices==4 && store.library.items[0].metricValues?["importance"]==9,"自动升级保留收藏身份、次数和人工评分")
    let backups=try FileManager.default.contentsOfDirectory(at:base.appendingPathComponent("data/link-repair-backups"),includingPropertiesForKeys:nil)
    let backup=try Data(contentsOf:backups[0])
    check(backups.count==1 && backup==original,"自动修复独立备份与原文件逐字节一致")
    check(store.autoRepairLegacyLinks(vaults:vaults)==0,"自动迁移只执行一次，不覆盖原有撤销记录")
    let restarted=ReadingStore(directory:base.appendingPathComponent("data"));restarted.undoRepairs()
    check(restarted.library.items[0].target==legacy && restarted.library.registeredLinkMigration==1,"撤销自动修复后重启不再次强行迁移")
    let second=other.appendingPathComponent("Daily/2025/11/2025-11-08.md")
    try FileManager.default.createDirectory(at:second.deletingLastPathComponent(),withIntermediateDirectories:true)
    try Data("other note".utf8).write(to:second)
    check(ObsidianLinks.resolveLegacy(legacy,vaults:vaults+[RegisteredVault(id:"other",root:other)])==nil,"跨仓库同路径歧义不自动改写")
    check(ObsidianLinks.resolveLegacy("obsidian://open?vault=real-id&file=missing",vaults:vaults+[RegisteredVault(id:"other",root:other)])==nil,"明确仓库身份不被其他库替换")
}
