import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var store: ReadingStore!
    var pendingURLs: [URL] = []
    var researchTimer:Timer?
    var glance: GlanceController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let preview = args.contains("--preview")
        var directory: URL?
        if let index = args.firstIndex(of:"--data-dir"), args.count > index+1 { directory=URL(fileURLWithPath:args[index+1]) }
        if preview && directory == nil { directory=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("WanderRead-preview-\(UUID().uuidString)") }
        store = ReadingStore(directory:directory,preview:preview)
        let compact = args.contains("--compact")
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:compact ? 1020 : 1220,height:compact ? 780 : 880),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = "漫读"; window.titlebarAppearsTransparent = true; window.backgroundColor = NSColor(Palette.paper); window.appearance=NSAppearance(named:Palette.theme.isDark ? .darkAqua:.aqua)
        window.contentView = NSHostingView(rootView:MainView(store:store)); window.minSize=NSSize(width:1020,height:780)
        window.center(); if !preview { window.setFrameAutosaveName("MainWindow") }; window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps:true); ThemeAppIcon.apply(Palette.theme); setupMenus()
        if !preview { glance = GlanceController(store: store) { [weak self] in self?.showMain() } }
        if !preview {researchTimer=Timer.scheduledTimer(withTimeInterval:2,repeats:true) {[weak self] _ in self?.store.pollResearchLink()}}
        if !pendingURLs.isEmpty { let pending=pendingURLs; pendingURLs=[]; application(NSApp,open:pending) }
        if let index=args.firstIndex(of:"--snapshot"), args.count > index+1 {
            let root=URL(fileURLWithPath:args[index+1]); try? FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            capturePages(root:root,index:0)
        }
    }
    func capturePages(root: URL, index: Int) {
        let fixture=CommandLine.arguments.contains("--preview")
        let pages=fixture ? ["发现","策略","回顾","里程","收藏","偏好","策略编辑","逐篇指标","分享工作台","阅读中","收尾","空库","批量对齐","数据管理","海盐","陶土","暮紫","深夜","名片编辑","主题词云","修复入口"] : ["发现","策略","回顾","里程","收藏","偏好"]
        guard index < pages.count else {
            if fixture {Task {@MainActor in self.exportPosters(root:root); NSApp.terminate(nil)}} else {NSApp.terminate(nil)}
            return
        }
        if index < 6 { store.page=pages[index] }
        if index >= 6 {window.minSize=NSSize(width:400,height:400)}
        if index == 6 {window.contentView=NSHostingView(rootView:StrategyEditor(store:store)); window.setContentSize(NSSize(width:730,height:660))}
        if index == 7 {window.contentView=NSHostingView(rootView:MetricEditor(store:store,item:store.library.items[0])); window.setContentSize(NSSize(width:620,height:650))}
        if index == 8 {window.contentView=NSHostingView(rootView:ShareStudio(store:store)); window.setContentSize(NSSize(width:920,height:700))}
        if index == 9 {
            store.commit {$0.items[0].target="/tmp/漫读界面示例.pdf";$0.items[0].researchNoteURL="obsidian://pfr-excerpt?vault=Preview&file=paper.md&id=11111111-2222-3333-4444-555555555555"}
            let item=store.library.items[0]
            store.commit { $0.sessions.append(ReadingSession(itemID:item.id,title:item.title,startedAt:Date(),seconds:186,runningSince:nil)) }
            store.page="发现";window.contentView=NSHostingView(rootView:MainView(store:store));window.setContentSize(NSSize(width:CommandLine.arguments.contains("--compact") ? 1020:1220,height:CommandLine.arguments.contains("--compact") ? 780:880))
        }
        if index == 10 {
            window.contentView=NSHostingView(rootView:FinishView(store:store)); window.setContentSize(NSSize(width:560,height:780))
        }
        if index == 11 {
            let empty=ReadingStore(directory:URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("WanderRead-empty-\(UUID().uuidString)"))
            window.contentView=NSHostingView(rootView:MainView(store:empty)); window.setContentSize(NSSize(width:CommandLine.arguments.contains("--compact") ? 1020 : 1220,height:CommandLine.arguments.contains("--compact") ? 780 : 880))
        }
        if index == 12 {
            store.commit {$0.items[0].metricValues=nil;$0.items[1].metricValues=nil}
            store.setScope(tag:"",question:"阅读 好奇 方向")
            window.contentView=NSHostingView(rootView:AlignmentView(store:store));window.setContentSize(NSSize(width:660,height:560))
        }
        if index == 13 {
            store.mergeItems([ReadingItem(title:"误收录的示例入口",target:"https://example.com/import-preview")],label:"Obsidian · 示例库")
            window.contentView=NSHostingView(rootView:DataManager(store:store));window.setContentSize(NSSize(width:820,height:640))
        }
        if index >= 14 && index < 18 {
            let themes:[AppTheme]=[.tide,.clay,.lilac,.night]
            store.selectTheme(themes[index-14]);store.page="发现"
            window.contentView=NSHostingView(rootView:MainView(store:store));window.setContentSize(NSSize(width:1020,height:780))
        }
        if index == 18 {
            store.selectTheme(.paper)
            var profile=ShareProfile();profile.nickname="漫读的人";profile.bio="沿着问题散步，让好奇留下形状。";profile.visible=true
            let icon=ThemeAppIcon.image(.clay)
            if let tiff=icon.tiffRepresentation,let rep=NSBitmapImageRep(data:tiff) {profile.avatar=rep.representation(using:.png,properties:[:])}
            _=store.saveProfile(profile)
            window.contentView=NSHostingView(rootView:ProfileEditor(store:store));window.setContentSize(NSSize(width:580,height:520))
        }
        if index == 19 {
            window.contentView=NSHostingView(rootView:ShareStudio(store:store,initialTemplate:.cloud));window.setContentSize(NSSize(width:920,height:700))
        }
        if index == 20 {
            window.contentView=NSHostingView(rootView:LinkRepairView(store:store));window.setContentSize(NSSize(width:720,height:540))
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.8) {
            guard let view=self.window.contentView else { return }
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            if let rep=view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                view.cacheDisplay(in:view.bounds,to:rep)
                if let data=rep.representation(using:.png,properties:[:]) { try? data.write(to:root.appendingPathComponent("\(index)-\(pages[index]).png")) }
            }
            self.capturePages(root:root,index:index+1)
        }
    }
    @MainActor func exportPosters(root:URL) {
        let folder=root.appendingPathComponent("分享图")
        do {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            for template in PosterTemplate.allCases {for layout in PosterLayout.allCases {
                let theme:PosterTheme=template == .calendar ? .forest : template == .topics ? .night:.clay
                let poster=PosterView(library:store.library,period:.quarter,theme:theme,layout:layout,template:template,showTopics:true,isPreview:true)
                try ShareExporter.png(poster).write(to:folder.appendingPathComponent("\(template.rawValue)-\(layout.rawValue).png"),options:.atomic)
            }}
            let identity=PosterView(library:store.library,template:.cloud,profile:store.library.preferences.shareProfile,showTopics:true,isPreview:true)
            try ShareExporter.png(identity).write(to:folder.appendingPathComponent("profile-cloud.png"),options:.atomic)
            for theme in AppTheme.allCases {if let tiff=ThemeAppIcon.image(theme).tiffRepresentation,let rep=NSBitmapImageRep(data:tiff),let data=rep.representation(using:.png,properties:[:]) {try data.write(to:root.appendingPathComponent("icon-\(theme.rawValue).png"))}}
            let privatePoster=PosterView(library:store.library,theme:.dawn,template:.topics,displayName:"",showTopics:false,isPreview:true)
            try ShareExporter.png(privatePoster).write(to:folder.appendingPathComponent("hidden-topics.png"),options:.atomic)
            let board=NSPasteboard.withUniqueName()
            try ShareExporter.copy(privatePoster,to:board)
            guard let copied=board.data(forType:.png),copied == (try ShareExporter.png(privatePoster)) else {throw InputError.invalid("剪贴板图片回读不一致")}
            board.releaseGlobally()
            print("14 张 PNG 已导出；隔离剪贴板 PNG 写入与回读一致。")
        } catch {fputs("分享图导出失败：\(error)\n",stderr)}
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard store != nil else { pendingURLs.append(contentsOf:urls); return }
        for url in urls {
            if url.scheme == "wanderread" {
                do {
                    if url.host == "read" {
                        store.revealReaderNote(try ReaderNoteLink(url))
                    } else {
                        let capture = try CaptureLink.parse(url)
                        _ = store.add(title: capture.title, target: capture.target, note: "", tags: "", minutes: 15, difficulty: 2, interest: 3)
                    }
                }
                catch { store.error=error.localizedDescription }
            }
            else if url.isFileURL { store?.importFiles([url]) }
        }
        showMain()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMain() }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        let preferences = store?.library.preferences.glance ?? GlancePreferences()
        return !preferences.menuBar && !preferences.island
    }
    private func showMain() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard saveReader() else { return false }
        store?.pauseOnQuit()
        return true
    }
    private func saveReader() -> Bool {
        if let reader = store?.textReader { return reader.saveDraft() && reader.persist() }
        if let reader = store?.pdfReader { return reader.saveDraft() && reader.flushPosition(force: true) }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        saveReader() ? .terminateNow : .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) { store?.pauseOnQuit() }
    func setupMenus() {
        let bar=NSMenu(); let appRoot=NSMenuItem(); bar.addItem(appRoot); let app=NSMenu(); appRoot.submenu=app
        app.addItem(withTitle:"关于漫读",action:#selector(about),keyEquivalent:"").target=self
        app.addItem(.separator()); app.addItem(withTitle:"退出漫读",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let fileRoot=NSMenuItem(); fileRoot.title="文件"; bar.addItem(fileRoot); let file=NSMenu(title:"文件"); fileRoot.submenu=file
        file.addItem(withTitle:"收下一篇…",action:#selector(add),keyEquivalent:"n").target=self
        file.addItem(withTitle:"换一批",action:#selector(refresh),keyEquivalent:"r").target=self
        file.addItem(.separator()); file.addItem(withTitle:"关闭窗口",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w")
        let editRoot=NSMenuItem(); editRoot.title="编辑"; bar.addItem(editRoot); let edit=NSMenu(title:"编辑"); editRoot.submenu=edit
        edit.addItem(withTitle:"撤销",action:Selector(("undo:")),keyEquivalent:"z")
        edit.addItem(.separator())
        edit.addItem(withTitle:"剪切",action:#selector(NSText.cut(_:)),keyEquivalent:"x")
        edit.addItem(withTitle:"复制",action:#selector(NSText.copy(_:)),keyEquivalent:"c")
        edit.addItem(withTitle:"粘贴",action:#selector(NSText.paste(_:)),keyEquivalent:"v")
        edit.addItem(withTitle:"全选",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a")
        let viewRoot = NSMenuItem()
        viewRoot.title = "显示"
        bar.addItem(viewRoot)
        let viewMenu = NSMenu(title: "显示")
        viewRoot.submenu = viewMenu
        let focusItem = viewMenu.addItem(withTitle: "切换专注阅读", action: #selector(toggleReadingFocus), keyEquivalent: "f")
        focusItem.keyEquivalentModifierMask = [.command, .shift]
        focusItem.target = self
        let islandItem = viewMenu.addItem(withTitle: "打开阅读岛", action: #selector(showGlance), keyEquivalent: "i")
        islandItem.keyEquivalentModifierMask = [.command, .shift]
        islandItem.target = self
        NSApp.mainMenu=bar
    }
    @objc func showGlance() { glance?.show() }
    @objc func toggleReadingFocus() { store?.toggleReadingFocus() }
    @objc func add() { NotificationCenter.default.post(name:Notification.Name("WanderAdd"),object:nil) }
    @objc func refresh() { NotificationCenter.default.post(name:Notification.Name("WanderRefresh"),object:nil) }
    @objc func about() { NSApp.orderFrontStandardAboutPanel(options:[.applicationName:"漫读",.applicationVersion:"0.9.0",.credits:NSAttributedString(string:"让好奇带路。\n指标与优先级设计参考 ebAobS 的漫游式渐进阅读。")]) }
}

@main struct WanderReadApp {
    static func main() {
        if CommandLine.arguments.contains("--repair-links-only") {
            let store=ReadingStore(refreshOnLoad:false)
            print("Repaired entries: \(store.library.linkRepairUndo?.count ?? 0); migration: \(store.library.registeredLinkMigration ?? 0)")
            if let error=store.error {fputs(error+"\n",stderr);exit(1)}
            return
        }
        let app=NSApplication.shared; app.setActivationPolicy(.regular)
        let delegate=AppDelegate(); app.delegate=delegate; withExtendedLifetime(delegate) { app.run() }
    }
}
