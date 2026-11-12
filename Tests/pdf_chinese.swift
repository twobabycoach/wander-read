import AppKit
import CoreText
import PDFKit

func writeChineseReadingFixture(_ url: URL, mode: String = "book") throws {
    var bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
    guard let context = CGContext(url as CFURL, mediaBox: &bounds, nil) else {
        throw InputError.invalid("无法生成中文 PDF 样本。")
    }
    func line(_ text: String, x: CGFloat = 64, y: CGFloat, size: CGFloat = 16) {
        let value = NSAttributedString(string: text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("PingFangSC-Regular" as CFString, size, nil)
        ])
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(value), context)
    }
    func page(_ draw: () -> Void) {
        context.beginPDFPage(nil)
        draw()
        context.endPDFPage()
    }
    if mode == "book" {
        page {
            line("目　录", y: 710, size: 27)
            line("第一章　阅读的起点 …… 1", y: 655)
            line("第二章　注意力的边界 …… 9", y: 621)
            line("第三章　回到原文 …… 26", y: 587)
        }
        page {
            line("第一章　阅读的起点", y: 762, size: 12)
            line("第一章　阅读的起点", y: 704, size: 24)
            line("读长文时，先找到作者正在回答的问题，才知道该在什么地", y: 657)
            line("方停下来。停顿给读者留下一点对照原文的空间。", y: 635)
            line("另一段从缩进开始，接下来的判断需要看到上下文。", x: 96, y: 613)
            line("这段材料既能用于练习识别段落，也能验证摘录的位置。", y: 591)
            line("第一节　如何把问题写下来", y: 519, size: 21)
            line("为了避免遗漏证据，先把观点和支撑它的文字放在一起。", y: 479)
            line("有些线索需要跨页读完，才能看清前后论述的联系。", y: 457)
        }
        page {
            line("第一章　阅读的起点", y: 762, size: 12)
            line("读到第二页，第一章仍在继续，读者需要沿着论证接着读。", y: 694)
            line("一、随手记录一个问题", y: 672)
            line("二、翻回前一页确认出处", y: 650)
            line("第二章　注意力的边界", y: 511, size: 24)
            line("这一章从本页中间开始，接下来讨论注意力的边界。", y: 465)
            line("正文里的每句话还可以定位回 PDF 上的位置。", y: 443)
        }
        page {
            line("第二章　注意力的边界", y: 762, size: 12)
            line("第二章的讨论仍在继续，页眉保持不变，但这并不是一个新标题。", y: 688)
            line("这是一段用来核对连续阅读与回到原页的中文正文。", y: 666)
        }
    } else if mode == "loose-prose" {
        page {
            for row in 0..<26 {
                line("这里是一段行距较宽的中文论述，字形的高度随文字变化，但作者仍在继续讨论同一个问题，",
                     x: row == 0 ? 82 : 62, y: 724 - CGFloat(row) * 17.5, size: row.isMultiple(of: 4) ? 10.6 : 10)
            }
            line("引领欧洲各国的", y: 269, size: 10)
            line("产业革命。", y: 251.5, size: 10)
            line("而相应时期的中国，另起一段讨论。", x: 82, y: 234, size: 10)
        }
    } else if mode == "wrapped" {
        let heads = ["一、地方制度与社会变迁的历史脉", "二、公共资源与地方生活的关系研", "三、社会参与与公共决策的证据来"]
        let tails = ["络及其发展", "究方法和案例", "源与解释框架"]
        for index in heads.indices {
            page {
                if index == 0 {
                    line("摘要说明本文从地方制度和社会变迁出发。", y: 720, size: 14)
                }
                line(heads[index], x: 84, y: 645, size: 14)
                line(tails[index], x: 62, y: 627, size: 14)
                line("这一段正文必须保留供读者核对。", x: 84, y: 603, size: 14)
                line("接下来用相同的字号说明资料为何值得比较。", x: 62, y: 585, size: 14)
            }
        }
    } else if mode == "numbered" || mode == "traditional" {
        for index in 0..<2 {
            page {
                let title = mode == "numbered" ? ["一 研究问题", "二 讨论材料"][index] : ["第一章 閱讀方法", "第二章 回看原文"][index]
                line(title, y: 704, size: 23)
                line("閱讀時先找出作者提出的問題，然後按照正文的推理逐段核對。", y: 657)
            }
        }
    } else {
        page {
            line("讨论材料", y: 720, size: 22)
            line("这一段是正常的阅读材料，需要从第一句话读到最后一句。", y: 674)
            line("一、查找出处", y: 652)
            line("二、记录想法", y: 630)
            line("这两行只是清单的一部分，读者并未进入新的章节。", y: 608)
        }
        page {
            line("这是连贯的论述，正文继续使用相同的字重和字号。", y: 700)
            line("读完这一段，仍然可以按原页码跳转并查看截图。", y: 678)
        }
    }
    context.closePDF()
}

func runPDFChineseChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wander-chinese-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("无书签中文书.pdf")
    try writeChineseReadingFixture(url)
    let document = PDFDocument(url: url)!
    let inferred = PDFOutlineInference.detect(in: document)
    check(document.outlineRoot == nil && inferred.map(\.location.page) == [1, 1, 2] &&
          inferred[0].title.contains("阅读的起点") && inferred[1].depth == 1,
          "无书签时在正文找到中文章、节，排除印刷目录、重复页眉和普通清单")
    check(PDFOutlineInference.detect(in: document, cancelled: { true }).isEmpty, "离开后可以取消正文目录识别")
    let store = ReadingStore(directory: root.appendingPathComponent("state"), refreshOnLoad: false)
    let item = ReadingItem(title: "中文书", target: url.path)
    let reader = PDFReader(item: item, url: url, revision: "1", document: document, store: store)
    let wrappedURL = root.appendingPathComponent("跨行节标题.pdf")
    try writeChineseReadingFixture(wrappedURL, mode: "wrapped")
    let wrappedDocument = PDFDocument(url: wrappedURL)!
    let wrapped = PDFOutlineInference.detect(in: wrappedDocument)
    check(wrapped.map(\.title) == ["一、地方制度与社会变迁的历史脉络及其发展",
                                 "二、公共资源与地方生活的关系研究方法和案例",
                                 "三、社会参与与公共决策的证据来源与解释框架"],
          "正文同字号的连续小节可凭编号和版式识别，保留完整的两行标题")
    let wrappedReader = PDFReader(item: item, url: wrappedURL, revision: "wrapped", document: wrappedDocument, store: store)
    let wrappedChapters = wrappedReader.chapters(unit: .chapter, groupSize: 3, inferred: wrapped)
    let opening = wrappedReader.foldedPage(0, in: wrappedChapters[0]).passages.map(\.displayText).joined()
    check(wrappedChapters[0].title == "卷首" && opening.contains("摘要说明") && !opening.contains("历史脉"),
          "识别到首页中段的第一节时，前面的摘要仍可在卷首阅读")
    let wrappedBody = wrappedReader.foldedPage(0, in: wrappedChapters[1]).passages.map(\.displayText).joined()
    check(wrappedBody.contains("这一段正文必须保留") && !wrappedBody.contains("络及其发展"),
          "两行章标题只出现在目录，正文第一段保留")
    let chapters = reader.chapters(unit: .chapter, groupSize: 3, inferred: inferred)
    check(chapters.count == 4 && chapters[0].title == "卷首" && chapters[1].pages(total: 4) == 1..<3,
          "识别的中文目录保留卷首与跨页范围")
    let before = reader.foldedPage(2, in: chapters[1]).passages.map(\.displayText).joined()
    let after = reader.foldedPage(2, in: chapters[3]).passages.map(\.displayText).joined()
    check(before.contains("第一章仍在继续") && !before.contains("阅读的起点") && !before.contains("这一章从本页") &&
          after.contains("这一章从本页") && !after.contains("第一章仍在继续"),
          "中文同页分章时从实际标题位置切分")
    let passages = reader.foldedPage(1, in: chapters[1]).passages
    guard let first = passages.first(where: { $0.displayText.contains("读长文") }) else {
        throw InputError.invalid("找不到跨行的中文段落。")
    }
    check(first.firstLine.hasSuffix("该在什么地方停下来。") && !first.displayText.contains("\n") &&
          first.text.contains("\n") && !first.text.contains("另一段"),
          "中文段首跨软换行取完整句，尊重段落缩进")
    let source = document.page(at: 1)!.string! as NSString
    check(source.substring(with: first.range) == first.text && document.page(at: 1)!.textSelection(in: first.range) != nil,
          "重排只作用于展示，摘录保留 PDF 原文及选区")
    let quote = FoldedPDFPassage(range: NSRange(), text: "作者写道：“答案要回到原文。”下一句接着展开。")
    check(quote.firstLine == "作者写道：“答案要回到原文。”", "中文段首保留句末引号")
    let verse = "床前明月光\n疑是地上霜\n举头望明月"
    check(ChineseReading.reflow(verse) == verse, "短行诗歌保留原来的换行")

    let loose = root.appendingPathComponent("宽行距长段.pdf")
    try writeChineseReadingFixture(loose, mode: "loose-prose")
    let looseDoc = PDFDocument(url: loose)!
    let looseReader = PDFReader(item: item, url: loose, revision: "1", document: looseDoc, store: store)
    let looseChapter = looseReader.chapters(unit: .page, groupSize: 3)[0]
    let prose = looseReader.foldedPage(0, in: looseChapter).passages
    check(prose.count == 2 && prose[0].range.length > 860 &&
          prose[0].displayText.hasSuffix("引领欧洲各国的产业革命。") && prose[1].displayText.hasPrefix("而相应时期"),
          "宽行距长段读到原有段尾，再按缩进另起一段")

    let plain = root.appendingPathComponent("只有正文.pdf")
    try writeChineseReadingFixture(plain, mode: "plain")
    let noOutline = PDFOutlineInference.detect(at: plain)
    check(noOutline.isEmpty && reader.chapters(unit: .chapter, groupSize: 3, inferred: noOutline).first?.title == "PDF 第 1–3 页",
          "标题证据不足时按连续页段回退")
    for mode in ["numbered", "traditional"] {
        let book = root.appendingPathComponent(mode + ".pdf")
        try writeChineseReadingFixture(book, mode: mode)
        check(PDFOutlineInference.detect(at: book).count == 2, "可从\(mode == "numbered" ? "中文序号式" : "繁体中文")标题建立参考目录")
    }
    let jpeg = try PDFScan.image(of: document.page(at: 1)!, region: CGRect(x: 59, y: 625, width: 475, height: 46))
    let scan = root.appendingPathComponent("中文扫描.pdf")
    try writeScanFixture(scan, from: jpeg)
    check(PDFOutlineInference.detect(at: scan).isEmpty, "纯扫描页按页处理，正文目录不会自动调用 OCR")
    let recognized = try PDFScan.recognize(jpeg)
    check(recognized.contains("找到作者正在回答的问题"), "已有框选 OCR 实测能识别简体中文正文")
    try runChineseAcademicChecks(root)
    try runChinesePageFlowChecks(root)
}

