import AppKit
import PDFKit
import Vision

struct PDFScanClip: Codable, Equatable {
    let jpeg: Data
}

enum PDFScan {
    static func image(of page: PDFPage, region: CGRect) throws -> Data {
        guard let source = page.pageRef else { throw InputError.invalid("无法取得这一页的图像。") }
        let crop = source.getBoxRect(.cropBox)
        let selected = region.standardized.intersection(crop)
        guard !selected.isNull, !selected.isInfinite, selected.width >= 4, selected.height >= 4 else {
            throw InputError.invalid("框选范围太小。请在一页内拖出一个区域。")
        }
        let rotation = abs(source.rotationAngle) % 180
        let ratio = min(4, 1700 / max(selected.width, selected.height))
        let size = rotation == 0 ? crop.size : CGSize(width: crop.height, height: crop.width)
        let canvas = CGRect(origin: .zero, size: CGSize(width: size.width * ratio, height: size.height * ratio))
        let transform = source.getDrawingTransform(.cropBox, rect: canvas, rotate: 0, preserveAspectRatio: true)
        let bounds = selected.applying(transform).standardized.integral.intersection(canvas.integral)
        guard !bounds.isNull, let context = CGContext(data: nil, width: Int(bounds.width), height: Int(bounds.height),
                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw InputError.invalid("无法生成选区图像。")
        }
        context.setFillColor(CGColor.white)
        context.fill(CGRect(origin: .zero, size: bounds.size))
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.concatenate(transform)
        context.drawPDFPage(source)
        guard let image = context.makeImage() else { throw InputError.invalid("未能保存选区图像。") }
        let bitmap = NSBitmapImageRep(cgImage: image)
        for quality in [0.9, 0.77, 0.65, 0.5] {
            if let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]), data.count <= 350_000 {
                return data
            }
        }
        throw InputError.invalid("这个区域的图像较大，请缩小框选范围再试。")
    }

    static func recognize(_ data: Data) throws -> String {
        try recognizeLines(data).map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func recognizeLines(_ data: Data) throws -> [(text: String, bounds: CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let available = Set(try request.supportedRecognitionLanguages())
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"].filter { available.contains($0) }
        try VNImageRequestHandler(data: data).perform([request])
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { ($0.string, observation.boundingBox) }
        }
    }
}

extension PDFReader {
    func clip(page index: Int, region: CGRect) throws -> PDFReadingMark? {
        guard let page = document.page(at: index) else { return nil }
        let box = page.pageRef?.getBoxRect(.cropBox) ?? page.bounds(for: .cropBox)
        let selected = region.standardized.intersection(box)
        let data = try PDFScan.image(of: page, region: selected)
        var mark = PDFReadingMark(kind: .annotation, revision: revision,
                                  location: PDFReadingLocation(page: index, point: CGPoint(x: selected.minX, y: selected.maxY)),
                                  lines: [PDFReadingLine(page: index, rect: selected)], quote: "", note: "")
        mark.isExcerpt = true
        mark.scan = PDFScanClip(jpeg: data)
        return save(mark) ? mark : nil
    }
}
