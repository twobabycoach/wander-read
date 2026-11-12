import AppKit
import PDFKit
import SwiftUI

struct PDFReaderView: View {
    @ObservedObject var reader: PDFReader
    @ObservedObject var store: ReadingStore
    @State private var expandedSection: Int?
    @State private var chapters: [PDFChapter] = []
    @State private var inferredSections: [PDFReadingSection]?
    @State private var outlineEditor: OutlineSheet?
    @State private var documentFoldUnit: PDFFoldUnit?
    @State private var readingPageGroup = false
    @State private var sourceChapterPages: [PDFFoldedPage] = []
    @State private var chapterPages: [PDFFoldedPage] = []
    @State private var foldRestore: FoldRestore?
    private struct FoldRestore { let id = UUID(); let position: PDFFoldPosition }
    private struct FoldScroll: Equatable { let id: UUID; let destination: PDFFoldPosition }
    private struct OutlineSheet: Identifiable {
        let id = UUID()
        var manual: PDFOutlineCandidate?
    }
    private struct SplitRequest: Identifiable {
        let id = UUID()
        let choices: [PDFSplitChoice]
    }
    @State private var splitRequest: SplitRequest?

    private enum FoldRow: Identifiable {
        enum ID: Hashable {
            case chapter(Int), page(Int), position(PDFFoldPosition), loading
        }
        case chapter(PDFChapter)
        case page(Int, depth: Int)
        case passage(FoldedPDFPassage, page: Int, depth: Int)
        case notes(PDFFoldedPage, depth: Int)
        case empty(PDFFoldedPage, depth: Int)
        case loading(depth: Int)

