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
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(request.isCandidate ? "先看看" : "临时查阅")
                        .font(.system(size: 11, weight: .semibold)).foregroundColor(Palette.green)
                    Spacer()
                    Text(request.sourceLabel).font(.system(size: 11)).foregroundColor(Palette.muted)
                }
                Text(request.item.title).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                if !request.quote.isEmpty, case .pdf = content {
                    Text(ChineseReading.reflow(request.quote)).font(.system(size: 13))
                        .foregroundColor(Palette.muted).lineLimit(2).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 13)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 12) {
                Text(request.isCandidate ? "点「就读这个」后才开始记录" : "关闭后接着原来的阅读")
                    .font(.system(size: 12)).foregroundColor(Palette.muted)
                Spacer()
                Button(request.isCandidate ? "返回候选" : "关闭查阅") { store.inspection = nil }
                    .buttonStyle(ReadingControlStyle()).keyboardShortcut(.cancelAction)
                Button(request.isCandidate ? "就读这个" : "从这里继续读") {
                    store.acceptInspection(request, content: content)
                }.buttonStyle(ReadingControlStyle(accented: true))
                    .disabled(!request.isCandidate && content == nil)
            }.padding(.horizontal, 16).padding(.vertical, 9)
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
                InspectionPDFCanvas(document: document, location: destination.location, lines: destination.lines,
                                    isRegion: request.isRegion)
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
    let isRegion: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = LaidOutPDFView()
        view.backgroundColor = NSColor(Palette.side)
        view.displayMode = .singlePageContinuous
        view.document = document
        view.autoScales = true
        let marks = PDFHighlightSurface(pdf: view) { view in
            let visible = Dictionary(uniqueKeysWithValues: view.visiblePages.map { (document.index(for: $0), $0) })
            return lines.compactMap { line in
                guard let page = visible[line.page] else { return nil }
                return PDFCanvasHighlight(rect: view.convert(line.rect, from: page), isRegion: isRegion)
            }
        }
        let surface = NSView()
        for child in [view as NSView, marks] {
            child.frame = surface.bounds
            child.autoresizingMask = [.width, .height]
            surface.addSubview(child)
        }
        view.onFirstLayout = { [weak view, weak marks, weak coordinator = context.coordinator] in
            guard let view, let page = document.page(at: location.page) else { return }
            view.layoutDocumentView()
            view.go(to: page)
            if let point = location.point, point.x.isFinite, point.y.isFinite,
               let scroll = view.documentView?.enclosingScrollView {
                let clip = scroll.contentView
                let target = clip.convert(view.convert(point, from: page), from: view)
                var bounds = clip.bounds
                bounds.origin.y = target.y - bounds.height * (clip.isFlipped ? 0.36 : 0.64)
                if target.x < bounds.minX + 20 || target.x > bounds.maxX - 20 {
                    bounds.origin.x = target.x - bounds.width / 2
                }
                clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
                scroll.reflectScrolledClipView(clip)
            }
            if let marks { coordinator?.observe(view, marks: marks); marks.needsDisplay = true }
        }
        return surface
    }

    func updateNSView(_ view: NSView, context: Context) {}

    final class Coordinator {
        private var observers: [NSObjectProtocol] = []

        func observe(_ view: PDFView, marks: NSView) {
            let center = NotificationCenter.default
            for name in [Notification.Name.PDFViewVisiblePagesChanged, .PDFViewScaleChanged] {
                observers.append(center.addObserver(forName: name, object: view, queue: .main) { [weak marks] _ in
                    marks?.needsDisplay = true
                })
            }
            if let clip = view.documentView?.enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak marks] _ in
                    marks?.needsDisplay = true
                })
            }
        }

        deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
