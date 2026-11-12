import Foundation

func runRoamingQueueChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wander-queue-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    var items = (0..<9).map { i in
        ReadingItem(title: "候选 \(i)", target: "https://example.com/queue/\(i)", tags: ["专题"],
                    priorityOverride: Double(10 - i))
    }
    items.append(ReadingItem(title: "范围外", target: "https://example.com/outside", priorityOverride: 10))
    let broken = ReadingItem(title: "已移动的 PDF", target: root.appendingPathComponent("missing.pdf").path,
                             tags: ["专题"], priorityOverride: 10)
    items.insert(broken, at: 9)
    var original = ReadingStrategy.defaults[2]
    original.absoluteProbability = 1
    original.scopeTag = "专题"
    let store = ReadingStore(directory: root, refreshOnLoad: false)
    check(store.commit {
        $0.items = items
        $0.preferences.strategies = [original]
        $0.preferences.strategyID = original.id
    }, "构造固定优先级及范围的队列")
    store.refresh()
    check(store.recommendations.map(\.id) == items[0..<3].map(\.id), "最高优先级模式按序取一批，排除范围外")
    check(store.unavailableCount == 1 && store.library.exposures?.contains { $0.itemID == broken.id } == false,
          "已失效的本地入口跳过抽样与曝光，原收藏保留")
    let restarted = ReadingStore(directory: root)
    check(restarted.recommendations.map(\.id) == items[0..<3].map(\.id) && restarted.library.exposures?.count == 3,
          "重开保留原队列，未重复计曝光")
    restarted.refresh()
    check(restarted.recommendations.map(\.id) == items[3..<6].map(\.id), "刷新只取本轮尚未出现的文献")
    restarted.returnToPreviousBatch()
    check(restarted.viewingPreviousBatch && restarted.recommendations.map(\.id) == items[0..<3].map(\.id), "可找回上一批")
    let viewedAgain = ReadingStore(directory: root)
    check(viewedAgain.viewingPreviousBatch && viewedAgain.library.exposures?.count == 6, "翻看位置跨重启保留")
    viewedAgain.refresh()
    check(viewedAgain.recommendations.map(\.id) == items[3..<6].map(\.id) && viewedAgain.library.exposures?.count == 6,
          "从上一批返回当前批不消耗候选和曝光")
    viewedAgain.archive(items[0].id)
    viewedAgain.snooze(items[6].id)
    viewedAgain.setScope(tag: "专题", question: "更新研究问题")
    check(viewedAgain.recommendations.map(\.id) == items[3..<6].map(\.id) &&
          viewedAgain.previousRecommendations.map(\.id) == items[1..<3].map(\.id),
          "归档和设置更新即时校验批次，不清空已遇见记录")
    viewedAgain.refresh()
    check(viewedAgain.recommendations.map(\.id) == items[7..<9].map(\.id), "休息期的资料不进入下一批")
    check(viewedAgain.startVisit(items[7].id), "主动选择进入停留")
    check(!viewedAgain.recommendations.contains { $0.id == items[7].id }, "正在读的文献与队列一起原子更新")
    viewedAgain.finish(outcome: "想接着读", bookmark: "第二节")
    viewedAgain.refresh()
    let exhausted = ReadingStore(directory: root)
    check(exhausted.recommendations.isEmpty && exhausted.library.exposures?.count == 8 &&
          exhausted.library.items.first(where: { $0.id == items[7].id })?.choices == 1,
          "耗尽后重开不暗中重置，展示与主动选择分别计数")
    exhausted.refresh(restart: true)
    check(exhausted.recommendations.map(\.id) == items[1..<4].map(\.id) &&
          exhausted.library.sessions.count == 1 && exhausted.library.exposures?.count == 11,
          "显式新一轮保留历史及归档和休息边界")

    // Force the existing backup path to fail during the transaction.
    let backup = exhausted.dataURL.appendingPathExtension("bak")
    try FileManager.default.removeItem(at: backup)
    try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
    let before = exhausted.library.roamingQueue
    exhausted.refresh()
    check(exhausted.library.roamingQueue == before && exhausted.library.exposures?.count == 11 && exhausted.error != nil,
          "保存失败时队列和曝光同时保持原值")

    let reopenRoot = root.appendingPathComponent("moved")
    try FileManager.default.createDirectory(at: reopenRoot, withIntermediateDirectories: true)
    let file = reopenRoot.appendingPathComponent("exists.md")
    try Data("local note".utf8).write(to: file)
    let moving = ReadingStore(directory: reopenRoot)
    moving.importFiles([file])
    check(moving.recommendations.count == 1, "存在的本地入口可进入候选")
    try FileManager.default.removeItem(at: file)
    let afterMove = ReadingStore(directory: reopenRoot)
    check(afterMove.recommendations.isEmpty && afterMove.unavailableCount == 1 &&
          afterMove.library.exposures?.count == 1 && afterMove.library.items.count == 1,
          "重开校验已保存批次，移动文件后不再显示失效入口")
    rejects({ _ = try ObsidianLinks.checkedURL("obsidian://open?path=") }, "空的 Obsidian 路径有明确错误")
}
