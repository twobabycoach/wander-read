import AppKit
import PDFKit
import SwiftUI

struct PDFReaderView: View {
    @ObservedObject var reader: PDFReader
    @ObservedObject var store: ReadingStore
    @State private var expandedSection: Int?
    @State private var chapters: [PDFChapter] = []
    @State private var navigationPresented = false
    @State private var outlineEditor: OutlineSheet?
    @State private var sourceChapterPages: [PDFFoldedPage] = []
    @State private var chapterPages: [PDFFoldedPage] = []
    @State private var foldRestore: FoldRestore?
    @State private var foldLoad: FoldLoad?
    private struct FoldLoad: Equatable {
        let id = UUID()
        let chapterID: Int
        let pages: Range<Int>
        var restore: PDFFoldPosition?
    }
    private struct FoldRestore { let id = UUID(); let position: PDFFoldPosition? }
    private struct FoldScroll: Equatable { let id: UUID; let destination: FoldRow.ID }
    private struct OutlineSheet: Identifiable {
        let id = UUID()
        var manual: PDFOutlineCandidate?
        var reviewPending = false
    }
    private struct SplitRequest: Identifiable {
        let id = UUID()
        let choices: [PDFSplitChoice]
    }
    @State private var splitRequest: SplitRequest?

    private enum FoldRow: Identifiable {
        enum ID: Hashable {
            case chapter(Int), page(Int), position(PDFFoldPosition), loading, earlier, later, nextChapter
        }
        case chapter(PDFChapter)
        case page(Int, depth: Int)
        case passage(FoldedPDFPassage, page: Int, depth: Int)
        case notes(PDFFoldedPage, depth: Int)
        case empty(PDFFoldedPage, depth: Int)
        case loading(depth: Int)
        case earlier(depth: Int)
        case later(depth: Int)
        case nextChapter(PDFChapter)

