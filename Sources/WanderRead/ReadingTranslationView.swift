import AppKit
import SwiftUI

final class ReadingTranslationSession: ObservableObject {
    enum Tab: Hashable { case passage, pdf }
    enum Status {
        case idle, translating, result(PassageTranslation, saved: Bool), failed(String)
    }
    enum SentenceMark {
        case pdf(PDFSentenceHit, panelOnLeadingEdge: Bool)
        case folded(page: Int, passage: Int, range: NSRange)
        case text(NSRange)
    }

    @Published private(set) var presented = false
    @Published var tab: Tab = .passage
    @Published var configuring = false
    @Published private(set) var pointMode = false
    @Published private(set) var passage: TranslationPassage?
    @Published private(set) var retranslating = false
    @Published private(set) var verifySource = false
    @Published private(set) var status: Status = .idle
    @Published private(set) var language: TranslationLanguage = .chinese
    @Published private var sentenceMark: SentenceMark?
    private var work: Task<Void, Never>?
    private var requestID = UUID()

    var activeSentence: SentenceMark? { presented && tab == .passage ? sentenceMark : nil }
    var pdfSentence: PDFSentenceHit? {
        if case .pdf(let hit, _) = activeSentence { return hit }
        return nil
    }
    var panelOnLeadingEdge: Bool {
        if case .pdf(_, let leading) = activeSentence { return leading }
        return false
    }

    func togglePointMode() {
        pointMode.toggle()
        if !pointMode { clearSentence() }
    }

    func open(_ selectedTab: Tab) {
        tab = selectedTab
        presented = true
    }

    func show(_ source: TranslationPassage, settings: ReadingTranslationSettings, archive: ReadingTranslationArchive,
              sentence: SentenceMark? = nil, retranslate: Bool = false, verify: Bool = false) {
        sentenceMark = sentence
        passage = source
        retranslating = retranslate
        verifySource = verify
        language = settings.target
        configuring = false
        open(.passage)
        if verify || (retranslate && settings.isRemote) { stop() }
        else { translate(settings: settings, archive: archive, refresh: retranslate) }
    }

    func close() {
        presented = false
        clearSentence()
    }

    func clearSentence() {
        guard sentenceMark != nil || retranslating else { return }
        sentenceMark = nil
        retranslating = false
        verifySource = false
        passage = nil
        stop()
        if tab == .passage && !configuring { presented = false }
    }

    func translate(settings: ReadingTranslationSettings, archive: ReadingTranslationArchive, refresh: Bool = false) {
        stop()
        language = settings.target
        guard let passage else { return }
        guard !passage.suspectedEncodingError else {
            status = .failed("所选文字可能含 PDF 错码。请先对照原页校对，或从已校对的摘录翻译。")
            return
        }
        guard !passage.cleaned.isEmpty, passage.cleaned.utf8.count <= 8_000 else {
            status = .failed("请选一小段文字翻译。长文档可使用 PDF 对照。")
            return
        }
        let profile = settings.passageProfile
        if !refresh, let cached = archive.cached(passage, language: settings.target, profile: profile) {
            status = .result(cached, saved: true)
            return
        }
        guard let service = settings.service else { return }
        status = .translating
        let request = requestID
        let revise = retranslating
        work = Task { @MainActor [weak self] in
            do {
                let result = try await service.translate(passage.cleaned, into: settings.target, guidance: settings.rules, revise: revise)
                guard let self, self.requestID == request, !Task.isCancelled else { return }
                var saved = true
                do { try archive.save(result, source: passage, language: settings.target, profile: profile) }
                catch { saved = false }
                self.status = .result(result, saved: saved)
                self.work = nil
            } catch {
                guard let self, self.requestID == request, !Task.isCancelled else { return }
                self.status = .failed(error.localizedDescription)
                self.work = nil
            }
        }
    }

    func stop() {
        requestID = UUID()
        work?.cancel()
        work = nil
        status = .idle
    }

    deinit { work?.cancel() }
}

struct ReadingTranslationButton: View {
    @ObservedObject var session: ReadingTranslationSession
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("翻译", systemImage: "character.bubble")
                .accessibilityIdentifier("ReadingTranslate")
        }
        .buttonStyle(ReadingControlStyle(selected: session.presented))
        .help("翻译所选文字 · ⇧⌘T")
    }
}

