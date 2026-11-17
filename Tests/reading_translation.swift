import Foundation
import CoreText
import PDFKit

func runReadingTranslationChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wander-translation-\(UUID().uuidString)")
    let files = FileManager.default
    try files.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: root) }

    try checkSentenceReading(in: root)

    check(try ReadingModelService.address(" http://localhost:11434/ ").absoluteString == "http://127.0.0.1:11434/v1",
          "本机翻译地址规范化后直连回环接口")
    check(try ReadingModelService.address("http://[::1]:8080/v1/").absoluteString == "http://[::1]:8080/v1",
          "支持 IPv6 本机翻译服务")
    rejects({ _ = try ReadingModelService.address("https://127.0.0.1.example.com/v1") }, "本地模式不接受外部域名")
    rejects({ _ = try ReadingModelService.address("http://127.0.0.1:8080/v1/chat/completions") }, "完成接口不误作翻译服务基础地址")
    rejects({ _ = try ReadingModelService.address("http://127.0.0.1:8080/v1?proxy=external") }, "本地翻译拒绝带查询字段的服务地址")
    check(try ReadingModelService.address("https://Example.com/local-compatible/v1/", remote: true).absoluteString ==
          "https://example.com/local-compatible/v1", "远程 API 使用 HTTPS，可填写自定义基础路径")
    rejects({ _ = try ReadingModelService.address("http://example.com/v1", remote: true) }, "远程密钥必须走 HTTPS")
    rejects({ _ = try ReadingModelService.address("https://name@example.com/v1", remote: true) }, "拒绝在 API 地址中嵌入凭据")

    let runtime = root.appendingPathComponent(".build/pdf-translation-runtime")
    let worker = runtime.appendingPathComponent("venv/bin/pdf2zh_next")
    var trial = ReadingTranslationSettings(serviceURL: "http://localhost:11588/v1/", model: "qwen2.5:3b",
                                           pdfTool: worker.path)
    let savedConnection = try trial.connection()
    check(trial.hasLocalTrial && LocalOllamaTrial(base: savedConnection.base, pdfTool: worker.path)?.directory.path == runtime.path,
          "已保存的试译配置可定位到本机模型目录")
    trial.serviceURL = "http://127.0.0.1:11434/v1"
    check(!trial.hasLocalTrial, "其他端口的本地服务仍由使用者管理")
    trial.serviceURL = "http://127.0.0.1:11588/v1"
    trial.pdfTool = "/opt/homebrew/bin/pdf2zh_next"
    check(!trial.hasLocalTrial, "普通 PDF 引擎路径不触发试译服务启动")

    let legacy = Data(#"{"serviceURL":"http://127.0.0.1:11588/v1","model":"qwen2.5:3b","target":"zh-CN","pdfSource":"en"}"#.utf8)
    let settings = try JSONDecoder().decode(ReadingTranslationSettings.self, from: legacy)
    check(!settings.isRemote && settings.selectedModel == "qwen2.5:3b" && settings.rules.field == .general,
          "旧版设置从本机模型和通用领域继续")
    var customized = settings
    customized.guidance = TranslationGuidance(field: .cognition, prompt: "保留英文原词", terminology: "retrieval practice = 提取练习")
    check(try customized.rules.terms().first?.target == "提取练习" && settings.pdfProfile != customized.pdfProfile &&
          settings.passageProfile != customized.passageProfile, "专业领域和提示词影响译文缓存，术语表可用于两种翻译")
    rejects({ _ = try TranslationGuidance(terminology: "term = 术语\nterm = 名词").terms() }, "同一术语的冲突译法在保存时提示")

    let mixed = "這代表我們會討論記憶鞏固（PDF 7、STDP、[$1]）"
    check(TranslationLanguage.chinese.normalize(mixed) == "这代表我们会讨论记忆巩固（PDF 7、STDP、[$1]）" &&
          TranslationLanguage.traditionalChinese.normalize(mixed) == mixed && TranslationLanguage.japanese.normalize(mixed) == mixed,
          "简体字形规范保留引文、编号和占位符，其他目标语言沿用原译文")

    var gesture = PDFComparisonScroll()
    check(gesture.turn(delta: -70, axis: .vertical, timestamp: 1, precise: true, atEdge: false, canTurn: true) == nil &&
          gesture.turn(delta: -32, axis: .vertical, timestamp: 1.1, precise: true, atEdge: true, canTurn: true) == nil &&
          gesture.turn(delta: -28, axis: .vertical, timestamp: 1.2, precise: true, atEdge: true, canTurn: true) == .init(step: 1, fromBottom: false) &&
          gesture.blocksMomentum &&
          gesture.turn(delta: -80, axis: .vertical, timestamp: 1.7, precise: true, atEdge: true, canTurn: true) == nil,
          "翻页手势先走完当前页，触边后继续滚动才翻页，一次触控只翻一页")
    gesture.begin()
    check(gesture.turn(delta: 1, axis: .vertical, timestamp: 2, precise: false, atEdge: true, canTurn: true) == .init(step: -1, fromBottom: true) &&
          gesture.turn(delta: -1, axis: .horizontal, timestamp: 3, precise: false, atEdge: true, canTurn: false) == nil,
          "鼠标向上翻页抵达前一页底部，首尾页保留边界")

    let plan = PDFTranslationFollow(page: 4, pageCount: 14, automatic: true, manual: false)
    check(plan.pages == [4, 5] && plan.next(available: { _ in false }, failed: []) == 4 &&
          plan.next(available: { $0 == 4 }, failed: []) == 5 &&
          plan.next(available: { [4, 5].contains($0) }, failed: []) == nil, "跟读优先当前页，只预译紧接着的一页")
    check(plan.next(available: { _ in false }, failed: [4]) == nil, "当前页失败后不会重复自动请求或越过它")
    check(PDFTranslationFollow(page: 13, pageCount: 14, automatic: true, manual: false).pages == [13] &&
          PDFTranslationFollow(page: 4, pageCount: 14, automatic: false, manual: true).pages == [4] &&
          PDFTranslationFollow(page: 4, pageCount: 14, automatic: false, manual: false).pages.isEmpty,
          "末页和手动单页翻译不会额外排队")
    check(PDFTranslationHeadings.changed(source: "2. Memory traces\n2.1 Memory structure",
                                         translation: "2.1 记忆痕迹\n2.2 记忆结构") &&
          !PDFTranslationHeadings.changed(source: "2. Memory traces\n2.1 Memory structure\n7 https://example.com/source",
                                          translation: "2．记忆痕迹\n2.1 记忆结构"),
          "对照提示章节编号实质变化，全角标点不误报")

    let sourceURL = root.appendingPathComponent("原文.pdf")
    let translatedURL = root.appendingPathComponent("现成译文.pdf")
    try writeReadingPDF(sourceURL)
    try writeReadingPDF(translatedURL, suffix: " — translated")
    let sourceRevision = try PDFReader.fingerprint(sourceURL)
    let document = TranslationDocument(itemID: UUID(), revision: sourceRevision)
    let source = PDFTranslationSource(document: document, url: sourceURL, pageCount: 3)
    let archive = ReadingTranslationArchive(root: root.appendingPathComponent("Translations"))

    let pdf = PDFDocument(url: sourceURL)!
    let outline = PDFOutline()
    let author = PDFOutline()
    author.label = "PDF 自带标题"
    author.destination = PDFDestination(page: pdf.page(at: 0)!, at: CGPoint(x: 42, y: 620))
    outline.insertChild(author, at: 0)
    pdf.outlineRoot = outline
    let item = ReadingItem(title: "原文", target: sourceURL.path)
    let store = ReadingStore(directory: root.appendingPathComponent("AuthorOutline"), refreshOnLoad: false)
    _ = store.commit { $0.items = [item] }
    let reader = PDFReader(item: item, url: sourceURL, revision: sourceRevision, document: pdf, store: store)
    var draft = reader.outlineForEditing
    check(draft.first?.title == "PDF 自带标题", "PDF 内置目录进入校准编辑器")
    if let index = draft.indices.first {
        draft[index].title = "校准后的标题"
        check(reader.saveOutline(draft) && reader.navigationSections.first?.title == "校准后的标题" &&
              pdf.outlineRoot?.child(at: 0)?.label == "PDF 自带标题", "校准结果保存在漫读并作为导航目录")
        check(reader.restoreAuthorOutline() && reader.navigationSections.first?.title == "PDF 自带标题",
              "恢复 PDF 自带目录后清除漫读的覆盖目录")
    }

    let request = TranslationPassage(text: "The rate rose by 2.5% [12].", title: "阅读测试", place: "PDF 第 2 页", document: document)
    let valid = PassageTranslation(source: request.text, translated: "比率上升了 2.5% [12]。")
    let invalid = PassageTranslation(source: request.text, translated: "比率上升了 2.5% [13]。")
    check(!valid.checkReferences && invalid.checkReferences, "译文中改动引文编号会提示核对")
    check(PassageTranslation(source: "The formula is $x=2$.", translated: "公式是 $x=3$。").checkReferences,
          "译文中改变内嵌公式会提示核对")

    try archive.save(valid, source: request, language: .chinese)
    let reopenedArchive = ReadingTranslationArchive(root: archive.root)
    let different = TranslationPassage(text: request.text, title: request.title, place: request.place,
                                      document: TranslationDocument(itemID: document.itemID,
                                                                    revision: String(repeating: "d", count: 64)))
    check(reopenedArchive.cached(request, language: .chinese) == valid &&
          reopenedArchive.cached(request, language: .japanese) == nil &&
          reopenedArchive.cached(different, language: .chinese) == nil,
          "原文版本和译文语言共同决定段落译文缓存")
    try archive.save(invalid, source: request, language: .chinese, profile: customized.passageProfile)
    check(archive.cached(request, language: .chinese, profile: customized.passageProfile) == invalid &&
          archive.cached(request, language: .chinese, profile: settings.passageProfile) == nil &&
          archive.cached(request, language: .chinese) == valid, "切换翻译配置后读取各自的句段译文")

    let entire = try archive.importPDF(translatedURL, for: source, scope: .document)
    check(entire.imported && entire.pages == 0..<3 && entire.translatedPage(for: 2) == 2 &&
          entire.url != translatedURL && reopenedArchive.pdf(source, scope: .document)?.id == entire.id,
          "导入译文在同一条原文下以本地副本保存，重开后仍可按页对照")

    let partialURL = root.appendingPathComponent("第二页译文.pdf")
    let manual = PDFDocument(url: translatedURL)!
    let one = PDFDocument()
    one.insert(manual.page(at: 1)!, at: 0)
    check(one.write(to: partialURL), "构造按页试译样本")
    let partial = try archive.importPDF(partialURL, for: source, scope: .page(1), target: .chinese)
    check(partial.pages == 1..<2 && partial.translatedPage(for: 1) == 0 && partial.translatedPage(for: 0) == nil &&
          archive.pdf(source, scope: .document)?.id == entire.id,
          "第二页的单页译文不错误挂到首页，也不替代整篇对照")
    let withPrompt = try archive.importPDF(partialURL, for: source, scope: .page(1), target: .chinese, profile: customized.pdfProfile)
    check(archive.generatedPDF(source, scope: .page(1), settings: customized)?.id == withPrompt.id &&
          archive.generatedPDF(source, scope: .page(1), settings: settings) == nil &&
          archive.pdf(source, scope: .page(1))?.id == partial.id,
          "同一页可保留上一种译文，按当前提示词查找缓存")

    rejects({ _ = try archive.importPDF(partialURL, for: source, scope: .document) }, "页数不符拒绝关联")
    rejects({ _ = try archive.importPDF(sourceURL, for: source, scope: .document) }, "误选原 PDF 不替换可用译文")
    let wideURL = root.appendingPathComponent("错版译文.pdf")
    try writeReadingPDF(wideURL, suffix: " — translated", pageWidth: 1_200)
    rejects({ _ = try archive.importPDF(wideURL, for: source, scope: .document) }, "同页数的双页或错版式结果也拒绝关联")
    check(archive.pdf(source, scope: .document)?.id == entire.id, "导入失败后旧对照仍可使用")

    try archive.removePDF(source, scope: .page(1))
    check(archive.pdf(source, scope: .page(1)) == nil && files.fileExists(atPath: partialURL.path) &&
          files.fileExists(atPath: translatedURL.path) && archive.pdf(source, scope: .document)?.id == entire.id,
          "移除单页译文只清除相应的漫读副本")
    check(archive.generatedPDF(source, scope: .page(1), settings: customized)?.id == withPrompt.id,
          "移除旧译文不会删除用新配置生成的同页译文")

    try writeReadingPDF(sourceURL, suffix: " version 2")
    let updated = PDFTranslationSource(document: TranslationDocument(itemID: document.itemID,
                                                  revision: try PDFReader.fingerprint(sourceURL)),
                                      url: sourceURL, pageCount: 3)
    check(archive.pdf(updated, scope: .document) == nil, "原 PDF 变更后不沿用旧译文")
    rejects({ _ = try archive.importPDF(translatedURL, for: source, scope: .document) }, "生成期间原文变更时拒绝保存旧对照")
}

