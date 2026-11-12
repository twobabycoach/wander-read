import Foundation
import AppKit

func runReadingWorkspaceChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wander-workspace-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let md = root.appendingPathComponent("想法.md")
    let source = "# 研究路线\n\n> 先把注意力留在 **材料** 上。\n\n- 反复比较 🧭 两种方法\n\n```swift\nlet n = 3\n```\n## 原文\n原文和想法可以并排。"
    try source.write(to: md, atomically: true, encoding: .utf8)
    let document = try TextDocument(url: md)
    check(document.headings.map(\.text) == ["研究路线", "原文"] && document.content.contains("注意力留在 材料 上"), "Markdown 保留标题与引用结构，摘录从阅读文本取词")
    check(document.content.contains("let n = 3") && !document.content.contains("```"), "Markdown 围栏代码按原文显示")
    let quote = "🧭 两种方法"
    let range = (document.content as NSString).range(of: quote)
    check(document.quote(range) == quote && document.place(at: range.location).hasPrefix("研究路线"), "中文与 emoji 摘录使用准确的 UTF-16 位置")
    check(document.quote(NSRange(location: Int.max - 1, length: 1)) == nil, "越界摘录定位安全")
    let txt = root.appendingPathComponent("段落.txt")
    try "开头\r\n下一段".write(to: txt, atomically: true, encoding: .utf16)
    check(try TextDocument(url: txt).content.contains("开头\n下一段"), "纯文本支持带 BOM 的 UTF-16 与 CRLF")
    let html = root.appendingPathComponent("研究.html")
    try "<!doctype html><html><head><meta charset=utf-8><script>hidden_unsafe</script></head><body><h1>阅读路线</h1><p>原始 <em>材料</em> &amp; 文本<img src='https://example.invalid/a'></body></html>".write(to: html, atomically: true, encoding: .utf8)
    let page = try TextDocument(url: html)
    check(page.headings.first?.text == "阅读路线" && page.content.contains("原始 材料 & 文本") && !page.content.contains("hidden_unsafe"), "HTML 解析保留标题和实体，略过脚本和外部资源")
    let rtf = root.appendingPathComponent("研究.rtf")
    try Data("{\\rtf1\\ansi Primary note}".utf8).write(to: rtf)
    check(try TextDocument(url: rtf).content.contains("Primary note"), "RTF 可作为正文打开")

    let store = ReadingStore(directory: root, refreshOnLoad: false)
    let item = ReadingItem(title: "想法", target: md.path)
    check(store.commit { $0.items = [item] } && store.startReaderVisit(item.id), "文本阅读沿用主动选择的会话入口")
    let reader = TextReader(item: item, url: md, document: document, store: store, focused: true)
    reader.selection = range
    reader.offset = range.location
    let excerpt = reader.capture()!
    check(reader.capture()?.id == excerpt.id && reader.excerpts.count == 1, "同一段重复摘录复用原记录")
    reader.editing = excerpt.id
    reader.draft = "这一句值得回看"
    check(reader.saveDraft() && reader.excerpts[0].note == "这一句值得回看", "摘录的想法可保存")
    reader.remove(excerpt.id); reader.undo()
    check(reader.excerpts.first?.id == excerpt.id, "误移除的摘录可撤销")
    store.textReader = reader
    store.leaveReader()
    let loaded = ReadingStore(directory: root, refreshOnLoad: false)
    check(loaded.activeSession == nil && loaded.library.items.first?.textReading?.offset == range.location &&
          loaded.library.items.first?.choices == 1, "离开与重启保留阅读位置和摘录，选择只计一次")
    try ("开场白\n" + source).write(to: md, atomically: true, encoding: .utf8)
    let revised = try TextDocument(url: md)
    let reopened = TextReader(item: loaded.library.items[0], url: md, document: revised, store: loaded, focused: true)
    check(reopened.sourceOffset(excerpt) == (revised.content as NSString).range(of: quote).location, "源文件改动后只在引文唯一时自动定位")

    let decoder = JSONDecoder()
    let folders = try decoder.decode([ZoteroCollection].self, from: Data("""
    [{"key":"PARENT01","data":{"name":"议题","parentCollection":false}},
     {"key":"CHILD001","data":{"name":"论文","parentCollection":"PARENT01"}}]
    """.utf8))
    let rows = try decoder.decode([ZoteroRow].self, from: Data("""
    [{"key":"PAPER001","data":{"itemType":"journalArticle","title":"论文","collections":["CHILD001"],"date":"2021-01","creators":[{"lastName":"作者"}],"tags":[{"tag":"专题"}]}},
     {"key":"BOOK0001","data":{"itemType":"book","title":"书","collections":["PARENT01"]}},
     {"key":"NOTE0001","data":{"itemType":"note","title":"随笔"}}]
    """.utf8))
    let attachments = try decoder.decode([ZoteroRow].self, from: Data("""
    [{"key":"PDF00001","data":{"itemType":"attachment","parentItem":"PAPER001","filename":"原文.pdf","linkMode":"linked_file"}}]
    """.utf8))
    let snapshot = ZoteroSnapshot(collections: folders, rows: rows, attachments: attachments)
    let imported = snapshot.selection(folder: "PARENT01", pdfOnly: true)
    check(imported.count == 1 && imported.first?.zotero?.pdfKey == "PDF00001" && imported.first?.note == "作者 · 2021", "Zotero 按分类含子分类，识别附件并保留作者年份")
    check(imported.first?.target == "zotero://select/library/items/PAPER001" && imported.first?.canReadInside == true, "Zotero 文献保留条目链接并能进入 PDF 阅读")
    check(store.mergeItems(imported, label: "Zotero · 议题") && store.mergeItems(imported, label: "Zotero · 议题") &&
          store.library.items.filter { $0.zotero != nil }.count == 1, "重复导入跳过，保留单一收录批次")
    let prefs = FocusLayout(width: 2000, notebookWidth: 5, textSize: .infinity).normalized()
    check(prefs.width == 1200 && prefs.notebookWidth == 240 && prefs.textSize == 17, "专注区域宽度与字号有安全上下限")
    let glance = GlanceCounts(store.library)
    check(glance.choices == 1 && glance.pending == 2, "阅读岛统计来自真实选择与待读条目")
}
