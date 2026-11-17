import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct PDFTranslationControls: View {
    let source: PDFTranslationSource
    let page: Int
    let archive: ReadingTranslationArchive
    let settings: ReadingTranslationSettings
    let changeSourceLanguage: (TranslationLanguage) -> Void
    @ObservedObject var jobs: PDFTranslationJobs
    let configure: () -> Void
    let open: (PDFTranslationFile?, Bool) -> Void

    @State private var importing = false
    @State private var localMessage: String?
    @State private var decision: Decision?
    private struct Decision: Identifiable {
        let id = UUID()
        let scope: PDFTranslationScope
        var removal: PDFTranslationFile?
    }
    private var whole: PDFTranslationFile? { saved(.document) }
    private var partial: PDFTranslationFile? { saved(.page(page)) }
    private func saved(_ scope: PDFTranslationScope) -> PDFTranslationFile? {
        archive.generatedPDF(source, scope: scope, settings: settings) ?? archive.pdf(source, scope: scope)
    }
    private var recentPage: (Int, PDFTranslationFile)? {
        guard let outcome = jobs.outcome, outcome.document == source.document,
              case .page(let index) = outcome.scope, index != page,
              let file = outcome.file else { return nil }
        return (index, file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button { open(partial ?? whole, true) } label: {
                Label("边读边译", systemImage: "rectangle.split.2x1")
            }.buttonStyle(ReadingControlStyle(accented: true))
            if let whole { fileRow(whole, scope: .document) }
            if let partial { fileRow(partial, scope: .page(page)) }
            if let (index, file) = recentPage { fileRow(file, scope: .page(index)) }
            if whole == nil && partial == nil && recentPage == nil {
                Text("从当前页开始阅读，可在对照窗口预译下一页。")
                    .font(.system(size: 12)).foregroundColor(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let activity = jobs.activity, activity.document == source.document {
                HStack(alignment: .center, spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(activity.cancelling ? "正在停止…" : "正在翻译 \(activity.scope.description)，可继续读原文")
                        .font(.system(size: 12)).foregroundColor(Palette.muted)
                    Spacer(minLength: 3)
                    Button("停止", action: jobs.cancel)
                        .buttonStyle(ReadingControlStyle()).disabled(activity.cancelling)
                }.padding(.vertical, 3)
            } else if let outcome = jobs.outcome, outcome.document == source.document,
                      let message = outcome.message {
                Text(message).font(.system(size: 12)).foregroundColor(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let localMessage {
                Text(localMessage).font(.system(size: 12)).foregroundColor(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Menu {
                    Picker("原文语言", selection: Binding(get: { settings.pdfSource }, set: changeSourceLanguage)) {
                        ForEach(TranslationLanguage.allCases) { Text($0.title).tag($0) }
                    }
                    Divider()
                    Button("先试第 \(page + 1) 页") { request(.page(page)) }
                    Button("生成整篇译文…") { request(.document) }
                } label: { Label("生成译文", systemImage: "doc.badge.gearshape") }
                    .menuStyle(.borderlessButton).fixedSize()
                Spacer()
                Button(importing ? "正在关联…" : "关联译文 PDF…", action: importPDF)
                    .buttonStyle(ReadingControlStyle())
            }.disabled(importing || jobs.activity != nil)
            if jobs.activity?.document != source.document && jobs.activity != nil {
                Text("另一份 PDF 正在翻译，完成后可生成这一篇。")
                    .font(.system(size: 11)).foregroundColor(Palette.muted)
            }
        }
        .alert(item: $decision) { choice in
            if let file = choice.removal {
                return Alert(title: Text("移除这份译文？"),
                             message: Text("漫读会清除保存在本机资料库中的译文副本。"),
                             primaryButton: .destructive(Text("移除")) {
                    do {
                        try archive.removePDF(source, scope: choice.scope, profile: file.profile)
                        jobs.clearOutcome(for: source.document)
                        localMessage = "已移除这份译文。"
                    } catch { localMessage = "未能移除译文。\(error.localizedDescription)" }
                }, secondaryButton: .cancel(Text("取消")))
            }
            let title = choice.scope == .document ? "生成整篇译文？" : "更新这一页的译文？"
            return Alert(title: Text(title),
                         message: Text(settings.isRemote
                            ? "译为\(settings.target.title)。这次生成会把所选范围的 PDF 文本发送给配置的 API，可能产生费用。"
                            : "以\(settings.pdfSource.title)为原文，译为\(settings.target.title)。生成时可以继续阅读。"),
                         primaryButton: .default(Text("开始生成")) { start(choice.scope) },
                         secondaryButton: .cancel(Text("取消")))
        }
    }

    private func fileRow(_ translation: PDFTranslationFile, scope: PDFTranslationScope) -> some View {
        HStack(spacing: 8) {
            Button {
                open(translation, translation.pages.count == 1)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 14, weight: .medium)).foregroundColor(Palette.green)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("读\(scope.description)对照").font(.system(size: 13, weight: .medium))
                        Text(translation.target?.title ?? "导入的译文").font(.system(size: 11)).foregroundColor(Palette.muted)
                    }
                    Spacer()
                }.padding(6).contentShape(Rectangle())
            }.buttonStyle(ReadingControlStyle(horizontalPadding: 4))
            Menu {
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([translation.url]) }
                Button("移除译文…", role: .destructive) { decision = Decision(scope: scope, removal: translation) }
                    .disabled(importing || jobs.activity != nil)
            } label: { Image(systemName: "ellipsis").frame(width: 24) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 30)
                .accessibilityLabel("管理译文")
        }.background(Palette.side, in: RoundedRectangle(cornerRadius: 8))
    }

    private func request(_ scope: PDFTranslationScope) {
        localMessage = nil
        if settings.service == nil || PDFTranslationTool.executable(settings.pdfTool) == nil {
            configure()
        } else if settings.target == settings.pdfSource {
            localMessage = "原文和译文语言相同。请在「生成译文」里调整原文语言。"
        } else if settings.isRemote || scope == .document || saved(scope) != nil {
            decision = Decision(scope: scope)
        } else {
            start(scope)
        }
    }

    private func start(_ scope: PDFTranslationScope) {
        localMessage = nil
        jobs.start(source, scope: scope, settings: settings)
    }

    private func importPDF() {
        let panel = NSOpenPanel()
        panel.title = "关联与原文逐页对应的译文 PDF"
        panel.message = "请选择与原文页数和版式一致的纯译文 PDF。"
        panel.allowedContentTypes = [.pdf]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let archive = self.archive, source = self.source
        importing = true
        localMessage = nil
        let task = Task.detached(priority: .userInitiated) {
            try archive.importPDF(url, for: source, scope: .document)
        }
        Task { @MainActor in
            defer { importing = false }
            do {
                let file = try await task.value
                jobs.clearOutcome(for: source.document)
                open(file, false)
            } catch {
                localMessage = error.localizedDescription
            }
        }
    }
}