private func checkSentenceReading(in root: URL) throws {
    func sentences(_ text: String) -> [String] {
        ReadingSentence.ranges(in: text).map { (text as NSString).substring(with: $0) }
    }

    check(sentences("他写道：“论证要回到原文。”〔2〕（P87）这就是下一句。") ==
          ["他写道：“论证要回到原文。”〔2〕（P87）", "这就是下一句。"],
          "点句保留中文引号、尾随引文编号和引文页码")
    check(sentences("See Fig. 2 for the\n2.5% increase [12]. Here is why.") ==
          ["See Fig. 2 for the\n2.5% increase [12].", "Here is why."],
          "点句识别缩写、小数与跨行英文原句")
    check(sentences("章节标题\n \n这句引用𠀀字。下一句。") == ["章节标题", "这句引用𠀀字。", "下一句。"],
          "段落边界保留，含扩展汉字时仍按原文偏移定位")

    let full = "这一句介绍背景。由此可见，论证还应回到原文核对。最后一句。"
    let preview = "由此可见，论证还应回到…"
    let visible = ReadingSentence.visibleRanges(in: preview, from: full)
    check(visible.count == 1 && (preview as NSString).substring(with: visible[0].visible) == "由此可见，论证还应回到" &&
          (full as NSString).substring(with: visible[0].source) == "由此可见，论证还应回到原文核对。",
          "折叠速览截断的行仍命中原段中的完整句")

    let url = root.appendingPathComponent("点句双栏.pdf")
    var bounds = CGRect(x: 0, y: 0, width: 610, height: 750)
    guard let context = CGContext(url as CFURL, mediaBox: &bounds, nil) else { throw InputError.invalid("无法绘制双栏测试样本。") }
    context.beginPDFPage(nil)
    func line(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat = 12) {
        let attributes = [kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, size, nil)]
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
    }
    line("Begin here. Evidence for the actual claim", x: 58, y: 680)
    line("The right column starts on the same line.", x: 331, y: 680)
    line("wrapped across the page, see Fig. 2 [12].", x: 58, y: 665)
    line("It has its own sentence in this line.", x: 331, y: 665)
    line("The next sentence stays separate.", x: 58, y: 650)
    line("Other claims belong to the right column.", x: 331, y: 650)
    context.endPDFPage()
    context.beginPDFPage(nil)
    context.endPDFPage()
    let headings = [("2.", "2.1"), ("2.", "2.1"), ("2.1", "2.2")]
    for (index, pair) in headings.enumerated() {
        context.beginPDFPage(nil)
        line("\(pair.0) Memory traces", x: 60, y: 670)
        line("\(pair.1) Memory structure", x: 60, y: 620)
        line("A body line wide enough to supply the normal size of the running text.", x: 60, y: 580)
        if index == 0 { line("14 Available at the archive", x: 60, y: 78, size: 6) }
        context.endPDFPage()
    }
    context.beginPDFPage(nil)
    line("Figure 1: Memory traces represent groups of neurons", x: 90, y: 640)
    line("that become active again when a memory is retrieved.", x: 90, y: 625)
    line("2.2 How retrieval works", x: 61, y: 605, size: 14)
    line("This line belongs to the following section, below the figure caption.", x: 61, y: 587)
    context.endPDFPage()
    context.closePDF()

    guard let pdf = PDFDocument(url: url), let page = pdf.page(at: 0) else {
        throw InputError.invalid("无法读取双栏测试样本。")
    }
    func hit(_ word: String, on page: PDFPage) -> PDFSentenceHit? {
        guard let text = page.string else { return nil }
        let offset = (text as NSString).range(of: word).location
        guard offset != NSNotFound else { return nil }
        let glyph = page.characterBounds(at: offset + 1)
        return page.sentence(at: CGPoint(x: glyph.midX, y: glyph.midY))
    }
    let wrapped = hit("wrapped", on: page)
    check(wrapped?.text == "Evidence for the actual claim wrapped across the page, see Fig. 2 [12]." && wrapped?.selections.count == 2,
          "PDF 点击跨行句只取左栏相邻两行，保留选区和引文")
    check(hit("own sentence", on: page)?.text == "It has its own sentence in this line.", "PDF 点击右栏不混入同一行的左栏文字")
    check(page.sentence(at: CGPoint(x: 300, y: 670)) == nil && pdf.page(at: 1)?.sentence(at: CGPoint(x: 80, y: 680)) == nil,
          "空白和无文字的 PDF 页不会命中原句")
    check(!PDFTranslationHeadings.changed(on: pdf.page(at: 2), comparedWith: pdf.page(at: 3)) &&
          PDFTranslationHeadings.changed(on: pdf.page(at: 2), comparedWith: pdf.page(at: 4)),
          "版式核对忽略页脚小号引文编号，并识别正文标题编号变化")
    if let captionPage = pdf.page(at: 5), let text = captionPage.string {
        let offset = (text as NSString).range(of: "Memory traces").location
        let glyph = offset == NSNotFound ? CGRect.zero : captionPage.characterBounds(at: offset)
        let caption = captionPage.paragraph(at: CGPoint(x: glyph.midX, y: glyph.midY))
        check(caption?.text == "Figure 1: Memory traces represent groups of neurons that become active again when a memory is retrieved."
              && caption?.selections.count == 2, "图注重译取完整原段，在相邻数字章节标题前停止")
    } else {
        throw InputError.invalid("无法读取图注样本。")
    }

    let chineseURL = root.appendingPathComponent("点句中文.pdf")
    try writeChineseReadingFixture(chineseURL)
    guard let chinese = PDFDocument(url: chineseURL), let chinesePage = chinese.page(at: 1) else {
        throw InputError.invalid("无法读取中文测试样本。")
    }
    let chineseSentence = "读长文时，先找到作者正在回答的问题，才知道该在什么地方停下来。"
    check(hit("才知道", on: chinesePage)?.text == chineseSentence && hit("方停下来", on: chinesePage)?.text == chineseSentence,
          "中文 PDF 跨行断词的前半句和后半句都命中同一原句")

    let pending = PDFOutlineCandidate(title: "第一节 如何把问题写下米", location: PDFReadingLocation(page: 1), needsReview: true)
    let confirmed = PDFOutlineCandidate(title: "第一章 阅读的起点", location: PDFReadingLocation(page: 1))
    let candidates = try PDFOutlineCalibration.candidates(in: chinese, entries: [confirmed, pending])
    check(candidates.count == 2 && candidates.first?.id == pending.id &&
          candidates.first?.options.first?.title == "第一节 如何把问题写下来",
          "AI 校准优先看待核对项，也能校准已定位条目")
    let suggested = try PDFOutlineCalibration.matches(in: #"{"matches":[{"entry":1,"option":1},{"entry":2,"option":1}]}"# + "\"", candidates: candidates)
    check(suggested[pending.id]?.location.page == 1 && suggested[pending.id]?.location.point != nil &&
          suggested[confirmed.id]?.location.point != nil && confirmed.location?.point == nil,
          "已定位条目的校准建议使用原文坐标，原条目仍待采用")
    rejects({ _ = try PDFOutlineCalibration.matches(in: #"{"matches":[{"entry":1,"option":99}]}"#, candidates: candidates) },
            "拒绝模型自行编造的目录位置")
    let inventory = try PDFOutlineCalibration.inventory(in: chinese)
    guard let chapter = inventory.options.firstIndex(where: { $0.title == "第一章 阅读的起点" }),
          let section = inventory.options.firstIndex(where: { $0.title == "第一节 如何把问题写下来" }) else {
        throw InputError.invalid("生成目录未保留已验证的正文标题。")
    }
    let generated = try PDFOutlineCalibration.generation(
        in: "{\"headings\":[{\"id\":\(section + 1),\"level\":2},{\"id\":\(chapter + 1),\"level\":1}]}",
        options: inventory.options
    )
    check(generated.map(\.title) == ["第一章 阅读的起点", "第一节 如何把问题写下来"] &&
          generated.map(\.depth) == [0, 1] && generated.allSatisfy({ $0.location?.point != nil }),
          "AI 生成目录以原文顺序和坐标为准，并接受两级章节")
    rejects({ _ = try PDFOutlineCalibration.generation(in: #"{"headings":[{"id":999,"level":1}]}"#, options: inventory.options) },
            "AI 生成目录拒绝候选以外的标题")
    check(PDFOutlineInference.wrappedTitle(head: CGRect(x: 106, y: 405, width: 172, height: 15),
                                          tail: CGRect(x: 157, y: 388, width: 69, height: 15),
                                          body: CGRect(x: 109, y: 360, width: 187, height: 11)),
          "双栏论文居中换行的标题按同一章名处理")
}