private func runChinesePageFlowChecks(_ root: URL) throws {
    let url = root.appendingPathComponent("中文跨页期刊.pdf")
    var bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
    guard let context = CGContext(url as CFURL, mediaBox: &bounds, nil) else {
        throw InputError.invalid("无法生成跨页样本。")
    }
    func line(_ text: String, x: CGFloat = 62, y: CGFloat, size: CGFloat = 14) {
        let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, size, nil)
        let value = NSMutableAttributedString(string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
        let latin = (text as NSString).range(of: "A")
        if latin.location != NSNotFound {
            value.addAttribute(kCTFontAttributeName as NSAttributedString.Key,
                               value: CTFontCreateWithName("Helvetica" as CFString, 24, nil), range: latin)
        }
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(value), context)
    }
    let prefix = "研究者阅读过完整的引文后发现此前研究对原始材料的解释"
    for index in 0..<4 {
        context.beginPDFPage(nil)
        line("·\(44 + index)· 《学术期刊》本期卷首", y: 766, size: 11)
        let head = index == 1 ? "已经偏离原文。此处为理解这段引文需要仔细回到文章的正文段落上下" : prefix + "有待细读"
        line(head, x: index == 2 ? 90 : 62, y: 718)
        for row in 1..<28 {
            let y = CGFloat(718 - 21 * row)
            if index == 1 && row <= 2 {
                line(row == 1 ? prefix + "提到哆啦 A" : "梦的故事作为例子，引出自己的观点。", y: y)
                continue
            }
            let paragraph = row % 5 == 1 || (index == 1 && row == 3)
            line(paragraph ? String(prefix.dropLast(2)) + "尚有缺漏。" : prefix + "都需要仔细",
                 x: paragraph ? 90 : 62, y: y)
        }
        line(prefix + "仍接着提到" + (index == 2 ? "（下转第九页）" : ""), y: 130)
        line("①甲作者：《原始资料来源》，第八页。", y: 90, size: 10)
        line("②乙作者：《原始资料来源》，第九页。", y: 75, size: 10)
        line("－ \(44 + index) －", x: 270, y: 38, size: 12)
        context.endPDFPage()
    }
    context.closePDF()

    let store = ReadingStore(directory: root.appendingPathComponent("page-flow-state"), refreshOnLoad: false)
    let item = ReadingItem(title: "中文跨页期刊", target: url.path)
    check(store.commit { $0.items = [item] }, "隔离资料库收录跨页样本")
    let doc = PDFDocument(url: url)!
    let reader = PDFReader(item: item, url: url, revision: "1", document: doc, store: store)
    let section = reader.chapters(unit: .group, groupSize: 4)[0]
    var pages = (0..<4).map { reader.foldedPage($0, in: section) }
    for index in 1..<pages.count {
        var previous = pages[index - 1]
        reader.stitchFoldedPages(&previous, &pages[index])
        pages[index - 1] = previous
    }
    let stitched = pages[0].passages.last
    check(stitched?.displayText.contains("接着提到已经偏离原文") == true &&
          !pages[1].passages.contains { $0.displayText.hasPrefix("已经偏离原文") } &&
          pages[0].footnotes.count == 2 && pages[1].footnotes.count == 2,
          "同一页段跨页接回完整段落，略过刊名和页下注且不重复显示")
    check(stitched?.displayText.filter { !$0.isWhitespace }.contains("哆啦A梦的故事") == true,
          "拉丁字母抬高字框时仍接回同一中文段")
    if let stitched, let mark = try reader.excerpt(stitched, page: 0) {
        let ranges = stitched.sources(startingOn: 0)
        let original = ranges.map { source in
            (doc.page(at: source.page)!.string! as NSString).substring(with: source.range)
        }.joined(separator: "\n")
        check(mark.quote == original && Set(mark.lines.map(\.page)) == [0, 1] &&
              ReaderNote(mark).location == "PDF 第 1–2 页", "跨页摘录保留两页来源和页码")
    } else {
        check(false, "跨页段落可摘录")
    }
    check(pages[1].passages.last?.sources(startingOn: 1).allSatisfy { $0.page == 1 } == true,
          "下一页明确缩进时保留新段")
    check(!ChineseReading.canContinueParagraph(after: "这一讨论仍在继续（下转第 9 页）", before: "另一篇文章的正文") &&
          !ChineseReading.canContinueParagraph(after: "上一页已经写完。①", before: "下一段正文"),
          "刊物跳页提示和带脚注的句末保留原边界")
    let joinPoint = stitched!.sources(startingOn: 0).last!
    let boundary = PDFFoldPosition(page: joinPoint.page, offset: joinPoint.range.location)
    let beforeBytes = try Data(contentsOf: url)
    reader.saveFoldCorrection(PDFFoldCorrection(boundary: boundary))
    let separated = reader.correctedFoldPages(pages)
    check(separated[1].passages.first?.displayText.hasPrefix("已经偏离原文") == true &&
          separated[0].passages.last?.sources(startingOn: 0).count == 1 &&
          separated[1].footnotes.count == pages[1].footnotes.count, "按原文行拆段后两页来源和脚注完整")
    let reopened = PDFReader(item: store.library.items[0], url: url, revision: "1", document: doc, store: store)
    let replaced = PDFReader(item: store.library.items[0], url: url, revision: "2", document: doc, store: store)
    check(reopened.correctedFoldPages(pages)[1].passages.first?.id == boundary.offset &&
          replaced.foldCorrections.isEmpty, "分段调整在重开后保留，只使用同一文件版本的位置")
    let left = PDFFoldPosition(page: 0, offset: stitched?.id)
    reader.saveFoldCorrection(PDFFoldCorrection(boundary: boundary, joinAfter: left))
    check(reader.correctedFoldPages(pages)[0].passages.last?.displayText == stitched?.displayText,
          "显式合并相邻段落保留整段原文")
    reader.undoFoldCorrection()
    let afterBytes = try Data(contentsOf: url)
    check(reader.correctedFoldPages(pages)[1].passages.first?.id == boundary.offset &&
          afterBytes == beforeBytes, "撤销合并恢复手工拆段，原 PDF 字节一致")
}