struct PDFBilingualRequest: Identifiable {
    var id = UUID()
    let original: PDFDocument
    let source: PDFTranslationSource
    let startingFile: PDFTranslationFile?
    let title: String
    let startPage: Int
    let follow: Bool
}

private final class PDFComparisonWindow: ReadingAppWindow {
    var navigate: ((PDFComparisonScroll.Turn) -> Void)?
    var canNavigate: ((Int) -> Bool)?
    private var pageGesture = PDFComparisonScroll()

    override func sendEvent(_ event: NSEvent) {
        if handleNavigation(event) { return }
        super.sendEvent(event)
    }

    private func handleNavigation(_ event: NSEvent) -> Bool {
        guard attachedSheet == nil, let navigate, let canNavigate else { return false }
        if event.type == .keyDown {
            guard !(firstResponder is NSTextView),
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
            let step: Int
            switch event.keyCode {
            case 123, 116: step = -1 // Left, Page Up
            case 124, 121: step = 1  // Right, Page Down
            default: return false
            }
            if canNavigate(step) { navigate(.init(step: step, fromBottom: false)) }
            return true
        }
        guard event.type == .scrollWheel || event.type == .swipe,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let pdf = pdfUnderPointer(event),
              let scrollView = pdf.documentView?.enclosingScrollView else { return false }
        let clip = scrollView.contentView
        if event.type == .scrollWheel, !event.momentumPhase.isEmpty {
            if !pageGesture.blocksMomentum { pan(scrollView, by: event) }
            return true
        }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) { pageGesture.begin() }
        if event.type == .scrollWheel, event.phase.contains(.ended) || event.phase.contains(.cancelled) { return true }
        if event.type == .scrollWheel, !event.phase.isEmpty, pageGesture.blocksMomentum { return true }

        let x = event.type == .swipe ? event.deltaX : event.scrollingDeltaX
        let y = event.type == .swipe ? event.deltaY : event.scrollingDeltaY
        let horizontal = abs(x) > abs(y) * 1.3
        let delta = horizontal ? x : y
        let step = delta < 0 ? 1 : -1
        let frame = clip.documentRect
        let viewport = clip.bounds
        let forwards = horizontal || clip.isFlipped ? step > 0 : step < 0
        let fitsWidth = frame.width - viewport.width <= 32
        let atEdge = horizontal
            ? (fitsWidth || (forwards ? viewport.maxX >= frame.maxX - 2 : viewport.minX <= frame.minX + 2))
            : (forwards ? viewport.maxY >= frame.maxY - 2 : viewport.minY <= frame.minY + 2)
        if let turn = pageGesture.turn(delta: delta, axis: horizontal ? .horizontal : .vertical,
                                       timestamp: event.timestamp > 0 ? event.timestamp : ProcessInfo.processInfo.systemUptime,
                                       precise: event.type == .scrollWheel && event.hasPreciseScrollingDeltas,
                                       atEdge: atEdge, canTurn: canNavigate(step)) {
            navigate(turn)
        } else if event.type == .scrollWheel {
            pan(scrollView, by: event)
        }
        return true
    }

    private func pan(_ scrollView: NSScrollView, by event: NSEvent) {
        // PDFKit may turn only its own pane when its scroll view receives an event at the page edge.
        let clip = scrollView.contentView
        let frame = clip.documentRect, viewport = clip.bounds
        let lines = !event.hasPreciseScrollingDeltas
        let x = viewport.minX - event.scrollingDeltaX * (lines ? scrollView.horizontalLineScroll : 1)
        let y = viewport.minY + event.scrollingDeltaY * (lines ? scrollView.verticalLineScroll : 1) * (clip.isFlipped ? -1 : 1)
        let location = CGPoint(x: min(max(frame.minX, frame.maxX - viewport.width), max(frame.minX, x)),
                               y: min(max(frame.minY, frame.maxY - viewport.height), max(frame.minY, y)))
        guard location != viewport.origin else { return }
        clip.scroll(to: location)
        scrollView.reflectScrolledClipView(clip)
    }

    private func pdfUnderPointer(_ event: NSEvent) -> PDFView? {
        guard let contentView else { return nil }
        let location = event.windowNumber == 0 ? convertPoint(fromScreen: event.locationInWindow) : event.locationInWindow
        let point = contentView.superview?.convert(location, from: nil) ?? location
        var hit = contentView.hitTest(point)
        while let view = hit {
            if let surface = view as? ComparisonPDFSurface { return surface.pdf }
            hit = view.superview
        }
        return nil
    }
}

