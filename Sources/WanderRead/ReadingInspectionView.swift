import AppKit
import PDFKit
import SwiftUI

struct DiscoveryPreviewKey: NSViewRepresentable {
    let preview: () -> Bool

    final class Coordinator {
        var preview: (() -> Bool)?
        var monitor: Any?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.preview = preview
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view, weak coordinator] event in
            guard event.keyCode == 49, !event.isARepeat,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  let window = view?.window, event.window === window, window.attachedSheet == nil,
                  !(window.firstResponder is NSTextView), !(window.firstResponder is NSControl)
            else { return event }
            return coordinator?.preview?() == true ? nil : event
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { context.coordinator.preview = preview }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }
}

struct ReadingInspectionView: View {
    @ObservedObject var store: ReadingStore
    let request: ReadingInspection
    @State private var content: InspectionContent?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text(request.isCandidate ? "先看看" : "临时查阅")
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(Palette.green)
                Text(request.item.title).font(.system(size: 22, weight: .medium, design: .serif)).lineLimit(2)
                Text(request.sourceLabel).font(.system(size: 12)).foregroundColor(Palette.muted)
                if !request.quote.isEmpty, case .pdf = content {
                    Text(ChineseReading.reflow(request.quote)).font(.system(size: 13))
                        .foregroundColor(Palette.muted).lineLimit(2).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 12) {
                Text(request.isCandidate ? "点「就读这个」后才开始记录" : "关闭后接着原来的阅读")
                    .font(.system(size: 12)).foregroundColor(Palette.muted)
                Spacer()
                Button(request.isCandidate ? "返回候选" : "关闭查阅") { store.inspection = nil }
                    .buttonStyle(ActionStyle()).keyboardShortcut(.cancelAction)
                Button(request.isCandidate ? "就读这个" : "从这里继续读") {
                    store.acceptInspection(request, content: content)
                }.buttonStyle(ActionStyle(primary: true))
                    .disabled(!request.isCandidate && content == nil)
            }.padding(18)
        }
        .frame(width: request.isCandidate ? 610 : 790, height: request.isCandidate ? 475 : 615)
        .foregroundColor(Palette.ink).background(Palette.paper)
        .task(id: request.id) {
            content = nil
            problem = nil
            do {
                let result = try await InspectionContent.load(request)
                if !Task.isCancelled { content = result }
            } catch {
                if !Task.isCancelled { problem = error.localizedDescription }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch content {
        case .pdf(_, let document, _, let destination):
            if let destination {
                InspectionPDFCanvas(document: document, location: destination.location, lines: destination.lines)
                    .id(request.id).accessibilityLabel("原文预览")
            }
        case .text(_, let document, let offset):
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !request.quote.isEmpty { section("当时的摘录", request.quote) }
                    let index = document.blocks.lastIndex { $0.id <= offset } ?? 0
                    let nearby = document.blocks[max(0, index - 1)...min(document.blocks.count - 1, index + 2)]
                    section("原文上下文", nearby.map { String($0.text.prefix(1200)) }.joined(separator: "\n\n"))
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .preview(let pages, let extract, let label, let headings):
            candidate(pages: pages, extract: extract, label: label, headings: headings)
        case .link:
            candidate()
        case nil:
            if let problem {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(problem).foregroundColor(Palette.muted)
                        if !request.quote.isEmpty { section("当时的摘录", request.quote) }
                        if request.isCandidate && !request.item.note.isEmpty { section("收藏时记下", request.item.note) }
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ProgressView("正在读取本地原文…").controlSize(.small)
            }
        }
    }

    private func candidate(pages: Int? = nil, extract: String? = nil, label: String = "", headings: [String] = []) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let pages { Text("\(pages) 页").font(.system(size: 12)).foregroundColor(Palette.muted) }
                if !request.item.note.isEmpty { section("收藏时记下", request.item.note) }
                if let extract { section(label, extract) }
                if !headings.isEmpty { section("目录", headings.joined(separator: "\n")) }
                if extract == nil && headings.isEmpty {
                    Text(request.item.canReadInside ? "这份材料没有可预览的文字。" : "这篇内容会在原来的应用里打开。")
                        .foregroundColor(Palette.muted).font(.system(size: 13))
                }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(Palette.green)
            Text(value).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
        }
    }
}

private struct InspectionPDFCanvas: NSViewRepresentable {
    let document: PDFDocument
    let location: PDFReadingLocation
    let lines: [PDFReadingLine]

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.backgroundColor = NSColor(Palette.side)
        view.displayMode = .singlePageContinuous
        view.autoScales = true
        view.document = document
        DispatchQueue.main.async { [weak view] in
            guard let view, let page = document.page(at: location.page) else { return }
            view.layoutDocumentView()
            let selection = PDFSelection(document: document)
            for line in lines where (0..<document.pageCount).contains(line.page) {
                if let text = document.page(at: line.page)?.selection(for: line.rect) { selection.add(text) }
            }
            view.go(to: page)
            if var point = location.point, point.x.isFinite, point.y.isFinite, view.scaleFactor > 0 {
                point.y = min(page.bounds(for: .cropBox).maxY, point.y + view.bounds.height * 0.28 / view.scaleFactor)
                view.go(to: PDFDestination(page: page, at: point))
            }
            if !selection.pages.isEmpty {
                selection.color = NSColor.systemYellow.withAlphaComponent(0.55)
                view.highlightedSelections = [selection]
            }
        }
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {}
}
