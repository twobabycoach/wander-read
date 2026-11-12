import AppKit
import CryptoKit
import PDFKit
import SwiftUI

struct PDFReadingLocation: Codable, Equatable {
    var page: Int
    var point: CGPoint?
}

struct PDFFoldPosition: Codable, Hashable {
    let page: Int
    var offset: Int?
}

struct PDFReadingCursor: Codable, Equatable {
    var revision: String
    var location: PDFReadingLocation
    var updatedAt: Date
    var intent: String?
    var isFolded: Bool?
    var foldPosition: PDFFoldPosition?
}

struct PDFReadingLine: Codable, Equatable {
    var page: Int
    var rect: CGRect
}

enum PDFMarkColor: String, Codable, CaseIterable {
    case yellow, green, blue, pink

    var title: String {
        switch self {
        case .yellow: return "黄色"
        case .green: return "绿色"
        case .blue: return "蓝色"
        case .pink: return "粉色"
        }
    }

    var color: NSColor {
        switch self {
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .pink: return .systemPink
        }
    }
}

struct PDFReadingMark: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case annotation, detour }

    var id = UUID()
    var kind: Kind
    var revision: String
    var location: PDFReadingLocation
    var lines: [PDFReadingLine]
    var quote: String
    var note: String
    var createdAt = Date()
    var color: PDFMarkColor?
    var isExcerpt: Bool?
    var scan: PDFScanClip?
    var printedPage: String?
}

struct PDFReadingState: Codable, Equatable {
    var cursor: PDFReadingCursor?
    var marks: [PDFReadingMark] = []
    var outline: PDFSavedOutline?
    var foldCorrections: PDFSavedFoldCorrections?
}

struct PDFReadingSection: Identifiable, Codable, Equatable {
    let id: Int
    let title: String
    let location: PDFReadingLocation
    let depth: Int
    var printedLabel: String?
}

struct PDFSavedOutline: Codable, Equatable {
    let revision: String
    let sections: [PDFReadingSection]
    var draft: [PDFOutlineCandidate]?
}

final class PDFReader: ObservableObject {
    let itemID: UUID
    let title: String
    let url: URL
    let revision: String
    let document: PDFDocument
    // The canvas can add transient Live Text. Folded reading keeps the file's text layer.
    private let sourceDocument: PDFDocument
    let sections: [PDFReadingSection]
    let hasAuthorOutline: Bool
    let intent: String
    var academicLayouts: [Int: PDFAcademicLayout] = [:]
    var printedPageLabels: [Int: String] = [:]

    @Published private(set) var marks: [PDFReadingMark]
    @Published private(set) var savedOutline: [PDFReadingSection]
    private(set) var outlineDraft: [PDFOutlineCandidate]?
    @Published private(set) var foldCorrections: [PDFFoldCorrection]
    @Published private(set) var location: PDFReadingLocation
    @Published private(set) var hasSelection = false
    var selectedQuote: String? { canvas?.currentSelection?.string }
    @Published private(set) var canUndo = false
    @Published private(set) var previousVersion: Bool
    @Published var noteDraft: PDFReadingMark?
    @Published var draftText = ""
    @Published var editingNote = false
    @Published var isFocused = false
    @Published var showOutline = false {
        didSet {
            guard showOutline != oldValue else { return }
            if !showOutline { restoreCanvasPosition() }
            schedulePositionSave()
        }
    }
    private(set) var foldPosition: PDFFoldPosition?
    @Published var revealedNote: UUID?
    @Published var selectingRegion = false { didSet { if selectingRegion { canvas?.clearSelection() } } }

    private weak var store: ReadingStore?
    private weak var canvas: PDFView?
    private var undoMarks: [[PDFReadingMark]] = []
    private var saveWork: DispatchWorkItem?
    private var restoring = false
    private var needsPositionSave = false
    private var contextualLocation: PDFReadingLocation?