final class PDFComparisonWindowController: NSObject, ObservableObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var jobs: PDFTranslationJobs?
    private var owner: UUID?

    @discardableResult func bringForward() -> Bool {
        guard let window else { return false }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func present(_ request: PDFBilingualRequest, reader: PDFReader, store: ReadingStore, returnToPage: @escaping (Int) -> Void) {
        if bringForward() { return }
        let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size ?? NSSize(width: 1220, height: 850)
        let window = PDFComparisonWindow(contentRect: NSRect(x: 0, y: 0, width: min(1280, area.width * 0.94),
                                                            height: min(900, area.height * 0.91)),
                                     styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = request.title + " · 双语对照"
        window.titleVisibility = .hidden
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentMinSize = NSSize(width: 850, height: 510)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: PDFBilingualView(request: request, reader: reader, store: store,
                                    jobs: store.pdfTranslationJobs, closeWindow: { [weak self] in self?.close() },
                                    returnToPage: returnToPage,
                                    installNavigation: { [weak window] canNavigate, navigate in
                                        window?.canNavigate = canNavigate
                                        window?.navigate = navigate
                                    }))
        if !window.setFrameUsingName("WanderReadPDFComparison") { window.center() }
        window.setFrameAutosaveName("WanderReadPDFComparison")
        self.window = window
        owner = request.id
        jobs = store.pdfTranslationJobs
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        if jobs?.activity?.owner == owner, owner != nil { jobs?.cancel() }
        (window as? PDFComparisonWindow)?.navigate = nil
        (window as? PDFComparisonWindow)?.canNavigate = nil
        window = nil
        jobs = nil
        owner = nil
    }
}

private struct PDFBilingualView: View {
    private enum Mode: Hashable { case original, both, translation }
    private struct LoadedPage {
        let file: PDFTranslationFile
        let document: PDFDocument
        let sourcePage: Int
        let numberingChanged: Bool
    }
    private enum RemoteAction { case follow, page }

    let request: PDFBilingualRequest
    @ObservedObject var reader: PDFReader
    @ObservedObject var store: ReadingStore
    @ObservedObject var jobs: PDFTranslationJobs
    let closeWindow: () -> Void
    let returnToPage: (Int) -> Void
    let installNavigation: (@escaping (Int) -> Bool, @escaping (PDFComparisonScroll.Turn) -> Void) -> Void
    @State private var mode: Mode = .both
    @State private var page: Int
    @State private var scroll = CGFloat(0)
    @State private var zoom = CGFloat(1)
    @State private var pageText: String
    @State private var following = false
    @State private var useStartingFile = true
    @State private var manuallyRequested = false
    @State private var failures: [Int: String] = [:]
    @State private var loaded: LoadedPage?
    @State private var remoteAction: RemoteAction?
    @State private var errorMessage: String?
    @State private var selection: PDFSelection?
    @State private var selectionAnchor: CGRect?
    @State private var selectionReset = UUID()
    @State private var retranslateMode = false
    @State private var retranslateHint: String?
    @State private var notesOpened = false
    @State private var noteDraft: PDFReadingMark?
    @State private var noteText = ""
    @State private var noteFilter = ReadingNoteFilter()
    @State private var selectingNotes = false
    @State private var selectedNotes = Set<UUID>()
    @State private var quoteRepair: PDFReadingMark?
    @State private var excerptedPage: Int?
    @StateObject private var sentences = ReadingTranslationSession()
    @StateObject private var transfer = NotebookSendState()

    init(request: PDFBilingualRequest, reader: PDFReader, store: ReadingStore, jobs: PDFTranslationJobs,
         closeWindow: @escaping () -> Void, returnToPage: @escaping (Int) -> Void,
         installNavigation: @escaping (@escaping (Int) -> Bool, @escaping (PDFComparisonScroll.Turn) -> Void) -> Void) {
        self.request = request
        self.reader = reader
        self.store = store
        self.jobs = jobs
        self.closeWindow = closeWindow
        self.returnToPage = returnToPage
        self.installNavigation = installNavigation
        let current = request.startPage
        let start = request.startingFile.map { $0.pages.contains(current) ? current : $0.pages.lowerBound } ?? current
        _page = State(initialValue: start)
        _pageText = State(initialValue: String(start + 1))
    }