struct ReadingPointTranslationButton: View {
    @ObservedObject var session: ReadingTranslationSession

    var body: some View {
        Button(action: session.togglePointMode) { Label("点句", systemImage: "text.cursor") }
            .buttonStyle(ReadingControlStyle(selected: session.pointMode))
            .help(session.pointMode ? "已开启 · 点击原文的一句话" : "开启后点一句原文查看译文")
            .accessibilityLabel("点句翻译")
            .accessibilityValue(session.pointMode ? "已开启" : "已关闭")
            .accessibilityIdentifier("ReadingPointTranslate")
    }
}

struct ReadingTranslationOverlay: ViewModifier {
    let store: ReadingStore
    @ObservedObject var session: ReadingTranslationSession
    var pdfTools: AnyView? = nil
    var inSheet = false

    func body(content: Content) -> some View {
        content.overlay(alignment: session.panelOnLeadingEdge ? .topLeading : .topTrailing) {
            if session.presented {
                ReadingTranslationPanel(store: store, session: session, pdfTools: pdfTools)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line.opacity(0.8))
                    }
                    .shadow(color: .black.opacity(0.17), radius: 15, x: 0, y: 6)
                    .padding(.top, 48).padding(.horizontal, 16)
                    .accessibilityElement(children: .contain).accessibilityLabel("阅读翻译")
            }
        }
        .onChange(of: session.presented) { if !inSheet { store.translationPanelOpen = $0 } }
        .onDisappear { if !inSheet { store.translationPanelOpen = false } }
    }
}

