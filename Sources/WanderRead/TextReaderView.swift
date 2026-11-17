import AppKit
import SwiftUI

struct TextReaderView: View {
    @ObservedObject var reader: TextReader
    @ObservedObject var store: ReadingStore
    @State private var notebooks = ReaderNotebookVisibility()
    @State private var contents = false
    @State private var related = false
    @State private var copied: UUID?
    @State private var selectingNotes = false
    @State private var selectedNotes = Set<UUID>()
    @State private var noteFilter = ReadingNoteFilter()
    @StateObject private var transfer = NotebookSendState()
    @StateObject private var relatedSearch = ReadingRelatedSearch()
    @StateObject private var translation = ReadingTranslationSession()
    @State private var justExcerpted: UUID?
    private var layout: FocusLayout { (store.library.preferences.focusLayout ?? FocusLayout()).normalized() }
    private var notes: Bool { notebooks[focused: reader.isFocused] || reader.editing != nil }
    private var markAppearance: ReadingMarkAppearance { store.library.preferences.readingMarkAppearance ?? ReadingMarkAppearance() }
    private var visibleNotes: [TextExcerpt] {
        reader.excerpts.reversed().filter {
            $0.id == reader.editing || noteFilter.matches(color: $0.appearance.color, text: $0.quote, $0.note, $0.place)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                TextCanvas(reader: reader, paper: reader.isFocused ? layout.paper : Palette.paper,
                           size: reader.isFocused ? layout.textSize : 17,
                           lineSpacing: reader.isFocused ? layout.paragraphLineSpacing : 6,
                           emphasis: store.library.preferences.readingAid, sentence: visibleSentence,
                           pointTranslate: translation.pointMode ? translateSentence : nil)
                    .overlay {
                        if let anchor = reader.selectionAnchor {
                            ReadingSelectionPalette(
                                anchor: anchor, appearance: markAppearance, excerpt: { capture() }, annotate: beginAnnotation,
                                useColor: { capture(appearance: ReadingMarkAppearance(color: $0, style: markAppearance.style)) },
                                setStyle: setMarkStyle, findRelated: searchRelated, copy: copySelection,
                                translate: translateSelection
                            )
                        }
                    }
                    .frame(maxWidth: reader.isFocused ? layout.width : 800)
                    .frame(maxWidth: .infinity)
                    .background(reader.isFocused ? layout.desk : Palette.side)
                if notes {
                    Divider()
                    notebook.frame(width: reader.isFocused ? layout.notebookWidth : 326)
                }
            }
            Divider()
            HStack(spacing: 8) {
                Text(reader.url.pathExtension.uppercased()).font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(Palette.muted)
                Spacer()
                if reader.selectedQuote != nil && reader.selectionAnchor == nil {
                    ReadingExcerptButton { capture() }
                    ReadingAnnotationButton(action: beginAnnotation)
                    Button("翻译", action: translateSelection).buttonStyle(ReadingControlStyle())
                    Button("查相关", action: searchRelated)
                        .buttonStyle(ReadingControlStyle()).help("用所选文字查相关原文")
                }
                if let justExcerpted { ReadingExcerptNotice { revealExcerpt(justExcerpted) } }
                if reader.canUndo {
                    ReadingIconButton(title: "撤销笔记改动", systemImage: "arrow.uturn.backward") {
                        if saveNote() { reader.undo(); justExcerpted = nil }
                    }
                }
            }.padding(.horizontal, 16).padding(.vertical, 5).frame(minHeight: 38)
                .font(.system(size: 13)).buttonStyle(.borderless)
        }
        .foregroundColor(Palette.ink).background(Palette.paper)
        .modifier(ReadingTranslationOverlay(store: store, session: translation))
        .notebookSheets(transfer, store: store, itemID: reader.itemID)
        .sheet(isPresented: $related) { RelatedReadingView(store: store, anchor: store.activeItem) }
        .task(id: justExcerpted) {
            guard justExcerpted != nil else { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { justExcerpted = nil }
        }
        .onAppear { if reader.revealed != nil { setNotes(true) } }
        .onChange(of: reader.revealed) { id in
            if let id, reader.editing == id || saveNote() {
                if let excerpt = reader.excerpts.first(where: { $0.id == id }) { includeInNotes(excerpt) }
                setNotes(true)
            }
        }
        .onChange(of: noteFilter) { _ in selectedNotes.formIntersection(visibleNotes.map(\.id)) }
        .onReceive(NotificationCenter.default.publisher(for: ReadingCommand.notification, object: store)) { event in
            guard let command = event.userInfo?["command"] as? ReadingCommand else { return }
            switch command {
            case .excerpt: capture()
            case .annotation: beginAnnotation()
            case .highlight: break
            case .translate: translateSelection()
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            ReadingIconButton(title: "保存位置并返回漫读", systemImage: "chevron.left") {
                if saveNote() { store.leaveReader() }
            }
            if !reader.isFocused {
                Text(reader.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).help(reader.title)
            }
            Spacer(minLength: 8)
            if !reader.document.headings.isEmpty {
                Button { contents.toggle() } label: { Label("目录", systemImage: "list.bullet.indent") }
                    .buttonStyle(ReadingControlStyle(selected: contents)).popover(isPresented: $contents, arrowEdge: .bottom) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(reader.document.headings) { heading in
                                    Button {
                                        reader.move?(heading.id); contents = false
                                    } label: {
                                        Text(heading.text).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(7).contentShape(Rectangle())
                                    }.buttonStyle(ReadingControlStyle())
                                }
                            }.padding(12)
                        }.frame(width: 290, height: 235).background(Palette.paper)
                    }
            }
            ReadingIconButton(title: notes ? "收起摘录与批注" : "打开摘录与批注", systemImage: "sidebar.right", selected: notes) {
                let shouldOpen = !notes
                if shouldOpen || saveNote() { setNotes(shouldOpen) }
            }
            ReadingAidButton(store: store)
            Group {
                ReadingTranslationButton(session: translation) {
                    if translation.presented { translation.close() }
                    else if reader.selectedQuote != nil { translateSelection() }
                    else { translation.open(.passage) }
                }
                ReadingPointTranslationButton(session: translation)
                ReadingFocusButton(focused: reader.isFocused, toggle: store.toggleReadingFocus)
            }
            if reader.isFocused { FocusLayoutButton(store: store) }
            if !reader.isFocused {
                Menu {
                    Button("查相似文献") { if saveNote() { related = true } }
                    Button("用原应用打开") { if let item = store.activeItem { store.openExternal(item) } }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28).accessibilityLabel("更多阅读操作")
            }
        }.padding(.horizontal, 16).padding(.vertical, 6)
    }

    private func translateSelection() {
        guard let text = reader.selectedQuote else { return }
        let source = TranslationPassage(text: text, title: reader.title, place: reader.document.place(at: reader.selection.location),
                                       document: TranslationDocument(itemID: reader.itemID, revision: reader.document.revision))
        translation.show(source, settings: store.library.preferences.translation ?? ReadingTranslationSettings(),
                         archive: store.translations)
    }

    private var visibleSentence: NSRange? {
        if case .text(let range) = translation.activeSentence { return range }
        return nil
    }

    private func translateSentence(at offset: Int) {
        guard let block = reader.document.blocks.first(where: { NSLocationInRange(offset, $0.range) }),
              let sentence = ReadingSentence.ranges(in: block.text).first(where: { NSLocationInRange(offset - block.range.location, $0) })
        else { return }
        if case .code = block.style { return }
        let text = (block.text as NSString).substring(with: sentence)
        guard text.contains(where: \.isLetter) else { return }
        let range = NSRange(location: block.range.location + sentence.location, length: sentence.length)
        let request = TranslationPassage(text: text, title: reader.title, place: reader.document.place(at: range.location),
                                        document: TranslationDocument(itemID: reader.itemID, revision: reader.document.revision))
        translation.show(request, settings: store.library.preferences.translation ?? ReadingTranslationSettings(),
                         archive: store.translations, sentence: .text(range))
    }

    private var notebook: some View {
        let visible = visibleNotes
        let sent = store.deliveredNotes(for: reader.itemID)
        return VStack(spacing: 0) {
            ReadingNotesHeader(total: reader.excerpts.count, visible: visible.count, selecting: selectingNotes,
                               searchPrompt: "搜原文、想法或章节", filter: $noteFilter, toggleSelection: {
                selectingNotes.toggle()
                selectedNotes = []
            }, close: {
                if saveNote() { setNotes(false) }
            })
            if selectingNotes && !visible.isEmpty {
                NotebookBatchControls(visible: Set(visible.map(\.id)), sent: sent, sending: transfer.sending, selected: $selectedNotes,
                                      send: send, remove: { saveNote() && reader.remove($0) })
                    .padding([.horizontal, .bottom], 9)
            }
            NotebookDeliveryStatus(transfer: transfer, store: store, itemID: reader.itemID)
                .padding(.horizontal, 9)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        if let pending = reader.pendingExcerpt { card(pending, sent: false, draft: true).id(pending.id) }
                        if visible.isEmpty && reader.pendingExcerpt == nil {
                            Text(noteFilter.isFiltering ? "没有找到符合条件的笔记。" : "选中文字可摘录或写批注。")
                                .font(.system(size: 12)).foregroundColor(Palette.muted)
                                .padding(.horizontal, 7).padding(.vertical, 12)
                        }
                        ForEach(visible) { excerpt in card(excerpt, sent: sent.contains(excerpt.id)).id(excerpt.id) }
                        ReadingRelatedSidebar(search: relatedSearch, store: store, itemID: reader.itemID,
                                              suggestedQuery: store.library.preferences.strategy.question, keep: keepRelated)
                            .id("reading-related")
                    }.padding(9)
                }
                .onAppear { if let id = reader.revealed { proxy.scrollTo(id, anchor: .top) } }
                .onChange(of: reader.revealed) { id in
                    if let id { DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) } }
                }
                .onChange(of: reader.editing) { id in
                    if let id { DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) } }
                }
                .onChange(of: relatedSearch.requestID) { _ in
                    DispatchQueue.main.async { proxy.scrollTo("reading-related", anchor: .top) }
                }
            }
        }.background(reader.isFocused ? layout.notes : Palette.paper)
    }

    private func card(_ excerpt: TextExcerpt, sent: Bool, draft: Bool = false) -> some View {
        let editing = reader.editing == excerpt.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                if selectingNotes && !draft { NotebookSelectionToggle(id: excerpt.id, selected: $selectedNotes) }
                Text(draft ? "新批注" : "摘录").font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 3)
                Text(excerpt.place).font(.system(size: 11)).foregroundColor(Palette.muted).lineLimit(1)
                    .help(excerpt.place)
            }
            ReadingNoteQuote(text: excerpt.quote, color: excerpt.appearance.color, editing: editing)
            if editing {
                ReadingNoteComposer(text: $reader.draft, cancel: reader.discardDraft, save: { _ = saveNote() })
            } else {
                if !excerpt.note.isEmpty {
                    Text(excerpt.note).font(.system(size: 13)).lineSpacing(3).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                noteActions(excerpt, sent: sent)
            }
        }
        .readingNoteRow(active: reader.revealed == excerpt.id || editing)
    }

    private func noteActions(_ excerpt: TextExcerpt, sent: Bool) -> some View {
        HStack(spacing: 1) {
            Button { store.inspectText(reader, excerpt: excerpt) } label: { Label("查原文", systemImage: "arrow.up.right") }
                .buttonStyle(ReadingControlStyle())
            Spacer(minLength: 0)
            ReadingIconButton(title: excerpt.note.isEmpty ? "写想法" : "编辑想法", systemImage: "square.and.pencil") {
                if saveNote() {
                    revealExcerpt(excerpt.id)
                    reader.editing = excerpt.id
                    reader.draft = excerpt.note
                }
            }
            ReadingIconButton(title: copied == excerpt.id ? "已复制" : "复制摘录与出处",
                              systemImage: copied == excerpt.id ? "checkmark" : "doc.on.doc") {
                let value = [reader.title + " · " + excerpt.place, excerpt.quote, excerpt.note].filter { !$0.isEmpty }.joined(separator: "\n\n")
                if copyText(value) { copied = excerpt.id }
            }
            NotebookSendButton(sent: sent) { if sent { store.openNotebook(reader.itemID, noteID: excerpt.id) } else { send([excerpt.id]) } }
                .disabled(transfer.sending && !sent)
            Menu {
                ReadingNoteAppearanceMenu(appearance: excerpt.appearance, changeColor: { color in
                    reader.setAppearance(ReadingMarkAppearance(color: color, style: excerpt.appearance.style), for: excerpt.id)
                }, changeStyle: { style in
                    reader.setAppearance(ReadingMarkAppearance(color: excerpt.appearance.color, style: style), for: excerpt.id)
                })
                Divider()
                Button("文献引文键…") { transfer.editingCitation = true }
                Button("Obsidian 收件设置…", action: transfer.openSetup)
                Button("移除", role: .destructive) { if saveNote() { reader.remove(excerpt.id) } }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: 28).accessibilityLabel("管理这条笔记")
        }.foregroundColor(Palette.muted)
    }

    private func setNotes(_ visible: Bool) {
        notebooks[focused: reader.isFocused] = visible
        if !visible { reader.revealed = nil }
    }

    private func capture(appearance: ReadingMarkAppearance? = nil) {
        guard saveNote(), let excerpt = reader.capture(appearance: appearance) else { return }
        reader.clearSelection?()
        if notes { revealExcerpt(excerpt.id) }
        else { justExcerpted = excerpt.id }
    }

    private func beginAnnotation() {
        guard saveNote(), let excerpt = reader.startAnnotation() else { return }
        reader.clearSelection?()
        reader.revealed = excerpt.id
        setNotes(true)
    }

    private func setMarkStyle(_ style: ReadingMarkStyle) {
        var appearance = markAppearance
        appearance.style = style
        store.commit { $0.preferences.readingMarkAppearance = appearance }
    }

    @discardableResult private func copyText(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    private func copySelection() {
        if let quote = reader.selectedQuote { copyText(quote) }
    }

    private func revealExcerpt(_ id: UUID) {
        justExcerpted = nil
        guard let excerpt = reader.excerpts.first(where: { $0.id == id }) else { return }
        includeInNotes(excerpt)
        setNotes(true)
        reader.revealed = id
    }

    private func includeInNotes(_ excerpt: TextExcerpt) {
        guard noteFilter.isFiltering else { return }
        noteFilter = noteFilter.including(color: excerpt.appearance.color, text: [excerpt.quote, excerpt.note, excerpt.place])
    }

    private func searchRelated() {
        guard let quote = reader.selectedQuote, saveNote() else { return }
        relatedSearch.search(quote, store: store, anchor: reader.itemID)
        reader.clearSelection?()
        setNotes(true)
    }

    private func keepRelated(_ text: String) -> Bool {
        guard saveNote() else { return false }
        let range = reader.selectedQuote != nil ? reader.selection :
            reader.document.blocks.last(where: { $0.id <= reader.offset })?.range
        guard let range else { return false }
        return reader.capture(at: range, addingNote: text) != nil
    }

    private func send(_ ids: Set<UUID>) {
        if saveNote() { transfer.send(ids, from: reader.itemID, store: store) }
    }

    private func saveNote() -> Bool {
        reader.saveDraft()
    }
}