        var id: ID {
            switch self {
            case .chapter(let chapter): return .chapter(chapter.id)
            case .page(let index, _): return .page(index)
            case .passage(let passage, let page, _): return .position(PDFFoldPosition(page: page, offset: passage.id))
            case .notes(let page, _): return .position(page.footnotePosition)
            case .empty(let page, _): return .position(PDFFoldPosition(page: page.id))
            case .loading: return .loading
            }
        }
    }
    @State private var openedPassages = Set<String>()
    @State private var openedFootnotes = Set<Int>()
    @State private var loadKey = UUID()
    @State private var loadingPages = false
    @State private var showFullPassages = false
    @State private var related = false
    @State private var notebook = false
    @State private var jumping = false
    @State private var excerptsOnly = false
    @State private var selectingNotes = false
    @State private var selectedNotes = Set<UUID>()
    @StateObject private var transfer = NotebookSendState()
    @StateObject private var relatedSearch = ReadingRelatedSearch()
    @State private var justExcerpted: UUID?
    private var visibleMarks: [PDFReadingMark] {
        reader.marks.reversed().filter { !excerptsOnly || $0.isExcerpt == true }
    }
    private var layout: FocusLayout { (store.library.preferences.focusLayout ?? FocusLayout()).normalized() }
    @State private var pageEntry = ""
    @State private var highlightCopied: UUID?
    @State private var scanEditor: ScanEditorID?
    private struct ScanEditorID: Identifiable { let id: UUID }
    @FocusState private var noteFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if reader.previousVersion {
                Label("PDF 内容已变化。旧批注仍在笔记里，可以重新定位。", systemImage: "info.circle")
                    .font(.system(size: 13))
                    .foregroundColor(Palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Palette.side)
            }
            if reader.selectingRegion {
                HStack {
                    Label("在同一页拖出要保存的区域", systemImage: "crop")
                    Spacer()
                    Button("取消框选") { reader.selectingRegion = false }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
                }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 24).padding(.vertical, 10)
                    .foregroundColor(Palette.green).background(Palette.card)
            }
            Divider()
            HStack(spacing: 0) {
                ZStack {
                    PDFCanvas(reader: reader, background: reader.isFocused ? layout.paper : Palette.side)
                        .accessibilityHidden(reader.showOutline)
                        .frame(maxWidth: reader.isFocused ? layout.width : 920)
                        .frame(maxWidth: .infinity)
                        .background(reader.isFocused ? layout.desk : Palette.side)
                    if reader.showOutline { outline.frame(maxWidth: reader.isFocused ? layout.width : .infinity) }
                }
                if notebook {
                    Divider()
                    notePanel.frame(width: reader.isFocused ? layout.notebookWidth : 310)
                }
            }
            Divider()
            footer
        }
        .foregroundColor(Palette.ink)
        .background(Palette.paper)
        .sheet(isPresented: $transfer.configuring) {
            NotebookExportEditor(store: store, pendingCount: transfer.pending.count) {
                transfer.send(transfer.pending, from: reader.itemID, store: store)
                transfer.pending = []
            }
        }
        .onAppear {
            if reader.revealedNote != nil { setNotebook(true) }
            if reader.showOutline && chapters.isEmpty { resetChapters() }
        }
        .sheet(item: $scanEditor) { PDFScanEditor(reader: reader, noteID: $0.id) }
        .sheet(item: $outlineEditor) { request in
            PDFOutlineEditor(reader: reader, manual: request.manual) {
                documentFoldUnit = .chapter
                readingPageGroup = false
                reader.showOutline = true
                resetChapters()
            }
        }
        .sheet(isPresented: $related) { RelatedReadingView(store: store, anchor: store.activeItem) }
        .task(id: justExcerpted) {
            guard justExcerpted != nil else { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { justExcerpted = nil }
        }
        .sheet(item: $splitRequest) { request in
            splitSheet(request)
        }
        .onChange(of: reader.foldCorrections) { _ in
            if let position = reader.foldPosition { foldRestore = FoldRestore(position: position) }
            chapterPages = reader.correctedFoldPages(sourceChapterPages)
        }
        .onChange(of: reader.isFocused) { focused in
            if focused { setNotebook(false) }
        }
        .onChange(of: reader.revealedNote) { id in
            if id != nil && reader.saveDraft() { excerptsOnly = false; setNotebook(true) }
        }
        .onChange(of: reader.showOutline) { showing in
            if showing {
                reader.selectingRegion = false
                if chapters.isEmpty {
                    resetChapters()
                } else {
                    openCurrentFold()
                }
            } else {
                foldRestore = nil
            }
        }
        .task(id: findingOutline) {
            guard findingOutline else { return }
            let url = reader.url
            let pageCount = reader.document.pageCount
            let worker = Task.detached(priority: .utility) {
                let entries = PDFOutlineBuilder.generate(at: url).filter { !$0.isPending }
                return PDFOutlineCandidate.sections(from: entries, pageCount: pageCount) ?? []
            }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled else { return }
            inferredSections = result
            if !result.isEmpty && !readingPageGroup { resetChapters() }
        }
        .task(id: loadKey) {
            guard let id = expandedSection, let chapter = chapters.first(where: { $0.id == id }) else { return }
            let pages = chapter.pages(total: reader.document.pageCount)
            var nextPages: [PDFFoldedPage] = []
            var pending: PDFFoldedPage?
            loadingPages = true
            for index in pages {
                guard !Task.isCancelled else { return }
                var page = reader.foldedPage(index, in: chapter)
                if var previous = pending {
                    reader.stitchFoldedPages(&previous, &page)
                    nextPages.append(previous)
                }
                pending = page
                if nextPages.count == 4 || (chapterPages.isEmpty && !nextPages.isEmpty) {
                    appendChapterPages(nextPages)
                    nextPages.removeAll(keepingCapacity: true)
                }
                try? await Task.sleep(nanoseconds: 12_000_000)
            }
            if let pending { nextPages.append(pending) }
            if !Task.isCancelled { appendChapterPages(nextPages) }
            if !Task.isCancelled { loadingPages = false }
        }
    }

    private func appendChapterPages(_ pages: [PDFFoldedPage]) {
        guard !pages.isEmpty else { return }
        sourceChapterPages += pages
        chapterPages = reader.correctedFoldPages(sourceChapterPages)
    }

    private var preferredFoldUnit: PDFFoldUnit {
        documentFoldUnit ?? (reader.savedOutline.isEmpty ? store.library.preferences.pdfFoldUnit : .chapter) ?? .chapter
    }
    private var foundOutline: Bool { !reader.savedOutline.isEmpty || inferredSections?.isEmpty == false }
    private var outlineName: String { reader.savedOutline.isEmpty ? "识别目录" : "我的目录" }
    private var findingOutline: Bool {
        reader.showOutline && preferredFoldUnit == .chapter && !reader.hasAuthorOutline &&
            reader.savedOutline.isEmpty && inferredSections == nil
    }

    private var foldUnit: PDFFoldUnit {
        if preferredFoldUnit == .chapter && !reader.hasAuthorOutline && (!foundOutline || readingPageGroup) { return .group }
        return preferredFoldUnit
    }

    private var outlineHint: String {
        if foldUnit == .chapter {
            if reader.hasAuthorOutline { return "按 PDF 目录展开一章，跨页接着读。段落仍能回到原页。" }
            if !reader.savedOutline.isEmpty { return "按已保存的目录展开章节，随时可以核对原页。" }
            return "根据原书目录或正文标题整理。展开可跨页阅读，底部也可切回按页。"
        }
        if reader.hasAuthorOutline { return "按所选页数浏览。也可以切回目录章节。" }
        if findingOutline { return "正在本机查找章节。现在也可以按页段阅读。" }
        if foundOutline { return "已识别章节，可在底部切换。当前按页段阅读。" }
        if inferredSections != nil { return "暂未找到可直接使用的章节。可按页读，或打开「生成目录」查看识别结果。" }
        return "这份 PDF 没有内置目录，可以按页阅读或生成目录。"
    }

    private var groupSize: Int { min(20, max(2, store.library.preferences.pdfFoldPages ?? 3)) }

    private var toolbar: some View {
        HStack(spacing: 14) {
            ReadingIconButton(title: "保存位置并返回漫读", systemImage: "chevron.left", action: leave)
            if !reader.isFocused {
                Text(reader.title).font(.system(size: 14, weight: .semibold)).lineLimit(1).help(reader.title)
            }
            Spacer(minLength: 12)
            Picker("阅读层次", selection: $reader.showOutline) {
                Text("原页").tag(false)
                Text("折叠").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 126)
            Button {
                if notebook && !reader.saveDraft() { return }
                setNotebook(!notebook)
            } label: {
                Label(notebook ? "收起笔记" : "笔记", systemImage: "sidebar.right")
            }
            Button(action: store.toggleReadingFocus) {
                Label(reader.isFocused ? "退出专注" : "专注", systemImage: reader.isFocused ? "arrow.down.right.and.arrow.up.left" : "viewfinder")
            }
            .help("切换专注阅读 ⇧⌘F")
            if !reader.showOutline {
                Button {
                    guard reader.saveDraft() else { return }
                    reader.selectingRegion.toggle()
                } label: { Label(reader.selectingRegion ? "正在框选" : "框选", systemImage: "crop") }
                    .help("框选原页图像，可再识别文字")
            }
            if reader.isFocused { FocusLayoutButton(store: store) }
            if !reader.isFocused {
                Menu {
                    if !reader.hasAuthorOutline {
                        Button(reader.savedOutline.isEmpty ? "生成目录…" : "编辑目录…") { outlineEditor = OutlineSheet() }
                        if !reader.showOutline {
                            Button("从此处加章节…") {
                                let anchor = reader.outlineEntryAtSelection()
                                outlineEditor = OutlineSheet(manual: PDFOutlineCandidate(title: anchor.title, location: anchor.location))
                            }
                        }
                        Divider()
                    }
                    Button("查相似文献") { related = true }
                    Button("用原阅读器打开") {
                        guard reader.flushPosition(force: true), let item = store.activeItem else { return }
                        store.openExternal(item)
                    }
                    if store.activeItem?.canSendToResearch == true {
                        Button("交给研贴摘录") {
                            if let item = store.activeItem { store.sendToResearch(item) }
                        }
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 34)
                .accessibilityLabel("更多阅读操作")
            }

        }
        .buttonStyle(.borderless)
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if reader.showOutline {
                foldUnitMenu
                Picker("折叠深度", selection: $showFullPassages) {
                    Text("原句速览").tag(false)
                    Text("原段").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 148)
                    .help("速览显示段内原句，展开可读同一段全文")
                Toggle("词首强调", isOn: Binding(
                    get: { store.library.preferences.readingWordEmphasis == true },
                    set: { value in store.updatePreferences { $0.readingWordEmphasis = value } }
                )).toggleStyle(.switch).controlSize(.small).tint(Palette.green)
            } else {
                Button {
                    movePage(-1)
                } label: { Image(systemName: "chevron.left").frame(width: 28, height: 28) }
                .accessibilityLabel("上一页")
                .disabled(reader.location.page == 0)
                Button {
                    pageEntry = String(reader.location.page + 1)
                    jumping = true
                } label: {
                    Text("第 \(reader.location.page + 1) / \(reader.document.pageCount) 页")
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                }
                .help("跳到指定 PDF 页")
                .popover(isPresented: $jumping) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("跳到 PDF 页").font(.headline)
                        if let label = reader.printedPageLabel(at: reader.location.page) {
                            Text("当前版面页码 \(label)").font(.system(size: 12)).foregroundColor(Palette.muted)
                        }
                        TextField("页码", text: $pageEntry)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(jump)
                        Button("跳转", action: jump)
                            .disabled(!validPageEntry)
                    }
                    .padding(16)
                    .frame(width: 180)
                }
                Button {
                    movePage(1)
                } label: { Image(systemName: "chevron.right").frame(width: 28, height: 28) }
                .accessibilityLabel("下一页")
                .disabled(reader.location.page + 1 >= reader.document.pageCount)
            }
            Spacer(minLength: 12)
            if !reader.intent.isEmpty && !reader.isFocused {
                Text(reader.intent).foregroundColor(Palette.muted).lineLimit(1).help(reader.intent)
            }
            if !reader.showOutline {
                if reader.hasSelection {
                    ReadingExcerptButton { excerpt() }
                    Button { capture(.annotation, edit: false) } label: { Label("划线", systemImage: "highlighter") }
                        .keyboardShortcut("h", modifiers: [.command, .shift]).help("划线 · ⇧⌘H")
                    Button("查相关") {
                        if let quote = reader.selectedQuote { searchRelated(quote) }
                    }.help("用所选文字查相关原文")
                } else if justExcerpted == nil {
                    Text("选中文字可摘录").font(.system(size: 12)).foregroundColor(Palette.muted)
                }
                Button {
                    capture(.annotation, edit: true, pageOnly: !reader.hasSelection)
                } label: {
                    Label(reader.hasSelection ? "批注" : "页边记", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .help("选中文字后批注，也可直接在当前页写一笔")
            }
            Button { capture(.detour, edit: true) } label: { Label("先放这里", systemImage: "tray.and.arrow.down") }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            if let justExcerpted {
                ReadingExcerptNotice { revealExcerpt(justExcerpted) }
            }
            if reader.canUndo {
                ReadingIconButton(title: "撤销笔记改动", systemImage: "arrow.uturn.backward") {
                    if reader.saveDraft() { reader.undo(); justExcerpted = nil }
                }
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 13))
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    private var foldUnitMenu: some View {
        Menu {
            Button("按文档自动") { setFoldUnit(nil) }
            if reader.hasAuthorOutline { Button("目录章节") { setFoldUnit(.chapter) } }
            else if foundOutline || inferredSections == nil {
                Button(foundOutline ? outlineName : "尝试识别正文目录") { setFoldUnit(.chapter) }
            }
            Button("单页") { setFoldUnit(.page) }
            Menu("连续页段") {
                ForEach([2, 3, 5, 10, 20], id: \.self) { count in
                    Button("每 \(count) 页") { setFoldUnit(.group, pages: count) }
                }
            }
            if !reader.hasAuthorOutline {
                Divider()
                Button(reader.savedOutline.isEmpty ? "生成目录…" : "编辑目录…") { outlineEditor = OutlineSheet() }
            }
        } label: {
            Label(foldUnit == .group ? "每 \(groupSize) 页" : foldUnit == .chapter && !reader.hasAuthorOutline ? outlineName : foldUnit.title, systemImage: "list.bullet.indent")
        }.menuStyle(.borderlessButton).fixedSize().help("选择折叠单位")
    }

    private var outline: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("折叠阅读").font(.system(size: 34, weight: .medium, design: .serif))
                                Spacer()
                                if !reader.hasAuthorOutline {
                                    Button { outlineEditor = OutlineSheet() } label: {
                                        Label(reader.savedOutline.isEmpty ? "生成目录…" : "编辑目录…", systemImage: "list.bullet.rectangle")
                                            .font(.system(size: 13, weight: .medium)).padding(.vertical, 5)
                                    }.buttonStyle(.borderless)
                                }
                            }
                            Text(outlineHint)
                                .font(.system(size: 14)).foregroundColor(Palette.muted)
                        }.padding(.bottom, 24)
                        ForEach(foldRows) { row in
                            foldRow(row).id(row.id)
                        }
                    }
                    .frame(maxWidth: reader.isFocused ? layout.width : 720, alignment: .leading)
                    .padding(.horizontal, 26).padding(.vertical, 26).frame(maxWidth: .infinity)
                }
                .coordinateSpace(name: "folded-reading")
                .onAppear {
                    if foldRestore == nil, let id = expandedSection { proxy.scrollTo(FoldRow.ID.chapter(id), anchor: .top) }
                }
                .task(id: readyFoldScroll) {
                    guard let request = readyFoldScroll else { return }
                    await Task.yield()
                    guard !Task.isCancelled, foldRestore?.id == request.id else { return }
                    proxy.scrollTo(FoldRow.ID.position(request.destination), anchor: .top)
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    if !Task.isCancelled && foldRestore?.id == request.id { foldRestore = nil }
                }
                .onPreferenceChange(FoldRowFrames.self) { frames in
                    DispatchQueue.main.async { updateFoldPosition(frames, height: viewport.size.height) }
                }
            }
        }.background(reader.isFocused ? layout.paper : Palette.paper)
            .accessibilityIdentifier("PDFOutline")
    }

    private var readyFoldScroll: FoldScroll? {
        guard let request = foldRestore, let page = chapterPages.first(where: { $0.id == request.position.page }) else { return nil }
        if let offset = request.position.offset, page.footnotes.contains(where: { NSLocationInRange(offset, $0.range) }) {
            return FoldScroll(id: request.id, destination: page.footnotePosition)
        }
        let chapter = chapters.first { $0.id == expandedSection }
        for candidate in chapterPages.reversed() where candidate.id <= page.id {
            if let passage = bodyPassages(on: candidate, in: chapter).first(where: { passage in
                passage.sources(startingOn: candidate.id).contains { source in
                    source.page == page.id && (request.position.offset.map { NSLocationInRange($0, source.range) }
                        ?? (candidate.id != page.id))
                }
            }) {
                return FoldScroll(id: request.id, destination: PDFFoldPosition(page: candidate.id, offset: passage.id))
            }
        }
        let body = bodyPassages(on: page, in: chapter)
        if let passage = body.first {
            return FoldScroll(id: request.id, destination: PDFFoldPosition(page: page.id, offset: passage.id))
        }
        if !page.footnotes.isEmpty { return FoldScroll(id: request.id, destination: page.footnotePosition) }
        return FoldScroll(id: request.id, destination: PDFFoldPosition(page: page.id))
    }

    private func updateFoldPosition(_ frames: [PDFFoldPosition: CGRect], height: CGFloat) {
        guard reader.showOutline, foldRestore == nil else { return }
        let threshold = min(24, height / 4)
        guard let position = frames.filter({ $0.value.maxY > threshold && $0.value.minY < height })
            .min(by: { $0.value.minY < $1.value.minY })?.key,
              reader.foldPosition != position,
              let page = chapterPages.first(where: { $0.id == position.page }) else { return }
        let passage = page.passages.first { $0.id == position.offset } ?? page.footnotes.first { $0.id == position.offset }
        reader.rememberFoldPosition(position, passage: passage)
    }

    private var foldRows: [FoldRow] {
        var rows: [FoldRow] = []
        for chapter in chapters {
            rows.append(.chapter(chapter))
            guard expandedSection == chapter.id else { continue }
            for page in chapterPages {
                let body = bodyPassages(on: page, in: chapter)
                if foldUnit != .page && !body.isEmpty { rows.append(.page(page.id, depth: chapter.depth)) }
                if body.isEmpty { rows.append(.empty(page, depth: chapter.depth)) }
                else { rows += body.map { .passage($0, page: page.id, depth: chapter.depth) } }
                if !page.footnotes.isEmpty { rows.append(.notes(page, depth: chapter.depth)) }
            }
            if loadingPages || chapterPages.isEmpty { rows.append(.loading(depth: chapter.depth)) }
        }
        return rows
    }

    private func bodyPassages(on page: PDFFoldedPage, in chapter: PDFChapter?) -> ArraySlice<FoldedPDFPassage> {
        guard let chapter, chapter.start.page == page.id, chapter.start.point != nil,
              let first = page.passages.first, PDFReader.headingKey(first.text) == PDFReader.headingKey(chapter.title) else {
            return page.passages[...]
        }
        return page.passages.dropFirst()
    }

    @ViewBuilder private func foldRow(_ row: FoldRow) -> some View {
        switch row {
        case .chapter(let chapter):
            VStack(spacing: 0) {
                Divider()
                chapterRow(chapter)
            }
        case .page(let page, let depth):
            Text(reader.pageReference(page))
                .font(.system(size: 11, weight: .medium)).foregroundColor(Palette.muted)
                .monospacedDigit().padding(.top, 14).padding(.bottom, 5)
                .modifier(FoldMargin(depth: depth))
        case .passage(let passage, let page, let depth):
            foldedCard(passage, page: page)
                .contextMenu {
                    let position = PDFFoldPosition(page: page, offset: passage.id)
                    let next = nextPassage(after: position)
                    Button("与下一段合并") {
                        if let next { reader.saveFoldCorrection(PDFFoldCorrection(boundary: next, joinAfter: position)) }
                    }.disabled(next == nil)
                    Button("在这段中拆开…") {
                        let choices = reader.splitChoices(for: passage, page: page)
                        if !choices.isEmpty { splitRequest = SplitRequest(choices: choices) }
                    }.disabled(reader.splitChoices(for: passage, page: page).isEmpty)
                    Button("查这一段的相关文献") { searchRelated(passage.displayText) }
                    Divider()
                    Button("撤销这份 PDF 上次分段调整", action: reader.undoFoldCorrection)
                        .disabled(reader.foldCorrections.isEmpty)
                }
                .modifier(FoldRowPosition(position: PDFFoldPosition(page: page, offset: passage.id)))
                .modifier(FoldMargin(depth: depth))
        case .notes(let page, let depth):
            footnotes(page)
                .modifier(FoldRowPosition(position: page.footnotePosition))
                .modifier(FoldMargin(depth: depth))
        case .empty(let page, let depth):
            if page.hasSourceText {
                Color.clear.frame(height: 0)
            } else {
                HStack {
                    Text("第 \(page.id + 1) 页无文字，可到原页框选识别").font(.system(size: 12)).foregroundColor(Palette.muted)
                    Spacer()
                    Button("看原页") { reveal(PDFReadingLocation(page: page.id)) }.buttonStyle(.plain).foregroundColor(Palette.green)
                }.padding(.vertical, 12)
                    .modifier(FoldMargin(depth: depth))
                    .modifier(FoldRowPosition(position: PDFFoldPosition(page: page.id)))
            }
        case .loading(let depth):
            ProgressView("正在读取本段…").controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .modifier(FoldMargin(depth: depth))
        }
    }

    private func nextPassage(after position: PDFFoldPosition) -> PDFFoldPosition? {
        let chapter = chapters.first { $0.id == expandedSection }
        let visible = chapterPages.flatMap { page in
            bodyPassages(on: page, in: chapter).map { (page.id, $0) }
        }
        guard let index = visible.firstIndex(where: { $0.0 == position.page && $0.1.id == position.offset }),
              visible.indices.contains(index + 1) else { return nil }
        let (page, next) = visible[index + 1]
        guard chapterPages.filter({ (position.page...page).contains($0.id) }).allSatisfy(\.hasSourceText) else { return nil }
        return PDFFoldPosition(page: page, offset: next.id)
    }

    private func splitSheet(_ request: SplitRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择新段的第一行").font(.system(size: 21, weight: .medium, design: .serif))
            Text("下面是原页中的行。选择一行，漫读就从那一行另起一段。")
                .font(.system(size: 13)).foregroundColor(Palette.muted)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(request.choices) { choice in
                        Button {
                            reader.saveFoldCorrection(PDFFoldCorrection(boundary: choice.id))
                            splitRequest = nil
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(reader.pageReference(choice.id.page)).font(.system(size: 11)).foregroundColor(Palette.muted)
                                Text(choice.text).font(.system(size: 14)).lineLimit(2)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Divider()
                    }
                }
            }.frame(minHeight: 100)
            HStack {
                Spacer()
                Button("取消") { splitRequest = nil }.buttonStyle(ActionStyle()).keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 550, height: 360)
            .foregroundColor(Palette.ink).background(Palette.paper)
    }

    private func chapterRow(_ chapter: PDFChapter) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button { toggleChapter(chapter) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: expandedSection == chapter.id ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11))
                        Text(chapter.title).font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel((expandedSection == chapter.id ? "收起 " : "展开 ") + chapter.title)
                if foldUnit == .chapter {
                    Text(chapter.pageLabel(total: reader.document.pageCount)).font(.system(size: 12)).foregroundColor(Palette.muted)
                }
                ReadingIconButton(title: "查原页 · " + reader.pageReference(chapter.start.page), systemImage: "arrow.up.right") {
                    store.inspectPDF(reader, at: chapter.start)
                }.foregroundColor(Palette.muted)
            }
        }.padding(.leading, CGFloat(min(4, chapter.depth)) * 12)
            .padding(.vertical, 5)
    }

    private func footnotes(_ page: PDFFoldedPage) -> some View {
        let expanded = openedFootnotes.contains(page.id)
        return VStack(alignment: .leading, spacing: 5) {
            Divider()
            Button {
                if expanded { openedFootnotes.remove(page.id) } else { openedFootnotes.insert(page.id) }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                    Text("本页脚注").font(.system(size: 12, weight: .medium))
                    Text(reader.pageReference(page.id)).font(.system(size: 11)).foregroundColor(Palette.muted)
                }.padding(.vertical, 9).contentShape(Rectangle())
            }.buttonStyle(.borderless).foregroundColor(Palette.muted)
                .accessibilityIdentifier("PDFFootnotes-\(page.id)")
                .accessibilityLabel((expanded ? "收起" : "展开") + "本页脚注 · " + reader.pageReference(page.id))
            if expanded {
                ForEach(page.footnotes) { note in
                    foldedCard(note, page: page.id, isFootnote: true)
                }
            }
        }.padding(.bottom, 8)
    }

    private func foldedCard(_ passage: FoldedPDFPassage, page: Int, isFootnote: Bool = false) -> some View {
        let key = "\(page):\(passage.id)"
        let expanded = isFootnote || showFullPassages || openedPassages.contains(key)
        let full = passage.displayText
        let preview = passage.scanExcerpt
        let text = expanded ? full : preview
        let decorated = !isFootnote && store.library.preferences.readingWordEmphasis == true
            ? ReadingWordEmphasis.format(text) : AttributedString(text)
        let canToggle = !isFootnote && !showFullPassages && preview != full
        let bodySize = reader.isFocused ? layout.textSize : 16
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(decorated).font(.system(size: isFootnote ? max(13, bodySize - 2) : bodySize))
                    .lineSpacing(isFootnote ? 4 : 6).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if canToggle {
                    Button {
                        if expanded { openedPassages.remove(key) }
                        else { openedPassages.insert(key) }
                    } label: {
                        Label(expanded ? "收起" : "展开原段", systemImage: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .medium)).frame(minHeight: 26)
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(Palette.muted)
                }
            }
            HStack(spacing: 0) {
                ReadingIconButton(title: "查原文 · " + reader.pageReference(page), systemImage: "arrow.up.right") {
                    let location = reader.location(of: passage, on: page)
                    store.inspectPDF(reader, at: location, lines: reader.sourceLines(of: passage, page: page),
                                     quote: passage.displayText)
                }
                ReadingIconButton(title: isFootnote ? "摘录脚注" : "摘录原段", systemImage: "quote.opening") {
                    excerpt(passage, page: page)
                }
            }
            .foregroundColor(Palette.muted)
            .padding(.top, -4)
        }.padding(.vertical, 10)
    }

    private func setFoldUnit(_ unit: PDFFoldUnit?, pages: Int? = nil) {
        if store.commit({
            $0.preferences.pdfFoldUnit = unit
            if let pages { $0.preferences.pdfFoldPages = pages }
        }) {
            if !reader.savedOutline.isEmpty { documentFoldUnit = unit }
            readingPageGroup = false
            resetChapters()
        }
    }

    private func resetChapters() {
        chapters = reader.chapters(unit: foldUnit, groupSize: groupSize, inferred: inferredSections ?? [])
        openCurrentFold(reload: true)
    }

    private func openCurrentFold(reload: Bool = false) {
        let chapter = reader.chapterAt(reader.location, in: chapters)
        let current = !reader.hasAuthorOutline && chapter?.id == -1 && reader.foldPosition == nil ? nil : chapter
        if reload || current?.id != expandedSection { expand(current) }
        guard let current, current.pages(total: reader.document.pageCount).contains(reader.location.page) else { return }
        if let saved = reader.foldPosition, saved.page == reader.location.page {
            foldRestore = FoldRestore(position: saved)
        } else if reader.location.page > current.start.page {
            foldRestore = FoldRestore(position: PDFFoldPosition(page: reader.location.page))
        }
    }

    private func toggleChapter(_ chapter: PDFChapter) {
        if findingOutline { readingPageGroup = true }
        expand(expandedSection == chapter.id ? nil : chapter)
    }

    private func expand(_ chapter: PDFChapter?) {
        expandedSection = chapter?.id
        foldRestore = nil
        sourceChapterPages = []
        chapterPages = []
        openedPassages = []
        loadingPages = chapter != nil
        loadKey = UUID()
    }

    private var notePanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let draft = reader.noteDraft {
                        Text(reader.editingNote ? "编辑笔记" : draft.kind == .detour ? "先放这里" : "留一句想法")
                            .font(.system(size: 22, weight: .medium, design: .serif))
                        if let data = draft.scan?.jpeg, let image = NSImage(data: data) {
                            Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 120).accessibilityLabel("框选原图")
                        }
                        if !draft.quote.isEmpty { quote(draft.quote) }
                        TextField(draft.kind == .detour ? "想查什么？也可以贴网址" : "你的想法", text: $reader.draftText, axis: .vertical)
                            .lineLimit(3...8)
                            .textFieldStyle(.roundedBorder)
                            .focused($noteFocused)
                            .accessibilityLabel("笔记内容")
                        HStack {
                            Button("取消", action: reader.discardDraft)
                                .keyboardShortcut(.cancelAction)
                            Spacer()
                            Button("保存") { _ = reader.saveDraft() }
                                .keyboardShortcut(.defaultAction)
                                .buttonStyle(.borderedProminent)
                                .disabled(draft.kind == .detour && reader.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.quote.isEmpty)
                        }
                        Divider()
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("这一篇的笔记").font(.system(size: 21, weight: .medium, design: .serif))
                            Spacer()
                            if !reader.marks.isEmpty {
                                Button(selectingNotes ? "完成" : "批量") {
                                    selectingNotes.toggle()
                                    selectedNotes = []
                                }.buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundColor(Palette.green)
                            }
                        }
                        NotebookDeliveryStatus(transfer: transfer) { store.openNotebook(reader.itemID) }
                        if reader.marks.isEmpty {
                            Text("划下想留下的一句，或把读到一半冒出来的念头暂放在这里。")
                                .font(.system(size: 13))
                                .foregroundColor(Palette.muted)
                                .lineSpacing(4)
                        }
                    }
                    ReadingRelatedSidebar(search: relatedSearch, store: store, itemID: reader.itemID,
                                          suggestedQuery: reader.intent, keep: keepRelated)
                        .id("reading-related")
                    if !reader.marks.isEmpty {
                        Picker("笔记范围", selection: $excerptsOnly) { Text("全部").tag(false); Text("摘录").tag(true) }
                            .pickerStyle(.segmented).labelsHidden()
                    }
                    if selectingNotes && !visibleMarks.isEmpty {
                        NotebookBatchControls(visible: Set(visibleMarks.map(\.id)), selected: $selectedNotes,
                                              send: send, remove: { reader.saveDraft() && reader.remove($0) })
                    }
                    let sent = store.deliveredNotes(for: reader.itemID)
                    ForEach(visibleMarks) { mark in noteCard(mark, sent: sent.contains(mark.id)).id(mark.id) }
                }
                .padding(20)
            }
            .onAppear {
                if let id = reader.revealedNote { proxy.scrollTo(id, anchor: .top) }
            }
            .onChange(of: reader.revealedNote) { id in
                if let id = id { proxy.scrollTo(id, anchor: .top) }
            }
            .onChange(of: relatedSearch.requestID) { _ in proxy.scrollTo("reading-related", anchor: .top) }
        }
        .background(reader.isFocused ? layout.notes : Palette.side)
    }

    private func quote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, design: .serif))
            .foregroundColor(Palette.muted)
            .lineSpacing(4)
            .textSelection(.enabled)
    }

    private func noteCard(_ mark: PDFReadingMark, sent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if selectingNotes { NotebookSelectionToggle(id: mark.id, selected: $selectedNotes) }
                if !mark.lines.isEmpty {
                    Circle().fill(Color((mark.color ?? .yellow).color)).frame(width: 8, height: 8)
                        .accessibilityLabel((mark.color ?? .yellow).title)
                }
                Text(mark.scan != nil ? "图摘" : mark.isExcerpt == true ? "摘录" : mark.kind == .detour ? "暂放" : mark.lines.isEmpty ? "页边记" : "批注")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Palette.green)
                Spacer()
                Text(mark.revision == reader.revision ? reader.pageReference(mark.location.page) : "旧版本 · 待定位")
                    .font(.system(size: 11))
                    .foregroundColor(Palette.muted)
            }
            if let data = mark.scan?.jpeg, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 135)
                    .clipShape(RoundedRectangle(cornerRadius: 5)).accessibilityLabel("框选原图")
                Button(mark.quote.isEmpty ? "识别文字" : "校对文字") {
                    if reader.saveDraft() { scanEditor = ScanEditorID(id: mark.id) }
                }.buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundColor(Palette.green)
            }
            if !mark.note.isEmpty { Text(mark.note).font(.system(size: 14)).textSelection(.enabled) }
            if !mark.quote.isEmpty { quote(mark.quote).lineLimit(4) }
            HStack {
                if mark.revision == reader.revision {
                    Button("查原文") {
                        store.inspectPDF(reader, at: mark.location, lines: mark.lines, note: mark.id, quote: mark.quote)
                    }
                } else if mark.scan == nil {
                    Button(mark.quote.isEmpty ? "定位到此页" : "用选中文字定位") { relocate(mark) }
                        .disabled(reader.showOutline || (!mark.quote.isEmpty && !reader.hasSelection))
                }
                Spacer()
                NotebookSendButton(sent: sent) { if sent { store.openNotebook(reader.itemID, noteID: mark.id) } else { send([mark.id]) } }
                if mark.isExcerpt == true {
                    Button { copy(mark) } label: { Image(systemName: highlightCopied == mark.id ? "checkmark" : "doc.on.doc") }
                        .accessibilityLabel("复制摘录与出处").help("复制摘录与出处")
                }
                Menu {
                    Button("编辑想法") { edit(mark) }
                    Button("Obsidian 收件与模板…", action: transfer.openSetup)
                    if !mark.lines.isEmpty {
                        Menu("划线颜色") {
                            ForEach(PDFMarkColor.allCases, id: \.self) { color in
                                Button(color.title) { reader.setColor(color, for: mark) }
                            }
                        }
                    }
                    Button(highlightCopied == mark.id ? "已复制" : "复制笔记") { copy(mark) }
                    Button("移除", role: .destructive) { reader.remove(mark.id) }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .frame(width: 26)
                .accessibilityLabel("管理这条笔记")
            }
            .font(.system(size: 12))
            .buttonStyle(.plain)
            .foregroundColor(Palette.green)
        }
        .padding(12)
        .background(reader.revealedNote == mark.id ? Palette.surface : Palette.card)
        .cornerRadius(8)
    }

    private var validPageEntry: Bool {
        Int(pageEntry).map { (1...reader.document.pageCount).contains($0) } ?? false
    }

    private func jump() {
        guard validPageEntry, let page = Int(pageEntry) else { return }
        movePage(page - 1 - reader.location.page)
        jumping = false
    }

    private func movePage(_ delta: Int) {
        reveal(PDFReadingLocation(page: reader.location.page + delta))
    }

    private func reveal(_ location: PDFReadingLocation) {
        reader.showOutline = false
        reader.go(to: location)
    }

    private func setNotebook(_ visible: Bool) {
        guard notebook != visible else { return }
        let position = reader.location
        notebook = visible
        if !visible { reader.revealedNote = nil }
        if !reader.showOutline {
            DispatchQueue.main.async { if !reader.showOutline { reader.go(to: position) } }
        }
    }

    private func capture(_ kind: PDFReadingMark.Kind, edit: Bool, pageOnly: Bool = false) {
        guard reader.saveDraft() else { return }
        do {
            let mark = try reader.draft(kind: kind, pageOnly: pageOnly)
            if edit {
                reader.noteDraft = mark
                reader.draftText = ""
                reader.editingNote = false
                setNotebook(true)
                noteFocused = true
            } else { _ = reader.save(mark) }
        } catch { store.error = error.localizedDescription }
    }

    private func excerpt(_ passage: FoldedPDFPassage? = nil, page: Int? = nil) {
        guard reader.saveDraft() else { return }
        do {
            if let mark = try reader.excerpt(passage, page: page) {
                if notebook { revealExcerpt(mark.id) }
                else { justExcerpted = mark.id }
            }
        } catch { store.error = error.localizedDescription }
    }

    private func revealExcerpt(_ id: UUID) {
        justExcerpted = nil
        guard reader.marks.contains(where: { $0.id == id }) else { return }
        excerptsOnly = false
        setNotebook(true)
        reader.revealedNote = id
    }

    private func searchRelated(_ quote: String) {
        guard reader.saveDraft() else { return }
        relatedSearch.search(quote, store: store, anchor: reader.itemID)
        setNotebook(true)
    }

    private func keepRelated(_ text: String) -> Bool {
        guard reader.saveDraft() else { return false }
        do {
            var mark = try reader.draft(kind: .detour, pageOnly: true)
            mark.note = text
            return reader.save(mark)
        } catch {
            store.error = error.localizedDescription
            return false
        }
    }

    private func edit(_ mark: PDFReadingMark) {
        guard reader.saveDraft() else { return }
        reader.noteDraft = mark
        reader.draftText = mark.note
        reader.editingNote = true
        noteFocused = true
    }

    private func leave() {
        store.leavePDF()
    }

    private func relocate(_ mark: PDFReadingMark) {
        do { _ = try reader.relocate(mark) }
        catch { store.error = error.localizedDescription }
    }

    private func send(_ ids: Set<UUID>) {
        if reader.saveDraft() { transfer.send(ids, from: reader.itemID, store: store) }
    }

    private func copy(_ mark: PDFReadingMark) {
        let place = mark.revision == reader.revision ? reader.pageReference(mark.location.page) : "旧版 PDF 第 \(mark.location.page + 1) 页"
        let text = [reader.title + " · " + place, mark.quote, mark.note].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let board = NSPasteboard.general
        board.clearContents()
        if let jpeg = mark.scan?.jpeg {
            let item = NSPasteboardItem()
            item.setData(jpeg, forType: NSPasteboard.PasteboardType("public.jpeg"))
            item.setString(text, forType: .string)
            if board.writeObjects([item]) { highlightCopied = mark.id }
        } else if board.setString(text, forType: .string) {
            highlightCopied = mark.id
        }
    }
}

