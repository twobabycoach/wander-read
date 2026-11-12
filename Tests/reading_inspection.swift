import Foundation
import PDFKit

func runReadingInspectionChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wander-inspection-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appendingPathComponent("正在读.pdf")
    let second = root.appendingPathComponent("查阅出处.pdf")
    try writeReadingPDF(first)
    try writeReadingPDF(second, suffix: " for lookup")
    let revision = try PDFReader.fingerprint(second)
    let source = PDFReadingLocation(page: 1, point: CGPoint(x: 72, y: 620))
    let mark = PDFReadingMark(kind: .annotation, revision: revision, location: source,
                              lines: [], quote: "Research evidence", note: "")
    let a = ReadingItem(title: "正在读", target: first.path)
    var b = ReadingItem(title: "查阅出处", target: second.path)
    b.pdfReading = PDFReadingState(marks: [mark])
    let store = ReadingStore(directory: root, refreshOnLoad: false)
    check(store.commit { $0.items = [a, b] }, "预览和临时查阅使用隔离资料")
    store.refresh()
    let candidates = store.recommendations.map(\.id)
    let beforePreview = try Data(contentsOf: store.dataURL)
    store.inspectCandidate(a)
    let afterPreview = try Data(contentsOf: store.dataURL)
    check(store.inspection?.item.id == a.id && store.inspection?.isCandidate == true &&
          store.activeSession == nil && store.recommendations.map(\.id) == candidates &&
          afterPreview == beforePreview, "先看看保留候选顺序，资料与阅读记录没有写入")
    store.inspection = nil
    let firstRevision = try PDFReader.fingerprint(first)
    try store.presentPDF(itemID: a.id, url: first, revision: firstRevision)
    let reader = store.pdfReader!
    reader.showOutline = true
    let paragraph = reader.foldedPassages(on: 2)[0]
    let position = PDFFoldPosition(page: 2, offset: paragraph.id)
    reader.rememberFoldPosition(position, passage: paragraph)
    reader.noteDraft = try reader.draft(kind: .detour, pageOnly: true)
    reader.draftText = "等下核对这一句"
    let beforeLookup = try Data(contentsOf: store.dataURL)
    let session = store.activeSession?.id
    store.revealReaderNote(ReaderNoteLink(itemID: b.id, noteID: mark.id))
    let request = store.inspection!
    let afterLookup = try Data(contentsOf: store.dataURL)
    check(request.item.id == b.id && request.sourceLabel == "PDF 第 2 页" &&
          store.pdfReader === reader && reader.foldPosition == position &&
          reader.draftText == "等下核对这一句" && store.activeSession?.id == session &&
          afterLookup == beforeLookup, "跨文献查阅保留折叠锚点、草稿和会话")
    store.inspection = nil
    check(reader.foldPosition == position && store.pdfReader === reader, "关闭临时查阅后仍在原文")
    store.revealReaderNote(ReaderNoteLink(itemID: b.id, noteID: mark.id))
    store.acceptInspection(store.inspection!, content: .pdf(second, PDFDocument(url: second)!, revision: revision))
    let previous = store.library.items.first { $0.id == a.id }
    check(store.pdfReader?.itemID == b.id && store.pdfReader?.location == source &&
          store.activeSession?.itemID == b.id && previous?.pdfReading?.cursor?.foldPosition == position &&
          previous?.resumeThought == "等下核对这一句", "明确继续才切换，前一篇保留位置与续读提示")
    let abstract = "〔摘 要〕 这里讨论可以回到原文的论证与引用出处，从具体的材料开始核对观点是否成立。\n〔关键词〕阅读；引文"
    check(InspectionContent.authorAbstract(in: abstract)?.hasSuffix("是否成立。") == true &&
          InspectionContent.authorAbstract(in: "这是正文中提到摘要的地方。") == nil, "只把有明确边界的原文标为作者摘要")
}
