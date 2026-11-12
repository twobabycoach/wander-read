import AppKit
import PDFKit
import SwiftUI

struct PDFOutlineEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var reader: PDFReader
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
    @State private var finished = false
    @State private var scanFailed = false
    @State private var pendingOnly = false

    private struct Job: Equatable {
        let id = UUID()
        var range: Range<Int>?
    }

    init(reader: PDFReader, manual: PDFOutlineCandidate? = nil, didSave: @escaping () -> Void) {
        self.reader = reader
        self.didSave = didSave
        var initial = reader.outlineDraft ?? reader.savedOutline.map {
            PDFOutlineCandidate(title: $0.title, depth: $0.depth, location: $0.location, printedLabel: $0.printedLabel)
        }
        if let manual {
            initial.append(manual)
            initial = Self.sorted(initial)
        }
        _entries = State(initialValue: initial)
        _selected = State(initialValue: manual?.id ?? initial.first?.id)
        _job = State(initialValue: initial.isEmpty ? Job() : nil)
    }

    private var selectedIndex: Int? { entries.firstIndex { $0.id == selected } }
    private var target: PDFReadingLocation? { selectedIndex.flatMap { entries[$0].location } }
    private var resolved: [PDFOutlineCandidate] { entries.filter { !$0.isPending } }
    private var reviewCount: Int { entries.count - resolved.count }
    private var visibleEntries: [PDFOutlineCandidate] { pendingOnly ? entries.filter(\.isPending) : entries }
    private var valid: Bool { PDFOutlineCandidate.sections(from: resolved, pageCount: reader.document.pageCount) != nil }
    private var page: Int? { parsePage(pageInput) }

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
            syncPageInput()
        }
        .onChange(of: selected) { _ in syncPageInput() }
        .task(id: job) {
            guard let job else { return }
            let url = reader.url
            let worker = Task.detached(priority: .utility) { PDFOutlineBuilder.generate(at: url, scanRange: job.range, autoScan: true) }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, self.job == job else { return }
            if !result.isEmpty {
                entries = result
                pendingOnly = false
                selected = result.first(where: \.isPending)?.id ?? result.first?.id
                syncPageInput()
            }
            finished = true
            scanFailed = job.range != nil && result.isEmpty
            self.job = nil
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("章节目录").font(.system(size: 23, weight: .semibold, design: .serif))
                Text(reader.title).font(.system(size: 12)).foregroundColor(Palette.muted).lineLimit(1)
            }
            Spacer()
            Button(entries.isEmpty ? "自动生成" : "重新生成") { job = Job() }.disabled(job != nil)
                .help("读取印刷目录或正文标题，遇到扫描页时尝试本机识别")
            Button("指定目录页…") {
                scanStart = "1"
                scanEnd = String(min(12, reader.document.pageCount))
                showScan = true
            }.disabled(job != nil)
                .popover(isPresented: $showScan, arrowEdge: .bottom) { scanOptions }
        }.buttonStyle(.borderless).controlSize(.regular)
            .font(.system(size: 13, weight: .medium)).padding(.horizontal, 21).padding(.vertical, 15)
    }

    private var catalog: some View {
        VStack(alignment: .leading, spacing: 0) {
            if entries.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    if job != nil {
                        ProgressView("正在本机查找目录…")
                            .controlSize(.small)
                    } else {
                        Text(scanFailed ? "在选定范围内未找到目录" : finished ? "未找到可用的目录" : "还没有目录条目")
                            .font(.system(size: 14, weight: .medium))
                        Text("可以指定印刷目录页重新识别，或从原页手动加一章。")
                            .font(.system(size: 12)).foregroundColor(Palette.muted)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(17)
            } else {
                if reviewCount > 0 {
                    Toggle("仅看待核对 · \(reviewCount)", isOn: $pendingOnly)
                        .toggleStyle(.checkbox).font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 8)
                        .onChange(of: pendingOnly) { _ in keepSelectionVisible() }
                }
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
                            if entry.isPending {
                                Image(systemName: "exclamationmark.circle")
                                    .foregroundColor(.secondary).accessibilityLabel("待核对")
                            }
                        }
                        .padding(.leading, CGFloat(entry.depth) * 10).padding(.vertical, 3)
                        .tag(entry.id)
                    }
                }.listStyle(.sidebar)
            }
            Divider()
            HStack(spacing: 7) {
                ReadingIconButton(title: "添加章节", systemImage: "plus") { addEntry() }
                ReadingIconButton(title: "移除选中的章节", systemImage: "minus") { removeEntry() }
                    .disabled(selectedIndex == nil)
                Spacer()
                Menu {
                    Button("按 PDF 页码排序") { entries = Self.sorted(entries) }.disabled(entries.count < 2)
                    Button("移除待核对条目") { removeUnconfirmed() }.disabled(reviewCount == 0)
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .accessibilityLabel("目录整理")
            }.padding(.horizontal, 12).padding(.vertical, 5).disabled(job != nil)
        }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                if let index = selectedIndex {
                    TextField("章节标题", text: $entries[index].title)
                        .textFieldStyle(.roundedBorder)
                    Picker("层级", selection: $entries[index].depth) {
                        ForEach(0..<5, id: \.self) { depth in Text("第 \(depth + 1) 级").tag(depth) }
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
                        Button("确认位置") {
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
            if let document {
                OutlinePDFPreview(document: document, location: target ?? reader.location, selection: $previewSelection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(13).disabled(job != nil)
    }

    private var footer: some View {
        HStack {
            if job != nil {
                ProgressView().controlSize(.small)
                Text("识别在本机进行").font(.system(size: 12)).foregroundColor(Palette.muted)
                Button("停止") { job = nil }.buttonStyle(.borderless)
            } else {
                Text(footerStatus).font(.system(size: 12)).foregroundColor(Palette.muted)
            }
            Spacer()
            Button("取消") { dismiss() }.buttonStyle(.borderless).keyboardShortcut(.cancelAction)
            Button(reviewCount == 0 ? "保存到漫读" : "保存已定位的 \(resolved.count) 项") {
                if reader.saveOutline(entries, resolvedOnly: true) { didSave(); dismiss() }
            }.buttonStyle(ActionStyle(primary: true)).keyboardShortcut(.defaultAction)
                .disabled(!valid || job != nil || pageInput != (target.map { String($0.page + 1) } ?? ""))
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
                        job = Job(range: range)
                    }
                }.disabled(scanRange == nil)
            }
        }.buttonStyle(.borderless).padding(16).frame(width: 310)
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
    }

    private static func selectedHeading(in view: PDFView) -> PDFOutlineCandidate? {
        guard let line = view.currentSelection?.selectionsByLine().first, let page = line.pages.first,
              let document = view.document, let text = line.string else { return nil }
        let index = document.index(for: page)
        let rect = line.bounds(for: page)
        guard (0..<document.pageCount).contains(index), !rect.isEmpty else { return nil }
        return PDFOutlineCandidate(title: String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)),
                                   location: PDFReadingLocation(page: index, point: CGPoint(x: rect.minX, y: rect.maxY)))
    }

    final class Coordinator {
        var shown: PDFReadingLocation?
        var selection: ((PDFOutlineCandidate?) -> Void)?
        var observation: NSObjectProtocol?
        deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }
    }
}