private func runChineseAcademicChecks(_ root: URL) throws {
    let url = root.appendingPathComponent("双栏期刊.pdf")
    var bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
    guard let context = CGContext(url as CFURL, mediaBox: &bounds, nil) else {
        throw InputError.invalid("无法生成期刊样本。")
    }
    func line(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat = 14) {
        let value = NSAttributedString(string: text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("PingFangSC-Regular" as CFString, size, nil)
        ])
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(value), context)
    }
    for (page, printed) in [44, 45, 80, 90].enumerated() {
        context.beginPDFPage(nil)
        line("供对照的刊名与卷期信息", x: 62, y: 763, size: 10)
        for row in 0..<7 {
            let y = CGFloat(710 - row * 21)
            let leftTail = page >= 2 ? "这个论证还未说完，前一段话出自" : "左栏末尾仍保留完整的研究论证。"
            let rightHead = "1843 年马克思写的一封信。"
            line(row == 6 ? leftTail : "左栏持续讨论不同材料中的同一问题", x: 62, y: y)
            let rightBody = row == 5 ? "右栏标题之后开始辨析下一条论证。" : "右栏接着讨论不同材料如何相互补充"
            let right = page >= 2 && row == 0 ? rightHead : rightBody
            line(right, x: page == 3 && row == 0 ? 343 : 315, y: y)
        }
        if page == 1 {
            line("参考文献", x: 62, y: 442, size: 19)
            line("[1] 第一条研究资料的作者与书名", x: 62, y: 414)
            line("这里接着记录第一条资料的刊年与页码", x: 62, y: 394)
            line("[2] 第二条研究资料的作者与书名", x: 62, y: 374)
        }
        if page == 0 {
            line("①甲作者：《用于核对的第一条资料》，第八页。", x: 65, y: 109, size: 10)
            line("第一条资料的出版信息接着写在这一行。", x: 58, y: 96, size: 10)
            line("②乙作者：《用于核对的第二条资料》，第九页。", x: 65, y: 83, size: 10)
        }
        line("－ \(printed) －", x: 275, y: 40, size: 12)
        context.endPDFPage()
    }
    context.closePDF()

    let document = PDFDocument(url: url)!
    let store = ReadingStore(directory: root.appendingPathComponent("academic-state"), refreshOnLoad: false)
    let item = ReadingItem(title: "双栏期刊", target: url.path)
    check(store.commit { $0.items = [item] }, "隔离资料库收录期刊样本")
    let reader = PDFReader(item: item, url: url, revision: "1", document: document, store: store)
    let chapter = reader.chapters(unit: .page, groupSize: 3)
    let folded = reader.foldedPage(0, in: chapter[0])
    let prose = folded.passages.map(\.displayText).joined(separator: "\n")
    check(prose.range(of: "左栏末尾").flatMap { left in prose.range(of: "右栏接着").map { left.lowerBound < $0.lowerBound } } == true,
          "双栏阅读先读完左栏，再读右栏")
    check(!prose.contains("刊名与卷期"), "折叠正文略过相邻页重复的小字页眉")
    check(!prose.contains("甲作者") && !prose.contains("乙作者") && folded.footnotes.count == 2 &&
          folded.footnotes[0].displayText.contains("出版信息"), "页脚注释独立保留并接上条目续行")
    check(reader.pageReference(0) == "PDF 第 1 页 · 版面 44" && reader.printedPageLabel(at: 1) == "45" &&
          reader.printedPageLabel(at: 2) == nil, "用相邻页印刷编号确认版面页码，忽略孤立数字")
    let source = document.page(at: 0)!.string! as NSString
    check((folded.passages + folded.footnotes).allSatisfy { source.substring(with: $0.range) == $0.text },
          "重排双栏后每个段落和脚注仍有准确的原文范围")
    if let note = folded.footnotes.first, let saved = try reader.excerpt(note, page: 0) {
        let stored = reader.marks.first { $0.id == saved.id }
        check(stored?.quote == note.text && stored?.location.page == 0 &&
              stored.map { ReaderNote($0).location } == "PDF 第 1 页 · 版面 44",
              "脚注摘录保留原文、跳转位置与导出的双页码")
    } else {
        check(false, "脚注可摘录")
    }
    let bibliography = reader.foldedPage(1, in: chapter[1]).passages.map(\.displayText)
    check(bibliography.contains { $0.contains("第一条研究资料") && $0.contains("刊年与页码") && !$0.contains("第二条研究资料") } &&
          bibliography.contains { $0.contains("第二条研究资料") }, "参考文献条目独立，续行留在同一条")
    let continued = reader.foldedPage(2, in: chapter[2]).passages.first { $0.displayText.contains("前一段话出自") }
    check(continued?.displayText.contains("前一段话出自1843") == true,
          "左栏铺满且语句未完时，接上齐头的右栏")
    if let continued, let saved = try reader.excerpt(continued, page: 2) {
        let source = document.page(at: 2)!.string! as NSString
        check(continued.sources(startingOn: 2).map { source.substring(with: $0.range) }.joined(separator: "\n") == saved.quote &&
              saved.lines.contains { $0.rect.minX < 300 } && saved.lines.contains { $0.rect.minX > 300 },
              "跨栏摘录保留两栏的文字和坐标")
    } else {
        check(false, "跨栏段落可摘录")
    }
    let indented = reader.foldedPage(3, in: chapter[3]).passages
    check(!indented.contains { $0.displayText.contains("前一段话出自") && $0.displayText.contains("1843") },
          "右栏明确缩进时保留原段边界")
    check(!ChineseReading.canContinueParagraph(after: "这是一句完整的引文。”〔 1 〕( P87 )", before: "另一段论述。") &&
          !ChineseReading.canContinueParagraph(after: "上一段末行未写句号", before: "一 、新的章节"),
          "行尾引文页码与右栏标题保留段落边界")
    let body = "研究者先介绍了若干史料以及其版本的流传情况。之后列举了不同版本在字词上的差异，指出某些差异来自传抄。由此可见，手稿的版本沿革决定了这段引文的解释范围。"
    let preview = FoldedPDFPassage(range: NSRange(location: 0, length: (body as NSString).length), text: body).scanExcerpt
    check(preview == "由此可见，手稿的版本沿革决定了这段引文的解释范围。" && body.contains(preview),
          "原句速览可挑段中论证句，文字来自原段")
}
