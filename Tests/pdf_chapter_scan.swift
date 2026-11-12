import AppKit
import CoreText
import PDFKit

func writeChapterFixture(_ url: URL) throws {
    var bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
    let context = CGContext(url as CFURL, mediaBox: &bounds, nil)!
    let rows: [[(Int, String)]] = [
        [(728, "Chapter Alpha"), (672, "Alpha opens on page one."), (602, "Subheading"), (553, "A child in Alpha.")],
        [(720, "Alpha continues on page two."), (512, "Chapter Beta"), (450, "Beta begins on the same page.")],
        [(716, "Beta continues on page three."), (632, "A final argument for Beta.")],
        [(728, "Chapter Gamma"), (654, "Gamma is a separate chapter.")]
    ]
    for lines in rows {
        context.beginPDFPage(nil)
        for (y, value) in lines {
            let text = NSAttributedString(string: value, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, 22, nil)
            ])
            context.textPosition = CGPoint(x: 58, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        context.endPDFPage()
    }
    context.closePDF()
    let document = PDFDocument(url: url)!
    let root = PDFOutline()
    func bookmark(_ title: String, page: Int, y: CGFloat, parent: PDFOutline) -> PDFOutline {
        let entry = PDFOutline()
        entry.label = title
        entry.destination = PDFDestination(page: document.page(at: page)!, at: CGPoint(x: 30, y: y))
        parent.insertChild(entry, at: parent.numberOfChildren)
        return entry
    }
    let alpha = bookmark("Chapter Alpha", page: 0, y: 758, parent: root)
    _ = bookmark("Subheading", page: 0, y: 624, parent: alpha)
    _ = bookmark("Chapter Beta", page: 1, y: 535, parent: root)
    _ = bookmark("Chapter Gamma", page: 3, y: 760, parent: root)
    document.outlineRoot = root
    guard document.write(to: url) else { throw InputError.invalid("目录样本写入失败。") }
}

func writeScanFixture(_ url: URL, from jpeg: Data) throws {
    guard let image = NSBitmapImageRep(data: jpeg)?.cgImage else { throw InputError.invalid("扫描图像无效。") }
    var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw InputError.invalid("无法创建扫描样本。") }
    context.beginPDFPage(nil)
    context.draw(image, in: box)
    context.endPDFPage()
    context.closePDF()
}

func runPDFChapterScanChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wander-chapter-scan-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let pdf = root.appendingPathComponent("目录样本.pdf")
    try writeChapterFixture(pdf)
    let store = ReadingStore(directory: root.appendingPathComponent("store"), refreshOnLoad: false)
    let item = ReadingItem(title: "目录样本", target: pdf.path)
    check(store.commit { $0.items = [item] }, "章节折叠准备带目录的本地文件")
    try store.presentPDF(itemID: item.id, url: pdf, revision: PDFReader.fingerprint(pdf))
    let reader = store.pdfReader!
    let chapters = reader.chapters(unit: .chapter, groupSize: 3)
    check(chapters.map(\.title) == ["Chapter Alpha", "Subheading", "Chapter Beta", "Chapter Gamma"] &&
          chapters[1].depth == 1, "折叠采用作者的目录层级")
    check(chapters[0].pages(total: 4) == 0..<2 && chapters[2].pages(total: 4) == 1..<4,
          "章可以跨页，同页起始的下一章可划分")
    let alpha = reader.foldedPage(1, in: chapters[0]).passages
    let beta = reader.foldedPage(1, in: chapters[2]).passages
    check(alpha.map(\.text).joined().contains("Alpha continues") && !alpha.map(\.text).joined().contains("Beta"),
          "折叠读到下一页，止于同页下一章标题")
    check(beta.map(\.text).joined().contains("Beta begins") && !beta.map(\.text).joined().contains("Alpha continues"),
          "从页中开始的章节排除上一章文字")
    let selected = try reader.excerpt(beta[0], page: 1)
    check(selected?.location.page == 1 && selected?.lines.isEmpty == false &&
          selected?.quote.contains("Chapter Beta") == true, "章节边界裁切后摘录仍可用原始坐标")
    check(reader.chapters(unit: .page, groupSize: 3).count == 4 &&
          reader.chapters(unit: .group, groupSize: 2).map { $0.pages(total: 4) } == [0..<2, 2..<4],
          "按单页和用户选择的连续页数折叠")
    let crop = CGRect(x: 50, y: 710, width: 210, height: 48)
    let bytes = try PDFScan.image(of: reader.document.page(at: 0)!, region: crop)
    let scanPath = root.appendingPathComponent("扫描样本.pdf")
    try writeScanFixture(scanPath, from: bytes)
    check(PDFDocument(url: scanPath)?.page(at: 0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
          "OCR 验证使用没有文本层的纯图像扫描页")
    store.leaveReader()
    let scanItem = ReadingItem(title: "扫描样本", target: scanPath.path)
    check(store.commit { $0.items.append(scanItem) }, "收录扫描 PDF")
    let exactSource = try Data(contentsOf: scanPath)
    try store.presentPDF(itemID: scanItem.id, url: scanPath, revision: PDFReader.fingerprint(scanPath))
    let scanned = store.pdfReader!
    let area = scanned.document.page(at: 0)!.bounds(for: .cropBox)
    scanned.finishRegion(page: 0, region: area)
    let captured = scanned.marks.first!
    check(captured.scan != nil && captured.quote.isEmpty && captured.lines.first?.rect == area,
          "扫描框选保留图和坐标，未校对前不写入 OCR 文本")
    let recognized = try PDFScan.recognize(captured.scan!.jpeg)
    check(recognized.localizedCaseInsensitiveContains("Chapter Alpha"), "本机 Vision 从真实扫描图中识别文字")
    var confirmed = captured
    confirmed.quote = recognized
    check(scanned.save(confirmed) && scanned.marks.first?.quote == recognized, "用户确认后保存识别文本")
    let vault = root.appendingPathComponent("图摘测试库")
    try FileManager.default.createDirectory(at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
    let settings = NotebookExportSettings(vault: vault.path)
    check(store.commit { $0.preferences.notebookExport = settings }, "图摘准备 Obsidian 收件位置")
    let result = try store.sendNotebookNotes([captured.id], from: scanItem.id)
    let folder = try settings.directory()
    let output = try String(contentsOf: folder.appendingPathComponent(result.delivery.file), encoding: .utf8)
    let imageFile = folder.appendingPathComponent("附件/漫读-\(captured.id.uuidString.lowercased()).jpg")
    let exportedImage = try Data(contentsOf: imageFile)
    check(output.contains("![框选原图]") && output.contains("Chapter Alpha") && exportedImage == captured.scan!.jpeg,
          "图摘和校对文字一起发送，保留原图附件")
    _ = scanned.remove([captured.id])
    scanned.undo()
    let after = try Data(contentsOf: scanPath)
    check(scanned.marks.first?.scan == captured.scan && after == exactSource,
          "撤销恢复图摘，PDF 原文件字节保持一致")
}
