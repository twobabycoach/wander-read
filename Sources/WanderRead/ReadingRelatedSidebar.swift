import SwiftUI

final class ReadingRelatedSearch: ObservableObject {
    @Published var expanded = false
    @Published var query = ""
    @Published private(set) var results: [RelatedReadingResult]?
    @Published private(set) var requestID: UUID?
    @Published private(set) var busy = false
    @Published private(set) var kept = Set<UUID>()
    private var task: Task<Void, Never>?

    deinit { task?.cancel() }

    func search(_ text: String, store: ReadingStore, anchor: UUID) {
        let query = String(ChineseReading.reflow(text).trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        guard !SemanticIndex.tokens(query).isEmpty else { return }
        self.query = query
        expanded = true
        requestID = UUID()
        task?.cancel()
        busy = true
        let items = store.library.items
        let preferences = store.library.preferences
        task = Task { @MainActor [weak self] in
            let worker = Task.detached(priority: .utility) {
                RelatedReading.rank(items: items, preferences: preferences, question: query, anchorID: anchor,
                                    limit: 60, inlineEvidence: true)
            }
            let report = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard let self, !Task.isCancelled else { return }
            self.results = report.results
            self.kept = []
            self.busy = false
        }
    }

    func keep(_ result: RelatedReadingResult, save: (String) -> Bool) {
        guard let evidence = result.pdfEvidence, !kept.contains(result.id) else { return }
        let note = "查相关 · \(result.item.title) · PDF 第 \(evidence.page + 1) 页\n\(ChineseReading.reflow(evidence.quote))"
        if save(note) { kept.insert(result.id) }
    }
}

struct ReadingRelatedSidebar: View {
    @ObservedObject var search: ReadingRelatedSearch
    @ObservedObject var store: ReadingStore
    let itemID: UUID
    let suggestedQuery: String
    let keep: (String) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Button {
                search.expanded.toggle()
                if search.expanded && search.query.isEmpty { search.query = suggestedQuery }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: search.expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("查相关").font(.system(size: 13, weight: .medium))
                    Spacer()
                }.padding(.vertical, 5).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundColor(Palette.muted)
                .accessibilityLabel(search.expanded ? "收起查相关" : "展开查相关")
            if search.expanded {
                HStack(spacing: 7) {
                    TextField("选段或输入想核对的问题", text: $search.query)
                        .textFieldStyle(.roundedBorder).onSubmit(run)
                    Button(search.busy ? "重查" : "查找", action: run)
                        .buttonStyle(.borderless).foregroundColor(Palette.green)
                        .disabled(search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if search.busy {
                    ProgressView("正在本机查找…").controlSize(.small).font(.system(size: 12))
                } else if let results = search.results {
                    if results.isEmpty {
                        Text("这次没有找到可定位的相关原文。").font(.system(size: 12)).foregroundColor(Palette.muted)
                    }
                    ForEach(results) { result in
                        if let evidence = result.pdfEvidence {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(result.item.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                                Text(ChineseReading.reflow(evidence.quote))
                                    .font(.system(size: 12)).lineSpacing(3).lineLimit(4).textSelection(.enabled)
                                HStack {
                                    Button("查原文 · 第 \(evidence.page + 1) 页") { store.inspectRelated(result) }
                                    Spacer(minLength: 4)
                                    Button(search.kept.contains(result.id) ? "已放好" : "先放这里") {
                                        search.keep(result, save: keep)
                                    }.disabled(search.kept.contains(result.id))
                                }.font(.system(size: 11)).buttonStyle(.borderless).foregroundColor(Palette.green)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                } else {
                    Text("从收藏里查找能回到 PDF 原页的片段。")
                        .font(.system(size: 12)).foregroundColor(Palette.muted)
                }
            }
        }
    }

    private func run() {
        search.search(search.query, store: store, anchor: itemID)
    }
}
