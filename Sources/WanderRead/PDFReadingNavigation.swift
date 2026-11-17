import SwiftUI
import PDFKit

struct PDFReadingNavigation: View {
    @ObservedObject var reader: PDFReader
    let onSection: (PDFReadingSection) -> Void
    let onPage: (Int) -> Void
    let onBookmark: (PDFPlaceBookmark) -> Void
    let onEdit: (Bool) -> Void
    let onToggleBookmark: () -> Void

    @State private var showingBookmarks = false
    @State private var query = ""
    @State private var editingBookmark: PDFPlaceBookmark?
    @State private var bookmarkTitle = ""
    @State private var collapsedBranches: Set<Int>?

    private var sections: [PDFReadingSection] { reader.navigationSections }
    private var current: Int? { reader.currentSectionID(in: sections) }
    private var searchText: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var page: Int? {
        guard let number = Int(searchText.precomposedStringWithCompatibilityMapping),
              (1...reader.document.pageCount).contains(number) else { return nil }
        return number - 1
    }
    private var matches: [PDFReadingSection] {
        guard !searchText.isEmpty else { return PDFOutlineHierarchy.visibleSections(sections, collapsed: collapsed) }
        return sections.filter { $0.title.localizedStandardContains(searchText) || $0.location.page == page }
    }
    private var branches: Set<Int> {
        Set(zip(sections, sections.dropFirst()).compactMap { $0.depth < $1.depth ? $0.id : nil })
    }
    private var collapsed: Set<Int> {
        collapsedBranches ?? branches.subtracting(PDFOutlineHierarchy.ancestors(of: current, in: sections))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ReadingTabs(selection: $showingBookmarks, options: [(false, "目录"), (true, "书签")])
                Spacer()
            }.padding(.horizontal, 11).padding(.vertical, 8)
            Divider()
            if showingBookmarks { bookmarkList }
            else { directory }
        }
        .frame(width: 372, height: 434)
        .background(Palette.paper).foregroundColor(Palette.ink)
        .alert("重命名书签", isPresented: Binding(get: { editingBookmark != nil }, set: {
            if !$0 { editingBookmark = nil }
        })) {
            TextField("书签名称", text: $bookmarkTitle)
            Button("取消", role: .cancel) {}
            Button("保存") {
                if let editingBookmark { reader.renameBookmark(editingBookmark.id, title: bookmarkTitle) }
            }.disabled(bookmarkTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var directory: some View {
        let current = self.current
        let branches = self.branches
        let collapsed = self.collapsed
        return VStack(alignment: .leading, spacing: 0) {
            ReadingSearchField(prompt: "搜章节，或输入 PDF 页码", query: $query, focusOnAppear: true,
                               identifier: "PDFNavigationSearch") {
                if let page { onPage(page) }
                else if !searchText.isEmpty, let first = matches.first { onSection(first) }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if let page {
                            Button { onPage(page) } label: {
                                Label("跳到 PDF 第 \(page + 1) 页", systemImage: "arrow.turn.down.right")
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            }.buttonStyle(.plain).foregroundColor(Palette.green)
                        }
                        ForEach(matches) { section in
                            HStack(spacing: 1) {
                                if searchText.isEmpty, branches.contains(section.id) {
                                    let closed = collapsed.contains(section.id)
                                    let action = closed ? "展开下级章节" : "折叠下级章节"
                                    Button {
                                        var updated = collapsed
                                        if closed { updated.remove(section.id) } else { updated.insert(section.id) }
                                        collapsedBranches = updated
                                    } label: {
                                        Image(systemName: closed ? "chevron.right" : "chevron.down")
                                            .font(.system(size: 9, weight: .semibold))
                                            .frame(width: 20, height: 27).contentShape(Rectangle())
                                    }.buttonStyle(.plain).foregroundColor(Palette.muted)
                                        .help(action).accessibilityLabel("\(action) \(section.title)")
                                } else {
                                    Color.clear.frame(width: 20).accessibilityHidden(true)
                                }
                                Button { onSection(section) } label: { sectionRow(section, selected: current == section.id) }
                                    .buttonStyle(ReadingControlStyle(selected: current == section.id, horizontalPadding: 0))
                            }
                            .padding(.leading, CGFloat(min(7, max(0, section.depth))) * 8)
                            .id(section.id)
                        }
                        if matches.isEmpty && page == nil { directoryStatus }
                    }.padding(.horizontal, 10).padding(.bottom, 8)
                }
                .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
                .onChange(of: reader.detectedOutline?.count) { _ in
                    collapsedBranches = nil
                    if searchText.isEmpty, let current { proxy.scrollTo(current, anchor: .center) }
                }
            }
            Divider()
            HStack(spacing: 8) {
                if !sections.isEmpty {
                    Text(reader.hasAuthorOutline && reader.savedOutline.isEmpty ? "PDF 自带 · \(sections.count) 项" :
                        (reader.savedOutline.isEmpty ? "本机识别" : "我的目录") + " · \(sections.count) 项")
                        .foregroundColor(Palette.muted)
                }
                Spacer(minLength: 0)
                if reader.pendingOutlineCount > 0 {
                    Button("核对 \(reader.pendingOutlineCount) 项") { onEdit(true) }
                }
                Button(sections.isEmpty ? "生成目录…" : "编辑目录…") { onEdit(false) }
            }
            .buttonStyle(ReadingControlStyle()).font(.system(size: 11))
            .padding(.horizontal, 13).padding(.vertical, 6)
        }
    }

    @ViewBuilder private var directoryStatus: some View {
        if reader.findingOutline {
            ProgressView("正在本机识别目录…").controlSize(.small).padding(9)
        } else {
            Text(!searchText.isEmpty ? "没有找到匹配章节" : reader.outlineFileChanged ?
                 "文件已更新，重新打开后可识别目录。" : "暂未找到可用的目录。可以跳到指定页。")
                .foregroundColor(Palette.muted).padding(9)
        }
    }

    private func sectionRow(_ section: PDFReadingSection, selected: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .semibold)).opacity(selected ? 1 : 0)
                .accessibilityHidden(true)
            Text(section.title).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(section.location.page + 1) 页").font(.system(size: 11))
                .foregroundColor(Palette.muted).monospacedDigit()
        }
        .font(.system(size: 13, weight: selected ? .semibold : .regular))
        .padding(.horizontal, 8).padding(.vertical, 7)
        .contentShape(Rectangle()).help(section.title)
    }

    private var bookmarkList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if reader.bookmarks.isEmpty {
                        Text("读到想回来的地方，按 ⌘B 留个书签。")
                            .font(.system(size: 13)).foregroundColor(Palette.muted).padding(9)
                    }
                    ForEach(reader.bookmarks.reversed()) { bookmark in
                        let usable = bookmark.revision == reader.revision
                            && (0..<reader.document.pageCount).contains(bookmark.location.page)
                        HStack(spacing: 8) {
                            Button { onBookmark(bookmark) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(bookmark.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                                    Text((usable ? "" : "旧版 · ") + "PDF 第 \(bookmark.location.page + 1) 页")
                                        .font(.system(size: 11)).foregroundColor(Palette.muted)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8).contentShape(Rectangle())
                            }.buttonStyle(ReadingControlStyle(horizontalPadding: 0)).disabled(!usable)
                            Menu {
                                Button("重命名…") { bookmarkTitle = bookmark.title; editingBookmark = bookmark }
                                Button("移除书签", role: .destructive) { reader.removeBookmark(bookmark.id) }
                            } label: { Image(systemName: "ellipsis") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 30)
                            .accessibilityLabel("管理书签")
                        }
                    }
                }.padding(10)
            }
            Divider()
            Button(action: onToggleBookmark) {
                Label(reader.bookmarkHere == nil ? "标记此处" : "移除此处书签",
                      systemImage: reader.bookmarkHere == nil ? "bookmark" : "bookmark.fill")
            }.buttonStyle(ReadingControlStyle()).padding(9)
        }
    }
}
