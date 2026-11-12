import AppKit
import NaturalLanguage
import SwiftUI

struct TextReaderView: View {
    @ObservedObject var reader: TextReader
    @ObservedObject var store: ReadingStore
    @State private var notes = false
    @State private var contents = false
    @State private var related = false
    @State private var copied: UUID?
    @State private var selectingNotes = false
    @State private var selectedNotes = Set<UUID>()
    @StateObject private var transfer = NotebookSendState()
    @StateObject private var relatedSearch = ReadingRelatedSearch()
    @State private var justExcerpted: UUID?
    private var layout: FocusLayout { (store.library.preferences.focusLayout ?? FocusLayout()).normalized() }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                TextCanvas(reader: reader, paper: reader.isFocused ? layout.paper : Palette.paper,
                           size: reader.isFocused ? layout.textSize : 17,
                           emphasis: store.library.preferences.readingWordEmphasis == true)
                    .frame(maxWidth: reader.isFocused ? layout.width : 800)
                    .frame(maxWidth: .infinity)
                    .background(reader.isFocused ? layout.desk : Palette.side)
                if notes {
                    Divider()
                    notebook.frame(width: reader.isFocused ? layout.notebookWidth : 308)
                }
            }
            Divider()
            HStack(spacing: 12) {
                Text(reader.url.pathExtension.uppercased()).font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 7).padding(.vertical, 4).background(Palette.side, in: RoundedRectangle(cornerRadius: 5))
                    .foregroundColor(Palette.green)
                Text(reader.title).font(.system(size: 12)).foregroundColor(Palette.muted).lineLimit(1)
                Spacer()
                Toggle("词首强调", isOn: Binding(get: { store.library.preferences.readingWordEmphasis == true },
                                             set: { value in store.updatePreferences { $0.readingWordEmphasis = value } }))
                    .toggleStyle(.switch).controlSize(.small).tint(Palette.green)
                if reader.selectedQuote != nil {
                    ReadingExcerptButton { capture() }
                    Button("写想法") { capture(edit: true) }
                        .keyboardShortcut("n", modifiers: [.command, .shift])
                    Button("查相关", action: searchRelated)
                        .help("用所选文字查相关原文")
                } else if justExcerpted == nil {
                    Text("选中文字可摘录").font(.system(size: 12)).foregroundColor(Palette.muted)
                }
                if let justExcerpted { ReadingExcerptNotice { revealExcerpt(justExcerpted) } }
                if reader.canUndo {
                    ReadingIconButton(title: "撤销笔记改动", systemImage: "arrow.uturn.backward") {
                        if saveNote() { reader.undo(); justExcerpted = nil }
                    }
                }
            }.padding(.horizontal, 24).padding(.vertical, 10)
                .font(.system(size: 13)).buttonStyle(.borderless)
        }
        .foregroundColor(Palette.ink).background(Palette.paper)
        .sheet(isPresented: $transfer.configuring) {
            NotebookExportEditor(store: store, pendingCount: transfer.pending.count) {
                transfer.send(transfer.pending, from: reader.itemID, store: store)
                transfer.pending = []
            }
        }
        .sheet(isPresented: $related) { RelatedReadingView(store: store, anchor: store.activeItem) }
        .task(id: justExcerpted) {
            guard justExcerpted != nil else { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { justExcerpted = nil }
        }
        .onAppear { if reader.revealed != nil { notes = true } }
        .onChange(of: reader.isFocused) { if $0 && reader.editing == nil { setNotes(false) } }
        .onChange(of: reader.revealed) { if $0 != nil { notes = true } }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button { if saveNote() { store.leaveReader() } } label: { Label("返回", systemImage: "chevron.left") }.buttonStyle(ActionStyle())
            if !reader.isFocused {
                VStack(alignment: .leading, spacing: 4) {
                    Text("阅读现场").font(.system(size: 11, weight: .medium)).foregroundColor(Palette.green)
                    Text(reader.title).font(.system(size: 19, weight: .medium, design: .serif)).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if !reader.document.headings.isEmpty {
                Button { contents.toggle() } label: { Label("目录", systemImage: "list.bullet.indent") }
                    .buttonStyle(ActionStyle()).popover(isPresented: $contents, arrowEdge: .bottom) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(reader.document.headings) { heading in
                                    Button {
                                        reader.move?(heading.id); contents = false
                                    } label: {
                                        Text(heading.text).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(7).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                            }.padding(12)
                        }.frame(width: 290, height: 235).background(Palette.paper)
                    }
            }
            Button { if saveNote() { setNotes(!notes) } } label: {
                Label(notes ? "收起摘录" : "摘录簿", systemImage: "sidebar.right")
            }.buttonStyle(ActionStyle())
            Button(action: store.toggleReadingFocus) {
                Label(reader.isFocused ? "退出专注" : "专注", systemImage: "viewfinder")
            }.buttonStyle(ActionStyle()).help("切换专注阅读 ⇧⌘F")
            if reader.isFocused { FocusLayoutButton(store: store).buttonStyle(ActionStyle()) }
            else {
                Menu {
                    Button("查相似文献") { if saveNote() { related = true } }
                    Button("用原应用打开") { if let item = store.activeItem { store.openExternal(item) } }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).frame(width: 34).accessibilityLabel("更多阅读操作")
            }
        }.padding(.horizontal, 24).padding(.vertical, 12)
    }

    private var notebook: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("摘录簿").font(.system(size: 25, weight: .medium, design: .serif))
                        Spacer()
                        if !reader.excerpts.isEmpty {
                            Button(selectingNotes ? "完成" : "批量") {
                                selectingNotes.toggle()
                                selectedNotes = []
                            }.buttonStyle(.plain).foregroundColor(Palette.green).font(.system(size: 12))
                        }
                    }
                    NotebookDeliveryStatus(transfer: transfer) { store.openNotebook(reader.itemID) }
                    if selectingNotes && !reader.excerpts.isEmpty {
                        NotebookBatchControls(visible: Set(reader.excerpts.map(\.id)), selected: $selectedNotes,
                                              send: send, remove: { saveNote() && reader.remove($0) })
                    }
                    if reader.excerpts.isEmpty {
                        Text("选一段文字，点「摘录」或按 ⇧⌘E。下次回来，还能找到它的位置。")
                            .font(.system(size: 13)).foregroundColor(Palette.muted).lineSpacing(4)
                    }
                    ReadingRelatedSidebar(search: relatedSearch, store: store, itemID: reader.itemID,
                        suggestedQuery: store.library.preferences.strategy.question, keep: keepRelated)
                        .id("reading-related")
                    let sent = store.deliveredNotes(for: reader.itemID)
                    ForEach(reader.excerpts.reversed()) { excerpt in card(excerpt, sent: sent.contains(excerpt.id)).id(excerpt.id) }
                }.padding(18)
            }
            .onAppear { if let id = reader.revealed { proxy.scrollTo(id, anchor: .top) } }
            .onChange(of: reader.revealed) { if let id = $0 { proxy.scrollTo(id, anchor: .top) } }
            .onChange(of: relatedSearch.requestID) { _ in proxy.scrollTo("reading-related", anchor: .top) }
        }.background(reader.isFocused ? layout.notes : Palette.side)
    }

    private func card(_ excerpt: TextExcerpt, sent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                if selectingNotes { NotebookSelectionToggle(id: excerpt.id, selected: $selectedNotes) }
                Text(excerpt.place).font(.system(size: 11, weight: .medium)).foregroundColor(Palette.green).lineLimit(2)
            }
            Text(excerpt.quote).font(.system(size: 14, design: .serif)).lineSpacing(3)
                .lineLimit(reader.editing == excerpt.id ? nil : 7).textSelection(.enabled)
            if reader.editing == excerpt.id {
                TextField("写下你的想法", text: $reader.draft, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
                HStack {
                    Button("取消") { reader.editing = nil }.buttonStyle(.plain)
                    Spacer()
                    Button("保存") { _ = saveNote() }.buttonStyle(.borderedProminent).tint(Palette.accent)
                }.font(.system(size: 12))
            } else if !excerpt.note.isEmpty {
                Text(excerpt.note).font(.system(size: 13)).foregroundColor(Palette.muted).textSelection(.enabled)
            }
            HStack {
                Button("查原文") { store.inspectText(reader, excerpt: excerpt) }
                Spacer()
                NotebookSendButton(sent: sent) { if sent { store.openNotebook(reader.itemID, noteID: excerpt.id) } else { send([excerpt.id]) } }
                Button {
                    let value = [reader.title + " · " + excerpt.place, excerpt.quote, excerpt.note].filter { !$0.isEmpty }.joined(separator: "\n\n")
                    NSPasteboard.general.clearContents()
                    if NSPasteboard.general.setString(value, forType: .string) { copied = excerpt.id }
                } label: { Image(systemName: copied == excerpt.id ? "checkmark" : "doc.on.doc") }
                    .accessibilityLabel("复制摘录与出处")
                Menu {
                    Button("写想法") { if saveNote() { reader.editing = excerpt.id; reader.draft = excerpt.note } }
                    Button("Obsidian 收件与模板…", action: transfer.openSetup)
                    Button("移除", role: .destructive) { if saveNote() { reader.remove(excerpt.id) } }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 25).accessibilityLabel("管理摘录")
            }.font(.system(size: 12)).buttonStyle(.plain).foregroundColor(Palette.green)
        }.padding(12)
            .background(reader.revealed == excerpt.id ? Palette.surface : Palette.paper, in: RoundedRectangle(cornerRadius: 9))
    }

    private func setNotes(_ visible: Bool) {
        notes = visible
        if !visible { reader.revealed = nil }
    }

    private func capture(edit: Bool = false) {
        guard saveNote(), let excerpt = reader.capture() else { return }
        if notes || edit { revealExcerpt(excerpt.id) }
        else { justExcerpted = excerpt.id }
        if edit {
            reader.editing = excerpt.id
            reader.draft = excerpt.note
        }
    }

    private func revealExcerpt(_ id: UUID) {
        justExcerpted = nil
        guard reader.excerpts.contains(where: { $0.id == id }) else { return }
        setNotes(true)
        reader.revealed = id
    }

    private func searchRelated() {
        guard let quote = reader.selectedQuote, saveNote() else { return }
        relatedSearch.search(quote, store: store, anchor: reader.itemID)
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
    let reader: TextReader
    var paper: Color
    var size: Double
    var emphasis: Bool

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
        guard let text = scroll.documentView as? NSTextView else { return }
        let background = NSColor(paper)
        scroll.backgroundColor = background
        text.backgroundColor = background
        let style = Display(size: size, emphasis: emphasis, theme: Palette.theme)
        let coordinator = context.coordinator
        if coordinator.display != style {
            let selection = text.selectedRange()
            let offset = reader.offset
            coordinator.display = style
            text.textStorage?.setAttributedString(formatted())
            text.setSelectedRange(selection)
            DispatchQueue.main.async { coordinator.move(to: offset) }
            coordinator.renderedMarks = nil
        }
        if coordinator.renderedMarks != reader.excerpts, let manager = text.layoutManager {
            coordinator.renderedMarks = reader.excerpts
            manager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: text.string.utf16.count))
            for excerpt in reader.excerpts where excerpt.revision == reader.document.revision && reader.document.quote(excerpt.range) == excerpt.quote {
                manager.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.24), forCharacterRange: excerpt.range)
            }
        }
    }

    struct Display: Equatable {
        let size: Double
        let emphasis: Bool
        let theme: AppTheme
    }

    private func formatted() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        let body = NSFont.systemFont(ofSize: size)
        let ink = NSColor(Palette.ink)
        let output = NSMutableAttributedString(string: reader.document.content, attributes: [
            .font: body, .foregroundColor: ink, .paragraphStyle: paragraph
        ])
        let tokenizer = emphasis ? NLTokenizer(unit: .word) : nil
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
            for run in block.inline?.runs.map({ $0 }) ?? [] {
                guard let inline = block.inline else { break }
                let length = String(inline[run.range].characters).utf16.count
                let range = NSRange(location: offset, length: length)
                if let intent = run.inlinePresentationIntent {
                    var styled = font
                    if intent.contains(.code) { styled = .monospacedSystemFont(ofSize: max(12, size - 1), weight: .regular) }
                    if intent.contains(.stronglyEmphasized) { styled = NSFontManager.shared.convert(styled, toHaveTrait: .boldFontMask) }
                    if intent.contains(.emphasized) { styled = NSFontManager.shared.convert(styled, toHaveTrait: .italicFontMask) }
                    output.addAttribute(.font, value: styled, range: range)
                }
                if let link = run.link, let scheme = link.scheme?.lowercased(), ["http", "https"].contains(scheme) {
                    output.addAttribute(.link, value: link, range: range)
                }
                offset += length
            }
            if case .code = block.style { continue }
            guard let tokenizer else { continue }
            tokenizer.string = block.text
            tokenizer.enumerateTokens(in: block.text.startIndex..<block.text.endIndex) { range, _ in
                let word = block.text[range]
                guard word.count > 1, word.contains(where: \.isLetter) else { return true }
                let end = word.index(word.startIndex, offsetBy: max(1, Int((Double(word.count) * 0.4).rounded(.up))))
                var head = NSRange(range.lowerBound..<end, in: block.text)
                head.location += block.id
                let current = output.attribute(.font, at: head.location, effectiveRange: nil) as? NSFont ?? font
                output.addAttribute(.font, value: NSFontManager.shared.convert(current, toHaveTrait: .boldFontMask), range: head)
                return true
            }
        }
        return output
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var reader: TextReader?
        weak var text: NSTextView?
        weak var clip: NSClipView?
        var observation: NSObjectProtocol?
        var display: Display?
        var renderedMarks: [TextExcerpt]?

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
            scroll.contentView.postsBoundsChangedNotifications = true
            observation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                guard let self, let text = self.text, let clip = self.clip else { return }
                let point = NSPoint(x: text.textContainerInset.width + 6, y: max(text.textContainerInset.height, clip.bounds.minY + 2))
                self.reader?.offset = text.characterIndexForInsertion(at: point)
            }
        }

        func move(to offset: Int) {
            guard let text, let manager = text.layoutManager, let container = text.textContainer, let clip else { return }
            let length = text.string.utf16.count
            let character = min(max(0, offset), max(0, length - 1))
            manager.ensureLayout(for: container)
            let glyph = manager.glyphIndexForCharacter(at: character)
            guard glyph < manager.numberOfGlyphs else { return }
            let rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let y = offset == 0 ? 0 : rect.minY + text.textContainerInset.height - 12
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: y), size: clip.bounds.size)).origin)
            clip.enclosingScrollView?.reflectScrolledClipView(clip)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let range = text?.selectedRange() else { return }
            DispatchQueue.main.async { [weak self] in self?.reader?.selection = range }
        }

        deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }
    }
}

private final class ReaderTextScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let text = documentView as? NSTextView, let container = text.textContainer else { return }
        let width = contentView.bounds.width
        guard width > text.textContainerInset.width * 2 else { return }
        if abs(text.frame.width - width) > 0.5 {
            text.setFrameSize(NSSize(width: width, height: text.frame.height))
        }
        let lineWidth = width - text.textContainerInset.width * 2
        if abs(container.containerSize.width - lineWidth) > 0.5 {
            container.containerSize = NSSize(width: lineWidth, height: CGFloat.greatestFiniteMagnitude)
        }
    }
}

final class ReaderTextView: NSTextView {
    var onClick: ((Int) -> Void)?
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 1, selectedRange().length == 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        onClick?(characterIndexForInsertion(at: point))
    }
}
