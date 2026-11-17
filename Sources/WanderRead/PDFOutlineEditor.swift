import AppKit
import PDFKit
import SwiftUI

struct PDFOutlineEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var reader: PDFReader
    @ObservedObject var store: ReadingStore
    let didSave: () -> Void

    @State private var entries: [PDFOutlineCandidate]
    @State private var selected: UUID?
    @State private var document: PDFDocument?
    @State private var previewSelection: PDFOutlineCandidate?
    @State private var pageInput = ""
    @State private var scanStart = ""
    @State private var scanEnd = ""
    @State private var showScan = false
    @State private var job: Job?
    @State private var waitingForAutomatic: Bool
    @State private var generationMessage: String?
    @State private var beforeGeneration: [PDFOutlineCandidate]?
    @State private var pendingOnly = false
    @State private var aiJob: AIJob?
    @State private var confirmRemote: AIAction?
    @State private var suggestions: [UUID: PDFOutlineCalibration.Option] = [:]
    @State private var suggestionPreview: UUID?

    private struct Job: Equatable {
        let id = UUID()
        var range: Range<Int>?
    }
    private enum AIAction: Equatable {
        case generate, calibrate
        var button: String { self == .generate ? "AI 生成目录…" : "校准目录" }
        var operation: String { self == .generate ? "生成目录" : "校准目录" }
    }
    private struct AIJob: Equatable {
        let id = UUID()
        let action: AIAction
        let remote: Bool
    }
    private enum AIInput {
        case generate(PDFOutlineCalibration.Inventory)
        case calibrate([PDFOutlineCalibration.Candidate])
    }

    init(reader: PDFReader, store: ReadingStore, manual: PDFOutlineCandidate? = nil, reviewPending: Bool = false, didSave: @escaping () -> Void) {
        self.reader = reader
        self.store = store
        self.didSave = didSave
        var initial = reader.outlineForEditing
        if let manual {
            initial.append(manual)
            initial = Self.sorted(initial)
        }
        let firstPending = reviewPending ? initial.first(where: \.isPending)?.id : nil
        _entries = State(initialValue: initial)
        _selected = State(initialValue: manual?.id ?? firstPending ?? initial.first?.id)
        _pendingOnly = State(initialValue: firstPending != nil)
        _waitingForAutomatic = State(initialValue: initial.isEmpty && reader.detectedOutline == nil)
    }

    private var busy: Bool { aiJob != nil || job != nil || (waitingForAutomatic && reader.findingOutline) }
    private var selectedIndex: Int? { entries.firstIndex { $0.id == selected } }
    private var target: PDFReadingLocation? { selectedIndex.flatMap { entries[$0].location } }
    private var resolved: [PDFOutlineCandidate] { entries.filter { !$0.isPending } }
    private var reviewCount: Int { entries.count - resolved.count }
    private var visibleEntries: [PDFOutlineCandidate] { pendingOnly ? entries.filter(\.isPending) : entries }
    private var valid: Bool { PDFOutlineCandidate.sections(from: resolved, pageCount: reader.document.pageCount) != nil }
    private var page: Int? { parsePage(pageInput) }
    private var settings: ReadingTranslationSettings { store.library.preferences.translation ?? ReadingTranslationSettings() }
    private var currentSuggestion: PDFOutlineCalibration.Option? { selected.flatMap { suggestions[$0] } }
    private var aiAction: AIAction { entries.isEmpty ? .generate : .calibrate }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                catalog.frame(width: 292)
                Divider()
                inspector
            }
            Divider()
            footer
        }
        .frame(width: 898, height: 630)
        .foregroundColor(Palette.ink).background(Palette.paper)
        .onAppear {
            document = PDFDocument(url: reader.url)
            if waitingForAutomatic { reader.prepareOutline(); adoptAutomaticOutline() }
            syncPageInput()
        }
        .onChange(of: selected) { _ in suggestionPreview = nil; syncPageInput() }
        .onChange(of: reader.detectedOutline) { _ in adoptAutomaticOutline() }
        .task(id: job) {
            guard let job else { return }
            let url = reader.url
            let revision = reader.revision
            let worker = Task.detached(priority: .utility) { PDFReader.detectOutline(at: url, revision: revision, scanRange: job.range) }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, self.job == job else { return }
            if let result, !result.isEmpty {
                beforeGeneration = entries.isEmpty ? nil : entries
                loadEntries(result, focusPending: result.contains(where: \.isPending))
            } else {
                generationMessage = result == nil ? "文件已更新，重新打开后可识别目录。" :
                    job.range == nil ? "暂未找到可用的目录。" : "在选定页内未找到目录。"
            }
            self.job = nil
        }
        .task(id: aiJob) { if let aiJob { await runAI(aiJob) } }
        .confirmationDialog("使用远程模型\(confirmRemote?.operation ?? "处理目录")",
                            isPresented: Binding(get: { confirmRemote != nil }, set: { if !$0 { confirmRemote = nil } }),
                            presenting: confirmRemote) { action in
            Button(action.operation) { startAI(action) }
            Button("取消", role: .cancel) {}
        } message: { action in
            Text(action == .generate ? "会发送从 PDF 原文提取的候选标题，可能产生 API 费用。" :
                    "会发送已有的目录条目与 PDF 里找到的候选标题，可能产生 API 费用。")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("章节目录").font(.system(size: 23, weight: .semibold, design: .serif))
                Text(reader.title).font(.system(size: 12)).foregroundColor(Palette.muted).lineLimit(1)
            }
            Spacer()
            Button(entries.isEmpty ? "自动生成" : "重新生成") { startGeneration(Job()) }.disabled(busy)
                .help("读取印刷目录或正文标题，遇到扫描页时尝试本机识别")
            Button(aiAction.button) { requestAI(aiAction) }.disabled(busy)
                .help(entries.isEmpty ? "从 PDF 原文选择章节标题并建立目录" : "核对目录的层级、标题和原文位置")
                .accessibilityIdentifier("OutlineAI")
            Button("指定目录页…") {
                scanStart = "1"
                scanEnd = String(min(12, reader.document.pageCount))
                showScan = true
            }.disabled(busy)
                .popover(isPresented: $showScan, arrowEdge: .bottom) { scanOptions }
        }.buttonStyle(.borderless).controlSize(.regular)
            .font(.system(size: 13, weight: .medium)).padding(.horizontal, 21).padding(.vertical, 15)
    }

    private var catalog: some View {
        VStack(alignment: .leading, spacing: 0) {
            if entries.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    if busy {
                        ProgressView(aiJob == nil ? "正在本机查找目录…" : "正在生成目录…")
                            .controlSize(.small)
                    } else {
                        Text(generationMessage ?? (reader.outlineFileChanged ? "文件已更新，请重新打开。" :
                            reader.detectedOutline != nil ? "暂未找到可用的目录。" : "还没有目录条目"))
                            .font(.system(size: 14, weight: .medium))
                        Text("可从正文生成目录，也可以指定印刷目录页。")
                            .font(.system(size: 12)).foregroundColor(Palette.muted)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(17)
            } else {
                if reviewCount > 0 {
                    Toggle("仅看待核对 · \(reviewCount)", isOn: $pendingOnly)
                        .toggleStyle(.checkbox).font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 8)
                        .onChange(of: pendingOnly) { _ in keepSelectionVisible() }
                }
                ScrollViewReader { proxy in
                    List(selection: $selected) {
                        ForEach(visibleEntries) { entry in
                            HStack(spacing: 7) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.title.isEmpty ? "未命名章节" : entry.title)
                                        .font(.system(size: 13)).lineLimit(2)
                                    Text(rowSubtitle(entry))
                                        .font(.system(size: 11)).foregroundColor(.secondary)
                                }
                                Spacer(minLength: 4)
                                if suggestions[entry.id] != nil {
                                    Image(systemName: "sparkle").foregroundColor(Palette.green).accessibilityLabel("有校准建议")
                                } else if entry.isPending {
                                    Image(systemName: "exclamationmark.circle")
                                        .foregroundColor(.secondary).accessibilityLabel("待核对")
                                }
                            }
                            .padding(.leading, CGFloat(min(7, max(0, entry.depth))) * 9).padding(.vertical, 3)
                            .tag(entry.id).id(entry.id)
                        }
                    }.listStyle(.sidebar)
                        .onChange(of: selected) { if let id = $0 { proxy.scrollTo(id) } }
                }
            }
            Divider()
            HStack(spacing: 7) {
                ReadingIconButton(title: "添加章节", systemImage: "plus") { addEntry() }
                ReadingIconButton(title: "移除选中的章节", systemImage: "minus") { removeEntry() }
                    .disabled(selectedIndex == nil)
                Spacer()
                Menu {
                    Button("按 PDF 页码排序") { entries = Self.sorted(entries) }.disabled(entries.count < 2)
                    if !entries.isEmpty {
                        Button("用 AI 重新生成…") { requestAI(.generate) }
                    }
                    Button("移除待核对条目") { removeUnconfirmed() }.disabled(reviewCount == 0)
                    if let beforeGeneration {
                        Button("撤回本次目录改动") {
                            loadEntries(beforeGeneration, focusPending: false)
                            self.beforeGeneration = nil
                        }
                    }
                    if reader.hasAuthorOutline && !reader.savedOutline.isEmpty {
                        Button("恢复 PDF 自带目录") {
                            if reader.restoreAuthorOutline() { didSave(); dismiss() }
                        }
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .accessibilityLabel("目录整理")
            }.padding(.horizontal, 12).padding(.vertical, 5)
        }
        .disabled(busy)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                if let index = selectedIndex {
                    TextField("章节标题", text: $entries[index].title)
                        .textFieldStyle(.roundedBorder)
                    Picker("层级", selection: $entries[index].depth) {
                        ForEach(0...min(PDFOutlineHierarchy.maximumDepth,
                                       max(PDFOutlineHierarchy.editableDepth, entries[index].depth)), id: \.self) { depth in
                            Text("第 \(depth + 1) 级").tag(depth)
                        }
                    }.labelsHidden().frame(width: 91).accessibilityLabel("章节层级")
                } else {
                    Text("原页预览").font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
            }
            HStack(spacing: 8) {
                if selectedIndex != nil {
                    Text("PDF 页").font(.system(size: 12)).foregroundColor(Palette.muted)
                    TextField("页码", text: $pageInput).textFieldStyle(.roundedBorder).frame(width: 55)
                        .accessibilityLabel("跳转的 PDF 页码").onSubmit(previewPage)
                    Button("预览", action: previewPage).disabled(page == nil)
                    if let index = selectedIndex, entries[index].needsReview, target != nil {
                        Button(pendingOnly && reviewCount > 1 ? "确认并看下一项" : "确认位置") {
                            entries[index].needsReview = false
                            keepSelectionVisible()
                        }
                        .disabled(page != target?.page)
                    }
                    Spacer(minLength: 5)
                    Button("定位到选中文字") { useSelection() }.disabled(previewSelection == nil)
                } else {
                    Text("从左侧选一条目录，核对原书上的标题。")
                        .font(.system(size: 12)).foregroundColor(Palette.muted)
                }
            }.buttonStyle(.borderless).controlSize(.small)
            if let suggestion = currentSuggestion, let selected, let index = selectedIndex {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text("校准建议 · PDF 第 \(suggestion.location.page + 1) 页")
                            .font(.system(size: 12, weight: .medium))
                        Text(suggestion.title).font(.system(size: 12)).lineLimit(2).foregroundColor(Palette.muted)
                        Spacer()
                        Button("预览") { suggestionPreview = selected }
                        Button("采用建议") { adopt([selected: suggestion]) }
                    }
                    if let depth = suggestion.depth, depth != entries[index].depth {
                        Text("第 \(entries[index].depth + 1) 级 → 第 \(depth + 1) 级")
                            .font(.system(size: 12)).foregroundColor(Palette.green)
                    }
                }.buttonStyle(.borderless).padding(.vertical, 5)
            }
            if let document {
                let preview = suggestionPreview == selected ? currentSuggestion?.location : nil
                OutlinePDFPreview(document: document, location: preview ?? target ?? reader.location, selection: $previewSelection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(13).disabled(busy)
    }

    private var footer: some View {
        HStack {
            if busy {
                ProgressView().controlSize(.small)
                Text(aiJob.map { "正在\($0.action.operation) · \($0.remote ? "远程模型" : "本地模型")" } ?? "识别在本机进行")
                    .font(.system(size: 12)).foregroundColor(Palette.muted)
                Button("停止") {
                    if waitingForAutomatic { reader.stopOutlineDetection(); waitingForAutomatic = false }
                    job = nil
                    aiJob = nil
                }.buttonStyle(.borderless)
            } else {
                Text(generationMessage ?? footerStatus).font(.system(size: 12)).foregroundColor(Palette.muted)
            }
            Spacer()
            if !busy, suggestions.count > 1 {
                Button("采用全部建议") { adopt(suggestions) }.buttonStyle(.borderless)
            }
            Button("取消") { dismiss() }.buttonStyle(.borderless).keyboardShortcut(.cancelAction)
            Button(reviewCount == 0 ? "保存到漫读" : "保存已定位的 \(resolved.count) 项") {
                if reader.saveOutline(entries, resolvedOnly: true) { didSave(); dismiss() }
            }.buttonStyle(ActionStyle(primary: true)).keyboardShortcut(.defaultAction)
                .disabled(!valid || busy || pageInput != (target.map { String($0.page + 1) } ?? ""))
        }.padding(.horizontal, 19).padding(.vertical, 11)
    }

    private var scanOptions: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("印刷目录可能在哪几页？").font(.system(size: 14, weight: .semibold))
            Text("填 PDF 文件页码。漫读会在本机识别这些页，并按需检查可能的章首页。")
                .font(.system(size: 12)).foregroundColor(Palette.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("起始页", text: $scanStart).textFieldStyle(.roundedBorder).accessibilityLabel("扫描起始页")
                Text("至")
                TextField("结束页", text: $scanEnd).textFieldStyle(.roundedBorder).accessibilityLabel("扫描结束页")
            }
            HStack {
                Text("每次最多 \(PDFOutlineBuilder.scanPageLimit) 页").font(.system(size: 11)).foregroundColor(Palette.muted)
                Spacer()
                Button("开始识别") {
                    if let range = scanRange {
                        showScan = false
                        startGeneration(Job(range: range))
                    }
                }.disabled(scanRange == nil)
            }
        }.buttonStyle(.borderless).padding(16).frame(width: 310)
    }

    private func adoptAutomaticOutline() {
        guard waitingForAutomatic, let result = reader.detectedOutline else { return }
        waitingForAutomatic = false
        loadEntries(result, focusPending: false)
    }

    private func startGeneration(_ next: Job) {
        waitingForAutomatic = false
        if reader.findingOutline { reader.stopOutlineDetection() }
        generationMessage = nil
        suggestions = [:]
        job = next
    }

    private func requestAI(_ action: AIAction) {
        if action == .generate && settings.service == nil {
            generationMessage = "请先在翻译设置连接本地模型或远程 API。"
            return
        }
        if settings.service?.remote == true { confirmRemote = action }
        else { startAI(action) }
    }

    private func startAI(_ action: AIAction) {
        waitingForAutomatic = false
        generationMessage = nil
        suggestions = [:]
        suggestionPreview = nil
        aiJob = AIJob(action: action, remote: settings.service?.remote == true)
    }

    @MainActor private func runAI(_ current: AIJob) async {
        defer { if aiJob == current { aiJob = nil } }
        let service = settings.service
        guard (service?.remote ?? false) == current.remote else {
            generationMessage = "模型设置已变化，请重新开始。"
            return
        }
        do {
            let url = reader.url, revision = reader.revision, snapshot = entries, focus = selected
            let worker = Task.detached(priority: .utility) { () throws -> AIInput in
                guard try PDFReader.fingerprint(url) == revision, let pdf = PDFDocument(url: url), !pdf.isLocked else {
                    throw InputError.invalid("原文件已变化，请重新打开后核对。")
                }
                switch current.action {
                case .generate: return .generate(try PDFOutlineCalibration.inventory(in: pdf))
                case .calibrate: return .calibrate(try PDFOutlineCalibration.candidates(in: pdf, entries: snapshot, prioritize: focus))
                }
            }
            let input = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            switch input {
            case .generate(let inventory):
                guard let service else { throw InputError.invalid("请先连接翻译设置里的模型。") }
                let result = try await PDFOutlineCalibration.generate(inventory.options, using: service)
                try await checkSource(for: current)
                if result.isEmpty {
                    generationMessage = "没有找到可生成目录的章节标题，可以指定目录页。"
                } else {
                    beforeGeneration = entries
                    loadEntries(result, focusPending: false)
                    generationMessage = inventory.limited ? "生成 \(result.count) 项 · 部分页或候选未扫描" : "生成 \(result.count) 项 · 预览后可保存"
                }
            case .calibrate(let candidates):
                var result = PDFOutlineCalibration.exactMatches(in: candidates)
                var modelError: String?
                if let service {
                    let uncertain = candidates.filter { result[$0.id] == nil }
                    do {
                        let extra = try await PDFOutlineCalibration.suggest(uncertain, using: service)
                        result.merge(extra) { current, _ in current }
                    } catch {
                        try Task.checkCancellation()
                        modelError = error.localizedDescription
                    }
                }
                try await checkSource(for: current)
                let original = reader.hasAuthorOutline && reader.sections.contains { $0.depth > 0 } ? reader.sections : []
                suggestions = PDFOutlineCalibration.corrections(for: entries, matched: result,
                    preserveDepths: !original.isEmpty && reader.savedOutline.isEmpty, authorOutline: original)
                let levelChange = entries.first { entry in suggestions[entry.id]?.depth.map { $0 != entry.depth } == true }
                if let first = levelChange ?? entries.first(where: { suggestions[$0.id] != nil }) {
                    if !first.isPending { pendingOnly = false }
                    selected = first.id
                    generationMessage = "\(suggestions.count) 项可校准 · 预览后可采用"
                } else if let modelError {
                    generationMessage = modelError
                } else if result.isEmpty {
                    generationMessage = "没有找到能可靠对应的正文标题。"
                } else {
                    generationMessage = "核对了 \(result.count)/\(entries.count) 项 · 未发现需要调整的条目"
                }
            }
        } catch {
            if aiJob == current && !Task.isCancelled { generationMessage = error.localizedDescription }
        }
    }

    @MainActor private func checkSource(for current: AIJob) async throws {
        let url = reader.url, revision = reader.revision
        let unchanged = await Task.detached(priority: .utility) { (try? PDFReader.fingerprint(url)) == revision }.value
        guard aiJob == current, !Task.isCancelled else { throw CancellationError() }
        guard unchanged else { throw InputError.invalid("原文件已变化，请重新打开后核对。") }
    }

    private func adopt(_ accepted: [UUID: PDFOutlineCalibration.Option]) {
        var updated = entries
        for index in updated.indices {
            guard let suggestion = accepted[updated[index].id] else { continue }
            updated[index].title = suggestion.title
            updated[index].location = suggestion.location
            if let depth = suggestion.depth { updated[index].depth = depth }
            updated[index].needsReview = false
        }
        let located = updated.filter { !$0.isPending }
        guard let sections = PDFOutlineCandidate.sections(from: located, pageCount: reader.document.pageCount) else {
            generationMessage = "建议位置与现有目录顺序冲突，请逐项核对。"
            return
        }
        guard zip(located, sections).allSatisfy({ entry, section in
            accepted[entry.id]?.depth.map { $0 == section.depth } ?? true
        }) else {
            generationMessage = "请先采用上一级建议，或一次采用全部建议。"
            return
        }
        if beforeGeneration == nil { beforeGeneration = entries }
        entries = updated
        for id in accepted.keys { suggestions[id] = nil }
        suggestionPreview = nil
        generationMessage = "已采用 \(accepted.count) 项建议 · 保存后生效"
        keepSelectionVisible()
        syncPageInput()
    }

    private func loadEntries(_ result: [PDFOutlineCandidate], focusPending: Bool) {
        entries = result
        suggestions = [:]
        suggestionPreview = nil
        pendingOnly = focusPending
        selected = (focusPending ? result.first(where: \.isPending)?.id : nil) ?? result.first?.id
        generationMessage = nil
        syncPageInput()
    }

    private var scanRange: Range<Int>? {
        guard let start = parsePage(scanStart), let end = parsePage(scanEnd),
              start <= end, end - start < PDFOutlineBuilder.scanPageLimit else { return nil }
        return start..<(end + 1)
    }

    private var footerStatus: String {
        if entries.isEmpty { return "目录保存在漫读中" }
        if resolved.isEmpty { return "\(reviewCount) 项待核对 · 先确认一项即可保存" }
        if !valid { return "检查空标题或页码顺序" }
        if reviewCount > 0 { return "\(resolved.count) 项已定位 · 保存后可继续核对其余 \(reviewCount) 项" }
        return "\(entries.count) 项 · 点目录可回到原页"
    }

    private func rowSubtitle(_ entry: PDFOutlineCandidate) -> String {
        let printed = entry.printedLabel.map { "版面 \($0) · " } ?? ""
        return printed + (entry.location.map { "PDF 第 \($0.page + 1) 页" } ?? "待定位")
    }

    private func parsePage(_ value: String) -> Int? {
        guard let number = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...reader.document.pageCount).contains(number) else { return nil }
        return number - 1
    }

    private func syncPageInput() {
        pageInput = target.map { String($0.page + 1) } ?? ""
        previewSelection = nil
    }

    private func previewPage() {
        guard let index = selectedIndex, let page, page != entries[index].location?.page else { return }
        entries[index].location = PDFReadingLocation(page: page)
        entries[index].needsReview = true
        previewSelection = nil
    }

    private func useSelection() {
        guard let index = selectedIndex, let match = previewSelection else { return }
        entries[index].location = match.location
        if entries[index].title.isEmpty { entries[index].title = match.title }
        entries[index].needsReview = false
        keepSelectionVisible()
        syncPageInput()
    }

    private func keepSelectionVisible() {
        if reviewCount == 0 { pendingOnly = false }
        if !visibleEntries.contains(where: { $0.id == selected }) { selected = visibleEntries.first?.id }
    }

    private func addEntry() {
        let anchor = target ?? reader.location
        let entry = PDFOutlineCandidate(title: "", location: anchor)
        entries.insert(entry, at: selectedIndex.map { $0 + 1 } ?? entries.count)
        pendingOnly = false
        selected = entry.id
    }

    private func removeEntry() {
        guard let index = selectedIndex else { return }
        entries.remove(at: index)
        selected = entries.indices.contains(index) ? entries[index].id : entries.last?.id
        keepSelectionVisible()
    }

    private func removeUnconfirmed() {
        entries.removeAll(where: \.isPending)
        keepSelectionVisible()
    }

    private static func sorted(_ entries: [PDFOutlineCandidate]) -> [PDFOutlineCandidate] {
        entries.enumerated().sorted {
            let left = $0.element.location?.page ?? Int.max
            let right = $1.element.location?.page ?? Int.max
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }
}