struct TextCanvas: NSViewRepresentable {
    @ObservedObject var reader: TextReader
    var paper: Color
    var size: Double
    var lineSpacing: Double
    var emphasis: ReadingAidMode
    var sentence: NSRange? = nil
    var pointTranslate: ((Int) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(reader: reader) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ReaderTextScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let text = ReaderTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.maxSize = NSSize(width: 100_000, height: 100_000_000)
        text.textContainerInset = NSSize(width: 28, height: 30)
        text.textContainer?.widthTracksTextView = false
        text.setAccessibilityLabel("正文")
        text.delegate = context.coordinator
        scroll.documentView = text
        context.coordinator.attach(text, to: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? ReaderTextView else { return }
        text.onSentenceClick = pointTranslate
        if text.visibleSentence != sentence { text.showSentence(sentence) }
        let background = NSColor(paper)
        scroll.backgroundColor = background
        text.backgroundColor = background
        let style = Display(size: size, lineSpacing: lineSpacing, emphasis: emphasis, theme: Palette.theme)
        let coordinator = context.coordinator
        guard coordinator.display != style || coordinator.renderedMarks != reader.excerpts else { return }
        // TextKit relayout can invalidate the host's geometry. Apply it outside SwiftUI's update pass.
        coordinator.renderID = UUID()
        let request = coordinator.renderID
        DispatchQueue.main.async { [weak text, weak coordinator] in
            guard let text, let coordinator, coordinator.renderID == request else { return }
            if coordinator.display != style {
                let selection = text.selectedRange()
                let position = coordinator.display == nil ? nil : coordinator.readingPosition()
                coordinator.restoreAfterReflow(position ?? .init(offset: reader.offset, y: 12))
                coordinator.display = style
                text.textStorage?.setAttributedString(formatted())
                text.setSelectedRange(selection)
                text.showSentence(text.visibleSentence)
                coordinator.renderedMarks = nil
            }
            if coordinator.renderedMarks != reader.excerpts { renderMarks(in: text, coordinator: coordinator) }
        }
    }

    private func renderMarks(in text: NSTextView, coordinator: Coordinator) {
        guard let storage = text.textStorage else { return }
        coordinator.renderedMarks = reader.excerpts
        storage.beginEditing()
        storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
        var underlines: [(range: NSRange, color: NSColor)] = []
        for excerpt in reader.excerpts where excerpt.revision == reader.document.revision && reader.document.quote(excerpt.range) == excerpt.quote {
            let appearance = excerpt.appearance
            if appearance.style == .underline {
                underlines.append((excerpt.range, appearance.color.underlineColor(onDark: Palette.theme.isDark)))
            } else {
                storage.addAttribute(.backgroundColor, value: appearance.color.color.withAlphaComponent(0.24),
                                     range: excerpt.range)
            }
        }
        storage.endEditing()
        if let readerView = text as? ReaderTextView {
            readerView.underlines = underlines
            readerView.needsDisplay = true
        }
    }

    struct Display: Equatable {
        let size: Double
        let lineSpacing: Double
        let emphasis: ReadingAidMode
        let theme: AppTheme
    }

    private func formatted() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let body = NSFont.systemFont(ofSize: size)
        let ink = NSColor(Palette.ink)
        let output = NSMutableAttributedString(string: reader.document.content, attributes: [
            .font: body, .foregroundColor: ink, .paragraphStyle: paragraph
        ])
        for block in reader.document.blocks {
            let font: NSFont
            switch block.style {
            case .heading(let level): font = .systemFont(ofSize: size + Double(max(1, 8 - level * 2)), weight: .semibold)
            case .code: font = .monospacedSystemFont(ofSize: max(12, size - 2), weight: .regular)
            case .body, .quote: font = body
            }
            output.addAttribute(.font, value: font, range: block.range)
            if case .quote = block.style { output.addAttribute(.foregroundColor, value: NSColor(Palette.green), range: block.range) }
            var offset = block.id
            var protected = [NSRange]()
            for run in block.inline?.runs.map({ $0 }) ?? [] {
                guard let inline = block.inline else { break }
                let length = String(inline[run.range].characters).utf16.count
                let range = NSRange(location: offset, length: length)
                if let intent = run.inlinePresentationIntent {
                    if intent.contains(.code) || intent.contains(.stronglyEmphasized) {
                        protected.append(NSRange(location: offset - block.id, length: length))
                    }
                    var styled = font
                    if intent.contains(.code) { styled = .monospacedSystemFont(ofSize: max(12, size - 1), weight: .regular) }
                    if intent.contains(.stronglyEmphasized) { styled = NSFontManager.shared.convert(styled, toHaveTrait: .boldFontMask) }
                    if intent.contains(.emphasized) { styled = NSFontManager.shared.convert(styled, toHaveTrait: .italicFontMask) }
                    output.addAttribute(.font, value: styled, range: range)
                }
                if let link = run.link, let scheme = link.scheme?.lowercased(), ["http", "https"].contains(scheme) {
                    output.addAttribute(.link, value: link, range: range)
                    protected.append(NSRange(location: offset - block.id, length: length))
                }
                offset += length
            }
            guard case .body = block.style, emphasis != .off else { continue }
            for var anchor in ReadingWordEmphasis.ranges(in: block.text, mode: emphasis, excluding: protected) {
                anchor.location += block.id
                var styled: [(NSRange, NSFont)] = []
                output.enumerateAttribute(.font, in: anchor) { existing, range, _ in
                    let current = existing as? NSFont ?? font
                    styled.append((range, NSFontManager.shared.convert(current, toHaveTrait: .boldFontMask)))
                }
                for (range, emphasized) in styled { output.addAttribute(.font, value: emphasized, range: range) }
            }
        }
        return output
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        struct Position {
            let offset: Int
            let y: CGFloat
        }

        weak var reader: TextReader?
        weak var text: NSTextView?
        weak var clip: NSClipView?
        var observation: NSObjectProtocol?
        var display: Display?
        var renderedMarks: [TextExcerpt]?
        var renderID = UUID()
        private var selectionTracker: ReadingSelectionTracker?
        private var pendingPosition: Position?
        private var reflowQueued = false

        init(reader: TextReader) { self.reader = reader }

        func attach(_ text: ReaderTextView, to scroll: NSScrollView) {
            self.text = text
            clip = scroll.contentView
            reader?.move = { [weak self] in self?.move(to: $0) }
            text.onClick = { [weak self] offset in
                guard let reader = self?.reader, let excerpt = reader.excerpts.last(where: {
                    $0.revision == reader.document.revision && NSLocationInRange(offset, $0.range)
                }) else { return }
                reader.revealed = excerpt.id
            }
            reader?.clearSelection = { [weak self] in
                guard let self, let text = self.text, let reader = self.reader else { return }
                let range = NSRange(location: text.selectedRange().location, length: 0)
                text.setSelectedRange(range)
                reader.selection = range
                if reader.selectionAnchor != nil { reader.selectionAnchor = nil }
            }
            selectionTracker = ReadingSelectionTracker(locate: { [weak text, weak scroll, weak reader] in
                guard let text, let scroll, let window = text.window,
                      reader?.selectedQuote != nil else { return nil }
                let rect = text.firstRect(forCharacterRange: text.selectedRange(), actualRange: nil)
                return ReadingSelectionTracker.anchor(scroll.convert(window.convertFromScreen(rect), from: nil), in: scroll)
            }, show: { [weak reader] rect in
                if let reader, reader.selectionAnchor != rect { reader.selectionAnchor = rect }
            })
            (scroll as? ReaderTextScrollView)?.willChangeLineWidth = { [weak self] in
                if let self, let position = self.lastPosition { self.restoreAfterReflow(position) }
            }
            (scroll as? ReaderTextScrollView)?.onLayout = { [weak self] in self?.selectionTracker?.refresh() }
            scroll.contentView.postsBoundsChangedNotifications = true
            observation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.schedulePositionRead()
                self.selectionTracker?.refresh()
            }
        }

