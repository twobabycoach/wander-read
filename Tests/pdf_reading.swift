import AppKit
import CoreText
import PDFKit

func writeReadingPDF(_ url: URL, suffix: String = "") throws {
    var bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
    guard let context = CGContext(url as CFURL, mediaBox: &bounds, nil) else {
        throw InputError.invalid("无法生成 PDF 测试文件。")
    }
    for page in 1...3 {
        context.beginPDFPage(nil)
        let text = NSAttributedString(
            string: "Research evidence on page \(page)\(suffix)",
            attributes: [kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, 16, nil)]
        )
        context.textPosition = CGPoint(x: 72, y: 610)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        context.endPDFPage()
    }
    context.closePDF()
}

func runPDFReadingChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wander-pdf-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("含空格的 论文.pdf")
    try writeReadingPDF(file)
    let original = try Data(contentsOf: file)
    let revision = try PDFReader.fingerprint(file)
    let store = ReadingStore(directory: root, refreshOnLoad: false)
    let item = ReadingItem(title: "论文章节", target: file.path, note: "看这个定义")
    check(store.commit { $0.items = [item] }, "收录本地 PDF")
    try store.presentPDF(itemID: item.id, url: file, revision: revision)
    let reader = store.pdfReader!
    check(store.activeSession?.inReader == true && store.library.items[0].choices == 1, "本地 PDF 实际打开后才记作选择")
    check(reader.sourceText(page: 1)?.contains("Research evidence on page 2") == true && reader.sections.count == 3, "没有作者目录时按真实页码展开 PDF 文本")
    let canvas = PDFView(frame: CGRect(x: 0, y: 0, width: 700, height: 600))
    canvas.document = reader.document
    reader.attach(canvas)
    let page = reader.document.page(at: 1)!
    let passage = page.selection(for: NSRange(location: 0, length: 17))!
    canvas.setCurrentSelection(passage, animate: false)
    let annotation = try reader.draft(kind: .annotation)
    check(annotation.location.page == 1 && !annotation.lines.isEmpty && annotation.quote == "Research evidence", "由 PDFKit 的原文选区取得页码、选中文字和页内几何")
    check(reader.save(annotation) && reader.marks.first?.lines == annotation.lines, "保存 PDF 原文选区坐标")
    reader.remove(annotation.id)
    reader.undo()
    check(reader.marks == [annotation], "撤销删除时恢复原文划线")
    reader.setColor(.blue, for: annotation)
    check(reader.marks.first?.color == .blue, "已有划线可换色")
    reader.undo()
    check(reader.marks.first?.color == nil, "划线换色可撤销")
    var second = annotation
    second.id = UUID()
    second.note = "批量清除用的第二条"
    check(reader.save(second) && reader.remove([annotation.id, second.id]) && reader.marks.isEmpty, "PDF 多条高亮一次清除")
    reader.undo()
    check(reader.marks == [annotation, second], "撤销批量清除恢复 PDF 高亮和批注")
    reader.undo()
    check(reader.marks == [annotation], "多次撤销保留操作顺序")
    let pageNote = try reader.draft(kind: .annotation, pageOnly: true)
    check(pageNote.quote.isEmpty && pageNote.lines.isEmpty && pageNote.location == reader.location,
          "页边记直接锚定当前页")
    let passages = reader.foldedPassages(on: 1)
    check(passages.count == 1 && reader.location(of: passages[0], on: 1).point != nil,
          "从折叠的 PDF 原段可计算实际页内位置")
    canvas.clearSelection()
    reader.go(to: annotation.location)
    reader.noteDraft = try reader.draft(kind: .detour)
    reader.draftText = "下次核对作者的定义"
    store.leavePDF()
    check(store.activeSession == nil && store.pdfReader == nil && store.library.items[0].choices == 1, "返回后收尾并保留进度，不重复记作选择")
    check(try Data(contentsOf: file) == original, "划线、撤销和暂放不修改原 PDF")
    let reopened = ReadingStore(directory: root, refreshOnLoad: false)
    try reopened.presentPDF(itemID: item.id, url: file, revision: revision)
    let resumed = reopened.pdfReader!
    check(resumed.location == annotation.location && resumed.intent == "看这个定义", "重新加载本机资料后恢复页内坐标和阅读意图")
    check(resumed.marks.count == 2 && resumed.marks.last?.note == "下次核对作者的定义", "离开时保存未提交的暂放草稿")
    let last = resumed.foldedPassages(on: 2)[0]
    let fold = PDFFoldPosition(page: 2, offset: last.id)
    resumed.showOutline = true
    resumed.rememberFoldPosition(fold, passage: last)
    check(resumed.location.page == 2 && resumed.foldPosition == fold, "折叠视图记录实际可见原段")
    reopened.leavePDF()
    try reopened.presentPDF(itemID: item.id, url: file, revision: revision)
    check(reopened.pdfReader?.showOutline == true && reopened.pdfReader?.location.page == 2 &&
          reopened.pdfReader?.foldPosition == fold, "续读恢复折叠视图和段落锚点")
    reopened.leavePDF()
    try reopened.presentPDF(itemID: item.id, url: file, revision: revision, markID: annotation.id)
    check(reopened.pdfReader?.showOutline == false && reopened.pdfReader?.location == annotation.location,
          "按笔记打开时优先显示批注所在原页")
    reopened.leavePDF()
    try writeReadingPDF(file, suffix: " revised")
    let revised = try PDFReader.fingerprint(file)
    try reopened.presentPDF(itemID: item.id, url: file, revision: revised, markID: annotation.id)
    let changed = reopened.pdfReader!
    check(revised != revision && changed.previousVersion && changed.location.page == 0, "同路径替换 PDF 后不复用旧坐标")
    check(changed.marks.first?.quote == annotation.quote && changed.marks.first?.revision != changed.revision, "版本变化后保留摘录，避免划到新文件")
    reopened.leavePDF()
    try Data("corrupt PDF".utf8).write(to: file)
    let before = reopened.library.sessions.count
    rejects({ try reopened.presentPDF(itemID: item.id, url: file, revision: revised) }, "损坏的 PDF 有明确的打开失败")
    check(reopened.library.sessions.count == before, "打开失败不产生阅读记录")
}