private struct FoldMargin: ViewModifier {
    let depth: Int
    func body(content: Content) -> some View {
        content.padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Rectangle().fill(Palette.line).frame(width: 1).accessibilityHidden(true)
            }
            .padding(.leading, CGFloat(min(4, depth)) * 12)
    }
}

private struct FoldRowFrames: PreferenceKey {
    static var defaultValue: [PDFFoldPosition: CGRect] = [:]
    static func reduce(value: inout [PDFFoldPosition: CGRect], nextValue: () -> [PDFFoldPosition: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct FoldRowPosition: ViewModifier {
    let position: PDFFoldPosition
    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                Color.clear.preference(key: FoldRowFrames.self, value: [position: proxy.frame(in: .named("folded-reading"))])
            }
        }
    }
}

struct PDFCanvas: NSViewRepresentable {
    @ObservedObject var reader: PDFReader
    var background = Palette.side

    func makeCoordinator() -> Coordinator { Coordinator(reader: reader) }

    func makeNSView(context: Context) -> PDFReadingSurface {
        let view = LaidOutPDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = NSColor(background)
        view.pageBreakMargins = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        view.document = reader.document
        view.autoScales = true
        reader.attach(view)
        view.onFirstLayout = { [weak reader, weak view] in
            guard let view = view else { return }
            reader?.restoreAfterLayout(in: view)
        }
        let surface = PDFReadingSurface(pdf: view, reader: reader)
        context.coordinator.observe(view, highlights: surface.highlights)
        return surface
    }