        var id: ID {
            switch self {
            case .chapter(let chapter): return .chapter(chapter.id)
            case .page(let index, _): return .page(index)
            case .passage(let passage, let page, _): return .position(PDFFoldPosition(page: page, offset: passage.id))
            case .notes(let page, _): return .position(page.footnotePosition)
            case .empty(let page, _): return .position(PDFFoldPosition(page: page.id))
            case .loading: return .loading
            case .earlier: return .earlier
            case .later: return .later
            case .nextChapter: return .nextChapter
            }
        }
    }
    @State private var openedPassages = Set<String>()
    @State private var openedFootnotes = Set<Int>()
    @State private var related = false
    @State private var notebooks = ReaderNotebookVisibility()
    @State private var jumping = false
    @State private var noteFilter = ReadingNoteFilter()
    @State private var selectingNotes = false
    @State private var selectedNotes = Set<UUID>()
    @StateObject private var transfer = NotebookSendState()
    @StateObject private var relatedSearch = ReadingRelatedSearch()
    @StateObject private var translation = ReadingTranslationSession()
    @StateObject private var comparison = PDFComparisonWindowController()
    @State private var openingComparison = false
    @State private var justExcerpted: UUID?
    private var visibleMarks: [PDFReadingMark] {
        if !noteFilter.isFiltering { return Array(reader.marks.reversed()) }
        return reader.marks.reversed().filter {
            $0.id == reader.noteDraft?.id || noteFilter.matches(
                color: $0.lines.isEmpty ? nil : $0.appearance.color, isExcerpt: $0.isExcerpt == true,
                text: $0.quote, $0.note, notePlace($0), ReaderNote($0).kind)
        }
    }
    private var layout: FocusLayout { (store.library.preferences.focusLayout ?? FocusLayout()).normalized() }
    private var notebook: Bool { notebooks[focused: reader.isFocused] || reader.noteDraft != nil }
    private var markAppearance: ReadingMarkAppearance { store.library.preferences.readingMarkAppearance ?? ReadingMarkAppearance() }
    @State private var pageEntry = ""
    @State private var highlightCopied: UUID?
    @State private var scanEditor: ScanEditorID?
    @State private var quoteEditor: ScanEditorID?
    private struct ScanEditorID: Identifiable { let id: UUID }

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
                    PDFCanvas(reader: reader, background: reader.isFocused ? layout.desk : Palette.side,
                              layoutWidth: reader.isFocused ? layout.width : 920, notebook: notebook,
                              sentence: translation.pdfSentence,
                              pointTranslate: translation.pointMode ? translateSentence : nil)
                        .overlay {
                            if !reader.showOutline, !reader.selectingRegion, let anchor = reader.selectionAnchor {
                                ReadingSelectionPalette(
                                    anchor: anchor, appearance: markAppearance, excerpt: { excerpt() },
                                    annotate: { capture(.annotation, edit: true) },
                                    useColor: { excerpt(appearance: ReadingMarkAppearance(color: $0, style: markAppearance.style)) },
                                    setStyle: setMarkStyle, findRelated: searchSelection, copy: copySelection,
                                    translate: translateSelection
                                )
                            }
                        }
                        .accessibilityHidden(reader.showOutline)
                        .frame(maxWidth: reader.isFocused ? layout.width : 920)
                        .frame(maxWidth: .infinity)
                        .background(reader.isFocused ? layout.desk : Palette.side)
                    if reader.showOutline { outline }
                }
                if notebook {
                    Divider()
                    notePanel.frame(width: reader.isFocused ? layout.notebookWidth : 326)
                }
            }
            Divider()
            footer
        }
        .foregroundColor(Palette.ink)
        .background(Palette.paper)
        .modifier(ReadingTranslationOverlay(store: store, session: translation, pdfTools: AnyView(translationTools)))
        .notebookSheets(transfer, store: store, itemID: reader.itemID)
        .onAppear {
            if reader.revealedNote != nil { setNotebook(true) }
            if reader.showOutline && chapters.isEmpty { beginFolding() }
        }
        .sheet(item: $scanEditor) { PDFScanEditor(reader: reader, noteID: $0.id) }
        .sheet(item: $quoteEditor) { PDFQuoteRepairEditor(reader: reader, noteID: $0.id) }
        .onDisappear { comparison.close() }
        .sheet(item: $outlineEditor) { request in
            PDFOutlineEditor(reader: reader, store: store, manual: request.manual, reviewPending: request.reviewPending) {
                if reader.showOutline { resetChapters() }
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
            rebuildFoldedPages()
        }
        .onChange(of: reader.isFocused) { _ in
            preserveFoldPosition()
        }
        .onChange(of: layout) { _ in
            if reader.isFocused { preserveFoldPosition() }
        }
        .onChange(of: store.library.preferences.readingAid) { _ in
            if reader.showOutline { preserveFoldPosition() }
        }
        .onChange(of: reader.revealedNote) { id in
            if let id, reader.noteDraft?.id == id || reader.saveDraft() {
                if let mark = reader.marks.first(where: { $0.id == id }) { includeInNotes(mark) }
                setNotebook(true)
            }
        }
        .onChange(of: noteFilter) { _ in
            selectedNotes.formIntersection(visibleMarks.map(\.id))
        }
        .onReceive(NotificationCenter.default.publisher(for: ReadingCommand.notification, object: store)) { event in
            guard let command = event.userInfo?["command"] as? ReadingCommand else { return }
            switch command {
            case .excerpt: excerpt()
            case .annotation: capture(.annotation, edit: true, pageOnly: !reader.hasSelection)
            case .highlight: capture(.annotation, edit: false)
            case .translate: translateSelection()
            }
        }
        .onChange(of: reader.showOutline) { showing in
            translation.clearSentence()
            if showing {
                reader.selectingRegion = false
                beginFolding()
            } else {
                foldRestore = nil
                foldLoad = nil
            }
        }
        .onChange(of: reader.selectingRegion) { if $0 { translation.clearSentence() } }
        .onChange(of: reader.detectedOutline) { _ in
            if reader.showOutline && reader.foldOptions.unit == .chapter && reader.savedOutline.isEmpty && foundOutline {
                resetChapters()
            }
        }
        .task(id: foldLoad) {
            guard let request = foldLoad, let chapter = expandedChapter, chapter.id == request.chapterID else { return }
            var pages: [PDFFoldedPage] = []
            for index in request.pages {
                guard !Task.isCancelled, foldLoad == request else { return }
                pages.append(reader.foldedPage(index, in: chapter))
                await Task.yield()
            }
            guard !Task.isCancelled, foldLoad == request else { return }
            if let position = request.restore {
                foldRestore = FoldRestore(position: reader.foldPosition ?? position)
            }
            sourceChapterPages = (sourceChapterPages + pages).sorted { $0.id < $1.id }
            rebuildFoldedPages()
            foldLoad = nil
        }
    }

    private func rebuildFoldedPages() {
        chapterPages = reader.correctedFoldPages(reader.stitchedFoldPages(sourceChapterPages))
        if let target = reader.foldReflowTarget, let offset = target.offset {
            for page in chapterPages where page.id <= target.page {
                if let passage = page.passages.first(where: { passage in
                    passage.sources(startingOn: page.id).contains {
                        $0.page == target.page && NSLocationInRange(offset, $0.range)
                    }
                }) {
                    openedPassages.insert("\(page.id):\(passage.id)")
                    break
                }
            }
        }
    }

    private var expandedChapter: PDFChapter? { chapters.first { $0.id == expandedSection } }
    private var foundOutline: Bool { !reader.navigationSections.isEmpty }
    private var foldUnit: PDFFoldUnit {
        reader.foldOptions.unit == .chapter && !foundOutline ? .group : reader.foldOptions.unit
    }
    private var groupSize: Int { min(20, max(2, reader.foldOptions.pages)) }
    private var showFullPassages: Bool { reader.foldOptions.fullPassages }

    private var toolbar: some View {
        HStack(spacing: 8) {
            ReadingIconButton(title: "保存位置并返回漫读", systemImage: "chevron.left", action: leave)
            if !reader.isFocused {
                Text(reader.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).help(reader.title)
            }
            Spacer(minLength: 12)
            Group {
                ReadingTabs(selection: Binding(get: { reader.showOutline }, set: setFoldedView),
                            options: [(false, "原页"), (true, "折叠")])
                Divider().frame(height: 15).padding(.horizontal, 3)
                Button(action: openNavigation) { Label("目录", systemImage: "list.bullet.indent") }
                    .buttonStyle(ReadingControlStyle(selected: navigationPresented))
                    .help("目录与书签 · ⇧⌘O")
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .popover(isPresented: $navigationPresented, arrowEdge: .bottom) {
                        PDFReadingNavigation(reader: reader, onSection: goToSection, onPage: goToPage,
                                             onBookmark: goToBookmark, onEdit: openOutlineEditor, onToggleBookmark: toggleBookmark)
                    }
                ReadingIconButton(title: reader.bookmarkHere == nil ? "添加书签 · ⌘B" : "移除此处书签 · ⌘B",
                                  systemImage: reader.bookmarkHere == nil ? "bookmark" : "bookmark.fill",
                                  selected: reader.bookmarkHere != nil, action: toggleBookmark)
                    .keyboardShortcut("b", modifiers: .command)
            }
            ReadingIconButton(title: notebook ? "收起摘录与批注" : "打开摘录与批注",
                              systemImage: "sidebar.right", selected: notebook) {
                let shouldOpen = !notebook
                if shouldOpen || reader.saveDraft() { setNotebook(shouldOpen) }
            }
            ReadingAidButton(store: store, inOriginalPDF: !reader.showOutline, canReflow: {
                let page = reader.readingAidOrigin().page
                return reader.sourceText(page: page)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }) {
                setFoldedView(true, forReadingAid: true)
            }
            Group {
                translationButton
                ReadingPointTranslationButton(session: translation).disabled(reader.selectingRegion)
                ReadingFocusButton(focused: reader.isFocused, toggle: store.toggleReadingFocus)
            }
            if !reader.showOutline && !reader.isFocused {
                ReadingIconButton(title: "框选图摘", systemImage: "crop", selected: reader.selectingRegion) {
                    guard reader.saveDraft() else { return }
                    reader.selectingRegion.toggle()
                }
            }
            if reader.isFocused {
                FocusLayoutButton(store: store, originalPDF: !reader.showOutline)
                if !reader.showOutline {
                    Menu {
                        Button("框选图摘") {
                            guard reader.saveDraft() else { return }
                            reader.selectingRegion.toggle()
                        }
                    } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28).accessibilityLabel("更多阅读操作")
                }
            }
            if !reader.isFocused {
                Menu {
                    if !reader.hasAuthorOutline {
                        if !reader.showOutline {
                            Button("从此处加章节…") {
                                let anchor = reader.outlineEntryAtSelection()
                                outlineEditor = OutlineSheet(manual: PDFOutlineCandidate(title: anchor.title, location: anchor.location))
                            }
                            Divider()
                        }
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
                .frame(width: 28)
                .accessibilityLabel("更多阅读操作")
            }

        }
        .buttonStyle(.borderless)
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var translationButton: some View {
        ReadingTranslationButton(session: translation) {
            if translation.presented { translation.close() }
            else if reader.translationSelection != nil { translateSelection() }
            else { translation.open(.pdf) }
        }
    }

    private var translationTools: some View {
        PDFTranslationControls(source: reader.translationSource, page: reader.location.page,
                               archive: store.translations, settings: translationSettings,
                               changeSourceLanguage: { language in
                                   var updated = translationSettings
                                   updated.pdfSource = language
                                   store.commit { $0.preferences.translation = updated }
                               },
                               jobs: store.pdfTranslationJobs, configure: { translation.configuring = true },
                               open: openComparison)
    }

    private var translationSettings: ReadingTranslationSettings {
        store.library.preferences.translation ?? ReadingTranslationSettings()
    }

    private func translateSelection() {
        if let passage = reader.translationSelection {
            translation.show(passage, settings: translationSettings, archive: store.translations)
        }
    }

    private func translateSentence(_ hit: PDFSentenceHit, panelOnLeadingEdge: Bool) {
        let page = reader.document.index(for: hit.page)
        guard (0..<reader.document.pageCount).contains(page) else { return }
        let passage = TranslationPassage(text: hit.text, title: reader.title, place: reader.pageReference(page),
                                         document: reader.translationDocument, suspectedEncodingError: hit.suspectedEncodingError)
        translation.show(passage, settings: translationSettings, archive: store.translations,
                         sentence: .pdf(hit, panelOnLeadingEdge: panelOnLeadingEdge))
    }

    private func translatePassage(_ passage: FoldedPDFPassage, page: Int, sentence: NSRange? = nil) {
        let first = reader.pageReference(page)
        let place = passage.sources(startingOn: page).last?.page ?? page
        let reference = place == page ? first : "PDF 第 \(page + 1)–\(place + 1) 页"
        let full = passage.displayText
        let text: String
        if let sentence {
            guard let range = Range(sentence, in: full) else { return }
            text = ReadingSentence.translationText(String(full[range]))
        } else { text = full }
        let request = TranslationPassage(text: text, title: reader.title, place: reference,
                                         document: reader.translationDocument,
                                         suspectedEncodingError: PDFQuoteQuality.isSuspicious(sentence == nil ? passage.text : text))
        translation.show(request, settings: translationSettings, archive: store.translations,
                         sentence: sentence.map { .folded(page: page, passage: passage.id, range: $0) })
    }

    private func openComparison(_ file: PDFTranslationFile?, follow: Bool) {
        guard !comparison.bringForward(), !openingComparison else { return }
        openingComparison = true
        let source = reader.translationSource
        let verification = Task.detached(priority: .userInitiated) {
            (try? PDFReader.fingerprint(source.url)) == source.document.revision
        }
        Task { @MainActor in
            defer { openingComparison = false }
            let matches = await verification.value
            guard store.pdfReader === reader else { return }
            guard matches, let original = PDFDocument(url: source.url), !original.isLocked,
                  original.pageCount == source.pageCount else {
                store.error = "无法打开这份对照。请重新打开原 PDF，或重新关联译文。"
                return
            }
            translation.close()
            let request = PDFBilingualRequest(original: original, source: source, startingFile: file,
                                               title: reader.title, startPage: reader.location.page, follow: follow)
            comparison.present(request, reader: reader, store: store) { page in
                if reader.showOutline || page != reader.location.page {
                    reader.showSource(at: PDFReadingLocation(page: page))
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if reader.showOutline {
                foldUnitMenu
                ReadingTabs(selection: Binding(get: { showFullPassages }, set: { value in
                    var options = reader.foldOptions
                    options.fullPassages = value
                    reader.setFoldOptions(options)
                }), options: [(false, "原句速览"), (true, "原段")])
                    .help("速览显示段内原句，展开可读同一段全文")
                Text("PDF 第 \(reader.location.page + 1) 页")
                    .font(.system(size: 11)).foregroundColor(Palette.muted).monospacedDigit()
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
                    if reader.selectionAnchor == nil {
                        ReadingExcerptButton { excerpt() }
                        ReadingAnnotationButton { capture(.annotation, edit: true) }
                        Button("翻译", action: translateSelection).buttonStyle(ReadingControlStyle())
                        Button("查相关", action: searchSelection).buttonStyle(ReadingControlStyle())
                    }
                    ReadingIconButton(title: "仅标记选区 · ⇧⌘H", systemImage: "highlighter") {
                        capture(.annotation, edit: false)
                    }
                } else {
                    if reader.isFocused {
                        ReadingIconButton(title: "页边记 · ⇧⌘N", systemImage: "square.and.pencil") {
                            capture(.annotation, edit: true, pageOnly: true)
                        }
                    } else {
                        ReadingAnnotationButton(title: "页边记") { capture(.annotation, edit: true, pageOnly: true) }
                    }
                }
            }
            ReadingIconButton(title: "先放这里 · ⇧⌘D", systemImage: "tray.and.arrow.down") { capture(.detour, edit: true) }
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
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }

    private var foldUnitMenu: some View {
        let automaticFallback = reader.foldOptions.unit == .chapter && foldUnit == .group
        return Menu {
            foldUnitOption("按目录自动", .chapter)
            foldUnitOption("单页", .page)
            Menu("连续页段") {
                ForEach([2, 3, 5, 10, 20], id: \.self) { count in
                    foldUnitOption("每 \(count) 页", .group, pages: count)
                }
            }
        } label: {
            let title = foldUnit == .group ? "每 \(groupSize) 页" : foldUnit.title
            Label(automaticFallback ? "自动 · " + title : title, systemImage: "rectangle.split.1x2")
        }.menuStyle(.borderlessButton).fixedSize()
            .help(automaticFallback ? "暂无可用目录，暂按连续页段折叠" : "这份 PDF 的折叠方式")
    }

    private func foldUnitOption(_ title: String, _ unit: PDFFoldUnit, pages: Int? = nil) -> some View {
        let selected = reader.foldOptions.unit == unit && (pages == nil || pages == groupSize)
        return Button { setFoldUnit(unit, pages: pages) } label: {
            if selected { Label(title, systemImage: "checkmark") }
            else { Text(title) }
        }
    }

    private var outline: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if reader.findingOutline && foldUnit == .group && reader.foldOptions.unit == .chapter {
                            ProgressView("正在识别目录，可以先按页段读").controlSize(.small)
                                .font(.system(size: 12)).foregroundColor(Palette.muted).padding(.bottom, 14)
                        }
                        ForEach(foldRows) { row in
                            foldRow(row).id(row.id)
                        }
                    }
                    .padding(.horizontal, 26).padding(.vertical, 26)
                    .frame(minHeight: viewport.size.height, alignment: .topLeading)
                }
                .frame(maxWidth: reader.isFocused ? layout.width : 772)
                .background(reader.isFocused ? layout.paper : Palette.paper)
                .frame(maxWidth: .infinity)
                .coordinateSpace(name: "folded-reading")
                .task(id: readyFoldScroll) {
                    guard let request = readyFoldScroll else { return }
                    await Task.yield()
                    guard !Task.isCancelled, foldRestore?.id == request.id else { return }
                    proxy.scrollTo(request.destination, anchor: .top)
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    if !Task.isCancelled && foldRestore?.id == request.id { foldRestore = nil }
                }
                .onPreferenceChange(FoldRowFrames.self) { frames in
                    let section = expandedSection
                    DispatchQueue.main.async {
                        if expandedSection == section { updateFoldPosition(frames, height: viewport.size.height) }
                    }
                }
            }
        }.background(reader.isFocused ? layout.desk : Palette.paper)
            .accessibilityIdentifier("PDFOutline")
    }

    private var readyFoldScroll: FoldScroll? {
        guard let request = foldRestore, let chapter = expandedChapter else { return nil }
        guard let position = request.position else {
            return FoldScroll(id: request.id, destination: .chapter(chapter.id))
        }
        guard let page = chapterPages.first(where: { $0.id == position.page }) else { return nil }
        if let offset = position.offset, page.footnotes.contains(where: { NSLocationInRange(offset, $0.range) }) {
            return FoldScroll(id: request.id, destination: .position(page.footnotePosition))
        }
        for candidate in chapterPages.reversed() where candidate.id <= page.id {
            if let passage = bodyPassages(on: candidate, in: chapter).first(where: { passage in
                passage.sources(startingOn: candidate.id).contains { source in
                    source.page == page.id && (position.offset.map { NSLocationInRange($0, source.range) }
                        ?? (candidate.id != page.id))
                }
            }) {
                return FoldScroll(id: request.id, destination: .position(PDFFoldPosition(page: candidate.id, offset: passage.id)))
            }
        }
        let body = bodyPassages(on: page, in: chapter)
        if let passage = body.first {
            return FoldScroll(id: request.id, destination: .position(PDFFoldPosition(page: page.id, offset: passage.id)))
        }
        if !page.footnotes.isEmpty { return FoldScroll(id: request.id, destination: .position(page.footnotePosition)) }
        if !page.hasSourceText { return FoldScroll(id: request.id, destination: .position(PDFFoldPosition(page: page.id))) }
        return FoldScroll(id: request.id, destination: .chapter(chapter.id))
    }

    private func updateFoldPosition(_ frames: [PDFFoldPosition: CGRect], height: CGFloat) {
        guard reader.showOutline, foldRestore == nil else { return }
        let threshold = min(24, height / 4)
        guard let position = frames.filter({ $0.value.maxY > threshold && $0.value.minY < height })
            .min(by: { $0.value.minY < $1.value.minY })?.key,
              let page = chapterPages.first(where: { $0.id == position.page }) else { return }
        let passage = page.passages.first { $0.id == position.offset } ?? page.footnotes.first { $0.id == position.offset }
        reader.rememberFoldPosition(position, passage: passage)
        if let last = chapterPages.last, position.page >= last.id - 1 {
            loadMorePages()
        }
    }

    private var foldRows: [FoldRow] {
        var rows: [FoldRow] = []
        for chapter in chapters {
            rows.append(.chapter(chapter))
            guard expandedSection == chapter.id else { continue }
            let bounds = chapter.pages(total: reader.document.pageCount)
            if let first = chapterPages.first, first.id > bounds.lowerBound { rows.append(.earlier(depth: chapter.depth)) }
            for page in chapterPages {
                let body = bodyPassages(on: page, in: chapter)
                if foldUnit != .page && !body.isEmpty { rows.append(.page(page.id, depth: chapter.depth)) }
                if body.isEmpty { rows.append(.empty(page, depth: chapter.depth)) }
                else { rows += body.map { .passage($0, page: page.id, depth: chapter.depth) } }
                if !page.footnotes.isEmpty { rows.append(.notes(page, depth: chapter.depth)) }
            }
            if foldLoad != nil {
                rows.append(.loading(depth: chapter.depth))
            } else if let last = chapterPages.last, last.id + 1 < bounds.upperBound {
                rows.append(.later(depth: chapter.depth))
            } else if let end = chapter.end, let next = chapters.first(where: { $0.id != chapter.id && $0.start == end }) {
                rows.append(.nextChapter(next))
            }
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
                    Button("翻译原段") { translatePassage(passage, page: page) }
                    Button("摘录原段") { excerpt(passage, page: page) }
                    Button("批注原段…") {
                        if reader.saveDraft() { beginNote(reader.draftExcerpt(passage, page: page)) }
                    }
                    Divider()
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
            ProgressView("正在展开原文…").controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .modifier(FoldMargin(depth: depth))
        case .earlier(let depth):
            Button(action: loadPreviousPages) { Label("展开本章前面的页", systemImage: "arrow.up") }
                .buttonStyle(.borderless).foregroundColor(Palette.green).padding(.vertical, 10)
                .modifier(FoldMargin(depth: depth)).disabled(foldLoad != nil)
        case .later(let depth):
            Button(action: loadMorePages) { Label("展开后面的页", systemImage: "arrow.down") }
                .buttonStyle(.borderless).foregroundColor(Palette.green).padding(.vertical, 10)
                .modifier(FoldMargin(depth: depth))
        case .nextChapter(let chapter):
            Button { activateChapter(chapter) } label: {
                Label(foldUnit == .chapter ? "读下一节" : foldUnit == .page ? "读下一页" : "读下一段", systemImage: "arrow.down")
            }.buttonStyle(.borderless).foregroundColor(Palette.green).padding(.vertical, 10)
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
        }.padding(.leading, CGFloat(min(7, chapter.depth)) * 10)
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
        let mode = isFootnote ? .off : store.library.preferences.readingAid
        let canToggle = !isFootnote && !showFullPassages && preview != full
        let bodySize = reader.isFocused ? layout.textSize : 16
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                foldedText(text, full: full, passage: passage, page: page, mode: mode)
                    .font(.system(size: isFootnote ? max(13, bodySize - 2) : bodySize))
                    .lineSpacing(isFootnote ? 4 : reader.isFocused ? layout.paragraphLineSpacing : 6)
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
                ReadingIconButton(title: isFootnote ? "翻译脚注" : "翻译原段", systemImage: "character.bubble") {
                    translatePassage(passage, page: page)
                }
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

    @ViewBuilder private func foldedText(_ text: String, full: String, passage: FoldedPDFPassage,
                                         page: Int, mode: ReadingAidMode) -> some View {
        let decorated = ReadingWordEmphasis.format(text, mode: mode)
        if translation.pointMode {
            let sentences = ReadingSentence.visibleRanges(in: text, from: full)
            Text(sentenceLinks(in: decorated, text: text, sentences: sentences, passage: passage.id, page: page))
                .tint(Palette.ink)
                .environment(\.openURL, OpenURLAction { url in
                    guard url.scheme == "wander-sentence", let index = Int(url.lastPathComponent), sentences.indices.contains(index) else {
                        return .discarded
                    }
                    translatePassage(passage, page: page, sentence: sentences[index].source)
                    return .handled
                })
        } else {
            Text(decorated).textSelection(.enabled)
        }
    }

    private func sentenceLinks(in decorated: AttributedString, text: String, sentences: [ReadingSentence.VisibleRange],
                                passage: Int, page: Int) -> AttributedString {
        var linked = decorated
        for (index, sentence) in sentences.enumerated() {
            guard let visible = Range(sentence.visible, in: text), let range = Range(visible, in: linked) else { continue }
            linked[range].link = URL(string: "wander-sentence://read/\(index)")
            if case .folded(let markedPage, let markedPassage, let markedRange) = translation.activeSentence,
               markedPage == page, markedPassage == passage, markedRange == sentence.source {
                linked[range].foregroundColor = Palette.green
                linked[range].underlineStyle = .single
            } else {
                linked[range].foregroundColor = Palette.ink
            }
        }
        return linked
    }

    private func setFoldUnit(_ unit: PDFFoldUnit, pages: Int? = nil) {
        var options = reader.foldOptions
        options.unit = unit
        if let pages { options.pages = pages }
        guard reader.setFoldOptions(options) else { return }
        beginFolding()
    }

    private func beginFolding() {
        if reader.foldOptions.unit == .chapter { reader.prepareOutline() }
        resetChapters()
    }

    private func setFoldedView(_ folded: Bool) {
        setFoldedView(folded, forReadingAid: false)
    }

    private func setFoldedView(_ folded: Bool, forReadingAid: Bool) {
        guard folded != reader.showOutline else { return }
        if folded {
            let original = reader.location
            let origin = forReadingAid ? reader.readingAidOrigin() : original
            reader.showOutline = true
            if forReadingAid {
                let position = reader.foldPosition(at: origin)
                reader.prepareFoldReflow(to: position, returnLocation: original)
                reader.jumpInFold(to: origin, position: position, preserveReflow: true)
            }
        } else {
            let original = reader.originalLocationForFoldReflow()
            reader.showOutline = false
            if let original {
                reader.go(to: original)
            } else {
                reader.showSource(at: reader.location)
            }
        }
    }

    private func resetChapters() {
        chapters = reader.chapters(unit: foldUnit, groupSize: groupSize)
        guard let chapter = reader.chapterAt(reader.location, in: chapters) else { expand(nil); return }
        let anchor = reader.foldPosition ?? (reader.location.point != nil || reader.location.page > chapter.start.page
            ? reader.foldPosition(at: reader.location) : nil)
        expand(chapter, position: anchor)
    }

    private func toggleChapter(_ chapter: PDFChapter) {
        if expandedSection == chapter.id { expand(nil) }
        else { activateChapter(chapter) }
    }

    private func activateChapter(_ chapter: PDFChapter) {
        reader.jumpInFold(to: chapter.start, position: nil)
        expand(chapter, scrollToHeading: true)
    }

    private func expand(_ chapter: PDFChapter?, position: PDFFoldPosition? = nil, scrollToHeading: Bool = false) {
        expandedSection = chapter?.id
        foldRestore = position != nil || scrollToHeading ? FoldRestore(position: position) : nil
        sourceChapterPages = []
        chapterPages = []
        openedPassages = []
        foldLoad = chapter.map {
            FoldLoad(chapterID: $0.id, pages: $0.initialPages(around: position?.page ?? $0.start.page,
                                                            total: reader.document.pageCount))
        }
    }

    private func loadMorePages() {
        guard foldLoad == nil, let chapter = expandedChapter, let last = chapterPages.last else { return }
        let start = last.id + 1
        let end = chapter.pages(total: reader.document.pageCount).upperBound
        guard start < end else { return }
        foldLoad = FoldLoad(chapterID: chapter.id, pages: start..<min(end, start + PDFChapter.batchSize))
    }

    private func loadPreviousPages() {
        guard foldLoad == nil, let chapter = expandedChapter, let first = chapterPages.first,
              first.id > chapter.start.page else { return }
        let start = max(chapter.start.page, first.id - PDFChapter.batchSize)
        foldLoad = FoldLoad(chapterID: chapter.id, pages: start..<first.id,
                            restore: reader.foldPosition ?? reader.foldPosition(at: reader.location))
    }

    private func openNavigation() {
        navigationPresented.toggle()
        if navigationPresented { reader.prepareOutline() }
    }

    private func openOutlineEditor(reviewPending: Bool) {
        navigationPresented = false
        DispatchQueue.main.async { outlineEditor = OutlineSheet(reviewPending: reviewPending) }
    }

    private func goToSection(_ section: PDFReadingSection) {
        let target = reader.sectionLocation(section)
        if reader.showOutline, foldUnit == .chapter, let chapter = chapters.first(where: { $0.id == section.id }) {
            navigationPresented = false
            activateChapter(chapter)
        } else {
            goToReadingLocation(target)
        }
    }

    private func goToPage(_ page: Int) {
        goToReadingLocation(PDFReadingLocation(page: page))
    }

    private func goToBookmark(_ bookmark: PDFPlaceBookmark) {
        guard bookmark.revision == reader.revision else { return }
        goToReadingLocation(bookmark.location, position: bookmark.foldPosition)
    }

    private func goToReadingLocation(_ location: PDFReadingLocation, position: PDFFoldPosition? = nil) {
        navigationPresented = false
        guard reader.showOutline else { reader.showSource(at: location); return }
        let anchor = position ?? reader.foldPosition(at: location)
        reader.jumpInFold(to: location, position: anchor)
        guard let chapter = reader.chapterAt(location, in: chapters) else { return }
        if expandedSection == chapter.id && chapterPages.contains(where: { $0.id == anchor.page }) {
            foldRestore = FoldRestore(position: anchor)
        } else {
            expand(chapter, position: anchor)
        }
    }

    private func toggleBookmark() {
        let outline = reader.navigationSections
        let current = reader.currentSectionID(in: outline)
        let title = outline.first(where: { $0.id == current })?.title
            ?? "第 \(reader.location.page + 1) 页"
        reader.toggleBookmark(title: title)
    }

    private var notePanel: some View {
        let visible = visibleMarks
        let sent = store.deliveredNotes(for: reader.itemID)
        return VStack(spacing: 0) {
            ReadingNotesHeader(total: reader.marks.count, visible: visible.count, selecting: selectingNotes,
                               canFilterExcerpts: true, filter: $noteFilter, toggleSelection: {
                selectingNotes.toggle()
                selectedNotes = []
            }, close: {
                if reader.saveDraft() { setNotebook(false) }
            })
            if selectingNotes && !visible.isEmpty {
                NotebookBatchControls(visible: Set(visible.map(\.id)), sent: sent, sending: transfer.sending, selected: $selectedNotes,
                                      send: send, remove: { reader.saveDraft() && reader.remove($0) })
                    .padding([.horizontal, .bottom], 9)
            }
            NotebookDeliveryStatus(transfer: transfer, store: store, itemID: reader.itemID)
                .padding(.horizontal, 9)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        if let draft = reader.noteDraft, !reader.editingNote {
                            noteCard(draft, sent: false, draft: true).id(draft.id)
                        }
                        if visible.isEmpty && reader.noteDraft == nil {
                            Text(noteFilter.isFiltering ? "没有找到符合条件的笔记。" : "选中文字可摘录或写批注。扫描页也可以框选。")
                                .font(.system(size: 12)).foregroundColor(Palette.muted)
                                .padding(.horizontal, 7).padding(.vertical, 12)
                        }
                        ForEach(visible) { mark in noteCard(mark, sent: sent.contains(mark.id)).id(mark.id) }
                        ReadingRelatedSidebar(search: relatedSearch, store: store, itemID: reader.itemID,
                                              suggestedQuery: reader.intent, keep: keepRelated)
                            .id("reading-related")
                    }.padding(9)
                }
                .onAppear { if let id = reader.revealedNote { proxy.scrollTo(id, anchor: .top) } }
                .onChange(of: reader.revealedNote) { id in
                    if let id { DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) } }
                }
                .onChange(of: reader.noteDraft?.id) { id in
                    if let id { DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) } }
                }
                .onChange(of: relatedSearch.requestID) { _ in
                    DispatchQueue.main.async { proxy.scrollTo("reading-related", anchor: .top) }
                }
            }
        }
        .background(reader.isFocused ? layout.notes : Palette.paper)
    }

    private func notePlace(_ mark: PDFReadingMark) -> String {
        if mark.revision != reader.revision { return "旧版 · " + ReaderNote(mark).location }
        if mark.lines.contains(where: { $0.page != mark.location.page }) { return ReaderNote(mark).location }
        return reader.pageReference(mark.location.page)
    }

    private func noteCard(_ mark: PDFReadingMark, sent: Bool, draft: Bool = false) -> some View {
        let editing = reader.noteDraft?.id == mark.id
        let color = mark.lines.isEmpty ? nil : mark.appearance.color
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                if selectingNotes && !draft { NotebookSelectionToggle(id: mark.id, selected: $selectedNotes) }
                Text(draft ? "新批注" : ReaderNote(mark).kind)
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 3)
                Text(notePlace(mark)).font(.system(size: 11)).foregroundColor(Palette.muted)
                    .monospacedDigit().lineLimit(1)
            }
            if let data = mark.scan?.jpeg, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 145)
                    .clipShape(RoundedRectangle(cornerRadius: 6)).accessibilityLabel("框选原图")
                Button(mark.quote.isEmpty ? "识别文字" : "校对文字") {
                    if reader.saveDraft() { scanEditor = ScanEditorID(id: mark.id) }
                }.buttonStyle(ReadingControlStyle())
            }
            if !mark.quote.isEmpty { ReadingNoteQuote(text: mark.quote, color: color, editing: editing) }
            if mark.needsQuoteReview && !draft {
                Button { repairQuote(mark) } label: {
                    Label("文字可能有错码 · 从原页校对", systemImage: "text.magnifyingglass")
                        .font(.system(size: 11))
                }.buttonStyle(ReadingControlStyle(accented: true))
                    .help("PDF 的显示字形可能与内部文字编码不一致。可以从选区原图重新识别。")
            }
            if editing {
                ReadingNoteComposer(prompt: mark.kind == .detour ? "想查什么？也可以贴网址" : "写下你的想法…",
                                    text: $reader.draftText, cancel: reader.discardDraft, save: { _ = reader.saveDraft() })
            } else {
                if !mark.note.isEmpty {
                    Text(mark.note).font(.system(size: 13)).lineSpacing(3).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                noteActions(mark, sent: sent)
            }
        }
        .readingNoteRow(active: reader.revealedNote == mark.id || editing)
    }

    private func noteActions(_ mark: PDFReadingMark, sent: Bool) -> some View {
        HStack(spacing: 1) {
            if mark.revision == reader.revision {
                Button {
                    store.inspectPDF(reader, at: mark.location, lines: mark.lines, note: mark.id, quote: mark.quote,
                                     isRegion: mark.scan != nil)
                } label: { Label("查原文", systemImage: "arrow.up.right") }
                    .buttonStyle(ReadingControlStyle())
            } else if mark.scan == nil {
                Button(mark.quote.isEmpty ? "定位到此页" : "重新定位") { relocate(mark) }
                    .buttonStyle(ReadingControlStyle())
                    .help("在新版 PDF 选中相同的原文后更新出处")
                    .disabled(reader.showOutline || (!mark.quote.isEmpty && !reader.hasSelection))
            }
            Spacer(minLength: 0)
            ReadingIconButton(title: mark.note.isEmpty ? "写想法" : "编辑想法", systemImage: "square.and.pencil") { edit(mark) }
            ReadingIconButton(title: highlightCopied == mark.id ? "已复制" : "复制摘录与出处",
                              systemImage: highlightCopied == mark.id ? "checkmark" : "doc.on.doc") { copy(mark) }
            NotebookSendButton(sent: sent) { if sent { store.openNotebook(reader.itemID, noteID: mark.id) } else { send([mark.id]) } }
                .disabled(transfer.sending && !sent)
            Menu {
                if !mark.quote.isEmpty && mark.scan == nil {
                    Button("校对摘录文字…") { repairQuote(mark) }
                    if mark.quoteCorrection != nil {
                        Button("恢复原提取文字") {
                            if reader.saveDraft() { _ = reader.restoreOriginalQuote(mark.id) }
                        }
                    }
                    Divider()
                }
                if !mark.quote.isEmpty {
                    Button("翻译摘录") {
                        let request = TranslationPassage(text: mark.quote, title: reader.title, place: notePlace(mark),
                            document: TranslationDocument(itemID: reader.itemID, revision: mark.revision),
                            suspectedEncodingError: mark.needsQuoteReview)
                        translation.show(request, settings: translationSettings, archive: store.translations)
                    }
                }
                if !mark.lines.isEmpty {
                    ReadingNoteAppearanceMenu(appearance: mark.appearance, styles: mark.scan == nil,
                                              changeColor: { reader.setColor($0, for: mark) },
                                              changeStyle: { reader.setStyle($0, for: mark) })
                    Divider()
                }
                Button("文献引文键…") { transfer.editingCitation = true }
                Button("Obsidian 收件设置…", action: transfer.openSetup)
                Button("移除", role: .destructive) {
                    if reader.saveDraft() { reader.remove(mark.id) }
                }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: 28).accessibilityLabel("管理这条笔记")
        }.foregroundColor(Palette.muted)
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
        if notebooks[focused: reader.isFocused] != visible { preserveFoldPosition() }
        notebooks[focused: reader.isFocused] = visible
        if !visible { reader.revealedNote = nil }
    }

    private func preserveFoldPosition() {
        if reader.showOutline, let anchor = reader.foldPosition, expandedChapter != nil {
            foldRestore = FoldRestore(position: anchor)
        }
    }

    private func capture(_ kind: PDFReadingMark.Kind, edit: Bool, pageOnly: Bool = false) {
        guard reader.saveDraft() else { return }
        do {
            let mark = try reader.draft(kind: kind, pageOnly: pageOnly || reader.showOutline)
            if edit { beginNote(mark) }
            else if reader.save(mark) {
                reader.clearSelection()
                if mark.needsQuoteReview { repairQuote(mark) }
            }
        } catch { store.error = error.localizedDescription }
    }

    private func beginNote(_ mark: PDFReadingMark) {
        reader.noteDraft = mark
        reader.draftText = mark.note
        reader.editingNote = reader.marks.contains(where: { $0.id == mark.id })
        reader.revealedNote = mark.id
        reader.clearSelection()
        setNotebook(true)
    }

    private func excerpt(_ passage: FoldedPDFPassage? = nil, page: Int? = nil, appearance: ReadingMarkAppearance? = nil) {
        guard reader.saveDraft() else { return }
        do {
            if let mark = try reader.excerpt(passage, page: page, appearance: appearance) {
                reader.clearSelection()
                if notebook { revealExcerpt(mark.id) }
                else { justExcerpted = mark.id }
                if mark.needsQuoteReview { repairQuote(mark) }
            }
        } catch { store.error = error.localizedDescription }
    }

    private func revealExcerpt(_ id: UUID) {
        justExcerpted = nil
        guard reader.marks.contains(where: { $0.id == id }) else { return }
        if let mark = reader.marks.first(where: { $0.id == id }) { includeInNotes(mark) }
        setNotebook(true)
        reader.revealedNote = id
    }

    private func repairQuote(_ mark: PDFReadingMark) {
        if reader.saveDraft() { quoteEditor = ScanEditorID(id: mark.id) }
    }

    private func includeInNotes(_ mark: PDFReadingMark) {
        guard noteFilter.isFiltering else { return }
        noteFilter = noteFilter.including(color: mark.lines.isEmpty ? nil : mark.appearance.color,
                                         isExcerpt: mark.isExcerpt == true,
                                         text: [mark.quote, mark.note, notePlace(mark), ReaderNote(mark).kind])
    }

    private func setMarkStyle(_ style: ReadingMarkStyle) {
        var appearance = markAppearance
        appearance.style = style
        store.commit { $0.preferences.readingMarkAppearance = appearance }
    }

    private func copySelection() {
        guard let quote = reader.selectedQuote else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(quote, forType: .string)
    }

    private func searchSelection() {
        guard let quote = reader.selectedQuote else { return }
        searchRelated(quote)
        reader.clearSelection()
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
        beginNote(mark)
    }

    private func leave() {
        store.leavePDF()
    }

    private func relocate(_ mark: PDFReadingMark) {
        do { _ = try reader.relocate(mark) }
        catch { store.error = error.localizedDescription }
    }

    private func send(_ ids: Set<UUID>) {
        if let mark = reader.marks.first(where: { ids.contains($0.id) && $0.needsQuoteReview }) {
            repairQuote(mark)
            return
        }
        if reader.saveDraft() { transfer.send(ids, from: reader.itemID, store: store) }
    }

    private func copy(_ mark: PDFReadingMark) {
        if mark.needsQuoteReview { repairQuote(mark); return }
        let text = [reader.title + " · " + notePlace(mark), mark.quote, mark.note].filter { !$0.isEmpty }.joined(separator: "\n\n")
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
    var layoutWidth: Double
    var notebook: Bool
    var sentence: PDFSentenceHit? = nil
    var pointTranslate: ((PDFSentenceHit, Bool) -> Void)? = nil

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
        context.coordinator.pointTranslate = pointTranslate
        context.coordinator.observe(view, highlights: surface.highlights)
        view.onLayout = { [weak coordinator = context.coordinator] in coordinator?.selectionTracker?.refresh() }
        return surface
    }

    func updateNSView(_ view: PDFReadingSurface, context: Context) {
        context.coordinator.pointTranslate = pointTranslate
        (view.pdf as? LaidOutPDFView)?.showSentence(sentence)
        context.coordinator.layoutChanged(width: layoutWidth, notebook: notebook, in: view.pdf)
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
        fileprivate var selectionTracker: ReadingSelectionTracker?
        private var lastWidth: Double?
        private var lastNotebook: Bool?
        var pointTranslate: ((PDFSentenceHit, Bool) -> Void)?

        init(reader: PDFReader) { self.reader = reader }

        func layoutChanged(width: Double, notebook: Bool, in view: PDFView) {
            let changed = lastWidth != nil && (lastWidth != width || lastNotebook != notebook)
            lastWidth = width
            lastNotebook = notebook
            if changed { reader?.preserveCanvasReadingPosition(in: view) }
        }

        func observe(_ view: PDFView, highlights: NSView) {
            selectionTracker = ReadingSelectionTracker(locate: { [weak self, weak view] in
                guard let view, let reader = self?.reader, reader.hasSelection, !reader.showOutline,
                      !reader.selectingRegion, let selection = view.currentSelection else { return nil }
                let rect = view.visiblePages.reduce(CGRect.null) { bounds, page in
                    let pageRect = selection.bounds(for: page)
                    return pageRect.isEmpty ? bounds : bounds.union(view.convert(pageRect, from: page))
                }
                return ReadingSelectionTracker.anchor(rect, in: view)
            }, show: { [weak reader] rect in
                if let reader, reader.selectionAnchor != rect { reader.selectionAnchor = rect }
            })
            let click = NSClickGestureRecognizer(target: self, action: #selector(revealClickedMark(_:)))
            click.delaysPrimaryMouseButtonEvents = false
            view.addGestureRecognizer(click)
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: .PDFViewSelectionChanged, object: view, queue: .main) { [weak self] _ in
                self?.reader?.selectionChanged()
                self?.selectionTracker?.refresh()
            })
            for name in [Notification.Name.PDFViewPageChanged, .PDFViewVisiblePagesChanged, .PDFViewScaleChanged] {
                observers.append(center.addObserver(forName: name, object: view, queue: .main) { [weak self, weak highlights] _ in
                    self?.reader?.visiblePositionChanged()
                    self?.selectionTracker?.refresh()
                    highlights?.needsDisplay = true
                })
            }
            if let clip = view.documentView?.enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self, weak highlights] _ in
                    self?.reader?.visiblePositionChanged()
                    self?.selectionTracker?.refresh()
                    highlights?.needsDisplay = true
                })
            }
        }

        @objc private func revealClickedMark(_ gesture: NSClickGestureRecognizer) {
            guard let view = gesture.view as? LaidOutPDFView, let reader, !reader.showOutline, !reader.selectingRegion else { return }
            let point = gesture.location(in: view)
            if let pointTranslate {
                if let hit = view.sentence(at: point) { pointTranslate(hit, point.x > view.bounds.midX) }
            } else { reader.revealAnnotation(at: point, in: view) }
        }

        func stop() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            selectionTracker = nil
        }

        deinit { stop() }
    }
}

