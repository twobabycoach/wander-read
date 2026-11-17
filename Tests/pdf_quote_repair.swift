import AppKit
import PDFKit

func runPDFQuoteRepairChecks() throws {
    let broken = "技术组织形式决定生产的规模和方式袁为社会组织形式的发展提供了可能遥野手推磨产生的是封建主的社会冶咱18暂602遥"
    check(PDFQuoteQuality.isSuspicious(broken), "中文 PDF 标点错码触发校对提示，不替换文字")
    check(!PDFQuoteQuality.isSuspicious("袁世凯的资料与遥远的往事，需要对照原文。这里讨论尧舜与田野。"), "正常姓名、遥远与田野不误报为乱码")
    check(!PDFQuoteQuality.isSuspicious("袁、遥、尧、冶、野都是汉字。"), "带正常标点的生僻字讨论不误判")
    check(PDFQuoteQuality.isSuspicious("无法读取��的文字"), "无法解码字符提示校对")
    check(PDFQuoteRepair.joinLines(["随着资本主", "义所有制确立。", "Research", "evidence"]) == "随着资本主义所有制确立。Research evidence",
          "中文 OCR 接行不插空格，英文词之间保留空格")

    let proposal = PDFQuoteRepair.proposal(original: "同一时间尧同一空间渊或者说同一劳动场所冤袁劳动的规模袁和起点咱18暂602遥",
                                            recognized: "同一时问、同一空间(或者说同一劳动场所)，劳动的规摸，和起点1S160。")
    check(proposal.preservesSource && proposal.text.contains("同一时间、") && proposal.text.contains("劳动的规模，") &&
          proposal.text.contains("18暂602"), "OCR 校正可确认标点时保留原汉字和引文数字，不引入识别错字")
    check(proposal.unresolved.contains("咱") && proposal.unresolved.contains("暂"), "无法确认的引文符号明确留待校对，不猜测替换")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wander-quote-repair-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("原页.pdf")
    try writeChineseReadingFixture(file)
    let original = try Data(contentsOf: file)
    let revision = try PDFReader.fingerprint(file)
    let store = ReadingStore(directory: root.appendingPathComponent("Library"), refreshOnLoad: false)
    let item = ReadingItem(title: "中文校对样本", target: file.path)
    _ = store.commit { $0.items = [item] }
    try store.presentPDF(itemID: item.id, url: file, revision: revision)
    let reader = store.pdfReader!, page = reader.document.page(at: 1)!
    let canvas = PDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 700))
    canvas.document = reader.document
    reader.attach(canvas)
    let substring = "找到作者正在回答的问题"
    let range = (page.string! as NSString).range(of: substring)
    check(range.location != NSNotFound, "中文 OCR 校对准备真实 PDF 文字选区")
    canvas.setCurrentSelection(page.selection(for: range), animate: false)
    var mark = try reader.draft(kind: .annotation)
    mark.note = "原有想法"; mark.color = .green; mark.style = .underline; mark.isExcerpt = true
    _ = reader.save(mark)
    let images = try PDFQuoteRepair.images(url: file, revision: revision, mark: mark)
    check(NSBitmapImageRep(data: images[0].jpeg)!.pixelsWide > Int(mark.lines[0].rect.width * 3),
          "选区图像真正放大到 OCR 分辨率，避免原始小字截图造成新错字")
    let recognized = try PDFQuoteRepair.recognize(images)
    check(recognized.contains("找到作者正在回答的问题") && !recognized.contains("才知道该在") && !recognized.contains("方停下来"),
          "从选区图像识别中文，排除同一行未选内容与下一行")
    check(reader.marks[0].quoteCorrection == nil && reader.marks[0].quote == mark.quote,
          "生成校对预览不改写原摘录")
    let replacement = "读长文时，先找到作者正在回答的问题。"
    check(try reader.correctQuote(mark.id, text: replacement, expected: mark.quote, method: .localOCR), "保存校对文字")
    let repaired = reader.marks[0]
    check(repaired.id == mark.id && repaired.lines == mark.lines && repaired.location == mark.location &&
          repaired.note == mark.note && repaired.appearance == mark.appearance && repaired.createdAt == mark.createdAt,
          "校对保留原 ID、高亮位置、批注、颜色、样式和创建时间")
    check(repaired.quoteCorrection?.original == mark.quote && ReaderNote(repaired).quote == replacement, "校对留存原提取文字，笔记导出采用校对结果")
    check(try reader.draft(kind: .annotation).id == mark.id, "重新摘录同一选区不重复添加，也不覆盖校对文字")
    do {
        _ = try reader.correctQuote(mark.id, text: "过期结果", expected: mark.quote, method: .manual)
        check(false, "过期校对窗口拒绝覆盖新文字")
    } catch { check(reader.marks[0].quote == replacement, "过期校对窗口拒绝覆盖新文字") }
    reader.undo()
    check(reader.marks[0] == mark, "校对可完整撤销")
    _ = try reader.correctQuote(mark.id, text: replacement, expected: mark.quote, method: .manual)
    let encoded = try JSONEncoder().encode(reader.marks[0])
    check(try JSONDecoder().decode(PDFReadingMark.self, from: encoded) == reader.marks[0], "校对来源和原文可持久化")
    let legacy = try JSONEncoder().encode(mark)
    check(try JSONDecoder().decode(PDFReadingMark.self, from: legacy).quoteCorrection == nil, "旧摘录无需迁移即可读取")
    check(reader.restoreOriginalQuote(mark.id) && reader.marks[0].quote == mark.quote && reader.marks[0].quoteCorrection == nil,
          "恢复原提取文字同时清除校对状态")
    reader.undo()
    check(reader.marks[0].quote == replacement, "恢复原文也可撤销")
    check(try Data(contentsOf: file) == original, "校对、识别和撤销不修改原 PDF")
    var stale = mark; stale.revision = "old"
    do {
        _ = try PDFQuoteRepair.images(url: file, revision: revision, mark: stale)
        check(false, "拒绝用旧坐标从新版 PDF 识别")
    } catch { check(true, "拒绝用旧坐标从新版 PDF 识别") }
    let left = PDFReadingLine(page: 0, rect: CGRect(x: 20, y: 700, width: 200, height: 25))
    let lower = PDFReadingLine(page: 0, rect: CGRect(x: 20, y: 680, width: 200, height: 25))
    let right = PDFReadingLine(page: 0, rect: CGRect(x: 300, y: 700, width: 200, height: 25))
    let next = PDFReadingLine(page: 1, rect: left.rect)
    check(PDFQuoteRepair.groups([left, lower, right, next]).map(\.count) == [2, 1, 1], "跨栏和跨页的选区依次识别，不合并为整页截图")
    let bands = PDFQuoteRepair.regions([left, lower])
    check(bands.allSatisfy { $0.height == 20 } && bands[0].minY == bands[1].maxY, "嵌入字体过高的选区收束到行距，排除邻行残片")

    let owned = ReadingAppWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    let system = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 28, height: 24), styleMask: [.borderless], backing: .buffered, defer: false)
    system.backgroundColor = .clear
    let originalAppearance = NSApp.appearance
    store.selectTheme(.night)
    check(owned.appearance?.name == .darkAqua && system.backgroundColor == .clear && system.appearance == nil && NSApp.appearance == originalAppearance,
          "主题仅修改漫读窗口，系统菜单栏与透明面板不被染色")
    store.selectTheme(.paper)
    check(owned.appearance?.name == .aqua && system.backgroundColor == .clear, "深浅主题反复切换不留下菜单栏背景")
    owned.orderOut(nil); system.orderOut(nil)
}
