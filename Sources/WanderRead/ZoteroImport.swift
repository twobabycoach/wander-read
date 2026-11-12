import Foundation

struct ZoteroReference: Codable, Equatable {
    var itemKey: String
    var pdfKey: String?
    var localPDF: String?
    var localURL: URL? {
        guard let localPDF, localPDF.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: localPDF)
        guard url.pathExtension.lowercased() == "pdf", FileManager.default.isReadableFile(atPath: url.path),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return url
    }
}

struct ZoteroCollection: Decodable {
    var key: String
    var data: Fields
    struct Fields: Decodable {
        var name: String
        var parentCollection: String?
        enum CodingKeys: String, CodingKey { case name, parentCollection }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            name = try values.decode(String.self, forKey: .name)
            parentCollection = try? values.decode(String.self, forKey: .parentCollection)
        }
    }
}

struct ZoteroRow: Decodable {
    var key: String
    var data: Fields
    struct Fields: Decodable {
        var itemType: String
        var title: String?
        var date: String?
        var parentItem: String?
        var contentType: String?
        var filename: String?
        var linkMode: String?
        var tags: [Tag]?
        var collections: [String]?
        var creators: [Creator]?
    }
    struct Tag: Decodable { var tag: String }
    struct Creator: Decodable { var name: String?; var firstName: String?; var lastName: String? }

    var pdf: Bool {
        data.itemType == "attachment" && data.linkMode != "linked_url" &&
            (data.contentType?.lowercased() == "application/pdf" || data.filename?.lowercased().hasSuffix(".pdf") == true)
    }
}

struct ZoteroSnapshot {
    struct Folder: Identifiable {
        var id: String
        var path: String
    }
    let folders: [Folder]
    let items: [(item: ReadingItem, folders: Set<String>)]

    init(collections: [ZoteroCollection], rows: [ZoteroRow], attachments: [ZoteroRow]) {
        let byKey = Dictionary(collections.map { ($0.key, $0.data) }, uniquingKeysWith: { first, _ in first })
        func ancestry(_ key: String) -> [String] {
            var current: String? = key
            var seen = Set<String>()
            var result: [String] = []
            while let id = current, let data = byKey[id], seen.insert(id).inserted {
                result.append(id)
                current = data.parentCollection
            }
            return result
        }
        folders = byKey.keys.map { id in
            Folder(id: id, path: ancestry(id).reversed().compactMap { byKey[$0]?.name }.joined(separator: " / "))
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let pdfs = Dictionary(grouping: attachments.filter { $0.pdf && ZoteroAPI.validKey($0.key) }, by: { $0.data.parentItem ?? $0.key })
        items = rows.compactMap { row in
            guard ZoteroAPI.validKey(row.key), !["note", "annotation"].contains(row.data.itemType),
                  row.data.itemType != "attachment" || row.pdf,
                  let title = row.data.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
            let children = pdfs[row.key, default: []].sorted { $0.key < $1.key }
            let best = row.pdf ? row.key : children.first?.key
            let keys = row.data.collections ?? []
            let authors = (row.data.creators ?? []).prefix(4).compactMap { author -> String? in
                let name = author.name ?? [author.firstName, author.lastName].compactMap { $0 }.joined(separator: " ")
                return name.isEmpty ? nil : name
            }
            let year = row.data.date?.range(of: "[0-9]{4}", options: .regularExpression).flatMap { range in row.data.date.map { String($0[range]) } }
            let detail = [authors.joined(separator: "、"), year ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
            var tags = Set<String>()
            let ordered = (row.data.tags ?? []).map(\.tag) + keys.compactMap { byKey[$0]?.name }
            let topics = Array(ordered.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && tags.insert($0).inserted }.prefix(24))
            var item = ReadingItem(title: title, target: "zotero://select/library/items/\(row.key)", note: detail,
                                   tags: topics.isEmpty ? ["Zotero"] : topics)
            item.zotero = ZoteroReference(itemKey: row.key, pdfKey: best)
            return (item, Set(keys.flatMap(ancestry)))
        }
    }

    func selection(folder: String?, pdfOnly: Bool) -> [ReadingItem] {
        items.filter { row in
            (folder.map { row.folders.contains($0) } ?? true) && (!pdfOnly || row.item.zotero?.pdfKey != nil)
        }.map(\.item)
    }
}

enum ZoteroAPI {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.urlCache = nil
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }()