    init(item: ReadingItem, url: URL, revision: String, document: PDFDocument, store: ReadingStore,
         markID: UUID? = nil, requestedLocation: PDFReadingLocation? = nil) {
        itemID = item.id
        title = item.title
        self.url = url
        self.revision = revision
        self.document = document
        sourceDocument = PDFDocument(url: url) ?? document
        self.store = store
        let storedMarks = item.pdfReading?.marks ?? []
        marks = storedMarks
        if let saved = item.pdfReading?.outline, saved.revision == revision {
            savedOutline = saved.sections.filter { (0..<document.pageCount).contains($0.location.page) }
            outlineDraft = saved.draft
        } else {
            savedOutline = []
        }
        let corrections = item.pdfReading?.foldCorrections
        foldCorrections = corrections?.revision == revision ? corrections?.edits ?? [] : []
        revealedNote = storedMarks.first(where: { $0.id == markID })?.id
        let cursor = item.pdfReading?.cursor
        let question = store.library.preferences.strategy.question.trimmingCharacters(in: .whitespacesAndNewlines)
        intent = cursor?.intent ?? (question.isEmpty ? item.note : question)
        previousVersion = (cursor.map { $0.revision != revision } ?? false) ||
            storedMarks.contains { $0.id == markID && $0.revision != revision }
        let mark = storedMarks.first { $0.id == markID && $0.revision == revision }
        let saved = cursor?.revision == revision ? cursor : nil
        let entry = requestedLocation ?? mark?.location ?? saved?.location ?? PDFReadingLocation(page: 0)
        let initialLocation = (0..<document.pageCount).contains(entry.page) ? entry : PDFReadingLocation(page: 0)
        location = initialLocation
        contextualLocation = requestedLocation ?? mark?.location
        if markID == nil, requestedLocation == nil, let position = saved?.foldPosition, position.page == initialLocation.page { foldPosition = position }
        let outline = Self.outline(in: document)
        hasAuthorOutline = !outline.isEmpty
        sections = outline.isEmpty ? (0..<document.pageCount).map { page in
            PDFReadingSection(id: page, title: "PDF 第 \(page + 1) 页", location: PDFReadingLocation(page: page), depth: 0)
        } : outline
        showOutline = markID == nil && requestedLocation == nil && saved?.isFolded == true
    }

    static func fingerprint(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", Int($0)) }.joined()
    }

    func saveFoldCorrection(_ correction: PDFFoldCorrection) {
        guard foldCorrections.count < 500 else {
            store?.error = "这份 PDF 已保存 500 次分段调整。可以先撤销已有调整。"
            return
        }
        saveFoldCorrections(foldCorrections + [correction])
    }

    func undoFoldCorrection() {
        guard !foldCorrections.isEmpty else { return }
        saveFoldCorrections(Array(foldCorrections.dropLast()))
    }

    private func saveFoldCorrections(_ edits: [PDFFoldCorrection]) {
        let saved = edits.isEmpty ? nil : PDFSavedFoldCorrections(revision: revision, edits: edits)
        guard store?.updatePDFReading(itemID, { $0.foldCorrections = saved }) == true else { return }
        foldCorrections = edits
    }

    private static func outline(in document: PDFDocument) -> [PDFReadingSection] {
        var result: [PDFReadingSection] = []
        func visit(_ node: PDFOutline, depth: Int) {
            guard depth < 32 else { return }
            if let target = node.destination, let page = target.page, let label = node.label, !label.isEmpty {
                let index = document.index(for: page)
                if index < document.pageCount {
                    let bounds = page.bounds(for: .cropBox)
                    let y = target.point.y
                    let point = y.isFinite && y != kPDFDestinationUnspecifiedValue
                        ? CGPoint(x: min(max(Self.validPoint(target.point)?.x ?? bounds.minX, bounds.minX), bounds.maxX),
                                  y: min(max(y, bounds.minY), bounds.maxY)) : nil
                    let location = PDFReadingLocation(page: index, point: point)
                    result.append(PDFReadingSection(id: result.count, title: label, location: location, depth: depth))
                }
            }
            for index in 0..<node.numberOfChildren {
                if let child = node.child(at: index) { visit(child, depth: depth + 1) }
            }
        }
        if let root = document.outlineRoot {
            for index in 0..<root.numberOfChildren {
                if let node = root.child(at: index) { visit(node, depth: 0) }
            }
        }
        return result
    }

    func attach(_ view: PDFView) {
        canvas = view
        restoring = true
    }