    private var settings: ReadingTranslationSettings { store.library.preferences.translation ?? ReadingTranslationSettings() }
    private var archive: ReadingTranslationArchive { store.translations }
    private var canTranslate: Bool {
        settings.pdfProfile != nil && settings.target != settings.pdfSource && PDFTranslationTool.executable(settings.pdfTool) != nil
    }
    private var markAppearance: ReadingMarkAppearance { store.library.preferences.readingMarkAppearance ?? ReadingMarkAppearance() }
    private var count: Int { request.source.pageCount }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if retranslateMode {
                HStack {
                    Label(retranslateHint ?? "点原文或译文中的一段，也可在原文拖选几句。", systemImage: "cursorarrow.click")
                        .font(.system(size: 11)).foregroundColor(Palette.muted)
                    Spacer()
                    Button("结束选段", action: toggleRetranslation).buttonStyle(ReadingControlStyle())
                }.padding(.horizontal, 15).padding(.vertical, 4)
                Divider()
            }
            HStack(spacing: 0) {
                if mode != .translation {
                    pairedPage("原文", document: request.original, index: page, isOriginal: true)
                }
                if mode == .both { Divider() }
                if mode != .original { translationPane }
                if notesOpened {
                    Divider()
                    notes.frame(width: 272)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 850, minHeight: 510)
        .background(Palette.paper).foregroundColor(Palette.ink)
        .preferredColorScheme(Palette.theme.isDark ? .dark : .light)
        .modifier(ReadingTranslationOverlay(store: store, session: sentences, inSheet: true))
        .onAppear {
            installNavigation({ step in
                !sentences.configuring && remoteAction == nil && !transfer.configuring
                    && noteDraft == nil && quoteRepair == nil && (0..<count).contains(page + step)
            }, { turn in jump(page + turn.step, fromBottom: turn.fromBottom) })
            let compatible = request.startingFile?.target.map { $0 == settings.target } ?? true
            following = request.follow && compatible && canTranslate && !settings.isRemote
            refreshPage()
            scheduleTranslation()
        }
        .onDisappear { if jobs.activity?.owner == request.id { jobs.cancel() } }
        .task(id: page) {
            // Let the new canvases lay out before the worker starts reading the PDF.
            try? await Task.sleep(nanoseconds: 240_000_000)
            if !Task.isCancelled { scheduleTranslation() }
        }
        .onChange(of: mode) { _ in sentences.clearSentence(); clearSelection(); retranslateHint = nil }
        .onChange(of: sentences.pointMode) { value in if value { retranslateMode = false; retranslateHint = nil } }
        .onChange(of: settings.pdfProfile) { _ in
            manuallyRequested = false
            remoteAction = nil
            useStartingFile = false
            if settings.isRemote || !canTranslate { following = false }
            failures = [:]
            sentences.clearSentence()
            refreshPage()
            scheduleTranslation()
        }
        .onReceive(jobs.$outcome) { result in
            guard let result else { return }
            if result.owner == request.id, result.profile == settings.pdfProfile, case .page(let index) = result.scope {
                if index == page { manuallyRequested = false }
                if !result.cancelled { failures[index] = result.message }
            }
            refreshPage()
            scheduleTranslation()
        }
        .confirmationDialog("使用远程 API 翻译", isPresented: Binding(get: { remoteAction != nil }, set: { if !$0 { remoteAction = nil } }),
                            presenting: remoteAction) { action in
            Button("开始") {
                switch action {
                case .follow: enableFollowing()
                case .page: translateCurrentPage()
                }
                remoteAction = nil
            }
            Button("取消", role: .cancel) { remoteAction = nil }
        } message: { action in
            Text(action == .follow
                 ? "会发送当前缺少译文的页面和接下来浏览时要预译的一页，可能产生 API 费用。关闭窗口即停止。"
                 : "会把当前页的待译文字发送给配置的 API，可能产生费用。")
        }
        .alert("双语对照", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .sheet(item: $noteDraft) { mark in editNote(mark) }
        .sheet(item: $quoteRepair) { mark in PDFQuoteRepairEditor(reader: reader, noteID: mark.id) }
        .notebookSheets(transfer, store: store, itemID: reader.itemID)
    }

    private var header: some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 4) {
                Text("双语对照").font(.system(size: 18, weight: .semibold))
                Text(request.title).font(.system(size: 11)).foregroundColor(Palette.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            ReadingTabs(selection: $mode, options: [(.original, "原文"), (.both, "对照"), (.translation, "译文")])
            Divider().frame(height: 19)
            Group {
                ReadingPointTranslationButton(session: sentences).disabled(mode == .translation)
                Button(action: toggleRetranslation) {
                    Label("重译", systemImage: "arrow.clockwise")
                }.buttonStyle(ReadingControlStyle(selected: retranslateMode))
                    .help("点选漏译或需要改译的段落")
                    .accessibilityIdentifier("ComparisonRetranslate")
                ReadingIconButton(title: "摘录与批注", systemImage: "sidebar.right", selected: notesOpened) { notesOpened.toggle() }
                ReadingIconButton(title: "翻译设置", systemImage: "gearshape", action: configure)
            }
            Button("回原文此页") { returnToPage(page); closeWindow() }
                .buttonStyle(ReadingControlStyle())
        }.padding(.horizontal, 15).padding(.vertical, 9)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Group {
            ReadingIconButton(title: "上一页 · ←", systemImage: "chevron.left") { jump(page - 1) }
                .disabled(page == 0).keyboardShortcut(.leftArrow, modifiers: .command)
            TextField("原文页码", text: $pageText).textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced)).multilineTextAlignment(.center)
                .frame(width: 44)
                .onSubmit {
                    if let value = Int(pageText), value > 0 { jump(value - 1) }
                    pageText = String(page + 1)
                }
                .accessibilityLabel("原文页码")
            Text("/ \(count)").font(.system(size: 12)).monospacedDigit().foregroundColor(Palette.muted)
            ReadingIconButton(title: "下一页 · →", systemImage: "chevron.right") { jump(page + 1) }
                .disabled(page + 1 == count).keyboardShortcut(.rightArrow, modifiers: .command)
                .help("滚到页底继续向下，或在页面内左右滑动。也可按 ← / →。")
            }
            Divider().frame(height: 17)
            Button(action: toggleFollowing) {
                Label("跟读翻译", systemImage: following ? "checkmark.circle.fill" : "arrow.clockwise")
            }.buttonStyle(ReadingControlStyle(selected: following))
                .help(following ? "开启 · 预译下一页" : "开启后，预先翻译紧接着的一页")
            translationStatus
            Spacer(minLength: 6)
            Group {
                ReadingIconButton(title: "缩小页面", systemImage: "minus.magnifyingglass") { zoom = max(0.75, zoom - 0.25) }.disabled(zoom <= 0.75)
                Button("\(Int(zoom * 100))%") { zoom = 1 }.buttonStyle(ReadingControlStyle()).monospacedDigit().help("恢复适合宽度")
                ReadingIconButton(title: "放大页面", systemImage: "plus.magnifyingglass") { zoom = min(2.5, zoom + 0.25) }.disabled(zoom >= 2.5)
            }
            Divider().frame(height: 17)
            Menu {
                Button(loaded?.file.pages.count == count ? "导出整份译文…" : "导出本页译文…", action: export).disabled(loaded == nil)
                Button("用当前设置重译此页") { requestCurrentPage() }.disabled(jobs.activity?.owner == request.id)
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
                .accessibilityLabel("译文操作")
        }.padding(.horizontal, 12).padding(.vertical, 7)
    }

    @ViewBuilder private var translationStatus: some View {
        if let activity = jobs.activity, activity.owner == request.id {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text(activity.cancelling ? "正在停止" : "翻译\(activity.scope.description)")
            }.font(.system(size: 11)).foregroundColor(Palette.muted).lineLimit(1)
        } else if following && page + 1 < count, file(at: page + 1) != nil {
            Label("下一页已就绪", systemImage: "checkmark").font(.system(size: 11)).foregroundColor(Palette.muted)
        } else if following, let message = failures[page + 1] {
            Button("重试下一页") { failures[page + 1] = nil; scheduleTranslation() }
                .buttonStyle(ReadingControlStyle()).help(message)
        } else if excerptedPage == page {
            Text("已摘录").font(.system(size: 11)).foregroundColor(Palette.muted)
        }
    }

    @ViewBuilder private var translationPane: some View {
        if let loaded, let index = loaded.file.translatedPage(for: page) {
            pairedPage(loaded.file.imported ? "导入译文" : "机器译文", document: loaded.document, index: index,
                       numberingChanged: loaded.numberingChanged)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                paneLabel("译文")
                VStack(alignment: .leading, spacing: 9) {
                    if let failure = failures[page] {
                        Text(failure).font(.system(size: 13)).foregroundColor(Palette.muted)
                        Button("重试此页", action: requestCurrentPage).buttonStyle(ReadingControlStyle(accented: true))
                    } else if let activity = jobs.activity, activity.document == request.source.document, activity.scope == .page(page) {
                        ProgressView("正在翻译第 \(page + 1) 页…").controlSize(.small)
                        if activity.owner == request.id {
                            Button("停止") { following = false; manuallyRequested = false; jobs.cancel() }
                                .buttonStyle(ReadingControlStyle())
                        }
                    } else {
                        Text("第 \(page + 1) 页还没有译文").font(.system(size: 15, weight: .medium))
                        Button("翻译此页", action: requestCurrentPage).buttonStyle(ReadingControlStyle(accented: true))
                    }
                }.frame(maxWidth: 350, alignment: .leading).padding(22)
                Spacer()
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func paneLabel(_ label: String, numberingChanged: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).font(.system(size: 12, weight: .medium))
                if numberingChanged {
                    Label("核对编号", systemImage: "exclamationmark.circle")
                        .font(.system(size: 11)).foregroundColor(Palette.green)
                        .help("译文中的段落或章节编号可能变化，请对照原页。")
                }
                Spacer()
                Text("PDF 第 \(page + 1) 页").font(.system(size: 11)).monospacedDigit().foregroundColor(Palette.muted)
            }.padding(.horizontal, 15).padding(.vertical, 8)
            Divider()
        }
    }

    private func pairedPage(_ label: String, document: PDFDocument, index: Int, isOriginal: Bool = false,
                            numberingChanged: Bool = false) -> some View {
        VStack(spacing: 0) {
            paneLabel(label, numberingChanged: numberingChanged)
            PDFComparisonPage(document: document, index: index, zoom: zoom, scroll: scroll,
                              sentence: isOriginal ? sentences.pdfSentence : nil,
                              pointTranslate: isOriginal && sentences.pointMode && !retranslateMode ? translateSentence : nil,
                              retranslate: retranslateMode ? { source, point, onRight in
                                  retranslateParagraph(from: source, at: point, isOriginal: isOriginal, onRight: onRight)
                              } : nil,
                              reader: isOriginal ? reader : nil, marks: isOriginal ? reader.marks : [],
                              selectionReset: selectionReset, selectionChanged: isOriginal ? showSelection : nil,
                              showNote: isOriginal ? { _ in notesOpened = true } : nil) { progress in
                if abs(scroll - progress) > 0.003 { scroll = progress }
            }
            .id(page)
            .overlay {
                if isOriginal, let selectionAnchor {
                    ReadingSelectionPalette(anchor: selectionAnchor, appearance: markAppearance,
                                            excerpt: { capture(excerpt: true) }, annotate: { capture(excerpt: false) },
                                            useColor: { capture(excerpt: true, appearance: ReadingMarkAppearance(color: $0, style: markAppearance.style)) },
                                            setStyle: { style in
                                                var appearance = markAppearance
                                                appearance.style = style
                                                store.commit { $0.preferences.readingMarkAppearance = appearance }
                                            },
                                            copy: copySelection, translate: { translateSelection(retry: retranslateMode) }, inComparison: true,
                                            retranslate: { translateSelection(retry: true) })
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func file(at index: Int) -> PDFTranslationFile? {
        if useStartingFile, let initial = request.startingFile, initial.pages.contains(index) {
            if let replacement = archive.generatedPDF(request.source, scope: .page(index), settings: settings) { return replacement }
            if FileManager.default.isReadableFile(atPath: initial.url.path) { return initial }
        }
        let single = PDFTranslationScope.page(index)
        for scope in [single, .document] {
            if let translated = archive.generatedPDF(request.source, scope: scope, settings: settings) { return translated }
        }
        for scope in [single, .document] {
            if let saved = archive.pdf(request.source, scope: scope), saved.target == nil || saved.target == settings.target { return saved }
        }
        return nil
    }

    private func refreshPage() {
        guard let file = file(at: page) else { loaded = nil; return }
        let existing = loaded?.file.id == file.id ? loaded : nil
        guard existing?.sourcePage != page else { return }
        guard let document = existing?.document ?? PDFDocument(url: file.url), !document.isLocked, document.pageCount == file.pages.count,
              let index = file.translatedPage(for: page) else {
            loaded = nil
            failures[page] = "保存的译文无法读取，可以重译当前页。"
            return
        }
        let changed = PDFTranslationHeadings.changed(on: request.original.page(at: page),
                                                      comparedWith: document.page(at: index))
        loaded = LoadedPage(file: file, document: document, sourcePage: page, numberingChanged: changed)
    }

    private func scheduleTranslation() {
        let plan = PDFTranslationFollow(page: page, pageCount: count, automatic: following, manual: manuallyRequested)
        if let activity = jobs.activity {
            if activity.owner == request.id, case .page(let index) = activity.scope,
               activity.profile != settings.pdfProfile || !plan.pages.contains(index) || !canTranslate { jobs.cancel() }
            return
        }
        guard canTranslate else { return }
        let target = manuallyRequested ? page : plan.next(available: { file(at: $0) != nil }, failed: Set(failures.keys))
        guard let target else { return }
        jobs.start(request.source, scope: .page(target), settings: settings, owner: request.id)
    }

    private func toggleFollowing() {
        if following { following = false; scheduleTranslation() }
        else if !canTranslate { configure() }
        else if settings.isRemote { remoteAction = .follow }
        else { enableFollowing() }
    }

    private func enableFollowing() {
        following = true
        failures[page] = nil
        failures[page + 1] = nil
        scheduleTranslation()
    }

    private func requestCurrentPage() {
        if !canTranslate { configure() }
        else if settings.isRemote { remoteAction = .page }
        else { translateCurrentPage() }
    }

    private func translateCurrentPage() {
        failures[page] = nil
        manuallyRequested = true
        scheduleTranslation()
    }

    private func configure() {
        sentences.open(.passage)
        sentences.configuring = true
    }

    private func jump(_ index: Int, fromBottom: Bool = false) {
        guard (0..<count).contains(index), index != page else { return }
        sentences.clearSentence()
        clearSelection()
        retranslateHint = nil
        manuallyRequested = false
        excerptedPage = nil
        scroll = fromBottom ? 1 : 0
        page = index
        pageText = String(index + 1)
        refreshPage()
    }

    private func showSelection(_ value: PDFSelection?, anchor: CGRect?) {
        selection = value
        if selectionAnchor != anchor { selectionAnchor = anchor }
    }

    private func clearSelection() {
        selection = nil
        selectionAnchor = nil
        selectionReset = UUID()
    }

    private func copySelection() {
        guard let quote = selection?.string else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(quote, forType: .string)
    }

    private func translateSelection(retry: Bool = false) {
        guard let text = selection?.string else { return }
        let source = TranslationPassage(text: text, title: request.title, place: reader.pageReference(page),
                                        document: request.source.document, suspectedEncodingError: PDFQuoteQuality.isSuspicious(text))
        sentences.show(source, settings: settings, archive: archive, retranslate: retry)
    }

    private func toggleRetranslation() {
        if sentences.pointMode { sentences.togglePointMode() }
        sentences.clearSentence()
        retranslateHint = nil
        retranslateMode.toggle()
    }

    private func retranslateParagraph(from displayed: PDFPage, at point: CGPoint, isOriginal: Bool, onRight: Bool) {
        guard let original = request.original.page(at: page),
              isOriginal ? original === displayed : loaded?.sourcePage == page else { return }
        let sourcePoint = isOriginal ? point : original.correspondingPoint(point, from: displayed)
        guard let sourcePoint, let hit = original.paragraph(at: sourcePoint, nearby: !isOriginal) else {
            retranslateHint = isOriginal ? "可拖选想重译的文字。" : "这里没匹配到原段。可切到原文点选或拖选。"
            return
        }
        retranslateHint = nil
        let source = TranslationPassage(text: hit.text, title: request.title, place: reader.pageReference(page),
                                        document: request.source.document, suspectedEncodingError: hit.suspectedEncodingError)
        sentences.show(source, settings: settings, archive: archive,
                       sentence: .pdf(hit, panelOnLeadingEdge: mode == .original && onRight),
                       retranslate: true, verify: !isOriginal)
    }

    private func translateSentence(_ hit: PDFSentenceHit, onRight: Bool) {
        guard request.original.index(for: hit.page) == page else { return }
        let source = TranslationPassage(text: hit.text, title: request.title, place: reader.pageReference(page),
                                        document: request.source.document, suspectedEncodingError: hit.suspectedEncodingError)
        sentences.show(source, settings: settings, archive: archive,
                       sentence: .pdf(hit, panelOnLeadingEdge: mode == .original && onRight))
    }

    private func capture(excerpt: Bool, appearance: ReadingMarkAppearance? = nil) {
        guard let selection, reader.saveDraft() else { return }
        do {
            var mark = try reader.draft(kind: .annotation, selection: selection, in: request.original)
            guard mark.location.page == page else { return }
            if !excerpt {
                noteText = mark.note
                noteDraft = mark
            } else {
                mark.isExcerpt = true
                if let appearance { mark.appearance = appearance }
                guard reader.save(mark, remembering: appearance) else { throw InputError.invalid("未能保存摘录。") }
                clearSelection()
                excerptedPage = page
                if mark.needsQuoteReview { quoteRepair = mark }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func editNote(_ mark: PDFReadingMark) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(reader.pageReference(mark.location.page)).font(.system(size: 12)).foregroundColor(Palette.muted)
            ReadingNoteQuote(text: mark.quote, color: mark.appearance.color, editing: true)
            ReadingNoteComposer(text: $noteText, cancel: { noteDraft = nil }, save: {
                var updated = mark
                updated.note = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
                if reader.save(updated) {
                    noteDraft = nil
                    clearSelection()
                    if updated.needsQuoteReview { quoteRepair = updated }
                }
            })
        }.padding(18).frame(width: 440).foregroundColor(Palette.ink).background(Palette.paper)
    }

    private var notes: some View {
        let marks = reader.marks.filter { $0.kind == .annotation }.reversed()
        let visible = marks.filter {
            noteFilter.matches(color: $0.lines.isEmpty ? nil : $0.appearance.color, isExcerpt: $0.isExcerpt == true,
                               text: $0.quote, $0.note, ReaderNote($0).location)
        }
        let sent = store.deliveredNotes(for: reader.itemID)
        return VStack(spacing: 0) {
            ReadingNotesHeader(total: marks.count, visible: visible.count, selecting: selectingNotes,
                               canFilterExcerpts: true, filter: $noteFilter, toggleSelection: {
                selectingNotes.toggle()
                selectedNotes = []
            }, close: { notesOpened = false }, undo: reader.canUndo ? reader.undo : nil)
            if selectingNotes && !visible.isEmpty {
                NotebookBatchControls(visible: Set(visible.map(\.id)), sent: sent, sending: transfer.sending,
                                      selected: $selectedNotes, send: sendNotes, remove: reader.remove)
                    .padding([.horizontal, .bottom], 9)
            }
            NotebookDeliveryStatus(transfer: transfer, store: store, itemID: reader.itemID)
                .padding(.horizontal, 9)
            Divider()
            ScrollView {
                LazyVStack(spacing: 3) {
                    if visible.isEmpty {
                        Text(noteFilter.isFiltering ? "没有找到符合条件的笔记。" : "在原文栏选中文字即可摘录。")
                            .font(.system(size: 12)).foregroundColor(Palette.muted).padding(10)
                    }
                    ForEach(visible) { mark in noteRow(mark, sent: sent.contains(mark.id)) }
                }.padding(6)
            }
        }.background(Palette.side)
    }

    private func noteRow(_ mark: PDFReadingMark, sent: Bool) -> some View {
        let current = mark.revision == reader.revision
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                if selectingNotes { NotebookSelectionToggle(id: mark.id, selected: $selectedNotes) }
                Button(ReaderNote(mark).location) {
                    if mode == .translation { mode = .both }
                    jump(mark.location.page)
                }.buttonStyle(ReadingControlStyle()).foregroundColor(Palette.green).disabled(!current)
            }
            if !mark.quote.isEmpty { ReadingNoteQuote(text: mark.quote, color: mark.appearance.color) }
            if !mark.note.isEmpty { Text(mark.note).font(.system(size: 12)).textSelection(.enabled) }
            HStack(spacing: 1) {
                ReadingIconButton(title: "编辑批注", systemImage: "square.and.pencil") {
                    noteText = mark.note; noteDraft = mark
                }
                NotebookSendButton(sent: sent) {
                    if sent { store.openNotebook(reader.itemID, noteID: mark.id) }
                    else { sendNotes([mark.id]) }
                }.disabled(transfer.sending && !sent)
                Menu {
                    ReadingNoteAppearanceMenu(appearance: mark.appearance, styles: mark.scan == nil,
                                              changeColor: { reader.setColor($0, for: mark) },
                                              changeStyle: { reader.setStyle($0, for: mark) })
                    Button("文献引文键…") { transfer.editingCitation = true }
                    Button("Obsidian 收件设置…", action: transfer.openSetup)
                    Button("移除", role: .destructive) { reader.remove(mark.id) }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 27)
                    .accessibilityLabel("管理这条笔记")
            }
        }.readingNoteRow(active: current && mark.location.page == page)
    }

    private func sendNotes(_ ids: Set<UUID>) {
        if let mark = reader.marks.first(where: { ids.contains($0.id) && $0.needsQuoteReview }) {
            quoteRepair = mark
        } else {
            transfer.send(ids, from: reader.itemID, store: store)
        }
    }

    private func export() {
        guard let file = loaded?.file else { return }
        let dialog = NSSavePanel()
        dialog.title = "保存译文 PDF"
        dialog.allowedContentTypes = [.pdf]
        let scope = file.pages.count == count ? "" : " · 第 \(page + 1) 页"
        dialog.nameFieldStringValue = request.title.replacingOccurrences(of: "/", with: "／") + scope + " · 译文.pdf"
        guard dialog.runModal() == .OK, let destination = dialog.url else { return }
        guard destination.resolvingSymlinksInPath() != request.source.url.resolvingSymlinksInPath() else {
            errorMessage = "请选择另一个译文保存位置。"
            return
        }
        do { try Data(contentsOf: file.url, options: .mappedIfSafe).write(to: destination, options: .atomic) }
        catch { errorMessage = error.localizedDescription }
    }
}

private final class ComparisonPDFSurface: NSView {
    let pdf: LaidOutPDFView
    let highlights: PDFHighlightSurface?

    init(pdf: LaidOutPDFView, reader: PDFReader?) {
        self.pdf = pdf
        highlights = reader.map { reader in
            PDFHighlightSurface(pdf: pdf) { [weak reader] view in
                reader?.highlights(in: view).map {
                    PDFCanvasHighlight(rect: $0.rect, appearance: $0.mark.appearance, isRegion: $0.mark.scan != nil)
                } ?? []
            }
        }
        super.init(frame: .zero)
        let layers = [pdf as NSView] + (highlights.map { [$0 as NSView] } ?? [])
        for layer in layers {
            addSubview(layer)
            layer.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                layer.leadingAnchor.constraint(equalTo: leadingAnchor), layer.trailingAnchor.constraint(equalTo: trailingAnchor),
                layer.topAnchor.constraint(equalTo: topAnchor), layer.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
    }

    required init?(coder: NSCoder) { nil }
}

private struct PDFComparisonPage: NSViewRepresentable {
    let document: PDFDocument
    let index: Int
    let zoom: CGFloat
    let scroll: CGFloat
    let sentence: PDFSentenceHit?
    let pointTranslate: ((PDFSentenceHit, Bool) -> Void)?
    let retranslate: ((PDFPage, CGPoint, Bool) -> Void)?
    let reader: PDFReader?
    let marks: [PDFReadingMark]
    let selectionReset: UUID
    let selectionChanged: ((PDFSelection?, CGRect?) -> Void)?
    let showNote: ((PDFReadingMark) -> Void)?
    let scrolled: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> ComparisonPDFSurface {
        let view = LaidOutPDFView()
        view.displayMode = .singlePage
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 12)
        view.autoScales = false
        view.minScaleFactor = 0.05
        view.maxScaleFactor = 4
        let coordinator = context.coordinator
        let click = NSClickGestureRecognizer(target: coordinator, action: #selector(Coordinator.pointClicked(_:)))
        click.delaysPrimaryMouseButtonEvents = false
        view.addGestureRecognizer(click)
        view.onLayout = { [weak view, weak coordinator] in
            if let view { coordinator?.onLayout(view) }
        }
        let surface = ComparisonPDFSurface(pdf: view, reader: reader)
        coordinator.attach(surface, reader: reader)
        return surface
    }

    func updateNSView(_ surface: ComparisonPDFSurface, context: Context) {
        let view = surface.pdf
        view.backgroundColor = NSColor(Palette.side)
        let coordinator = context.coordinator
        coordinator.pointTranslate = pointTranslate
        coordinator.retranslate = retranslate
        coordinator.selectionChanged = selectionChanged
        coordinator.showNote = showNote
        coordinator.resetSelection(to: selectionReset)
        coordinator.updateMarks(marks)
        view.showSentence(sentence)
        coordinator.update(view, document: document, index: index, zoom: zoom, scroll: scroll, scrolled: scrolled)
    }

    final class Coordinator: NSObject {
        var pointTranslate: ((PDFSentenceHit, Bool) -> Void)?
        var retranslate: ((PDFPage, CGPoint, Bool) -> Void)?
        var selectionChanged: ((PDFSelection?, CGRect?) -> Void)?
        var showNote: ((PDFReadingMark) -> Void)?
        private var observer: NSObjectProtocol?
        private var selectionObserver: NSObjectProtocol?
        private var tracker: ReadingSelectionTracker?
        private var selectionChangedSinceReport = false
        private var lastAnchor: CGRect?
        private var reset: UUID?
        private var appliedReset: UUID?
        private weak var reader: PDFReader?
        private weak var highlights: NSView?
        private var marks: [PDFReadingMark] = []
        private weak var clip: NSClipView?
        private var document: PDFDocument?
        private var desiredPage = 0
        private var zoom = CGFloat(1)
        private var scroll = CGFloat(0)
        private var sendProgress: ((CGFloat) -> Void)?
        private var viewportSize = CGSize.zero
        private var pendingSync = false
        private var applying = false

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        }

        func attach(_ surface: ComparisonPDFSurface, reader: PDFReader?) {
            guard let reader else { return }
            self.reader = reader
            highlights = surface.highlights
            let view = surface.pdf
            tracker = ReadingSelectionTracker(locate: { [weak view] in
                guard let view, let page = view.currentPage, let selection = view.currentSelection,
                      let text = selection.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                let rect = selection.bounds(for: page)
                guard !rect.isEmpty else { return nil }
                return ReadingSelectionTracker.anchor(view.convert(rect, from: page), in: view)
            }, show: { [weak self, weak view] anchor in
                guard let self, self.selectionChangedSinceReport || self.lastAnchor != anchor else { return }
                self.selectionChangedSinceReport = false
                self.lastAnchor = anchor
                self.selectionChanged?(anchor == nil ? nil : view?.currentSelection, anchor)
            })
            selectionObserver = NotificationCenter.default.addObserver(forName: .PDFViewSelectionChanged, object: view, queue: .main) {
                [weak self] _ in
                self?.selectionChangedSinceReport = true
                self?.tracker?.refresh()
            }
        }

        func resetSelection(to command: UUID) { reset = command }

        func updateMarks(_ value: [PDFReadingMark]) {
            guard value != marks else { return }
            marks = value
            highlights?.needsDisplay = true
        }

        @objc func pointClicked(_ gesture: NSClickGestureRecognizer) {
            guard let view = gesture.view as? LaidOutPDFView else { return }
            let point = gesture.location(in: view)
            if let retranslate, let page = view.page(for: point, nearest: false) {
                retranslate(page, view.convert(point, to: page), point.x > view.bounds.midX)
                view.clearSelection()
            } else if let pointTranslate {
                if let hit = view.sentence(at: point) { pointTranslate(hit, point.x > view.bounds.midX) }
            } else if let mark = reader?.highlights(in: view).last(where: { $0.rect.contains(point) })?.mark {
                showNote?(mark)
            }
        }

        func onLayout(_ view: PDFView) {
            guard view.bounds.size != viewportSize else { return }
            queueSync(view)
        }

        func update(_ view: PDFView, document: PDFDocument, index: Int, zoom: CGFloat, scroll: CGFloat, scrolled: @escaping (CGFloat) -> Void) {
            self.document = document
            desiredPage = index
            self.zoom = zoom
            self.scroll = scroll
            sendProgress = scrolled
            queueSync(view)
        }

        private func queueSync(_ view: PDFView) {
            guard !pendingSync else { return }
            pendingSync = true
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self else { return }
                self.pendingSync = false
                if let view { self.apply(to: view) }
            }
        }

        private func apply(to view: PDFView) {
            guard view.window != nil, view.bounds.width > 24, view.bounds.height > 0,
                  let document, let page = document.page(at: desiredPage) else { return }
            viewportSize = view.bounds.size
            applying = true
            defer {
                applying = false
                highlights?.needsDisplay = true
                tracker?.refresh()
            }
            let changedDocument = view.document !== document
            let changedPage = changedDocument || view.currentPage !== page
            // PDFKit can leave the first page blank if the document is assigned before the view has a size.
            if changedDocument { view.document = document }
            if changedPage { view.go(to: page) }
            if appliedReset != reset {
                appliedReset = reset
                if view.currentSelection != nil { view.setCurrentSelection(nil, animate: false) }
            }
            let width = page.bounds(for: view.displayBox).width
            guard width > 0 else { return }
            let scale = min((view.bounds.width - 24) / width * zoom, view.maxScaleFactor)
            if abs(view.scaleFactor - scale) > 0.004 { view.scaleFactor = scale }
            if changedPage { view.layoutDocumentView() }
            if let scrollView = view.documentView?.enclosingScrollView {
                scrollView.allowsMagnification = false
                let clip = scrollView.contentView
                watch(clip)
                let travel = max(0, clip.documentRect.height - clip.bounds.height)
                guard travel > 0 else { return }
                let ratio = clip.isFlipped ? scroll : 1 - scroll
                let y = clip.documentRect.minY + travel * ratio
                if abs(y - clip.bounds.origin.y) > 1 {
                    clip.scroll(to: CGPoint(x: clip.bounds.origin.x, y: y))
                    scrollView.reflectScrolledClipView(clip)
                }
            }
        }

        private func watch(_ clip: NSClipView) {
            guard self.clip !== clip else { return }
            if let observer { NotificationCenter.default.removeObserver(observer) }
            self.clip = clip
            clip.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self, weak clip] _ in
                guard let self, let clip else { return }
                self.highlights?.needsDisplay = true
                self.tracker?.refresh()
                guard !self.applying, !self.pendingSync else { return }
                let travel = clip.documentRect.height - clip.bounds.height
                guard travel > 1 else { return }
                let ratio = min(1, max(0, (clip.bounds.origin.y - clip.documentRect.minY) / travel))
                let progress = clip.isFlipped ? ratio : 1 - ratio
                guard abs(self.scroll - progress) > 0.003 else { return }
                self.scroll = progress
                self.sendProgress?(progress)
            }
        }
    }
}
