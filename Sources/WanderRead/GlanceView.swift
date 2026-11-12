import SwiftUI
import AppKit
import Combine

struct GlanceSettings: View {
    @ObservedObject var store: ReadingStore
    var inPopover = false
    private var settings: GlancePreferences { store.library.preferences.glance ?? GlancePreferences() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !inPopover {
                Text("阅读岛").font(.system(size: 19, weight: .medium, design: .serif))
                Text("抬眼看一眼今天，顺手暂停、续读或换一批。").font(.system(size: 13)).foregroundColor(Palette.muted)
            }
            VStack(alignment: .leading, spacing: 10) {
                Toggle("菜单栏入口", isOn: binding(\.menuBar))
                Toggle("屏幕顶端胶囊", isOn: binding(\.island))
            }
            if !inPopover {
                Text("有刘海时，入口贴在刘海下方。外接屏上贴在屏幕顶部中央。")
                    .font(.system(size: 11)).foregroundColor(Palette.muted)
            }
            Divider()
            HStack {
                Toggle("正在读", isOn: binding(\.activity))
                Toggle("一览数据", isOn: binding(\.counts))
                Toggle("快捷操作", isOn: binding(\.actions))
            }.toggleStyle(.checkbox)
            Picker("配色", selection: binding(\.ink)) {
                Text("深墨").tag(true)
                Text("跟随主题").tag(false)
            }.pickerStyle(.segmented)
        }.tint(Palette.accent)
    }

    private func binding(_ key: WritableKeyPath<GlancePreferences, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: key] }, set: { value in
            var updated = settings
            updated[keyPath: key] = value
            store.updatePreferences { $0.glance = updated }
        })
    }
}

struct GlanceBoard: View {
    @ObservedObject var store: ReadingStore
    let showMain: () -> Void
    let close: () -> Void
    @State private var settingsOpen = false
    private var preferences: GlancePreferences { store.library.preferences.glance ?? GlancePreferences() }
    private var ink: Color { preferences.ink ? Color(red: 0.93, green: 0.95, blue: 0.93) : Palette.ink }
    private var muted: Color { preferences.ink ? Color(red: 0.69, green: 0.75, blue: 0.74) : Palette.muted }
    private var accent: Color { preferences.ink ? Color(red: 0.72, green: 0.87, blue: 0.76) : Palette.green }
    private var background: Color { preferences.ink ? Color(red: 0.072, green: 0.105, blue: 0.106) : Palette.paper }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 9) {
                Image(systemName: "book.closed").font(.system(size: 16, weight: .medium))
                    .foregroundColor(accent).frame(width: 22, height: 28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("阅读岛").font(.system(size: 15, weight: .semibold))
                    Text(settingsOpen ? "显示设置" : "今日一览").font(.system(size: 11)).foregroundColor(muted)
                }
                Spacer()
                ReadingIconButton(title: settingsOpen ? "返回一览" : "自定义阅读岛",
                                  systemImage: settingsOpen ? "xmark" : "gearshape") {
                    settingsOpen.toggle()
                }
                .foregroundColor(muted)
                .accessibilityIdentifier("GlanceSettings")
            }
            Divider()
            if settingsOpen {
                GlanceSettings(store: store, inPopover: true)
                    .foregroundColor(ink)
            } else {
                TimelineView(.periodic(from: Date(), by: 30)) { context in
                    VStack(alignment: .leading, spacing: 11) {
                        if preferences.activity { activity(context.date) }
                        if preferences.counts {
                            let counts = GlanceCounts(store.library, now: context.date)
                            HStack(spacing: 0) {
                                metric(counts.choices.formatted(), "今日选择")
                                metric(GlanceCounts.duration(counts.seconds), "今日停留").help("汇总今天开启的阅读会话")
                                metric(counts.pending.formatted(), "待读")
                            }.padding(.vertical, 4)
                        }
                    }
                }
                if preferences.actions {
                    quickActions
                }
            }
            Divider()
            Button {
                close(); showMain()
            } label: {
                HStack { Text("打开漫读"); Spacer(); Image(systemName: "arrow.up.right") }
                    .font(.system(size: 12)).frame(minHeight: 24).contentShape(Rectangle())
            }.buttonStyle(.borderless).foregroundColor(ink)
        }.padding(16).frame(width: 324, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundColor(ink).background(background.opacity(preferences.ink || Palette.theme.isDark ? 0.96 : 0.72))
            .environment(\.colorScheme, preferences.ink || Palette.theme.isDark ? .dark : .light)
    }

    private func activity(_ now: Date) -> some View {
        HStack(spacing: 10) {
            Circle().fill(store.activeSession?.runningSince == nil ? muted : accent).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 3) {
                if let session = store.activeSession {
                    Text(session.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text((session.runningSince == nil ? "已暂停" : "正在读") + " · " + GlanceCounts.duration(session.elapsed(at: now)))
                        .font(.system(size: 11)).foregroundColor(muted)
                } else {
                    Text("留给下一篇").font(.system(size: 13, weight: .medium))
                    Text("此刻没有进行中的阅读").font(.system(size: 11)).foregroundColor(muted)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.system(size: 18, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7).monospacedDigit()
            Text(label).font(.system(size: 11)).foregroundColor(muted)
        }.frame(maxWidth: .infinity)
    }

    private var quickActions: some View {
        HStack(spacing: 14) {
            if let session = store.activeSession {
                action(session.runningSince == nil ? "继续计时" : "暂停", icon: session.runningSince == nil ? "play.fill" : "pause.fill") {
                    store.pauseResume()
                }
            } else {
                action("换一批", icon: "shuffle") {
                    store.page = "发现"; store.refresh()
                }.disabled(store.readerOpening != nil || store.recommendations.isEmpty)
            }
            action("专注阅读", icon: "viewfinder") {
                close(); showMain()
                if store.pdfReader?.isFocused != true && store.textReader?.isFocused != true { store.toggleReadingFocus() }
            }.disabled(store.readerOpening != nil || (store.activeItem ?? store.recommendations.first?.item)?.canReadInside != true)
            Spacer(minLength: 0)
        }
    }

    private func action(_ title: String, icon: String, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .medium))
                .frame(minHeight: 24).contentShape(Rectangle())
        }.buttonStyle(.borderless).tint(ink)
    }
}

