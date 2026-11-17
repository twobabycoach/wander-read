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

enum ReadingMarkColor: String, Codable, CaseIterable {
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

    func underlineColor(onDark: Bool) -> NSColor {
        onDark ? color : (color.blended(withFraction: 0.29, of: .black) ?? color)
    }
}

enum ReadingMarkStyle: String, Codable, CaseIterable {
    case highlight, underline

    var title: String {
        switch self {
        case .highlight: return "高亮"
        case .underline: return "下划线"
        }
    }
}

struct ReadingMarkAppearance: Codable, Equatable {
    var color: ReadingMarkColor = .yellow
    var style: ReadingMarkStyle = .highlight
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
    var color: ReadingMarkColor?
    var isExcerpt: Bool?
    var scan: PDFScanClip?
    var printedPage: String?
    var printedPageEnd: String?
    var style: ReadingMarkStyle?
    var quoteCorrection: PDFQuoteCorrection?

    var needsQuoteReview: Bool { quoteCorrection == nil && PDFQuoteQuality.isSuspicious(quote) }

    var appearance: ReadingMarkAppearance {
        get { ReadingMarkAppearance(color: color ?? .yellow, style: style ?? .highlight) }
        set {
            color = newValue.color
            style = newValue.style
        }
    }
}

struct PDFReadingState: Codable, Equatable {
    var cursor: PDFReadingCursor?
    var marks: [PDFReadingMark] = []
    var outline: PDFSavedOutline?
    var foldCorrections: PDFSavedFoldCorrections?
    var detectedOutline: PDFDetectedOutline?
    var foldOptions: PDFFoldOptions?
    var bookmarks: [PDFPlaceBookmark]?
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

struct PDFDetectedOutline: Codable, Equatable {
    static let currentVersion = 3
    var version = Self.currentVersion
    let revision: String
    let entries: [PDFOutlineCandidate]
}

struct PDFPlaceBookmark: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    let revision: String
    let location: PDFReadingLocation
    let foldPosition: PDFFoldPosition?
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
    @Published private(set) var detectedOutline: [PDFOutlineCandidate]?
    private var automaticSections: [PDFReadingSection] = []
    @Published private(set) var findingOutline = false
    @Published private(set) var outlineFileChanged = false
    @Published private(set) var foldOptions: PDFFoldOptions
    @Published private(set) var bookmarks: [PDFPlaceBookmark]
    @Published private(set) var foldCorrections: [PDFFoldCorrection]
    @Published private(set) var location: PDFReadingLocation
    @Published private(set) var hasSelection = false
    @Published var selectionAnchor: CGRect?
    var selectedQuote: String? { canvas?.currentSelection?.string }
    var translationDocument: TranslationDocument { TranslationDocument(itemID: itemID, revision: revision) }
    var translationSource: PDFTranslationSource {
        PDFTranslationSource(document: translationDocument, url: url, pageCount: document.pageCount)
    }