        func readingPosition() -> Position? {
            guard let text, let clip, !text.string.isEmpty else { return nil }
            if clip.bounds.minY <= 1 { return Position(offset: 0, y: 0) }
            let origin = text.textContainerOrigin
            let point = NSPoint(x: origin.x + 6, y: max(origin.y, clip.bounds.minY + 9))
            let offset = text.characterIndexForInsertion(at: point)
            let y = lineTop(at: offset).map { $0 - clip.bounds.minY } ?? 9
            return Position(offset: offset, y: y)
        }

        private var lastPosition: Position?
        private var positionReadQueued = false

        private func schedulePositionRead() {
            guard pendingPosition == nil, !positionReadQueued else { return }
            positionReadQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.positionReadQueued = false
                guard self.pendingPosition == nil else { return }
                self.readPosition()
            }
        }

        private func readPosition() {
            guard let position = readingPosition() else { return }
            lastPosition = position
            reader?.offset = position.offset
        }

        func restoreAfterReflow(_ position: Position) {
            if pendingPosition == nil { pendingPosition = position }
            guard !reflowQueued else { return }
            reflowQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reflowQueued = false
                guard let position = self.pendingPosition else { return }
                self.scroll(to: position)
                self.pendingPosition = nil
                self.readPosition()
                self.selectionTracker?.refresh()
            }
        }

        func move(to offset: Int) {
            pendingPosition = nil
            scroll(to: Position(offset: offset, y: 12))
            readPosition()
        }

        private func lineTop(at offset: Int) -> CGFloat? {
            guard let text, let manager = text.layoutManager else { return nil }
            let length = text.textStorage?.length ?? 0
            guard length > 0 else { return nil }
            let character = min(max(0, offset), length - 1)
            manager.ensureLayout(forCharacterRange: NSRange(location: character, length: 1))
            let glyph = manager.glyphIndexForCharacter(at: character)
            guard glyph < manager.numberOfGlyphs else { return nil }
            return manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + text.textContainerOrigin.y
        }

        private func scroll(to position: Position) {
            guard let clip, let top = lineTop(at: position.offset) else { return }
            var target = clip.bounds
            target.origin.y = position.offset == 0 ? 0 : top - position.y
            clip.scroll(to: clip.constrainBoundsRect(target).origin)
            clip.enclosingScrollView?.reflectScrolledClipView(clip)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            DispatchQueue.main.async { [weak self] in
                guard let self, let range = self.text?.selectedRange(), let reader = self.reader else { return }
                if reader.selection != range { reader.selection = range }
                self.selectionTracker?.refresh()
            }
        }

        deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }
    }
}

