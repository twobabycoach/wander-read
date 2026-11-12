import SwiftUI
import AppKit

struct ZoteroImportView: View {
    @ObservedObject var store: ReadingStore
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: ZoteroSnapshot?
    @State private var folder: String?
    @State private var pdfOnly = false
    @State private var busy = false
    @State private var problem: String?
    @State private var loadID = UUID()
    private var selection: [ReadingItem] { snapshot?.selection(folder: folder, pdfOnly: pdfOnly) ?? [] }
    private var fresh: [ReadingItem] {
        let existing = Set(store.library.items.map { Targets.key($0.target) })
        return selection.filter { !existing.contains(Targets.key($0.target)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "books.vertical").font(.system(size: 22))
                    .foregroundColor(Palette.green).frame(width: 48, height: 48)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text("从 Zotero 收录").font(.system(size: 28, weight: .medium, design: .serif))
                    Text("个人文献库 · 本机连接").font(.system(size: 12)).foregroundColor(Palette.muted)
                }
                Spacer()
            }
            if busy {
                ProgressView("正在读取分类和条目…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let problem {
                VStack(alignment: .leading, spacing: 16) {
                    Text(problem).font(.system(size: 14)).lineSpacing(5).foregroundColor(Palette.muted)
                    HStack {
                        Button("打开 Zotero") { NSWorkspace.shared.open(URL(string: "zotero://select/library")!) }.buttonStyle(ActionStyle())
                        Button("重新连接") { loadID = UUID() }.buttonStyle(ActionStyle(primary: true))
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else if let snapshot {
                HStack {
                    Picker("分类", selection: $folder) {
                        Text("整个个人库").tag(nil as String?)
                        ForEach(snapshot.folders) { Text($0.path).tag(Optional($0.id)) }
                    }
                    Toggle("仅带 PDF", isOn: $pdfOnly).toggleStyle(.checkbox).fixedSize()
                }
                Text("将收录 \(fresh.count) 篇，跳过 \(selection.count - fresh.count) 篇已有文献。选分类时包含它的子分类。")
                    .font(.system(size: 12, weight: .medium)).foregroundColor(Palette.green)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if fresh.isEmpty {
                            Text("这个范围没有新的条目。").foregroundColor(Palette.muted).padding(13)
                        }
                        ForEach(fresh.prefix(30)) { item in
                            HStack(spacing: 10) {
                                Image(systemName: item.zotero?.pdfKey != nil ? "doc.text" : "books.vertical")
                                    .foregroundColor(Palette.green).frame(width: 18)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title).lineLimit(2).font(.system(size: 13, weight: .medium))
                                    if !item.note.isEmpty { Text(item.note).lineLimit(1).font(.system(size: 11)).foregroundColor(Palette.muted) }
                                }
                                Spacer()
                            }.padding(10)
                            Divider()
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.background(Palette.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                Text(fresh.count > 30 ? "这里预览前 30 篇。确认后会收录这个范围内的全部新条目。" :
                    "原条目与附件留在 Zotero。可在漫读的「管理导入与回收站」按批次清理。")
                    .font(.system(size: 11)).foregroundColor(Palette.muted)
            }
            HStack {
                Button("关闭") { dismiss() }.buttonStyle(ActionStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                if snapshot != nil {
                    Button("收录 \(fresh.count) 篇") {
                        let name = snapshot?.folders.first { $0.id == folder }?.path ?? "个人库"
                        if store.mergeItems(selection, label: "Zotero · " + name) { dismiss() }
                    }.buttonStyle(ActionStyle(primary: true)).disabled(fresh.isEmpty || busy).keyboardShortcut(.defaultAction)
                }
            }
        }.padding(27).frame(width: 630, height: 510).background(Palette.paper).foregroundColor(Palette.ink)
            .task(id: loadID) {
                busy = true; problem = nil
                do {
                    let result = try await ZoteroAPI.snapshot()
                    try Task.checkCancellation()
                    snapshot = result
                } catch {
                    guard !Task.isCancelled else { return }
                    problem = error.localizedDescription
                }
                busy = false
            }
    }
}