    func updateNSView(_ view: PDFReadingSurface, context: Context) {
        view.pdf.backgroundColor = NSColor(background)
        view.highlights.needsDisplay = true
        view.regionOverlay.refresh()
    }

    static func dismantleNSView(_ view: PDFReadingSurface, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject {
        private weak var reader: PDFReader?
        private var observers: [NSObjectProtocol] = []

        init(reader: PDFReader) { self.reader = reader }

        func observe(_ view: PDFView, highlights: NSView) {
            let click = NSClickGestureRecognizer(target: self, action: #selector(revealClickedMark(_:)))
            click.delaysPrimaryMouseButtonEvents = false
            view.addGestureRecognizer(click)
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: .PDFViewSelectionChanged, object: view, queue: .main) { [weak self] _ in
                self?.reader?.selectionChanged()
            })
            for name in [Notification.Name.PDFViewPageChanged, .PDFViewVisiblePagesChanged, .PDFViewScaleChanged] {
                observers.append(center.addObserver(forName: name, object: view, queue: .main) { [weak self, weak highlights] _ in
                    self?.reader?.visiblePositionChanged()
                    highlights?.needsDisplay = true
                })
            }
            if let clip = view.documentView?.enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self, weak highlights] _ in
                    self?.reader?.visiblePositionChanged()
                    highlights?.needsDisplay = true
                })
            }
        }

        @objc private func revealClickedMark(_ gesture: NSClickGestureRecognizer) {
            guard let view = gesture.view as? PDFView else { return }
            reader?.revealAnnotation(at: gesture.location(in: view), in: view)
        }

        func stop() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
        }

        deinit { stop() }
    }
}

