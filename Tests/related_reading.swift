import Foundation
import AppKit
import CoreText
import PDFKit

func runRelatedReadingChecks() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wander-related-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let pdf = folder.appendingPathComponent("fixture.pdf")
    try writeReadingPDF(pdf, suffix: " with nitrogen fixation")
    let note = folder.appendingPathComponent("fixture.md")
    try Data("追踪豆科作物的固氮作用，比较盐碱地的土壤过程。".utf8).write(to: note)
    let bodyOnly = ReadingItem(title: "一份文章", target: pdf.path, tags: ["研究"])
    let noteOnly = ReadingItem(title: "手记", target: note.path, tags: ["研究"])
    let broken = ReadingItem(title: "nitrogen fixation", target: folder.appendingPathComponent("missing.pdf").path, tags: ["研究"])
    let other = ReadingItem(title: "摄影指南", target: "https://example.com/photo", tags: ["研究"])
    let outside = ReadingItem(title: "nitrogen fixation", target: "https://example.com/outside")
    let library = [bodyOnly, noteOnly, broken, other, outside]
    var prefs = Preferences()
    var profile = prefs.strategy
    profile.scopeTag = "研究"
    prefs.strategies = [profile]
    let ranking = RelatedReading.rank(items: library, preferences: prefs, question: "nitrogen fixation", anchorID: nil, limit: 60)
    check(ranking.results.first?.id == bodyOnly.id && ranking.results.first?.sampledPages == [1, 2, 3],
          "英文只在本地 PDF 正文出现时仍可登榜，带首中尾取样页")
    check(ranking.compared == 3 && ranking.sampled == 2 && !ranking.results.contains { $0.id == broken.id || $0.id == outside.id },
          "正文榜尊重范围并跳过已失效入口")
    let chinese = RelatedReading.rank(items: library, preferences: prefs, question: "固氮作用", anchorID: nil, limit: 60)
    check(chinese.results.first?.id == noteOnly.id && chinese.results.first?.excerpt?.contains("固氮作用") == true,
          "本地 Markdown 的正文样本能支持中文问题")
    check(RelatedReading.rank(items: library, preferences: prefs, question: "", anchorID: nil, limit: 60).needsAnchor,
          "相似度榜缺少问题与阅读锚点时提示补充")
    let linked = RelatedReading.rank(items: library + [ReadingItem(title: "nitrogen fixation", target: "https://example.com/anchor")],
                                     preferences: prefs, question: "", anchorID: outside.id, limit: 60)
    check(linked.results.first?.id == bodyOnly.id, "收藏中主动打开的范围外锚点也可用于当前专题比较")

    let pageSpecific = folder.appendingPathComponent("带定位的原句.pdf")
    try writeRelatedPages(pageSpecific, pages: ["作者与期刊信息", "劳动异化与拜物教的批判指向并不完全相同。", "研究方法与材料"])
    let source = ReadingItem(title: "期刊论文", target: pageSpecific.path, tags: ["研究"])
    let titleOnly = ReadingItem(title: "劳动异化与拜物教", target: "https://example.com/title-only", tags: ["研究"])
    let titlePDF = folder.appendingPathComponent("只有题名匹配.pdf")
    let title = "劳动异化、拜物教和现代社会的概念辨析"
    try writeRelatedPages(titlePDF, pages: [title + "。", "其他作者信息"])
    let printedTitle = ReadingItem(title: title, target: titlePDF.path, tags: ["研究"])
    let exact = RelatedReading.rank(items: library + [source, titleOnly, printedTitle], preferences: prefs,
                                    question: "劳动异化 拜物教", anchorID: noteOnly.id, limit: 60, inlineEvidence: true)
    check(exact.results.map(\.id) == [source.id], "侧栏只返回有可定位 PDF 原文的相关结果")
    let evidence = exact.results.first!.pdfEvidence!
    let document = PDFDocument(url: pageSpecific)!
    let selection = try evidence.selection(in: document)
    check(evidence.page == 1 && evidence.quote.contains("拜物教") &&
          selection.pages.first.map { document.index(for: $0) } == 1,
          "相关原句携带准确的 PDF 页与文字坐标")
    let repeated = (0..<3).map { index -> ReadingItem in
        let copy = folder.appendingPathComponent("同题研究\(index).pdf")
        try! FileManager.default.copyItem(at: pageSpecific, to: copy)
        return ReadingItem(title: "同题研究 \(index)", target: copy.path, tags: ["研究"])
    }
    let capped = RelatedReading.rank(items: repeated + [source], preferences: prefs, question: "劳动异化 拜物教",
                                     anchorID: source.id, limit: 60, inlineEvidence: true)
    check(capped.results.count == 2 && !capped.results.contains { $0.id == source.id }, "按需关联最多两篇并排除当前篇")
    try writeRelatedPages(pageSpecific, pages: ["作者信息", "标题未变但原句已替换。"])
    rejects({ _ = try evidence.selection(in: PDFDocument(url: pageSpecific)!) }, "文件改变后拒用旧的原句范围")

    let original = "First sentence. The next follows.\n\n中文段落。它还有下文。"
    let passages = FoldedPDFPassage.split(original)
    check(passages.count == 2 && passages[0].firstLine == "First sentence." &&
          passages.allSatisfy { (original as NSString).substring(with: $0.range) == $0.text },
          "折叠可展开完整原段并保留 PDFKit 使用的 UTF‑16 范围")
    let decorated = ReadingWordEmphasis.format(original)
    check(String(decorated.characters) == original &&
          decorated.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized },
          "词首强调保留中英文和换行，只附加强调样式")
    let mixed = "🧭 历史唯物主义讨论社会结构与生产关系，也要考察制度变迁。 Reading evidence. 《资本论》 https://example.com/evidence （P87）"
    let ranges = ReadingWordEmphasis.ranges(in: mixed, mode: .adaptive)
    let nsMixed = mixed as NSString
    let han = ranges.filter { ChineseReading.hasHan(nsMixed.substring(with: $0)) }
    let protected = ["《资本论》", "https://example.com/evidence", "（P87）"].map { nsMixed.range(of: $0) }
    check(!han.isEmpty && han.allSatisfy { nsMixed.substring(with: $0).count >= 2 } &&
          zip(han, han.dropFirst()).allSatisfy { NSMaxRange($0) + 13 <= $1.location },
          "中文仿生只稀疏强调完整词，避免逐字跳动")
    check(ranges.contains { nsMixed.substring(with: $0) == "Re" } &&
          ranges.allSatisfy { range in protected.allSatisfy { NSIntersectionRange($0, range).length == 0 } } &&
          String(ReadingWordEmphasis.format(mixed).characters) == mixed,
          "中英混排保留英文词首、书名、页注、链接和原文字符")
    check(ReadingWordEmphasis.ranges(in: mixed, mode: .off).isEmpty &&
          !ReadingWordEmphasis.ranges(in: mixed, mode: .english).isEmpty &&
          ReadingWordEmphasis.ranges(in: mixed, mode: .english).allSatisfy { !ChineseReading.hasHan(nsMixed.substring(with: $0)) } &&
          ReadingWordEmphasis.ranges(in: "[1] Reading evidence and social structure.", mode: .adaptive).isEmpty,
          "仅英文模式保留中文原字重，参考文献条目不加阅读标记")
    let traditional = "比較不同文獻中的勞動過程與生產關係，再回到材料中尋找證據。"
    check(!ReadingWordEmphasis.ranges(in: traditional, mode: .adaptive).isEmpty &&
          String(ReadingWordEmphasis.format(traditional).characters) == traditional &&
          ReadingWordEmphasis.ranges(in: "GDPW＝正内部性福利价值－负外部性成本", mode: .adaptive).isEmpty,
          "繁体中文可用整词强调，公式和原文内容保持完整")
}

private func writeRelatedPages(_ url: URL, pages: [String]) throws {
    var bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
    guard let context = CGContext(url as CFURL, mediaBox: &bounds, nil) else {
        throw InputError.invalid("无法生成相关原句的测试 PDF。")
    }
    for text in pages {
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, 16, nil)
        let value = NSAttributedString(string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
        context.textPosition = CGPoint(x: 64, y: 720)
        CTLineDraw(CTLineCreateWithAttributedString(value), context)
        context.endPDFPage()
    }
    context.closePDF()
}