final class GlanceController: NSObject, NSPopoverDelegate {
    private let store: ReadingStore
    private let showMain: () -> Void
    private var status: NSStatusItem?
    private let popover = NSPopover()
    private weak var popoverAnchor: NSView?
    private var island: NSPanel?
    private var capsule: NSButton?
    private var observation: AnyCancellable?
    private var pointerOpened = false

    init(store: ReadingStore, showMain: @escaping () -> Void) {
        self.store = store
        self.showMain = showMain
        super.init()
        popover.delegate = self
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        observation = store.$library.map { $0.preferences.glance ?? GlancePreferences() }.removeDuplicates()
            .sink { [weak self] preferences in self?.configure(preferences) }
        NotificationCenter.default.addObserver(self, selector: #selector(positionIsland), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func configure(_ preferences: GlancePreferences) {
        if preferences.menuBar {
            if status == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                item.button?.image = NSImage(systemSymbolName: "book.closed", accessibilityDescription: "漫读阅读岛")
                item.button?.toolTip = "漫读阅读岛"
                item.button?.target = self
                item.button?.action = #selector(statusClicked)
                status = item
            }
        } else if let status {
            if popoverAnchor === status.button { popover.performClose(nil) }
            NSStatusBar.system.removeStatusItem(status)
            self.status = nil
        }
        if preferences.island {
            if island == nil { createIsland() }
            positionIsland()
        } else if let island {
            if popoverAnchor === capsule { popover.performClose(nil) }
            island.orderOut(nil)
            self.island = nil; capsule = nil
        }
    }

    private func createIsland() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 91, height: 24), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.hidesOnDeactivate = false; panel.isMovable = false; panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let button = NSButton(title: "阅读岛", target: self, action: #selector(islandClicked))
        button.isBordered = false; button.wantsLayer = true
        button.layer?.backgroundColor = NSColor(srgbRed: 0.08, green: 0.11, blue: 0.11, alpha: 0.97).cgColor
        button.layer?.cornerRadius = 12
        button.layer?.borderWidth = 1; button.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        button.attributedTitle = NSAttributedString(string: "阅读岛  ⌄", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white
        ])
        button.toolTip = "打开漫读的阅读岛"
        button.setAccessibilityLabel("打开阅读岛")
        panel.contentView = button
        island = panel; capsule = button
    }

    @objc private func positionIsland() {
        guard let island, let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let left = screen.auxiliaryTopLeftArea?.maxX
        let right = screen.auxiliaryTopRightArea?.minX
        let center = (left != nil && right != nil) ? ((left ?? 0) + (right ?? 0)) / 2 : screen.frame.midX
        let top = min(screen.visibleFrame.maxY, screen.frame.maxY - screen.safeAreaInsets.top)
        island.setFrameOrigin(NSPoint(x: center - island.frame.width / 2, y: top - island.frame.height - 3))
        island.orderFrontRegardless()
    }

    @objc private func statusClicked() {
        if let button = status?.button { toggle(relativeTo: button) }
    }

    @objc private func islandClicked() {
        if let capsule { toggle(relativeTo: capsule) }
    }

    func show() {
        if let button = status?.button { toggle(relativeTo: button) }
        else if let capsule { toggle(relativeTo: capsule) }
        else { showMain(); store.page = "偏好" }
    }

    private func toggle(relativeTo anchor: NSView) {
        let wasSame = popover.isShown && popoverAnchor === anchor
        if popover.isShown { popover.performClose(nil) }
        guard !wasSame else { return }
        let board = GlanceBoard(store: store, showMain: showMain, close: { [weak self] in self?.popover.performClose(nil) })
        let host = NSHostingController(rootView: board)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.contentSize = host.view.fittingSize
        popoverAnchor = anchor
        let mouseEvents: Set<NSEvent.EventType> = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        pointerOpened = NSApp.currentEvent.map { mouseEvents.contains($0.type) } ?? false
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    func popoverDidShow(_ notification: Notification) {
        if pointerOpened, let content = popover.contentViewController?.view {
            content.window?.makeFirstResponder(content)
        }
    }
}