private final class LaidOutPDFView: PDFView {
    var onFirstLayout: (() -> Void)?

    override func layout() {
        super.layout()
        guard window != nil, bounds.width > 0, bounds.height > 0, let ready = onFirstLayout else { return }
        onFirstLayout = nil
        DispatchQueue.main.async(execute: ready)
    }
}


final class PDFReadingSurface: NSView {
    let highlights: NSView
    let pdf: PDFView
    let regionOverlay: PDFRegionOverlay

    init(pdf: PDFView, reader: PDFReader) {
        self.pdf = pdf
        highlights = PDFHighlightSurface(pdf: pdf, reader: reader)
        regionOverlay = PDFRegionOverlay(pdf: pdf, reader: reader)
        super.init(frame: .zero)
        addSubview(pdf)
        addSubview(highlights, positioned: .above, relativeTo: pdf)
        addSubview(regionOverlay, positioned: .above, relativeTo: highlights)
        for child in [pdf as NSView, highlights, regionOverlay] {
            child.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: leadingAnchor),
                child.trailingAnchor.constraint(equalTo: trailingAnchor),
                child.topAnchor.constraint(equalTo: topAnchor),
                child.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
    }

    required init?(coder: NSCoder) { nil }
}

private final class PDFHighlightSurface: NSView {
    private weak var pdf: PDFView?
    private weak var reader: PDFReader?

    init(pdf: PDFView, reader: PDFReader) {
        self.pdf = pdf
        self.reader = reader
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let pdf = pdf, let reader = reader, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.clip(to: bounds)
        context.setBlendMode(.multiply)
        for highlight in reader.highlights(in: pdf) {
            let frame = convert(highlight.rect, from: pdf)
            let color = (highlight.mark.color ?? .yellow).color
            if highlight.mark.scan == nil {
                context.setFillColor(color.withAlphaComponent(0.40).cgColor)
                context.fill(frame)
            } else {
                context.setStrokeColor(color.withAlphaComponent(0.9).cgColor)
                context.setLineWidth(2)
                context.stroke(frame.insetBy(dx: 1, dy: 1))
            }
        }
        context.restoreGState()
    }
}
