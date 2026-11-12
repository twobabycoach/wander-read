import AppKit
import CoreText
import PDFKit

func writePrintedOutlineFixture(_ url: URL, wrapped: Bool = false) throws {
    var box = CGRect(x: 0, y: 0, width: 600, height: 800)
    guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
        throw InputError.invalid("无法创建目录测试文件。")
    }
    func line(_ text: String, x: CGFloat = 65, y: CGFloat, size: CGFloat = 19) {
        let value = NSAttributedString(string: text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("PingFangSC-Regular" as CFString, size, nil)
        ])
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(value), context)
    }
    for index in 0..<9 {
        context.beginPDFPage(nil)
        switch index {
        case 0: line("地方研究札记", y: 684, size: 32)
        case 1: line("开场白", y: 675, size: 26)
        case 2:
            line("目　录", y: 714, size: 32)
            line("开场白 …… i", y: 642)
            line("1", y: 605)
            line("第一章 研究框架", x: 102, y: 605)
            line("第一节 档案与口述 …… 1", x: 119, y: 568)
            if wrapped {
                line("7", y: 531)
                line("第二章 地方经验与社区制度", x: 102, y: 531)
                line("的历史关系", x: 102, y: 505)
            } else {
                line("第二章 地方经验 …… 7", y: 531)
            }
            line("附录 访谈索引 …… 8", y: 465)
        case 4:
            line("第一章 研究框架", y: 704, size: 29)
            line("从材料出发，首先回到问题的历史语境。", y: 650)
            line("第一节 档案与口述", y: 526, size: 23)
            line("这两种资料有各自的来处和使用方法。", y: 480)
            line("1", x: 297, y: 38, size: 14)
        case 5:
            line("第一章 研究框架", y: 773, size: 12)
            line("材料之间的差别需要通过出处加以核对。", y: 672)
            line("2", x: 297, y: 38, size: 14)
        case 7:
            if wrapped {
                line("第二章 地方经验与社区制度", y: 669, size: 29)
                line("的历史关系", y: 627, size: 29)
            } else {
                line("第二章 地方经验", y: 627, size: 29)
            }
            line("第二章换了一组材料，因此从另一处开始。", y: 574)
            line("7", x: 297, y: 38, size: 14)
        case 8:
            line("附录 访谈索引（续）", y: 679, size: 25)
            line("本页汇总访谈的时间、地点与档案位置。", y: 629)
            line("8", x: 297, y: 38, size: 14)
        default: break
        }
        context.endPDFPage()
    }
    context.closePDF()
}

func writeImageOnlyOutlineFixture(from source: PDFDocument, to url: URL) throws {
    var box = CGRect(x: 0, y: 0, width: 600, height: 800)
    guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
        throw InputError.invalid("无法创建扫描目录样本。")
    }
    for index in 0..<source.pageCount {
        let page = source.page(at: index)!
        let data = try PDFScan.image(of: page, region: page.bounds(for: .cropBox))
        guard let image = NSBitmapImageRep(data: data)?.cgImage else { throw InputError.invalid("无法读取扫描样本。") }
        context.beginPDFPage(nil)
        context.draw(image, in: box)
        context.endPDFPage()
    }
    context.closePDF()
}

func runPDFOutlineBuilderChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wander-outline-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let pdf = root.appendingPathComponent("印刷目录.pdf")
    try writePrintedOutlineFixture(pdf)
    let original = try Data(contentsOf: pdf)
    let doc = PDFDocument(url: pdf)!
    let candidates = PDFOutlineBuilder.generate(in: doc)
    check(candidates.map(\.printedLabel) == ["i", "1", "1", "7", "8"],
          "读取左右两种印刷页码，保留标题顺序与罗马页码")
    check(candidates.map { $0.location?.page } == [1, 4, 4, 7, 8] &&
          candidates.map(\.needsReview) == [false, false, false, false, true],
          "正文匹配纠正前置页和不同页码偏移，只有推算位置的条目待核对")
    check(candidates[2].depth == 1 && candidates[1].location!.point!.y > candidates[2].location!.point!.y,
          "同一文件页保留章与节各自的页内位置")
    check(PDFOutlineBuilder.generate(in: doc, cancelled: { true }).isEmpty, "本地识别可取消")
    let wrapped = root.appendingPathComponent("折行印刷目录.pdf")
    try writePrintedOutlineFixture(wrapped, wrapped: true)
    let wrappedEntries = PDFOutlineBuilder.generate(in: PDFDocument(url: wrapped)!)
    check(wrappedEntries.count == 5 && wrappedEntries[3].title == "第二章 地方经验与社区制度的历史关系" &&
          wrappedEntries[3].location?.page == 7 && !wrappedEntries[3].isPending,
          "左侧印刷页码与折行的目录标题能对上正文完整标题")
    let store = ReadingStore(directory: root.appendingPathComponent("Library"), refreshOnLoad: false)
    let item = ReadingItem(title: "印刷目录样本", target: pdf.path)
    check(store.commit { $0.items = [item] }, "建立目录测试资料")
    let reader = PDFReader(item: item, url: pdf, revision: "fixture", document: doc, store: store)
    check(!reader.saveOutline(candidates) && reader.savedOutline.isEmpty, "待核对的位置不能直接保存")
    check(reader.saveOutline(candidates, resolvedOnly: true) && reader.savedOutline.count == 4,
          "仅保存已定位的章节，待核对位置不用于导航")
    let draftStore = ReadingStore(directory: root.appendingPathComponent("Library"), refreshOnLoad: false)
    let draftReader = PDFReader(item: draftStore.library.items.first!, url: pdf, revision: "fixture", document: doc, store: draftStore)
    check(draftReader.outlineDraft == candidates && draftReader.savedOutline.count == 4,
          "确认项和待核对条目在重开后均可接续")
    var confirmed = candidates
    confirmed[4].needsReview = false
    check(reader.saveOutline(confirmed) && reader.chapters(unit: .chapter, groupSize: 3).contains { $0.title.contains("地方经验") },
          "核对后可保存并用于章节折叠")
    let reopened = ReadingStore(directory: root.appendingPathComponent("Library"), refreshOnLoad: false)
    let savedItem = reopened.library.items.first!
    let same = PDFReader(item: savedItem, url: pdf, revision: "fixture", document: doc, store: reopened)
    let revised = PDFReader(item: savedItem, url: pdf, revision: "changed", document: doc, store: reopened)
    let after = try Data(contentsOf: pdf)
    check(same.savedOutline == reader.savedOutline && same.outlineDraft == nil && revised.savedOutline.isEmpty && after == original,
          "目录跨重开保留，旧版本位置不复用，原文件保持一致")
    let scanned = root.appendingPathComponent("扫描目录.pdf")
    try writeImageOnlyOutlineFixture(from: doc, to: scanned)
    let imagePDF = PDFDocument(url: scanned)!
    let localOCR = PDFOutlineBuilder.generate(in: imagePDF, scanRange: 2..<3)
    check(PDFOutlineBuilder.generate(in: imagePDF).isEmpty &&
          localOCR.contains { $0.title.contains("研究框架") && $0.location?.page == 4 && $0.location?.point != nil },
          "扫描版按需在本机识别目录，并定位章首页")
    let automatic = PDFOutlineBuilder.generate(in: imagePDF, autoScan: true)
    check(automatic.contains { $0.title.contains("研究框架") && $0.location?.page == 4 && !$0.isPending },
          "扫描版自动生成可以找到目录并确认章节，无需手填扫描范围")
}