    static func validKey(_ value: String) -> Bool {
        value.utf8.count == 8 && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) }
    }

    static func snapshot() async throws -> ZoteroSnapshot {
        async let folders: [ZoteroCollection] = pages("collections")
        async let rows: [ZoteroRow] = pages("items/top")
        async let attachments: [ZoteroRow] = pages("items", query: [.init(name: "itemType", value: "attachment")])
        return try await ZoteroSnapshot(collections: folders, rows: rows, attachments: attachments)
    }

    static func pdfURL(_ key: String) async throws -> URL {
        guard validKey(key) else { throw InputError.invalid("Zotero 附件标识无效。") }
        let (data, _) = try await get("items/\(key)/file/view/url")
        guard let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: path), url.isFileURL, url.host?.isEmpty != false || url.host == "localhost",
              url.pathExtension.lowercased() == "pdf", FileManager.default.isReadableFile(atPath: url.path),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw InputError.invalid("这份 PDF 附件还没在本机就绪。可在 Zotero 下载或修复附件，再回漫读打开。")
        }
        return url.standardizedFileURL
    }

    private static func pages<T: Decodable>(_ route: String, query: [URLQueryItem] = []) async throws -> [T] {
        let size = 150
        var result: [T] = []
        var expectedVersion: String?
        while true {
            try Task.checkCancellation()
            let (data, response) = try await get(route, query: query + [
                .init(name: "start", value: String(result.count)), .init(name: "limit", value: String(size))
            ])
            let rows = try JSONDecoder().decode([T].self, from: data)
            let version = response.value(forHTTPHeaderField: "Last-Modified-Version")
            if let expectedVersion, let version, version != expectedVersion {
                throw InputError.invalid("Zotero 文献库在读取期间有变动，请重新预览。")
            }
            expectedVersion = version
            result += rows
            let total = response.value(forHTTPHeaderField: "Total-Results").flatMap(Int.init)
            if rows.isEmpty || (total.map { result.count >= $0 } ?? (rows.count < size)) { return result }
        }
    }

    private static func get(_ route: String, query: [URLQueryItem] = []) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = 23119
        components.path = "/api/users/0/" + route
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw InputError.invalid("Zotero 入口无效。") }
        var request = URLRequest(url: url)
        request.setValue("3", forHTTPHeaderField: "Zotero-API-Version")
        request.setValue("WanderRead", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw InputError.invalid("没有收到 Zotero 的响应。") }
            switch http.statusCode {
            case 200: return (data, http)
            case 403: throw InputError.invalid("请在 Zotero「设置 → 高级」允许本机应用与 Zotero 通信，再重试。")
            case 404 where route.hasSuffix("/file/view/url"):
                throw InputError.invalid("Zotero 找不到这份附件。请在 Zotero 检查附件位置。")
            default: throw InputError.invalid("Zotero 返回了 \(http.statusCode)，请检查桌面版是否正常运行。")
            }
        } catch let error as URLError where error.code != .cancelled {
            throw InputError.invalid("连不上本机 Zotero。请打开 Zotero 并启用本机通信，再重试。")
        }
    }
}

extension ReadingStore {
    func openZoteroPDF(_ item: ReadingItem, focused: Bool = false, markID: UUID? = nil) {
        guard readerOpening == nil, pdfReader == nil, textReader == nil, let reference = item.zotero, let key = reference.pdfKey else { return }
        guard activeSession == nil || activeSession?.itemID == item.id else {
            page = "发现"; message = "先收好正在读的那一篇，再打开这份 PDF。"; return
        }
        readerOpening = item.id
        Task { @MainActor [weak self] in
            do {
                let url: URL
                if let cached = reference.localURL { url = cached }
                else { url = try await ZoteroAPI.pdfURL(key) }
                let revision = try await Task.detached(priority: .userInitiated) { try PDFReader.fingerprint(url) }.value
                guard let self, self.readerOpening == item.id else { return }
                defer { self.readerOpening = nil }
                try self.presentPDF(itemID: item.id, url: url, revision: revision, markID: markID, focused: focused, zoteroKey: key)
            } catch {
                guard let self, self.readerOpening == item.id else { return }
                self.readerOpening = nil
                self.error = error.localizedDescription
            }
        }
    }
}