private struct ReadingTranslationPanel: View {
    @ObservedObject var store: ReadingStore
    @ObservedObject var session: ReadingTranslationSession
    let pdfTools: AnyView?
    @State private var showSource = false
    @State private var copied = false
    private var settings: ReadingTranslationSettings { store.library.preferences.translation ?? ReadingTranslationSettings() }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 7) {
                if session.configuring {
                    ReadingIconButton(title: "返回翻译", systemImage: "chevron.left") { session.configuring = false }
                }
                Text(session.configuring ? "翻译设置" : session.retranslating ? "局部重译" :
                        session.activeSentence != nil ? "句子译文" : "翻译")
                    .font(.system(size: 16, weight: .semibold))
                Spacer(minLength: 4)
                if !session.configuring {
                    ReadingIconButton(title: "翻译设置", systemImage: "gearshape") { session.configuring = true }
                }
                ReadingIconButton(title: "收起翻译", systemImage: "xmark", action: session.close)
                    .keyboardShortcut(.cancelAction)
                    .foregroundColor(Palette.muted)
            }
            if session.configuring {
                ScrollView {
                    ReadingTranslationSettingsForm(current: settings, hasPDF: pdfTools != nil) { updated in
                        if store.commit({ $0.preferences.translation = updated }) {
                            session.configuring = false
                            if updated.isRemote || session.verifySource { session.stop() }
                            else if session.tab == .passage && session.passage != nil {
                                session.translate(settings: updated, archive: store.translations, refresh: session.retranslating)
                            }
                        }
                    }
                }.frame(maxHeight: 480)
            } else {
                if pdfTools != nil && session.activeSentence == nil {
                    ReadingTabs(selection: $session.tab, options: [(.passage, "选段"), (.pdf, "PDF 对照")])
                }
                Divider()
                if session.tab == .pdf, let pdfTools { pdfTools }
                else { passage }
            }
        }
        .padding(15).frame(width: 400, alignment: .leading)
        .foregroundColor(Palette.ink).background(Palette.paper)
        .onChange(of: session.passage) { _ in
            showSource = session.verifySource
            copied = false
        }
    }

    @ViewBuilder private var passage: some View {
        if let request = session.passage {
            HStack {
                Text(request.place.isEmpty ? request.title : request.place)
                    .font(.system(size: 11, weight: .medium)).foregroundColor(Palette.muted)
                    .lineLimit(1).help(request.reference)
                Spacer(minLength: 6)
                if !session.verifySource || !isIdle {
                    Button(showSource ? "收起原文" : "看原文") { showSource.toggle() }
                        .buttonStyle(ReadingControlStyle(selected: showSource))
                }
                Menu(session.language.title) {
                    ForEach(TranslationLanguage.allCases) { language in
                        Button(language.title) {
                            var updated = settings
                            updated.target = language
                            if store.commit({ $0.preferences.translation = updated }) {
                                copied = false
                                if session.retranslating && (session.verifySource || updated.isRemote) { session.stop() }
                                else { session.translate(settings: updated, archive: store.translations, refresh: session.retranslating) }
                            }
                        }
                    }
                }.menuStyle(.borderlessButton).fixedSize()
            }
            if showSource || (session.verifySource && isIdle) {
                readingText(request.cleaned, color: Palette.muted, maximum: 105)
            }
            switch session.status {
            case .idle:
                if settings.service == nil {
                    description("连接翻译模型后，可以在这里查看译文。")
                    Button("连接翻译模型…") { session.configuring = true }
                        .buttonStyle(ReadingControlStyle(accented: true))
                } else {
                    if session.verifySource { description("按版面找到这段原文，请确认是你选的段落。") }
                    if session.retranslating && settings.isRemote { description("继续会把这段文字发送到配置的 API。") }
                    Button(session.retranslating ? (session.verifySource ? "确认原文并重译" : "重译这段") :
                            session.activeSentence != nil ? "翻译这一句" : "翻译这一段") {
                        session.translate(settings: settings, archive: store.translations, refresh: session.retranslating)
                    }
                        .buttonStyle(ReadingControlStyle(accented: true))
                }
            case .translating:
                HStack {
                    ProgressView("正在翻译…").controlSize(.small)
                    Spacer()
                    Button("取消") { session.stop() }.buttonStyle(ReadingControlStyle())
                }
            case .failed(let message):
                description(message)
                if !request.suspectedEncodingError {
                    HStack {
                        if settings.service != nil {
                            Button("重试") { session.translate(settings: settings, archive: store.translations, refresh: true) }
                                .buttonStyle(ReadingControlStyle(accented: true))
                        }
                        Button("检查设置") { session.configuring = true }.buttonStyle(ReadingControlStyle())
                    }
                }
            case .result(let result, let saved):
                readingText(result.text, color: Palette.ink, maximum: 236)
                    .accessibilityIdentifier("TranslationResult")
                if result.checkReferences {
                    Label("数字、引文或公式与原文不同，请对照核对。", systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).foregroundColor(Palette.green)
                }
                HStack {
                    Text(saved ? "机器译文 · 已保留" : "机器译文 · 未能保存")
                        .font(.system(size: 11)).foregroundColor(Palette.muted)
                    Spacer()
                    if settings.service != nil {
                        Button("重译") {
                            copied = false
                            session.translate(settings: settings, archive: store.translations, refresh: true)
                        }.buttonStyle(ReadingControlStyle())
                    }
                    ReadingIconButton(title: copied ? "已复制" : "复制译文及出处", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        copied = NSPasteboard.general.setString(
                            "机器译文 · \(request.reference)\n\n\(result.text)", forType: .string)
                    }
                }
            }
        } else {
            description("选中想看的文字，再点「翻译」或按 ⇧⌘T。")
        }
    }

    private var isIdle: Bool {
        if case .idle = session.status { return true }
        return false
    }

    private func readingText(_ text: String, color: Color, maximum: CGFloat) -> some View {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .paragraphStyle: paragraph]
        let size = (text as NSString).boundingRect(with: CGSize(width: 342, height: 10_000),
                                                   options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
        return ScrollView {
            Text(text).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled).foregroundColor(color)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
        .frame(height: min(maximum, max(40, ceil(size.height) + 24)))
            .background(Palette.side, in: RoundedRectangle(cornerRadius: 7))
    }

    private func description(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundColor(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ReadingTranslationSettingsForm: View {
    @State private var draft: ReadingTranslationSettings
    @State private var models: [String] = []
    @State private var checking = false
    @State private var feedback: String?
    @State private var probe: Task<Void, Never>?
    @State private var advanced: Bool
    @State private var custom = false
    @State private var key = ""
    private let save: (ReadingTranslationSettings) -> Void

    init(current: ReadingTranslationSettings, hasPDF: Bool, save: @escaping (ReadingTranslationSettings) -> Void) {
        _draft = State(initialValue: current)
        _advanced = State(initialValue: hasPDF && current.pdfTool != nil)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ReadingTabs(selection: Binding(get: { draft.isRemote }, set: { draft.useRemote = $0 }),
                        options: [(false, "本地模型"), (true, "远程 API")])
            Text(connectionHint).font(.system(size: 12)).foregroundColor(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 5) {
                label(draft.isRemote ? "API 基础地址" : "本地服务地址")
                HStack {
                    TextField(draft.isRemote ? "https://api.openai.com/v1" : "http://127.0.0.1:8080/v1", text: address)
                        .accessibilityIdentifier("TranslationServiceAddress")
                        .accessibilityLabel(draft.isRemote ? "API 基础地址" : "本地服务地址")
                    Button(checking ? "正在检测…" : "检测", action: detect)
                        .buttonStyle(ReadingControlStyle()).disabled(checking)
                }
            }
            if draft.isRemote {
                HStack {
                    SecureField("API 密钥（留空沿用已存密钥）", text: $key)
                        .accessibilityLabel("API 密钥")
                    Menu {
                        Button("移除当前地址的密钥", role: .destructive, action: removeKey)
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden)
                        .frame(width: 27).accessibilityLabel("管理 API 密钥")
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                label("翻译模型")
                if !models.isEmpty {
                    Picker("翻译模型", selection: model) {
                        Text("选一个模型").tag("")
                        if !draft.selectedModel.isEmpty && !models.contains(draft.selectedModel) {
                            Text(draft.selectedModel).tag(draft.selectedModel)
                        }
                        ForEach(models, id: \.self) { model in Text(model).tag(model) }
                    }.labelsHidden()
                    Button("改为手动输入模型", action: { models = [] }).buttonStyle(ReadingControlStyle())
                } else {
                    TextField("填写模型名称", text: model)
                        .accessibilityLabel("翻译模型").accessibilityIdentifier("TranslationModelName")
                }
            }
            Picker("默认译文语言", selection: $draft.target) {
                ForEach(TranslationLanguage.allCases) { Text($0.title).tag($0) }
            }
            Picker("专业领域", selection: rule(\.field)) {
                ForEach(TranslationField.allCases) { Text($0.title).tag($0) }
            }
            DisclosureGroup("提示词与术语表", isExpanded: $custom) {
                VStack(alignment: .leading, spacing: 5) {
                    label("补充提示词")
                    TextField("例如：保留关键概念的英文原词", text: rule(\.prompt), axis: .vertical)
                        .lineLimit(2...5).accessibilityLabel("补充提示词")
                    label("术语表")
                    TextField("retrieval practice = 提取练习", text: rule(\.terminology), axis: .vertical)
                        .lineLimit(2...6).accessibilityLabel("术语表")
                    Text("每行填一对「原词 = 译法」。适用于选段和新生成的 PDF 译文。")
                        .font(.system(size: 11)).foregroundColor(Palette.muted)
                }.padding(.top, 5)
            }.font(.system(size: 12))
            DisclosureGroup("保留版式的 PDF 翻译", isExpanded: $advanced) {
                Picker("PDF 原文语言", selection: $draft.pdfSource) {
                    ForEach(TranslationLanguage.allCases) { Text($0.title).tag($0) }
                }.padding(.top, 5)
                HStack {
                    Text(PDFTranslationTool.executable(draft.pdfTool) == nil ? "未找到 PDFMathTranslate-next" : "已选好 PDFMathTranslate-next")
                        .font(.system(size: 12)).foregroundColor(Palette.muted)
                    Spacer()
                    Button("选择程序…", action: chooseTool).buttonStyle(ReadingControlStyle())
                }.padding(.top, 5)
                if let path = draft.pdfTool {
                    Text(path).font(.system(size: 10, design: .monospaced)).foregroundColor(Palette.muted)
                        .lineLimit(1).truncationMode(.middle)
                }
            }.font(.system(size: 12))
            Group {
                if let feedback {
                    Text(feedback).font(.system(size: 12)).foregroundColor(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("保存设置", action: commit).buttonStyle(ReadingControlStyle(accented: true))
                        .accessibilityIdentifier("TranslationSaveSettings")
                }
            }
        }.textFieldStyle(.roundedBorder)
            .onChange(of: address.wrappedValue) { _ in resetProbe(); key = "" }
            .onChange(of: draft.isRemote) { _ in resetProbe(); key = "" }
            .onDisappear { probe?.cancel() }
    }

    private var address: Binding<String> {
        Binding(get: { draft.isRemote ? draft.remoteURL ?? "" : draft.serviceURL }, set: {
            if draft.isRemote { draft.remoteURL = $0 } else { draft.serviceURL = $0 }
        })
    }

    private var model: Binding<String> {
        Binding(get: { draft.selectedModel }, set: {
            if draft.isRemote { draft.remoteModel = $0 } else { draft.model = $0 }
        })
    }

    private func rule<T>(_ field: WritableKeyPath<TranslationGuidance, T>) -> Binding<T> {
        Binding(get: { draft.rules[keyPath: field] }, set: { value in
            var guidance = draft.rules
            guidance[keyPath: field] = value
            draft.guidance = guidance
        })
    }

    private var connectionHint: String {
        if draft.isRemote { return "兼容 OpenAI 的 HTTPS API。调用会发送待处理文字，密钥保存在 macOS 钥匙串。" }
        return draft.hasLocalTrial ? "检测或翻译时按需启动本机试译服务。" : "连接 Mac 上的 OpenAI 兼容服务。"
    }

    private func resetProbe() {
        models = []
        probe?.cancel()
        checking = false
        feedback = nil
    }

    private func label(_ value: String) -> some View {
        Text(value).font(.system(size: 12, weight: .medium))
    }

    private func detect() {
        do {
            let supplied = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let service = try draft.connection(key: supplied.isEmpty ? nil : supplied)
            checking = true
            feedback = nil
            probe = Task { @MainActor in
                defer { if !Task.isCancelled { checking = false } }
                do {
                    let names = try await service.models()
                    guard !Task.isCancelled else { return }
                    models = names
                    if names.count == 1 { model.wrappedValue = names[0] }
                    feedback = names.isEmpty ? "服务已连接。可以手动填入模型名称。" : "服务已连接。"
                } catch {
                    if !Task.isCancelled { feedback = error.localizedDescription }
                }
            }
        } catch { feedback = error.localizedDescription }
    }

    private func commit() {
        do {
            _ = try draft.rules.terms()
            var updated = draft
            let name = draft.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if draft.isRemote || !address.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !name.isEmpty {
                let url = try ReadingModelService.address(address.wrappedValue, remote: draft.isRemote)
                guard !name.isEmpty, name.utf8.count <= 1_000, !name.contains(where: \.isNewline) else {
                    throw InputError.invalid("请选择或填写模型名称。")
                }
                if draft.isRemote {
                    let supplied = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !supplied.isEmpty { try ReadingModelCredentials.save(supplied, for: url) }
                    else { _ = try draft.connection().requestKey() }
                    updated.remoteURL = url.absoluteString
                    updated.remoteModel = name
                } else {
                    updated.serviceURL = url.absoluteString
                    updated.model = name
                }
            } else {
                updated.serviceURL = ""
                updated.model = ""
            }
            save(updated)
        } catch { feedback = error.localizedDescription }
    }

    private func removeKey() {
        do {
            try ReadingModelCredentials.remove(for: ReadingModelService.address(address.wrappedValue, remote: true))
            key = ""
            resetProbe()
            feedback = "已移除密钥。"
        } catch { feedback = error.localizedDescription }
    }

    private func chooseTool() {
        let panel = NSOpenPanel()
        panel.title = "选择 PDFMathTranslate-next"
        panel.message = "选择已安装的 pdf2zh_next 可执行文件。"
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            if PDFTranslationTool.executable(url.path) == nil { feedback = "请选择可运行的 pdf2zh_next 文件。" }
            else { draft.pdfTool = url.path; feedback = nil }
        }
    }
}
