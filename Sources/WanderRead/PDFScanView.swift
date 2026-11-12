import AppKit
import PDFKit
import SwiftUI

struct PDFScanEditor: View {
    @ObservedObject var reader: PDFReader
    let noteID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var busy = false
    @State private var status: String?
    @State private var worker: Task<Void, Never>?
    private var mark: PDFReadingMark? { reader.marks.first { $0.id == noteID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("校对框选文字").font(.system(size: 27, weight: .medium, design: .serif))
            Text("对照左侧原图。确认后，文字和图会一起留在摘录里。")
                .font(.system(size: 13)).foregroundColor(Palette.muted)
            HStack(alignment: .top, spacing: 14) {
                if let jpeg = mark?.scan?.jpeg, let image = NSImage(data: jpeg) {
                    ScrollView {
                        Image(nsImage: image).resizable().scaledToFit()
                            .padding(10).accessibilityLabel("框选原图")
                    }.frame(width: 295).background(Palette.card, in: RoundedRectangle(cornerRadius: 9))
                }
                TextEditor(text: $text)
                    .font(.system(size: 14)).scrollContentBackground(.hidden).padding(8)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityLabel("校对后的文字")
            }.frame(height: 248)
            if busy { ProgressView("正在本机识别…").controlSize(.small) }
            else if let status { Text(status).font(.system(size: 12)).foregroundColor(Palette.muted) }
            HStack {
                Button("识别文字", action: recognize).buttonStyle(ActionStyle()).disabled(busy || mark == nil)
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(ActionStyle()).keyboardShortcut(.cancelAction)
                Button("保存校对文字") {
                    guard var current = mark else { return }
                    current.quote = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if reader.save(current) { dismiss() }
                }.buttonStyle(ActionStyle(primary: true)).disabled(busy || mark == nil || text.utf8.count > 30_000)
            }
        }.padding(24).frame(width: 670).background(Palette.paper).foregroundColor(Palette.ink)
            .onAppear { text = mark?.quote ?? ""; if text.isEmpty { recognize() } }
            .onDisappear { worker?.cancel() }
    }

    private func recognize() {
        guard let data = mark?.scan?.jpeg else { return }
        busy = true
        status = nil
        worker = Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { Result { try PDFScan.recognize(data) } }.value
            guard !Task.isCancelled else { return }
            busy = false
            switch result {
            case .success(let value):
                if value.isEmpty { status = "未识别到文字，可以对照原图手动录入。" }
                else { text = value; status = "识别已完成。请核对字词、数字和标点。" }
            case .failure: status = "本机识别暂时不可用，可以手动录入。"
            }
        }
    }
}

final class PDFRegionOverlay: NSView {
    weak var pdf: PDFView?
    weak var reader: PDFReader?
    private var first: CGPoint?
    private var current: CGPoint?
    private var page: PDFPage?

    init(pdf: PDFView, reader: PDFReader) {
        self.pdf = pdf
        self.reader = reader
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        reader?.selectingRegion == true ? super.hitTest(point) : nil
    }

    override func resetCursorRects() {
        if reader?.selectingRegion == true { addCursorRect(bounds, cursor: .crosshair) }
    }

    func refresh() {
        if reader?.selectingRegion != true { first = nil; current = nil; page = nil }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let pdf else { return }
        let at = convert(event.locationInWindow, from: nil)
        page = pdf.page(for: pdf.convert(at, from: self), nearest: false)
        first = page == nil ? nil : at
        current = first
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        defer { first = nil; current = nil; page = nil; needsDisplay = true }
        guard let pdf, let reader, let page, let rect = frameForDrag, rect.width >= 6, rect.height >= 6 else { return }
        let region = pdf.convert(pdf.convert(rect, from: self), to: page)
        let index = reader.document.index(for: page)
        guard index >= 0, index < reader.document.pageCount else { return }
        reader.finishRegion(page: index, region: region)
    }

    private var frameForDrag: CGRect? {
        guard let pdf, let page, let first, let current else { return nil }
        let box = page.pageRef?.getBoxRect(.cropBox) ?? page.bounds(for: .cropBox)
        let pageRect = convert(pdf.convert(box, from: page), from: pdf)
        return CGRect(x: first.x, y: first.y, width: current.x - first.x, height: current.y - first.y)
            .standardized.intersection(pageRect)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard reader?.selectingRegion == true, let frameForDrag, !frameForDrag.isNull else { return }
        let path = NSBezierPath(roundedRect: frameForDrag, xRadius: 3, yRadius: 3)
        NSColor.controlAccentColor.withAlphaComponent(0.17).setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}