    func restoreAfterLayout(in view: PDFView) {
        guard canvas === view else { return }
        view.layoutDocumentView()
        moveCanvas(to: location)
        restoring = false
        view.documentView?.needsDisplay = true
        view.needsDisplay = true
    }

    private static func validPoint(_ point: CGPoint) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite, point.x != kPDFDestinationUnspecifiedValue,
              point.y != kPDFDestinationUnspecifiedValue else { return nil }
        return point
    }

    func selectionChanged() {
        hasSelection = canvas?.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func visiblePositionChanged() {
        guard !showOutline, !restoring, let view = canvas, let page = view.currentPage else { return }
        let index = document.index(for: page)
        guard index < document.pageCount else { return }
        let bounds = page.bounds(for: view.displayBox)
        let point = view.currentDestination.flatMap { destination -> CGPoint? in
            guard destination.page === page, let point = Self.validPoint(destination.point) else { return nil }
            return CGPoint(x: min(bounds.maxX, max(bounds.minX, point.x)),
                           y: min(bounds.maxY, max(bounds.minY, point.y)))
        }
        let next = PDFReadingLocation(page: index, point: point)
        if foldPosition?.page == index, let y = point?.y,
           abs(y - (location.point?.y ?? bounds.maxY)) <= 16 {
            // PDFKit can adjust a destination to fit the page margin or current zoom.
            return
        }
        guard next != location else { return }
        location = next
        foldPosition = nil
        schedulePositionSave()
    }

    private func moveCanvas(to target: PDFReadingLocation) {
        guard let canvas, (0..<document.pageCount).contains(target.page), let page = document.page(at: target.page) else { return }
        // Establish the destination page's tiles before restoring its intra-page offset.
        canvas.go(to: page)
        if var point = target.point {
            if contextualLocation == target, page.rotation == 0, canvas.scaleFactor > 0 {
                let crop = page.bounds(for: canvas.displayBox)
                point.y = min(crop.maxY, point.y + canvas.bounds.height * 0.38 / canvas.scaleFactor)
            }
            canvas.go(to: PDFDestination(page: page, at: point))
        }
    }

    func showSource(at target: PDFReadingLocation) {
        showOutline = false
        contextualLocation = target
        go(to: target)
    }

    func go(to target: PDFReadingLocation) {
        guard (0..<document.pageCount).contains(target.page) else { return }
        if target != location {
            foldPosition = nil
            if contextualLocation != target { contextualLocation = nil }
        }
        location = target
        restoreCanvasPosition()
        schedulePositionSave()
    }

    func restoreCanvasPosition() {
        let wasRestoring = restoring
        restoring = true
        moveCanvas(to: location)
        restoring = wasRestoring
    }

    func rememberFoldPosition(_ position: PDFFoldPosition, passage: FoldedPDFPassage? = nil) {
        guard showOutline, (0..<document.pageCount).contains(position.page), foldPosition != position else { return }
        var anchor = PDFReadingLocation(page: position.page)
        if let passage, let page = sourcePage(at: position.page),
           let line = page.textSelection(in: passage.range)?.selectionsByLine().first {
            let bounds = line.bounds(for: page)
            if !bounds.isEmpty { anchor.point = CGPoint(x: bounds.minX, y: bounds.maxY) }
        }
        foldPosition = position
        if location != anchor { location = anchor }
        schedulePositionSave()
    }

    func finishRegion(page: Int, region: CGRect) {
        do {
            if let mark = try clip(page: page, region: region) {
                selectingRegion = false
                revealedNote = mark.id
            }
        } catch { store?.error = error.localizedDescription }
    }

    func sourcePage(at index: Int) -> PDFPage? {
        guard (0..<sourceDocument.pageCount).contains(index) else { return nil }
        return sourceDocument.page(at: index)
    }

    func outlineEntryAtSelection() -> (title: String, location: PDFReadingLocation) {
        guard let line = canvas?.currentSelection?.selectionsByLine().first,
              let page = line.pages.first, let text = line.string else { return ("", location) }
        let index = document.index(for: page)
        let rect = line.bounds(for: page)
        guard (0..<document.pageCount).contains(index), !rect.isEmpty else { return ("", location) }
        return (String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)),
                PDFReadingLocation(page: index, point: CGPoint(x: rect.minX, y: rect.maxY)))
    }

    func saveOutline(_ entries: [PDFOutlineCandidate], resolvedOnly: Bool = false) -> Bool {
        let resolved = resolvedOnly ? entries.filter { !$0.isPending } : entries
        guard !hasAuthorOutline, let store,
              let sections = PDFOutlineCandidate.sections(from: resolved, pageCount: document.pageCount) else { return false }
        let draft = entries.count == resolved.count ? nil : entries
        let outline = PDFSavedOutline(revision: revision, sections: sections, draft: draft)
        guard store.updatePDFReading(itemID, { $0.outline = outline }) else { return false }
        outlineDraft = draft
        savedOutline = sections
        return true
    }

    func sourceText(page: Int) -> String? {
        sourcePage(at: page)?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func foldedPassages(on page: Int) -> [FoldedPDFPassage] {
        guard let text = sourcePage(at: page)?.string else { return [] }
        return FoldedPDFPassage.split(text)
    }

    func location(of passage: FoldedPDFPassage, on index: Int) -> PDFReadingLocation {
        guard let page = sourcePage(at: index),
              let line = page.textSelection(in: passage.range)?.selectionsByLine().first else {
            return PDFReadingLocation(page: index)
        }
        let bounds = line.bounds(for: page)
        let top = page.bounds(for: .cropBox).maxY
        return PDFReadingLocation(page: index, point: CGPoint(x: bounds.minX, y: min(top, bounds.maxY + 24)))
    }

    private func schedulePositionSave() {
        needsPositionSave = true
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in _ = self?.flushPosition(showError: false) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    @discardableResult func flushPosition(showError: Bool = true, force: Bool = false) -> Bool {
        saveWork?.cancel()
        saveWork = nil
        guard needsPositionSave || force else { return true }
        let cursor = PDFReadingCursor(revision: revision, location: location, updatedAt: Date(), intent: intent,
                                      isFolded: showOutline ? true : nil, foldPosition: foldPosition)
        guard let store = store else { return false }
        let saved = store.updatePDFReading(itemID, reportError: showError) { $0.cursor = cursor }
        if saved { needsPositionSave = false }
        return saved
    }

    func draft(kind: PDFReadingMark.Kind, pageOnly: Bool = false) throws -> PDFReadingMark {
        if pageOnly { return PDFReadingMark(kind: kind, revision: revision, location: location, lines: [], quote: "", note: "") }
        guard let selection = canvas?.currentSelection,
              let text = selection.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if kind == .annotation { throw InputError.invalid("先在原页选中一句，就能划线或写批注。") }
            return PDFReadingMark(kind: kind, revision: revision, location: location, lines: [], quote: "", note: "")
        }
        return try draft(kind: kind, selection: selection, text: text, in: document)
    }

    private func draft(kind: PDFReadingMark.Kind, selection: PDFSelection, text: String, in document: PDFDocument) throws -> PDFReadingMark {
        try draft(kind: kind, lines: readingLines(in: selection, document: document), text: text)
    }

    private func readingLines(in selection: PDFSelection, document: PDFDocument) -> [PDFReadingLine] {
        selection.selectionsByLine().flatMap { line in
            line.pages.compactMap { page -> PDFReadingLine? in
                let index = document.index(for: page)
                let rect = line.bounds(for: page)
                guard index < document.pageCount, !rect.isEmpty, !rect.isInfinite else { return nil }
                return PDFReadingLine(page: index, rect: rect)
            }
        }
    }

    func sourceLines(of passage: FoldedPDFPassage, page: Int) -> [PDFReadingLine] {
        passage.sources(startingOn: page).flatMap { source -> [PDFReadingLine] in
            guard let selection = sourcePage(at: source.page)?.textSelection(in: source.range) else { return [] }
            return readingLines(in: selection, document: sourceDocument)
        }
    }

    private func draft(kind: PDFReadingMark.Kind, lines: [PDFReadingLine], text: String) throws -> PDFReadingMark {
        guard text.count <= 20_000 else { throw InputError.invalid("这次选中的文字太长，请选一个较短的段落。") }
        guard let first = lines.first, lines.count <= 500 else { throw InputError.invalid("这段文字的位置无法记录，请重新选中较短的段落。") }
        let origin = PDFReadingLocation(page: first.page, point: CGPoint(x: first.rect.minX, y: first.rect.maxY))
        return PDFReadingMark(kind: kind, revision: revision, location: origin, lines: lines, quote: text, note: "")
    }

    func excerpt(_ passage: FoldedPDFPassage? = nil, page: Int? = nil) throws -> PDFReadingMark? {
        var mark: PDFReadingMark
        if let passage, let page {
            let lines = sourceLines(of: passage, page: page)
            if let draft = try? draft(kind: .annotation, lines: lines, text: passage.text) {
                mark = draft
            } else {
                mark = PDFReadingMark(kind: .annotation, revision: revision, location: location(of: passage, on: page),
                                      lines: [], quote: passage.text, note: "")
            }
        } else {
            mark = try draft(kind: .annotation)
        }
        if let existing = marks.last(where: {
            $0.isExcerpt == true && $0.revision == mark.revision && $0.location == mark.location && $0.quote == mark.quote
        }) { return existing }
        mark.isExcerpt = true
        return save(mark) ? mark : nil
    }

    @discardableResult func save(_ mark: PDFReadingMark) -> Bool {
        var mark = mark
        if mark.revision == revision {
            mark.printedPage = printedPageLabel(at: mark.location.page)
        }
        var next = marks
        if let index = next.firstIndex(where: { $0.id == mark.id }) {
            next[index] = mark
        } else {
            next.append(mark)
        }
        return next == marks || updateMarks(next)
    }

    func discardDraft() {
        noteDraft = nil
        draftText = ""
        editingNote = false
    }

    @discardableResult func saveDraft() -> Bool {
        guard var mark = noteDraft else { return true }
        mark.note = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if (editingNote || !mark.note.isEmpty || !mark.quote.isEmpty) && !save(mark) { return false }
        discardDraft()
        return true
    }

    func remove(_ id: UUID) { _ = remove([id]) }

    @discardableResult func remove(_ ids: Set<UUID>) -> Bool {
        let remaining = marks.filter { !ids.contains($0.id) }
        return remaining == marks || updateMarks(remaining)
    }

    @discardableResult func relocate(_ mark: PDFReadingMark) throws -> Bool {
        if mark.scan != nil { throw InputError.invalid("原 PDF 版本有变。这张图摘仍保留，可在新版重新框选。") }
        let selected = try draft(kind: mark.kind, pageOnly: mark.quote.isEmpty)
        let comparable: (String) -> String = { text in text.filter { !$0.isWhitespace } }
        guard mark.quote.isEmpty || comparable(mark.quote) == comparable(selected.quote) else {
            throw InputError.invalid("请选中与旧摘录相同的文字，再更新位置。原来的摘录已保留。")
        }
        var updated = mark
        updated.location = selected.location
        updated.lines = selected.lines
        updated.revision = revision
        return save(updated)
    }

    func undo() {
        guard let previous = undoMarks.last, let store = store,
              store.updatePDFReading(itemID, { $0.marks = previous }) else { return }
        marks = previous
        undoMarks.removeLast()
        canUndo = !undoMarks.isEmpty
    }

    @discardableResult private func updateMarks(_ next: [PDFReadingMark]) -> Bool {
        guard let store = store, store.updatePDFReading(itemID, { $0.marks = next }) else { return false }
        undoMarks.append(marks)
        if undoMarks.count > 12 { undoMarks.removeFirst() }
        marks = next
        canUndo = true
        return true
    }

    func highlights(in view: PDFView) -> [(mark: PDFReadingMark, rect: CGRect)] {
        let visible = Dictionary(uniqueKeysWithValues: view.visiblePages.map { (document.index(for: $0), $0) })
        return marks.filter { $0.revision == revision && $0.kind == .annotation }.flatMap { mark in
            mark.lines.compactMap { line in
                guard let page = visible[line.page] else { return nil }
                return (mark, view.convert(line.rect, from: page))
            }
        }
    }

    func revealAnnotation(at point: CGPoint, in view: PDFView) {
        guard let mark = highlights(in: view).last(where: { $0.rect.contains(point) })?.mark else { return }
        revealedNote = nil
        revealedNote = mark.id
    }

    func setColor(_ color: PDFMarkColor, for mark: PDFReadingMark) {
        var updated = mark
        updated.color = color
        _ = save(updated)
    }

}

