import AppKit
import SwiftUI

struct PDFQuoteRepairEditor: View {
    @ObservedObject var reader: PDFReader
    let noteID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var initialQuote = ""
    @State private var images: [PDFQuoteImage] = []
    @State private var busy = false
    @State private var status: String?
    @State private var usedOCR = false
    @State private var ocrText: String?
    @State private var imageZoom: CGFloat = 1
    @State private var worker: Task<Void, Never>?
    private var mark: PDFReadingMark? { reader.marks.first { $0.id == noteID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("校对摘录").font(.system(size: 20, weight: .semibold))
                Spacer()
                if let mark { Text(ReaderNote(mark).location).font(.system(size: 12)).foregroundColor(Palette.muted) }
            }
            Text("从选区原图识别文字。核对后保存，原来的高亮和想法会保留。")
                .font(.system(size: 13)).foregroundColor(Palette.muted)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        Text("选区原图").font(.system(size: 12, weight: .medium))
                        Spacer()
                        ReadingIconButton(title: "缩小原图", systemImage: "minus.magnifyingglass") { imageZoom = max(1, imageZoom - 0.5) }
                            .disabled(imageZoom <= 1)
                        Text("\(Int(imageZoom * 100))%").font(.system(size: 11)).monospacedDigit().frame(width: 34)
                        ReadingIconButton(title: "放大原图", systemImage: "plus.magnifyingglass") { imageZoom = min(3, imageZoom + 0.5) }
                            .disabled(imageZoom >= 3)
                    }.foregroundColor(Palette.muted)
                    GeometryReader { geometry in
                        ScrollView([.horizontal, .vertical]) {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(images) { part in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("PDF 第 \(part.page + 1) 页").font(.system(size: 11)).foregroundColor(Palette.muted)
                                        if let image = NSImage(data: part.jpeg) {
                                            Image(nsImage: image).resizable().scaledToFit().accessibilityLabel("摘录选区原图")
                                                .onTapGesture(count: 2) { imageZoom = imageZoom == 1 ? 2 : 1 }
                                        }
                                    }
                                }
                                if images.isEmpty {
                                    Text(busy ? "正在准备原图…" : "暂时无法显示原图，可以返回原页核对。")
                                        .font(.system(size: 13)).foregroundColor(Palette.muted)
                                        .frame(maxWidth: .infinity, minHeight: 150)
                                }
                            }
                            .frame(width: max(100, geometry.size.width - 20) * imageZoom)
                            .frame(minHeight: max(0, geometry.size.height - 20), alignment: .topLeading).padding(10)
                        }
                    }.background(Palette.side, in: RoundedRectangle(cornerRadius: 8))
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 8) {
                    Text("摘录文字 · 可直接修改").font(.system(size: 12, weight: .medium)).foregroundColor(Palette.muted)
                        .frame(height: 28, alignment: .leading)
                    TextEditor(text: $text).font(.system(size: 14)).lineSpacing(5)
                        .scrollContentBackground(.hidden).padding(9)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line.opacity(0.6)) }
                        .accessibilityLabel("校对后的摘录文字").disabled(busy)
                }.frame(maxWidth: .infinity)
            }.frame(height: 370)
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small) }
                Text(status ?? "识别在本机完成。请留意人名、引号、引文编号和页码。")
                    .font(.system(size: 12)).foregroundColor(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(minHeight: 32, alignment: .leading)
            Divider()
            HStack(spacing: 12) {
                Button(usedOCR ? "重新识别" : "从原图识别", action: recognize)
                    .buttonStyle(ReadingControlStyle()).disabled(busy || images.isEmpty)
                Button("恢复当前摘录") { text = initialQuote; usedOCR = false; status = nil }
                    .buttonStyle(ReadingControlStyle()).disabled(busy || text == initialQuote)
                if let ocrText {
                    Menu("更多") {
                        Button("使用整段识别结果") {
                            text = ocrText; usedOCR = true
                            status = "已换成整段 OCR 结果。汉字和数字也可能识别有误，请逐句核对。"
                        }
                    }.menuStyle(.borderlessButton).fixedSize()
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存校对") { save() }.keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || mark == nil || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf8.count > 100_000)
            }.controlSize(.regular)
        }.padding(22).frame(width: 790).background(Palette.paper).foregroundColor(Palette.ink)
            .onAppear(perform: prepare)
            .onDisappear { worker?.cancel() }
    }

    private func prepare() {
        guard let mark else { return }
        initialQuote = mark.quote
        text = mark.quote
        busy = true
        let url = reader.url, revision = reader.revision
        worker = Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try PDFQuoteRepair.images(url: url, revision: revision, mark: mark) }
            }.value
            guard !Task.isCancelled else { return }
            busy = false
            switch result {
            case .success(let value):
                images = value
                if mark.needsQuoteReview { recognize() }
            case .failure(let error): status = error.localizedDescription
            }
        }
    }

    private func recognize() {
        guard !images.isEmpty else { return }
        let input = images
        busy = true
        status = "正在本机识别选区，暂不改动已保存的摘录…"
        worker = Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { Result { try PDFQuoteRepair.recognize(input) } }.value
            guard !Task.isCancelled else { return }
            busy = false
            switch result {
            case .success(let value):
                let proposal = PDFQuoteRepair.proposal(original: initialQuote, recognized: value)
                text = proposal.text
                ocrText = value
                usedOCR = true
                if proposal.preservesSource {
                    status = "已参照原图校正能确认的标点，保留原提取的正文和数字。" +
                        (proposal.unresolved.isEmpty ? "请核对后保存。" : "「\(proposal.unresolved)」仍需对照原图校对。")
                } else {
                    status = "已重新识别。请对照原图核对，保存后才会替换摘录文字。"
                }
            case .failure(let error): status = error.localizedDescription
            }
        }
    }

    private func save() {
        do {
            if try reader.correctQuote(noteID, text: text, expected: initialQuote, method: usedOCR ? .localOCR : .manual) { dismiss() }
            else { status = "未能保存。校对文字仍在这里，请重试。" }
        } catch { status = error.localizedDescription }
    }
}