private struct OutlinePDFPreview: NSViewRepresentable {
    let document: PDFDocument
    let location: PDFReadingLocation
    @Binding var selection: PDFOutlineCandidate?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePage
        view.displaysPageBreaks = false
        view.backgroundColor = NSColor(Palette.side)
        view.document = document
        view.autoScales = true
        context.coordinator.observation = NotificationCenter.default.addObserver(forName: .PDFViewSelectionChanged,
            object: view, queue: .main) { [weak view, weak coordinator = context.coordinator] _ in
                guard let view, let coordinator else { return }
                coordinator.selection?(Self.selectedHeading(in: view))
            }
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        let binding = $selection
        context.coordinator.selection = { value in
            DispatchQueue.main.async { binding.wrappedValue = value }
        }
        guard context.coordinator.shown != location, let page = document.page(at: location.page) else { return }
        context.coordinator.shown = location
        view.clearSelection()
        view.go(to: page)
        if let point = location.point, let line = page.selectionForLine(at: CGPoint(x: point.x + 3, y: point.y - 4)) {
            line.color = NSColor.systemYellow.withAlphaComponent(0.5)
            view.highlightedSelections = [line]
        } else {
            view.highlightedSelections = nil
        }
    }

    private static func selectedHeading(in view: PDFView) -> PDFOutlineCandidate? {
        guard let selection = view.currentSelection, selection.pages.count == 1,
              let line = selection.selectionsByLine().first, let page = line.pages.first,
              let document = view.document, let text = selection.string else { return nil }
        let index = document.index(for: page)
        let rect = line.bounds(for: page)
        guard (0..<document.pageCount).contains(index), !rect.isEmpty else { return nil }
        return PDFOutlineCandidate(title: String(ChineseReading.reflow(text).prefix(200)),
                                   location: PDFReadingLocation(page: index, point: CGPoint(x: rect.minX, y: rect.maxY)))
    }

    final class Coordinator {
        var shown: PDFReadingLocation?
        var selection: ((PDFOutlineCandidate?) -> Void)?
        var observation: NSObjectProtocol?
        deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }
    }
}