    var translationSelection: TranslationPassage? {
        guard !showOutline, !selectingRegion, let selection = canvas?.currentSelection,
              let text = selection.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let pages = selection.pages.map { document.index(for: $0) }.filter { (0..<document.pageCount).contains($0) }
        let first = pages.min() ?? location.page
        let last = pages.max() ?? first
        let place = first == last ? pageReference(first) : "PDF 第 \(first + 1)–\(last + 1) 页"
        return TranslationPassage(text: text, title: title, place: place, document: translationDocument,
                                  suspectedEncodingError: PDFQuoteQuality.isSuspicious(text))
    }
    var defaultMarkAppearance: ReadingMarkAppearance {
        store?.library.preferences.readingMarkAppearance ?? ReadingMarkAppearance()
    }
    @Published private(set) var canUndo = false
    @Published private(set) var previousVersion: Bool
    @Published var noteDraft: PDFReadingMark?
    @Published var draftText = ""
    @Published var editingNote = false
    @Published var isFocused = false
    @Published var showOutline = false {
        didSet {
            guard showOutline != oldValue else { return }
            foldReflow = nil
            if showOutline {
                clearSelection()
            } else {
                restoreCanvasPosition()
            }
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
    private var layoutRestore: DispatchWorkItem?
    private var needsPositionSave = false
    private var contextualLocation: PDFReadingLocation?
    private var programmaticViewport: PDFReadingLocation?
    private var foldReflow: FoldReflow?
    private var outlineWork: Task<Void, Never>?

    private struct FoldReflow {
        let destination: PDFFoldPosition
        let returnLocation: PDFReadingLocation?
    }

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
        let savedSections: [PDFReadingSection]
        if let saved = item.pdfReading?.outline, saved.revision == revision {
            savedSections = saved.sections.filter { (0..<document.pageCount).contains($0.location.page) }
            outlineDraft = saved.draft
        } else {
            savedSections = []
        }
        savedOutline = savedSections
        if let cache = item.pdfReading?.detectedOutline, cache.revision == revision,
           cache.version == PDFDetectedOutline.currentVersion {
            detectedOutline = cache.entries
            automaticSections = Self.readableSections(cache.entries, pageCount: document.pageCount)
        }
        let defaults = store.library.preferences
        foldOptions = item.pdfReading?.foldOptions ?? PDFFoldOptions(
            unit: savedSections.isEmpty ? (defaults.pdfFoldUnit ?? .chapter) : .chapter,
            pages: defaults.pdfFoldPages ?? 3
        )
        bookmarks = item.pdfReading?.bookmarks ?? []
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

    deinit { outlineWork?.cancel() }

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
        programmaticViewport = viewport(in: view)
        restoring = false
        view.documentView?.needsDisplay = true
        view.needsDisplay = true
    }

    func preserveCanvasReadingPosition(in view: PDFView) {
        guard canvas === view, !showOutline else { return }
        layoutRestore?.cancel()
        restoring = true
        let work = DispatchWorkItem { [weak self, weak view] in
            guard let self else { return }
            self.restoring = false
            self.layoutRestore = nil
            guard let view, self.canvas === view, !self.showOutline else { return }
            view.layoutDocumentView()
            self.restoreCanvasPosition()
        }
        layoutRestore = work
        DispatchQueue.main.async(execute: work)
    }
    private static func validPoint(_ point: CGPoint) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite, point.x != kPDFDestinationUnspecifiedValue,
              point.y != kPDFDestinationUnspecifiedValue else { return nil }
        return point
    }

    func selectionChanged() {
        let selected = selectedQuote?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if selected != hasSelection { hasSelection = selected }
    }

    func clearSelection() {
        canvas?.clearSelection()
        selectionChanged()
        if selectionAnchor != nil { selectionAnchor = nil }
    }

    func readingAidOrigin() -> PDFReadingLocation {
        guard let view = canvas else { return location }
        if let selection = view.currentSelection,
           let page = selection.pages.first(where: { page in view.visiblePages.contains(page) }),
           let line = selection.selectionsByLine().first(where: { !$0.bounds(for: page).isEmpty }) {
            let rect = line.bounds(for: page)
            return PDFReadingLocation(page: document.index(for: page), point: CGPoint(x: rect.minX, y: rect.maxY))
        }
        let sample = CGPoint(x: view.bounds.midX, y: view.bounds.maxY - min(72, view.bounds.height / 5))
        guard let page = document.page(at: location.page) ?? view.page(for: sample, nearest: true) else { return location }
        let point = view.convert(sample, to: page)
        let bounds = page.bounds(for: view.displayBox)
        if let anchor = location.point, anchor.x > bounds.minX + bounds.width * 0.07 { return location }
        let readingX = bounds.minX + bounds.width * 0.28
        let readingY = min(bounds.maxY, max(bounds.minY, point.y))
        return PDFReadingLocation(page: document.index(for: page), point: Self.validPoint(CGPoint(x: readingX, y: readingY)))
    }

    func visiblePositionChanged() {
        guard !showOutline, !restoring, let view = canvas, let next = viewport(in: view) else { return }
        if let initial = programmaticViewport, next.page == initial.page {
            // PDFKit can fit both columns and report the left edge after a jump to the right column.
            if next == initial { return }
            if let point = next.point, let origin = initial.point,
               abs(point.x - origin.x) <= 12 && abs(point.y - origin.y) <= 12 { return }
        }
        programmaticViewport = nil
        guard next != location else { return }
        location = next
        foldPosition = nil
        schedulePositionSave()
    }

