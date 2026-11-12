import SwiftUI

struct RelatedReadingView: View {
    @ObservedObject var store: ReadingStore
    var anchor: ReadingItem? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var limit = 120
    @State private var task: Task<Void, Never>?
    @State private var report: RelatedReadingReport?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Text("相似度榜").font(.system(size: 28, weight: .medium, design: .serif))
                Spacer()
                Button("关闭") { dismiss() }.buttonStyle(ActionStyle()).keyboardShortcut(.cancelAction)
            }
            Text(anchor.map { "以《\($0.title)》为线索，也可以输入一个问题。" }
                 ?? "用研究问题找资料。留空时参考近期和高频阅读。")
                .font(.system(size: 13)).foregroundColor(Palette.muted).lineLimit(2)
            HStack {
                TextField("例如，平台如何调配劳动时间？", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(scan)
                Picker("比较范围", selection: $limit) {
                    ForEach([60, 120, 300, 500], id: \.self) { Text("最多 \($0) 篇").tag($0) }
                }.labelsHidden().frame(width: 124)
                Button(busy ? "重新查找" : "查找相关文献", action: scan).buttonStyle(ActionStyle(primary: true))
            }
            Text("取本地 PDF 的首、中、尾页，或本地笔记的三段正文。其余来源按标题等资料匹配。")
                .font(.system(size: 12)).foregroundColor(Palette.muted)
            Divider()
            if busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在本机取样并比较…")
                    Spacer()
                    Button("停止") { task?.cancel(); busy = false }
                }.padding(.vertical, 10)
                Spacer()
            } else if let report = report {
                if report.needsAnchor {
                    Text("输入一个研究问题，就可以开始查找。").foregroundColor(Palette.muted)
                    Spacer()
                } else {
                    Text("比较了 \(report.compared) / \(report.available) 篇，\(report.sampled) 篇有正文样本")
                        .font(.system(size: 12, weight: .medium)).foregroundColor(Palette.green)
                    if report.results.isEmpty {
                        Text("没有找到有共同词语的资料，可以换个问题或扩大范围。").foregroundColor(Palette.muted)
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(report.results.enumerated()), id: \.element.id) { offset, result in
                                    resultRow(result, rank: offset + 1)
                                    Divider()
                                }
                            }
                        }
                    }
                }
            } else {
                Spacer()
            }
        }
        .padding(24)
        .frame(width: 730, height: 610)
        .background(Palette.paper)
        .foregroundColor(Palette.ink)
        .onAppear {
            if anchor == nil { question = store.library.preferences.strategy.question }
            scan()
        }
        .onDisappear { task?.cancel() }
    }

    private func resultRow(_ result: RelatedReadingResult, rank: Int) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Text(String(rank)).monospacedDigit().foregroundColor(Palette.muted).frame(width: 28)
            VStack(alignment: .leading, spacing: 7) {
                Text(result.item.title).font(.system(size: 15, weight: .medium)).lineLimit(2)
                if let excerpt = result.excerpt {
                    Text(excerpt).font(.system(size: 13)).lineLimit(3).textSelection(.enabled)
                }
                Text(result.sampledPages.isEmpty
                     ? result.item.source
                     : "PDF 取样页 " + result.sampledPages.map(String.init).joined(separator: "、"))
                    .font(.system(size: 11)).foregroundColor(Palette.muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 7) {
                Text(result.similarity.formatted(.number.precision(.fractionLength(3))))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(Palette.green).help("TF‑IDF 余弦相似度")
                Button("去读") { open(result.item.id) }.buttonStyle(ActionStyle())
            }
        }.padding(.vertical, 13)
    }

    private func scan() {
        task?.cancel()
        let items = store.library.items
        let preferences = store.library.preferences
        let query = question
        let anchorID = anchor?.id
        let limit = limit
        busy = true
        task = Task { @MainActor in
            let worker = Task.detached(priority: .userInitiated) {
                RelatedReading.rank(items: items, preferences: preferences, question: query,
                                    anchorID: anchorID, limit: limit)
            }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled else { return }
            report = result
            busy = false
        }
    }

    private func open(_ id: UUID) {
        guard let item = store.library.items.first(where: { $0.id == id && $0.trashedAt == nil }) else { return }
        if store.pdfReader != nil || store.textReader != nil {
            store.leaveReader()
            guard store.pdfReader == nil, store.textReader == nil else { return }
        }
        dismiss()
        DispatchQueue.main.async { store.choose(item) }
    }
}