final class LaidOutPDFView: PDFView {
    var onFirstLayout: (() -> Void)?
    var onLayout: (() -> Void)?
    private var visibleSentence: UUID?

    func sentence(at point: CGPoint) -> PDFSentenceHit? {
        guard let page = page(for: point, nearest: false) else { return nil }
        return page.sentence(at: convert(point, to: page))
    }

    func showSentence(_ hit: PDFSentenceHit?) {
        guard visibleSentence != hit?.id else { return }
        visibleSentence = hit?.id
        let color = NSColor(Palette.green).withAlphaComponent(0.26)
        hit?.selections.forEach { $0.color = color }
        highlightedSelections = hit?.selections
    }

    override func layout() {
        super.layout()
        onLayout?()
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
        highlights = PDFHighlightSurface(pdf: pdf) { [weak reader] view in
            reader?.highlights(in: view).map {
                PDFCanvasHighlight(rect: $0.rect, appearance: $0.mark.appearance, isRegion: $0.mark.scan != nil)
            } ?? []
        }
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

struct PDFCanvasHighlight {
    let rect: CGRect
    var appearance = ReadingMarkAppearance()
    var isRegion = false
}

final class PDFHighlightSurface: NSView {
    private weak var pdf: PDFView?
    private let marks: (PDFView) -> [PDFCanvasHighlight]

    init(pdf: PDFView, marks: @escaping (PDFView) -> [PDFCanvasHighlight]) {
        self.pdf = pdf
        self.marks = marks
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let pdf, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.clip(to: bounds)
        context.setBlendMode(.multiply)
        for highlight in marks(pdf) {
            let frame = convert(highlight.rect, from: pdf)
            let appearance = highlight.appearance
            let color = appearance.color.color
            if highlight.isRegion {
                context.setStrokeColor(color.withAlphaComponent(0.9).cgColor)
                context.setLineWidth(2)
                context.stroke(frame.insetBy(dx: 1, dy: 1))
            } else if appearance.style == .underline {
                context.setStrokeColor(appearance.color.underlineColor(onDark: false).cgColor)
                context.setLineWidth(1.7)
                context.setLineCap(.round)
                let y = frame.minY + 1
                context.move(to: CGPoint(x: frame.minX, y: y))
                context.addLine(to: CGPoint(x: frame.maxX, y: y))
                context.strokePath()
            } else {
                context.setFillColor(color.withAlphaComponent(0.34).cgColor)
                context.fill(frame)
            }
        }
        context.restoreGState()
    }
}
