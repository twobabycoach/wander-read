import Foundation

func runNotebookDeliveryChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wander-notes-\(UUID().uuidString)")
    let vault = root.appendingPathComponent("本机测试仓库")
    try FileManager.default.createDirectory(at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var settings = NotebookExportSettings(vault: vault.path, folder: "研究/收件", header: "---\nsource: 漫读\n---\n\n# {{title}}",
                                          entry: "{{kind}}\n{{quote}}\n{{comment}}\n{{location}}\n{{source_link}}")
    let item = ReadingItem(title: "专题/材料", target: "https://example.org")
    let note = ReaderNote(id: UUID(), kind: "摘录", location: "第 9 行", quote: "这是 {{title}} 的原文。", comment: "自己的想法")
    let extra = ReaderNote(id: UUID(), kind: "高亮", location: "PDF 第 7 页", quote: "第二条证据", comment: "")

    let first = try NotebookExport.deliver([note], from: item, using: settings)
    let output = try settings.directory().appendingPathComponent(first.delivery.file)
    let text = try String(contentsOf: output, encoding: .utf8)
    check(first.written == 1 && text.hasPrefix("---\nsource: 漫读\n---") && text.contains("这是 {{title}} 的原文。"),
          "Obsidian 新文件保留 YAML 开头，原文中的字段不会再次渲染")
    check(text.contains("第 9 行") && text.contains(ReaderNoteLink(itemID: item.id, noteID: note.id).url),
          "Markdown 含位置和返回原文的深链接")
    let link = try ReaderNoteLink(URL(string: ReaderNoteLink(itemID: item.id, noteID: note.id).url)!)
    check(link.itemID == item.id && link.noteID == note.id, "回原文链接可还原文献和摘录身份")
    let recovered = try NotebookExport.deliver([note], from: item, using: settings)
    check(recovered.written == 0 && recovered.delivery.sent == [note.id], "本地回执缺失时从笔记标记恢复，重试不会重复写入")

    let edited = text + "\n在 Obsidian 增加我的整理。\n"
    try edited.write(to: output, atomically: true, encoding: .utf8)
    var tracked = item; tracked.notebookDeliveries = [first.delivery]; tracked.title = "同一文献换了标题"
    let second = try NotebookExport.deliver([note, extra], from: tracked, using: settings)
    let appended = try String(contentsOf: output, encoding: .utf8)
    check(second.written == 1 && second.delivery.file == first.delivery.file &&
          appended.hasPrefix(edited) && appended.contains("第二条证据"), "改标题后复用原收件笔记，只追加，保留 Obsidian 的手工整理")

    let moved = vault.appendingPathComponent("整理后的摘录.md")
    try FileManager.default.moveItem(at: output, to: moved)
    tracked.notebookDeliveries = [second.delivery]
    let third = ReaderNote(id: UUID(), kind: "页边记", location: "PDF 第 2 页", quote: "", comment: "自己的想法")
    let next = try NotebookExport.deliver([note, third], from: tracked, using: settings)
    let newText = try String(contentsOf: output, encoding: .utf8)
    check(next.written == 1 && !newText.contains("这是 {{title}} 的原文。") &&
          newText.contains("自己的想法"), "收件笔记移走后仅给未发送的内容建新文件")
    try "这是用户自己的笔记".write(to: output, atomically: true, encoding: .utf8)
    rejects({ _ = try NotebookExport.deliver([third], from: tracked, using: settings) }, "同名用户文件受到保护")
    check(try String(contentsOf: output, encoding: .utf8) == "这是用户自己的笔记", "拒绝同名冲突后原文件不变")
    settings.folder = "../仓库外"
    rejects({ _ = try settings.directory() }, "拒绝仓库外的收件路径")
    let linkFolder = vault.appendingPathComponent("替身")
    try FileManager.default.createSymbolicLink(at: linkFolder, withDestinationURL: root)
    settings.folder = "替身/收件"
    rejects({ _ = try settings.directory() }, "拒绝经过符号链接的收件路径")
    settings.folder = "收件二"
    settings.entry = "{{comment}}"
    rejects({ _ = try NotebookExport.deliver([extra], from: item, using: settings) }, "内容为空时不显示已发送")

    let library = ReadingStore(directory: root.appendingPathComponent("store"), refreshOnLoad: false)
    let source = root.appendingPathComponent("原文.md")
    try "# 标题\n摘录一\n摘录二".write(to: source, atomically: true, encoding: .utf8)
    let document = try TextDocument(url: source)
    var reading = ReadingItem(title: "原文", target: source.path)
    reading.textReading = TextReadingState()
    settings.folder = "同步验收"
    settings.entry = NotebookExportSettings.defaultEntry
    check(library.commit { $0.items = [reading]; $0.preferences.notebookExport = settings }, "保存用户的 Obsidian 收件配置")
    let reader = TextReader(item: reading, url: source, document: document, store: library, focused: true)
    reader.selection = (document.content as NSString).range(of: "摘录一")
    let a = reader.capture()!
    reader.selection = (document.content as NSString).range(of: "摘录二")
    let b = reader.capture()!
    let sent = try library.sendNotebookNotes([a.id, b.id], from: reading.id)
    let sentFile = try settings.directory().appendingPathComponent(sent.delivery.file)
    let exact = try Data(contentsOf: sentFile)
    check(sent.written == 2 && library.deliveredNotes(for: reading.id) == [a.id, b.id], "批量发送两条后保存各条的回执")
    check(reader.remove([a.id, b.id]) && reader.excerpts.isEmpty, "文本摘录批量清除")
    reader.undo()
    check(reader.excerpts.map(\.id) == [a.id, b.id], "一次撤销恢复整个清除批次")
    reader.undo()
    check(reader.excerpts.map(\.id) == [a.id], "阅读会话可连续撤销")
    check(try Data(contentsOf: sentFile) == exact, "本地清除和撤销不会改写已发送的笔记")
}