private final class ReaderTextScrollView: NSScrollView {
    var willChangeLineWidth: (() -> Void)?
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        guard let text = documentView as? NSTextView, let container = text.textContainer else { return }
        let width = contentView.bounds.width
        guard width > text.textContainerInset.width * 2 else { return }
        let lineWidth = width - text.textContainerInset.width * 2
        let rewrap = abs(container.containerSize.width - lineWidth) > 0.5
        if rewrap { willChangeLineWidth?() }
        if abs(text.frame.width - width) > 0.5 {
            text.setFrameSize(NSSize(width: width, height: text.frame.height))
        }
        if rewrap {
            container.containerSize = NSSize(width: lineWidth, height: CGFloat.greatestFiniteMagnitude)
        }
        onLayout?()
    }
}

final class ReaderTextView: NSTextView {
    var onClick: ((Int) -> Void)?
    var onSentenceClick: ((Int) -> Void)?
    private(set) var visibleSentence: NSRange?
    var underlines: [(range: NSRange, color: NSColor)] = []

    func showSentence(_ range: NSRange?) {
        guard let manager = layoutManager, let length = textStorage?.length else { return }
        if let previous = visibleSentence, NSMaxRange(previous) <= length {
            manager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: previous)
        }
        visibleSentence = range
        if let range, NSMaxRange(range) <= length {
            manager.addTemporaryAttribute(.backgroundColor, value: NSColor(Palette.green).withAlphaComponent(0.22), forCharacterRange: range)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !underlines.isEmpty, let manager = layoutManager, let container = textContainer else { return }
        let origin = textContainerOrigin
        let visible = manager.glyphRange(forBoundingRect: dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let visibleCharacters = manager.characterRange(forGlyphRange: visible, actualGlyphRange: nil)
        for underline in underlines {
            let characters = NSIntersectionRange(underline.range, visibleCharacters)
            guard characters.length > 0 else { continue }
            let glyphs = manager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
            underline.color.setFill()
            manager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, container, line, _ in
                let segment = NSIntersectionRange(line, glyphs)
                let bounds = manager.boundingRect(forGlyphRange: segment, in: container)
                if bounds.width > 1 {
                    let y = origin.y + used.maxY - 2
                    NSBezierPath(roundedRect: CGRect(x: origin.x + bounds.minX, y: y, width: bounds.width, height: 1.6),
                                 xRadius: 0.8, yRadius: 0.8).fill()
                }
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 1, selectedRange().length == 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let onSentenceClick else { onClick?(characterIndexForInsertion(at: point)); return }
        guard let manager = layoutManager, let container = textContainer else { return }
        let local = CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = manager.glyphIndex(for: local, in: container)
        guard glyph < manager.numberOfGlyphs,
              manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) else { return }
        let index = manager.characterIndexForGlyph(at: glyph)
        guard let storage = textStorage, index < storage.length, storage.attribute(.link, at: index, effectiveRange: nil) == nil else { return }
        onSentenceClick(index)
    }
}
