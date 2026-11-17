import Foundation

struct ZoteroImportScope: Codable {
    var folder: String?
    var pdfOnly: Bool
}

struct ZoteroReference: Codable, Equatable {
    var itemKey: String
    var pdfKey: String?
    var localPDF: String?
    var citationKey: String?
    var localURL: URL? {
        guard let localPDF, localPDF.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: localPDF)
        guard url.pathExtension.lowercased() == "pdf", FileManager.default.isReadableFile(atPath: url.path),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return url
    }
}

enum CitationKey {
    static func normalized(_ raw: String?) -> String? {
        guard var key = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if key.hasPrefix("@") { key.removeFirst() }
        let lettersAndNumbers = CharacterSet.alphanumerics
        let allowed = lettersAndNumbers.union(CharacterSet(charactersIn: "_:.#$%&-+?<>~/"))
        guard !key.isEmpty, key.utf8.count <= 240, key.unicodeScalars.contains(where: lettersAndNumbers.contains),
              key.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return key
    }

    static func markdown(_ key: String, locator: String? = nil) -> String {
        let bareKey = #"\A[\p{L}\p{N}\p{M}_]+(?:[:.#$%&+?<>~/-][\p{L}\p{N}\p{M}_]+)*\z"#
        let identifier = key.range(of: bareKey, options: .regularExpression) == nil ? "{\(key)}" : key
        return "[@\(identifier)" + (locator.map { ", " + $0 } ?? "") + "]"
    }

    static func fromExtra(_ extra: String?) -> String? {
        for line in extra?.split(whereSeparator: \.isNewline) ?? [] {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "citation key",
               let key = normalized(String(parts[1])) { return key }
        }
        return nil
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
        var citationKey: String?
        var extra: String?

        var exportKey: String? {
            CitationKey.normalized(citationKey) ?? CitationKey.fromExtra(extra)
        }
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
            item.zotero = ZoteroReference(itemKey: row.key, pdfKey: best, citationKey: row.pdf ? nil : row.data.exportKey)
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

    static func pdfURL(_ key: String, timeout: TimeInterval = 8) async throws -> URL {
        guard validKey(key) else { throw InputError.invalid("Zotero 附件标识无效。") }
        let (data, _) = try await get("items/\(key)/file/view/url", timeout: timeout)
        guard let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: path), url.isFileURL, url.host?.isEmpty != false || url.host == "localhost",
              url.pathExtension.lowercased() == "pdf", FileManager.default.isReadableFile(atPath: url.path),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw InputError.invalid("这份 PDF 附件还没在本机就绪。可在 Zotero 下载或修复附件，再回漫读打开。")
        }
        return url.standardizedFileURL
    }

    static func citationLookup(_ item: ReadingItem) -> String? {
        if let key = item.zotero?.itemKey, validKey(key) { return key }
        let url = item.target.hasPrefix("/") ? URL(fileURLWithPath: item.target) : URL(string: item.target)
        guard let url else { return nil }
        if url.scheme == "zotero", ["select", "open-pdf"].contains(url.host ?? "") {
            let parts = url.path.split(separator: "/")
            if parts.count == 3, parts[0] == "library", parts[1] == "items", validKey(String(parts[2])) {
                return String(parts[2])
            }
        }
        if let folder = storageFolder(for: url), validKey(folder.lastPathComponent) { return folder.lastPathComponent }
        return nil
    }

    static func citationKey(for item: ReadingItem) async -> String? {
        guard let key = citationLookup(item) else { return nil }
        if item.zotero == nil {
            let target = item.target.hasPrefix("/") ? URL(fileURLWithPath: item.target) : URL(string: item.target)
            if let target, target.isFileURL {
                guard let attachment = try? await pdfURL(key, timeout: 2),
                      attachment.resolvingSymlinksInPath().path == target.resolvingSymlinksInPath().path else { return nil }
            }
        }
        guard let row = try? await citationRow(key) else { return nil }
        if row.data.itemType != "attachment" { return await exportKey(row) }
        guard let parent = row.data.parentItem, let record = try? await citationRow(parent),
              record.data.itemType != "attachment" else { return nil }
        return await exportKey(record)
    }

    private static func storageFolder(for url: URL) -> URL? {
        guard url.isFileURL, url.pathExtension.lowercased() == "pdf" else { return nil }
        let folder = url.deletingLastPathComponent()
        return folder.deletingLastPathComponent().lastPathComponent == "storage" ? folder : nil
    }

    private static func citationRow(_ key: String) async throws -> ZoteroRow {
        guard validKey(key) else { throw InputError.invalid("Zotero 文献标识无效。") }
        let (bytes, _) = try await get("items/\(key)", timeout: 2)
        let row = try JSONDecoder().decode(ZoteroRow.self, from: bytes)
        guard row.key == key else { throw InputError.invalid("Zotero 返回的文献与所选条目不一致。") }
        return row
    }

    private static func exportKey(_ row: ZoteroRow) async -> String? {
        guard !["note", "annotation"].contains(row.data.itemType) else { return nil }
        if let key = row.data.exportKey { return key }
        struct Response: Decodable { let result: [String: String?]? }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:23119/better-bibtex/json-rpc")!, timeoutInterval: 2)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "jsonrpc": "2.0", "method": "item.citationkey", "id": 1, "params": [[row.key]]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let keys = try? JSONDecoder().decode(Response.self, from: data).result,
              let key = keys[row.key] ?? nil else { return nil }
        return CitationKey.normalized(key)
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

    private static func get(_ route: String, query: [URLQueryItem] = [], timeout: TimeInterval = 8) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = 23119
        components.path = "/api/users/0/" + route
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw InputError.invalid("Zotero 入口无效。") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
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