extension ReadingStore {
    func updatePDFReading(_ id: UUID, reportError: Bool = true, _ change: (inout PDFReadingState) -> Void) -> Bool {
        guard library.items.contains(where: { $0.id == id && $0.trashedAt == nil }) else { return false }
        return commit(reportError: reportError) { library in
            guard let index = library.items.firstIndex(where: { $0.id == id }) else { return }
            var reading = library.items[index].pdfReading ?? PDFReadingState()
            change(&reading)
            library.items[index].pdfReading = reading
        }
    }

    func openPDF(_ item: ReadingItem, markID: UUID? = nil, focused: Bool = false) {
        guard readerOpening == nil, pdfReader == nil, textReader == nil else { return }
        guard activeSession == nil || activeSession?.itemID == item.id else {
            page = "发现"
            message = "先收好正在读的那一篇，再打开这份 PDF。"
            return
        }
        let url: URL
        do { url = try ObsidianLinks.checkedURL(item.target) }
        catch { self.error = error.localizedDescription; return }
        guard url.isFileURL, url.pathExtension.lowercased() == "pdf" else { return }
        readerOpening = item.id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try PDFReader.fingerprint(url) }
            DispatchQueue.main.async {
                guard let self = self, self.readerOpening == item.id else { return }
                self.readerOpening = nil
                do {
                    let revision = try result.get()
                    try self.presentPDF(itemID: item.id, url: url, revision: revision, markID: markID, focused: focused)
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func presentPDF(itemID: UUID, url: URL, revision: String, markID: UUID? = nil, focused: Bool = false,
                    zoteroKey: String? = nil, prepared: PDFDocument? = nil, location: PDFReadingLocation? = nil) throws {
        guard pdfReader == nil, textReader == nil, activeSession == nil || activeSession?.itemID == itemID,
              let item = library.items.first(where: { $0.id == itemID && $0.trashedAt == nil }) else { return }
        if let zoteroKey {
            guard item.zotero?.pdfKey == zoteroKey, url.isFileURL else { return }
        } else {
            guard (try? ObsidianLinks.checkedURL(item.target)) == url else { return }
        }
        guard let document = prepared ?? PDFDocument(url: url), !document.isLocked, document.pageCount > 0,
              document.page(at: 0) != nil else {
            throw InputError.invalid("漫读无法读出这份 PDF。加密文件或受损文件可以在收藏的菜单中用原阅读器打开。")
        }
        let reader = PDFReader(item: item, url: url, revision: revision, document: document, store: self,
                               markID: markID, requestedLocation: location)
        guard startReaderVisit(itemID) else { return }
        if zoteroKey != nil && item.zotero?.localPDF != url.path {
            _ = mutate(itemID) { $0.zotero?.localPDF = url.path }
        }
        message = nil
        reader.isFocused = focused
        pdfReader = reader
    }

    func toggleReadingFocus() {
        if let reader = pdfReader {
            guard reader.saveDraft() else { return }
            reader.isFocused.toggle()
            return
        }
        if let reader = textReader { reader.isFocused.toggle(); return }
        let candidate = activeItem ?? (page == "发现" ? recommendations.first?.item : nil)
        guard let item = candidate, item.canReadInside else {
            message = "打开一份 PDF 或文本后，可以用 ⇧⌘F 切换专注阅读。"
            return
        }
        openInReader(item, focused: true)
    }

    func leavePDF() {
        guard let reader = pdfReader, reader.saveDraft(), reader.flushPosition(force: true) else { return }
        if finishReaderVisit(reader.itemID) {
            pdfReader = nil
            fillQueueIfNeeded()
        }
    }

    var latestPDFToResume: ReadingItem? {
        library.items.filter { $0.trashedAt == nil && $0.state != .archived && ($0.canSendToResearch || $0.zotero?.pdfKey != nil) && $0.pdfReading?.cursor != nil }
            .max { left, right in
                (left.pdfReading?.cursor?.updatedAt ?? .distantPast) < (right.pdfReading?.cursor?.updatedAt ?? .distantPast)
            }
    }
}