    private func viewport(in view: PDFView) -> PDFReadingLocation? {
        guard let page = view.currentPage else { return nil }
        let index = document.index(for: page)
        guard (0..<document.pageCount).contains(index) else { return nil }
        let bounds = page.bounds(for: view.displayBox)
        let point = view.currentDestination.flatMap { destination -> CGPoint? in
            guard destination.page === page, let point = Self.validPoint(destination.point) else { return nil }
            return CGPoint(x: min(bounds.maxX, max(bounds.minX, point.x)),
                           y: min(bounds.maxY, max(bounds.minY, point.y)))
        }
        return PDFReadingLocation(page: index, point: point)
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

    func jumpInFold(to target: PDFReadingLocation, position: PDFFoldPosition?, preserveReflow: Bool = false) {
        guard showOutline, (0..<document.pageCount).contains(target.page) else { return }
        if !preserveReflow { foldReflow = nil }
        location = target
        foldPosition = position?.page == target.page ? position : nil
        schedulePositionSave()
    }

    func prepareFoldReflow(to destination: PDFFoldPosition, returnLocation: PDFReadingLocation?) {
        foldReflow = FoldReflow(destination: destination, returnLocation: returnLocation)
    }

    func originalLocationForFoldReflow() -> PDFReadingLocation? {
        foldReflow?.returnLocation
    }

    var foldReflowTarget: PDFFoldPosition? { foldReflow?.destination }

    func restoreCanvasPosition() {
        let wasRestoring = restoring
        restoring = true
        moveCanvas(to: location)
        programmaticViewport = canvas.flatMap(viewport(in:))
        restoring = wasRestoring
    }

    func rememberFoldPosition(_ position: PDFFoldPosition, passage: FoldedPDFPassage? = nil) {
        guard showOutline, (0..<document.pageCount).contains(position.page), foldPosition != position else { return }
        if let reflow = foldReflow {
            let staysOnPassage = position == reflow.destination || passage?.sources(startingOn: position.page).contains { source in
                source.page == reflow.destination.page &&
                    (reflow.destination.offset.map { NSLocationInRange($0, source.range) } ?? true)
            } == true
            if !staysOnPassage { foldReflow = nil }
        }
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
        guard let selection = canvas?.currentSelection, let page = selection.pages.first,
              let firstLine = selection.selectionsByLine().first, let text = selection.string else { return ("", location) }
        let index = document.index(for: page)
        let rect = firstLine.bounds(for: page)
        guard (0..<document.pageCount).contains(index), !rect.isEmpty else { return ("", location) }
        return (String(ChineseReading.reflow(text).prefix(200)),
                PDFReadingLocation(page: index, point: CGPoint(x: rect.minX, y: rect.maxY)))
    }

    private static func readableSections(_ entries: [PDFOutlineCandidate], pageCount: Int) -> [PDFReadingSection] {
        PDFOutlineCandidate.sections(from: entries.filter { !$0.isPending }, pageCount: pageCount) ?? []
    }

    var navigationSections: [PDFReadingSection] {
        if !savedOutline.isEmpty { return savedOutline }
        if hasAuthorOutline { return sections }
        return automaticSections
    }

    var outlineForEditing: [PDFOutlineCandidate] {
        if let outlineDraft { return outlineDraft }
        if savedOutline.isEmpty && !hasAuthorOutline { return detectedOutline ?? [] }
        let current = savedOutline.isEmpty ? sections : savedOutline
        return current.map {
            PDFOutlineCandidate(title: $0.title, depth: $0.depth, location: $0.location, printedLabel: $0.printedLabel)
        }
    }

    var pendingOutlineCount: Int {
        (outlineDraft ?? (savedOutline.isEmpty ? detectedOutline : nil))?.filter(\.isPending).count ?? 0
    }

    func prepareOutline() {
        guard !hasAuthorOutline, savedOutline.isEmpty, detectedOutline == nil,
              outlineWork == nil, !outlineFileChanged else { return }
        let url = self.url
        let revision = self.revision
        findingOutline = true
        let worker = Task.detached(priority: .utility) { Self.detectOutline(at: url, revision: revision) }
        outlineWork = Task { @MainActor [weak self] in
            let entries = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard let self, !Task.isCancelled else { return }
            self.outlineWork = nil
            if let entries { self.cacheOutline(entries) }
            else { self.outlineFileChanged = true }
            self.findingOutline = false
        }
    }

    func stopOutlineDetection() {
        outlineWork?.cancel()
        outlineWork = nil
        findingOutline = false
    }

    static func detectOutline(at url: URL, revision: String, scanRange: Range<Int>? = nil) -> [PDFOutlineCandidate]? {
        let entries = PDFOutlineBuilder.generate(at: url, scanRange: scanRange, autoScan: true)
        guard !Task.isCancelled, (try? fingerprint(url)) == revision else { return nil }
        return entries
    }

    private func cacheOutline(_ entries: [PDFOutlineCandidate]) {
        let cache = PDFDetectedOutline(revision: revision, entries: entries)
        _ = store?.updatePDFReading(itemID, reportError: false) { $0.detectedOutline = cache }
        automaticSections = Self.readableSections(entries, pageCount: document.pageCount)
        detectedOutline = entries
    }

    func saveOutline(_ entries: [PDFOutlineCandidate], resolvedOnly: Bool = false) -> Bool {
        let resolved = resolvedOnly ? entries.filter { !$0.isPending } : entries
        guard let store,
              let sections = PDFOutlineCandidate.sections(from: resolved, pageCount: document.pageCount) else { return false }
        let draft = entries.count == resolved.count ? nil : entries
        let outline = PDFSavedOutline(revision: revision, sections: sections, draft: draft)
        guard store.updatePDFReading(itemID, { $0.outline = outline }) else { return false }
        outlineDraft = draft
        savedOutline = sections
        return true
    }

    func restoreAuthorOutline() -> Bool {
        guard hasAuthorOutline, !savedOutline.isEmpty,
              store?.updatePDFReading(itemID, { $0.outline = nil }) == true else { return false }
        outlineDraft = nil
        savedOutline = []
        return true
    }

    @discardableResult func setFoldOptions(_ options: PDFFoldOptions) -> Bool {
        guard options != foldOptions else { return true }
        guard store?.updatePDFReading(itemID, { $0.foldOptions = options }) == true else { return false }
        foldOptions = options
        return true
    }

    var bookmarkHere: PDFPlaceBookmark? {
        bookmarks.last { bookmark in
            guard bookmark.revision == revision, bookmark.location.page == location.page else { return false }
            if let saved = bookmark.foldPosition, showOutline, saved == foldPosition { return true }
            switch (bookmark.location.point, location.point) {
            case (nil, nil): return true
            case (let first?, let second?): return abs(first.x - second.x) <= 12 && abs(first.y - second.y) <= 12
            default: return false
            }
        }
    }

    @discardableResult func toggleBookmark(title: String) -> Bool {
        if let bookmarkHere { return removeBookmark(bookmarkHere.id) }
        let mark = PDFPlaceBookmark(title: title, revision: revision, location: location,
                                    foldPosition: showOutline ? foldPosition : nil)
        return saveBookmarks(bookmarks + [mark])
    }

    @discardableResult func renameBookmark(_ id: UUID, title: String) -> Bool {
        let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !title.isEmpty, let index = bookmarks.firstIndex(where: { $0.id == id }) else { return false }
        var next = bookmarks
        next[index].title = title
        return saveBookmarks(next)
    }

    @discardableResult func removeBookmark(_ id: UUID) -> Bool {
        saveBookmarks(bookmarks.filter { $0.id != id })
    }

    private func saveBookmarks(_ next: [PDFPlaceBookmark]) -> Bool {
        guard store?.updatePDFReading(itemID, { $0.bookmarks = next }) == true else { return false }
        bookmarks = next
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
        return try draft(kind: kind, selection: selection, in: document)
    }

    func draft(kind: PDFReadingMark.Kind, selection: PDFSelection, in original: PDFDocument) throws -> PDFReadingMark {
        guard original.pageCount == document.pageCount, !selection.pages.isEmpty,
              selection.pages.allSatisfy({ (0..<original.pageCount).contains(original.index(for: $0)) }),
              let text = selection.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InputError.invalid("请在原文栏重新选取文字。")
        }
        let candidate = try draft(kind: kind, lines: readingLines(in: selection, document: original), text: text)
        return preparedMark(candidate)
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

    private func preparedMark(_ candidate: PDFReadingMark) -> PDFReadingMark {
        guard candidate.kind == .annotation, !candidate.quote.isEmpty else { return candidate }
        if let existing = marks.last(where: {
            $0.kind == .annotation && $0.scan == nil && $0.revision == candidate.revision
                && $0.location == candidate.location && $0.lines == candidate.lines
                && ($0.quote == candidate.quote || $0.quoteCorrection?.original == candidate.quote)
        }) { return existing }
        var mark = candidate
        if let appearance = store?.library.preferences.readingMarkAppearance { mark.appearance = appearance }
        return mark
    }

    func excerpt(_ passage: FoldedPDFPassage? = nil, page: Int? = nil,
                 appearance: ReadingMarkAppearance? = nil) throws -> PDFReadingMark? {
        var mark: PDFReadingMark
        if let passage, let page { mark = draftExcerpt(passage, page: page) }
        else { mark = try draft(kind: .annotation) }
        mark.isExcerpt = true
        if let appearance { mark.appearance = appearance }
        return save(mark, remembering: appearance) ? mark : nil
    }

    func draftExcerpt(_ passage: FoldedPDFPassage, page: Int) -> PDFReadingMark {
        let lines = sourceLines(of: passage, page: page)
        let candidate = (try? draft(kind: .annotation, lines: lines, text: passage.text))
            ?? PDFReadingMark(kind: .annotation, revision: revision, location: location(of: passage, on: page),
                              lines: [], quote: passage.text, note: "")
        var mark = preparedMark(candidate)
        mark.isExcerpt = true
        return mark
    }

    @discardableResult func save(_ mark: PDFReadingMark, remembering appearance: ReadingMarkAppearance? = nil) -> Bool {
        var mark = mark
        if mark.revision == revision {
            let pages = mark.lines.map(\.page) + [mark.location.page]
            let first = pages.min() ?? mark.location.page
            let last = pages.max() ?? first
            mark.printedPage = publicationPageLabel(at: first)
            mark.printedPageEnd = last > first ? publicationPageLabel(at: last) : nil
        }
        var next = marks
        if let index = next.firstIndex(where: { $0.id == mark.id }) {
            next[index] = mark
        } else {
            next.append(mark)
        }
        return updateMarks(next, remembering: appearance)
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

    @discardableResult private func updateMarks(_ next: [PDFReadingMark], remembering appearance: ReadingMarkAppearance? = nil) -> Bool {
        guard let store else { return false }
        let changed = marks != next
        if !changed && (appearance == nil || store.library.preferences.readingMarkAppearance == appearance) { return true }
        guard store.updatePDFReading(itemID, markAppearance: appearance, { $0.marks = next }) else { return false }
        guard changed else { return true }
        undoMarks.append(marks)
        if undoMarks.count > 12 { undoMarks.removeFirst() }
        marks = next
        canUndo = true
        return true
    }

    func highlights(in view: PDFView) -> [(mark: PDFReadingMark, rect: CGRect)] {
        guard let shown = view.document else { return [] }
        let visible = Dictionary(uniqueKeysWithValues: view.visiblePages.map { (shown.index(for: $0), $0) })
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

    func setColor(_ color: ReadingMarkColor, for mark: PDFReadingMark) {
        guard var updated = marks.first(where: { $0.id == mark.id }) else { return }
        updated.color = color
        _ = save(updated)
    }

    func setStyle(_ style: ReadingMarkStyle, for mark: PDFReadingMark) {
        guard var updated = marks.first(where: { $0.id == mark.id }) else { return }
        updated.style = style
        _ = save(updated)
    }
}

extension ReadingStore {
    func updatePDFReading(_ id: UUID, reportError: Bool = true, markAppearance: ReadingMarkAppearance? = nil,
                          _ change: (inout PDFReadingState) -> Void) -> Bool {
        guard library.items.contains(where: { $0.id == id && $0.trashedAt == nil }) else { return false }
        return commit(reportError: reportError) { library in
            guard let index = library.items.firstIndex(where: { $0.id == id }) else { return }
            var reading = library.items[index].pdfReading ?? PDFReadingState()
            change(&reading)
            library.items[index].pdfReading = reading
            if let markAppearance { library.preferences.readingMarkAppearance = markAppearance }
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
