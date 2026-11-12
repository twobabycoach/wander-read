import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class ReadingStore: ObservableObject {
    @Published private(set) var library = Library()
    @Published var pdfReader: PDFReader?
    @Published var textReader: TextReader?
    @Published var readerOpening: UUID?
    @Published var inspection: ReadingInspection?
    @Published var error: String?
    @Published var message: String?
    @Published var importing = false
    @Published var page = "发现"
    @Published var latestMilestone: MilestoneDefinition?
    let dataURL: URL
    let isPreview: Bool
    private(set) var recoveryRequired = false
    private var semanticFingerprint:Int?
    private var semanticScores:[UUID:Double]=[:]
    private(set) var semanticIndexBuildCount=0
    private var queue: RoamingQueue { library.roamingQueue ?? RoamingQueue() }
    var viewingPreviousBatch: Bool { queue.showingPrevious }
    var recommendations: [Recommendation] {
        resolve(queue.showingPrevious ? queue.previous : queue.current)
    }
    var previousRecommendations: [Recommendation] {
        queue.showingPrevious ? [] : resolve(queue.previous)
    }

    private func resolve(_ cards: [QueuedRecommendation]) -> [Recommendation] {
        let now = Date()
        return cards.compactMap { card in
            guard let item = library.items.first(where: { $0.id == card.id }), item.id != activeSession?.itemID,
                  queue.unavailableTargets?[item.id] != item.target,
                  AttentionEngine.eligible(item, now: now), PriorityEngine.inScope(item, preferences: library.preferences) else { return nil }
            return Recommendation(item: item, reason: card.reason, branch: card.branch, strategyName: card.strategyName)
        }
    }

    var activeSession: ReadingSession? { library.sessions.last(where: { $0.stoppedAt == nil }) }
    var activeItem: ReadingItem? { activeSession.flatMap { s in library.items.first { $0.id == s.itemID } } }
    var eligibleCount: Int {
        let now = Date()
        return library.items.filter {
            queue.unavailableTargets?[$0.id] != $0.target && AttentionEngine.eligible($0, now: now) &&
            PriorityEngine.inScope($0, preferences: library.preferences)
        }.count
    }
    var unavailableCount: Int {
        library.items.filter {
            queue.unavailableTargets?[$0.id] == $0.target && PriorityEngine.inScope($0, preferences: library.preferences)
        }.count
    }
    var hasUnseenCandidates: Bool {
        let now = Date()
        let seen = queue.seen
        return library.items.contains {
            !seen.contains($0.id) && $0.id != activeSession?.itemID &&
            queue.unavailableTargets?[$0.id] != $0.target &&
            AttentionEngine.eligible($0, now: now) && PriorityEngine.inScope($0, preferences: library.preferences)
        }
    }

    init(directory: URL? = nil, preview: Bool = false, refreshOnLoad:Bool = true) {
        isPreview=preview
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WanderRead")
        dataURL = root.appendingPathComponent("library.json")
        if FileManager.default.fileExists(atPath: dataURL.path) {
            do { library = try LibraryIO.decode(Data(contentsOf: dataURL)) }
            catch { recoveryRequired = true; self.error = "资料文件未能读取，已停止写入以保护原文件。可在偏好里导入备份恢复。\n\(error.localizedDescription)" }
        }
        // A restart pauses an unfinished visit; no overnight time is counted.
        for i in library.sessions.indices where library.sessions[i].stoppedAt == nil { library.sessions[i].runningSince = nil }
        if preview { library.items = DemoLibrary.make(); library.roamingQueue = nil; PreviewJourney.populate(&library) }
        Palette.theme=AppTheme(rawValue:library.preferences.appTheme ?? "") ?? .paper
        JourneyAnalytics.retainUnlocks(&library)
        if directory == nil && !preview {_=autoRepairLegacyLinks(vaults:ObsidianLinks.registeredVaults())}
        if refreshOnLoad {
            recheckQueuedTargets()
            fillQueueIfNeeded()
        }
    }
    @discardableResult func commit(reportError: Bool = true, _ change: (inout Library) -> Void) -> Bool {
        guard !recoveryRequired else {
            if reportError { error = "请先在偏好中恢复有效备份。原始资料仍保留在本地。" }
            return false
        }
        var next = library; change(&next)
        do {
            try PriorityEngine.validate(next.preferences)
            next.roamingQueue?.reconcile(items: next.items, preferences: next.preferences,
                                         active: next.sessions.last(where: { $0.stoppedAt == nil })?.itemID, now: Date())
            next.version=2
            JourneyAnalytics.retainUnlocks(&next)
            let data = try LibraryIO.encode(next)
            try FileManager.default.createDirectory(at: dataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dataURL.path) {
                let previous=try Data(contentsOf:dataURL)
                let migration=dataURL.deletingLastPathComponent().appendingPathComponent("library-v1-before-upgrade.json")
                if !FileManager.default.fileExists(atPath:migration.path), let json=try? JSONSerialization.jsonObject(with:previous) as? [String:Any], json["version"] as? Int == 1 {try previous.write(to:migration,options:.atomic)}
                try previous.write(to: dataURL.appendingPathExtension("bak"), options: .atomic)
            }
            try data.write(to: dataURL, options: .atomic)
            let oldIDs=Set((library.unlocks ?? []).map(\.id))
            let newlyEarned=(next.unlocks ?? []).last(where:{!oldIDs.contains($0.id)})
            library = next
            Palette.theme=AppTheme(rawValue:next.preferences.appTheme ?? "") ?? .paper
            if let earned=newlyEarned {latestMilestone=MilestoneDefinition.all.first(where:{$0.id == earned.id})}
            return true
        } catch {
            if reportError { self.error = "没能保存这次改动，已保留改动前的状态。\n\(error.localizedDescription)" }
            return false
        }
    }
    func refresh(restart: Bool = false) {
        var next = restart ? RoamingQueue() : queue
        if next.showingPrevious {
            _ = commit { $0.roamingQueue?.showingPrevious = false }
            recheckQueuedTargets()
            return
        }
        let active = activeSession.map { Set([$0.itemID]) } ?? []
        let preferences = library.preferences
        let now = Date()
        if preferences.strategy.mode == .adaptive && preferences.strategy.semanticBlend > 0 {
            let candidates = library.items.filter { PriorityEngine.inScope($0, preferences: preferences) }
            var key = Hasher()
            key.combine(preferences.strategy.question)
            for item in candidates {
                key.combine(item.id)
                key.combine(item.title)
                key.combine(item.note)
                key.combine(item.tags)
                key.combine(item.lastChosen)
                key.combine(item.choices)
            }
            let fingerprint = key.finalize()
            if fingerprint != semanticFingerprint {
                semanticScores = SemanticIndex.similarities(items: candidates, question: preferences.strategy.question)
                semanticFingerprint = fingerprint
                semanticIndexBuildCount += 1
            }
        }
        let vaults = ObsidianLinks.registeredVaults()
        let eligible = library.items.filter {
            !next.seen.contains($0.id) && !active.contains($0.id) &&
            AttentionEngine.eligible($0, now: now) && PriorityEngine.inScope($0, preferences: preferences) &&
            next.unavailableTargets?[$0.id] != $0.target
        }
        let available = eligible.filter { item in
            guard (try? ObsidianLinks.checkedURL(item.target, vaults: vaults)) == nil else { return true }
            if next.unavailableTargets == nil { next.unavailableTargets = [:] }
            next.unavailableTargets?[item.id] = item.target
            return false
        }
        let picks = AttentionEngine.draw(items: available, preferences: preferences,
                                         excluding: next.seen.union(active), now: now, similarityScores: semanticScores)
        if !next.current.isEmpty { next.previous = next.current }
        next.current = picks.map(QueuedRecommendation.init)
        next.seen.formUnion(picks.map(\.id))
        guard next != queue || !picks.isEmpty else { return }
        let pickByID = Dictionary(uniqueKeysWithValues: picks.map { ($0.id, $0) })
        commit { library in
            library.roamingQueue = next
            if library.exposureLogStartedAt == nil && !picks.isEmpty { library.exposureLogStartedAt = now }
            for index in library.items.indices {
                guard let pick = pickByID[library.items[index].id] else { continue }
                library.items[index].lastShown = now
                library.items[index].impressions += 1
                if library.exposures == nil { library.exposures = [] }
                library.exposures?.append(ExposureEvent(itemID: pick.id, date: now, source: pick.item.source,
                                                         isDemo: pick.item.isDemo, strategyName: pick.strategyName ?? preferences.strategy.name,
                                                         branch: pick.branch))
            }
        }
    }

    func returnToPreviousBatch() {
        recheckQueuedTargets()
        guard !previousRecommendations.isEmpty else { return }
        _ = commit { $0.roamingQueue?.showingPrevious = true }
    }

    private func recheckQueuedTargets() {
        var next = queue
        let cards = resolve(next.current + next.previous)
        guard !cards.isEmpty else { return }
        let vaults = ObsidianLinks.registeredVaults()
        for card in cards where (try? ObsidianLinks.checkedURL(card.item.target, vaults: vaults)) == nil {
            if next.unavailableTargets == nil { next.unavailableTargets = [:] }
            next.unavailableTargets?[card.id] = card.item.target
        }
        if next != queue { _ = commit { $0.roamingQueue = next } }
    }

    func fillQueueIfNeeded() {
        if activeSession == nil && recommendations.isEmpty && hasUnseenCandidates { refresh() }
    }

    func updatePreferences(_ change: (inout Preferences) -> Void, redraw: Bool = false) {
        if commit({ l in
            change(&l.preferences)
            var profiles=l.preferences.allStrategies
            if let i=profiles.firstIndex(where:{$0.id == l.preferences.strategy.id}) {profiles[i].exploration=l.preferences.exploration}
            l.preferences.strategies=profiles
        }), redraw { fillQueueIfNeeded() }
    }
    func selectStrategy(_ id: String) {
        if commit({ l in if let s=l.preferences.allStrategies.first(where:{$0.id == id}) {l.preferences.strategyID=id; l.preferences.exploration=s.exploration} }) {fillQueueIfNeeded()}
    }
    func applyStrategies(metrics: [MetricDefinition], profiles: [ReadingStrategy], selected: String) -> Bool {
        let result=commit { l in l.preferences.metrics=metrics; l.preferences.strategies=profiles.map {s in var copy=s; copy.weights=PriorityEngine.normalized(copy.weights); return copy}; l.preferences.strategyID=selected; l.preferences.exploration=profiles.first(where:{$0.id == selected})?.exploration ?? 0.35 }
        if result {fillQueueIfNeeded(); message="策略已保存。长期优先级与此刻状态分别计算。"}; return result
    }
    func setScope(tag: String, question: String) {
        if commit({ l in var profiles=l.preferences.allStrategies; if let i=profiles.firstIndex(where:{$0.id == l.preferences.strategy.id}) {profiles[i].scopeTag=tag; profiles[i].question=question}; l.preferences.strategies=profiles }) {fillQueueIfNeeded()}
    }
    func setMetrics(_ id: UUID, values: [String:Double], priority: Double?, locked: Bool) -> Bool {
        guard values.values.allSatisfy({$0.isFinite && (0...10).contains($0)}), priority.map({$0.isFinite && (0...10).contains($0)}) ?? true else {error="指标需要在 0—10 之间。"; return false}
        let saved=commit {l in if let i=l.items.firstIndex(where:{$0.id == id}) {l.items[i].metricValues=values; l.items[i].priorityOverride=priority; l.items[i].priorityLocked=locked; l.items[i].prioritySource=priority == nil ? nil:"manual"}}
        if saved {fillQueueIfNeeded()}; return saved
    }
    @discardableResult func setPriority(_ id: UUID, value: Double) -> Bool {
        guard value.isFinite else {return false}
        let saved=commit {l in if let i=l.items.firstIndex(where:{$0.id == id}) {l.items[i].priorityOverride=min(10,max(0,value)); l.items[i].prioritySource="manual"}}
        if saved { fillQueueIfNeeded() }; return saved
    }
    func alignPreview() -> [(ReadingItem,Double)] {
        let candidates=library.items.filter {PriorityEngine.inScope($0,preferences:library.preferences) && $0.state != .archived}
        let scores=SemanticIndex.similarities(items:candidates,question:library.preferences.strategy.question)
        let positive=scores.values.filter {$0 > 0}
        guard let min=positive.min(), let max=positive.max(), max-min > 0.00001 else {return []}
        return candidates.filter {PriorityEngine.acceptsAlignment($0,preferences:library.preferences) && (scores[$0.id] ?? 0) > 0}.map {($0, 1+8*((scores[$0.id] ?? 0)-min)/(max-min))}
    }
    func applyAlignment(_ changes: [(UUID,Double)]) {
        guard !changes.isEmpty, changes.allSatisfy({$0.1.isFinite && (0...10).contains($0.1)}) else {return}
        let planned=changes.filter {id,_ in library.items.contains { $0.id==id && PriorityEngine.acceptsAlignment($0,preferences:library.preferences) }}
        guard !planned.isEmpty else {message="没有可调整的文献。明确评分、锁定、手动指定和当前范围均保持不变。";return}
        if commit({l in
            l.alignmentUndo=[]
            for (id,value) in planned {if let i=l.items.firstIndex(where:{$0.id == id}), PriorityEngine.acceptsAlignment(l.items[i],preferences:l.preferences) {
                l.alignmentUndo?.append(PriorityAdjustment(itemID:id,previous:l.items[i].priorityOverride,applied:value)); l.items[i].priorityOverride=value; l.items[i].prioritySource="alignment"
            }}
        }) {fillQueueIfNeeded(); message="已按预览调整，可在策略页撤销本次对齐。"}
    }
    func undoAlignment() {
        var restored=0
        if commit({l in for change in l.alignmentUndo ?? [] {
            if let i=l.items.firstIndex(where:{$0.id == change.itemID}), l.items[i].priorityLocked != true, l.items[i].prioritySource == "alignment", l.items[i].priorityOverride == change.applied {l.items[i].priorityOverride=change.previous; l.items[i].prioritySource=nil; restored += 1}
        }; l.alignmentUndo=[]}) {fillQueueIfNeeded(); message="已撤回 \(restored) 篇的对齐；后续手动改动和锁定项保持不变。"}
    }
    func add(title: String, target: String, note: String, tags: String, minutes: Int, difficulty: Int, interest: Double, editing: UUID? = nil) -> Bool {
        do {
            let normalized = try Targets.normalize(target)
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw InputError.invalid("给它起个名字，方便下次认出来。") }
            guard !library.items.contains(where: { $0.id != editing && Targets.key($0.target) == Targets.key(normalized) }) else { throw InputError.invalid("这篇已经收下了，可以在收藏里找到它。") }
            let result = commit { l in
                var item = editing.flatMap { id in l.items.first { $0.id == id } } ?? ReadingItem(title:title, target:normalized)
                item.title = title.trimmingCharacters(in:.whitespacesAndNewlines); if item.target != normalized { item.zotero = nil }; item.target = normalized; item.note = note
                item.tags = Array(NSOrderedSet(array:tags.components(separatedBy:CharacterSet(charactersIn:",，#")).map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty })) as? [String] ?? []
                item.minutes = minutes; item.difficulty = difficulty; item.interest = interest
                if let i = l.items.firstIndex(where: { $0.id == item.id }) { l.items[i] = item } else { l.items.append(item) }
            }
            if result {
                message = editing == nil ? "收下了，下次也许就会遇见。" : "已保存。"
                fillQueueIfNeeded()
            }
            return result
        } catch { self.error = error.localizedDescription; return false }
    }
    @discardableResult func mutate(_ id: UUID, _ change: (inout ReadingItem) -> Void) -> Bool {
        if commit({ l in if let i = l.items.firstIndex(where: { $0.id == id }) { change(&l.items[i]) } }) {
            return true
        }; return false
    }
    func snooze(_ id: UUID) {if mutate(id,{ $0.state = .resting; $0.snoozedUntil = Date().addingTimeInterval(18*3600) }) {message = "让它休息一会儿，18 小时后再遇见。"}}
    func archive(_ id: UUID) {if mutate(id,{ $0.state = .archived; $0.snoozedUntil = nil }) {message = "已放好。以后仍可在收藏里找回来。"}}
    func restore(_ id: UUID) {if commit({ library in
        guard let index = library.items.firstIndex(where: { $0.id == id }) else { return }
        library.items[index].state = .inbox
        library.items[index].snoozedUntil = nil
        if library.roamingQueue?.current.contains(where: { $0.id == id }) != true &&
            library.roamingQueue?.previous.contains(where: { $0.id == id }) != true {
            library.roamingQueue?.seen.remove(id)
        }
    }) { fillQueueIfNeeded(); message = "它又可以被遇见了。" }}
    func choose(_ item: ReadingItem, external: Bool = false) {
        if !external && item.canReadInside {
            openInReader(item)
            return
        }
        guard readerOpening == nil, pdfReader == nil, textReader == nil else { return }
        if external && activeSession?.itemID == item.id {
            openExternal(item)
            return
        }
        guard activeSession == nil else { page = "发现"; message = "上一段停留还在，先收个尾再开始。"; return }
        guard openExternal(item) else { return }
        if startVisit(item.id) { page = "发现" }
    }
    @discardableResult func openExternal(_ item: ReadingItem) -> Bool {
        let url:URL
        do { url = try ObsidianLinks.checkedURL(item.target) }
        catch { self.error = error.localizedDescription; return false }
        guard NSWorkspace.shared.open(url) else {
            error = "没有找到能打开它的应用。请检查链接，或安装对应的阅读工具。"
            return false
        }
        return true
    }
    func openInReader(_ item: ReadingItem, focused: Bool = false) {
        if item.canSendToResearch { openPDF(item, focused: focused) }
        else if item.zotero?.pdfKey != nil { openZoteroPDF(item, focused: focused) }
        else if ReadingFile.textCandidate(item.target) { openText(item, focused: focused) }
    }

    func startReaderVisit(_ id: UUID) -> Bool {
        guard activeSession == nil || activeSession?.itemID == id else { return false }
        if activeSession == nil { return startVisit(id, inReader: true) }
        return commit { library in
            guard let index = library.sessions.lastIndex(where: { $0.itemID == id && $0.stoppedAt == nil }) else { return }
            library.sessions[index].inReader = true
            if library.sessions[index].runningSince == nil { library.sessions[index].runningSince = Date() }
        }
    }

    func finishReaderVisit(_ id: UUID) -> Bool {
        commit { library in
            guard let index = library.sessions.lastIndex(where: { $0.itemID == id && $0.stoppedAt == nil }) else { return }
            let now = Date()
            library.sessions[index].seconds = library.sessions[index].elapsed(at: now)
            library.sessions[index].stoppedAt = now
            library.sessions[index].runningSince = nil
            library.sessions[index].outcome = "留待续读"
        }
    }

    @discardableResult func startVisit(_ itemID: UUID, now: Date=Date(), inReader: Bool = false) -> Bool {
        guard activeSession == nil, let item=library.items.first(where:{$0.id == itemID && $0.trashedAt == nil}) else {return false}
        let recommendation=recommendations.first(where:{$0.id == itemID})
        return commit { l in
            guard let i = l.items.firstIndex(where: { $0.id == itemID }) else { return }
            l.items[i].choices += 1; l.items[i].lastChosen = now
            var session=ReadingSession(itemID:item.id,title:item.title,startedAt:now,runningSince:now)
            if inReader { session.inReader = true }
            session.tagsSnapshot=item.tags; session.sourceSnapshot=item.source; session.isDemoSnapshot=item.isDemo
            session.strategyName=recommendation?.strategyName ?? l.preferences.strategy.name; session.wasRecommended=recommendation != nil
            l.sessions.append(session)
            if l.roamingQueue == nil { l.roamingQueue = RoamingQueue() }
            l.roamingQueue?.seen.insert(item.id)
        }
    }
    func pauseResume() {
        commit { l in
            guard let i = l.sessions.lastIndex(where: { $0.stoppedAt == nil }) else { return }
            if l.sessions[i].runningSince != nil { l.sessions[i].seconds = l.sessions[i].elapsed(at:Date()); l.sessions[i].runningSince = nil }
            else { l.sessions[i].runningSince = Date() }
        }
    }
    func pauseOnQuit() {
        guard activeSession?.runningSince != nil else { return }; pauseResume()
    }
    func finish(outcome: String, bookmark: String, usefulness: String? = nil, reflection: String = "") {
        guard let session = activeSession else { return }
        if commit({ l in
            guard let si = l.sessions.firstIndex(where: { $0.id == session.id }), let ii = l.items.firstIndex(where: { $0.id == session.itemID }) else { return }
            l.sessions[si].seconds = l.sessions[si].elapsed(at:Date()); l.sessions[si].runningSince = nil; l.sessions[si].stoppedAt = Date(); l.sessions[si].outcome = outcome
            l.sessions[si].usefulness=usefulness; l.sessions[si].reflection=reflection.trimmingCharacters(in:.whitespacesAndNewlines)
            l.items[ii].bookmark = bookmark
            l.items[ii].snoozedUntil = Date().addingTimeInterval(outcome == "想接着读" ? 2*3600 : 18*3600)
            if outcome == "读到这里就够了" { l.items[ii].state = .archived }
            else { l.items[ii].state = .resting }
            if outcome == "想接着读" {
                if l.items[ii].metricValues?["interest"] == nil {l.items[ii].interest = min(5,l.items[ii].interest+0.25)}
            }
            let delta=usefulness == "不合适" ? -0.04 : usefulness == "有帮助" || outcome == "想接着读" ? 0.08 : 0
            if delta != 0 {for tag in l.items[ii].tags {
                let age=max(0,Date().timeIntervalSince(l.preferences.tagUpdatedAt?[tag] ?? Date())/86400)
                let old=0.5+((l.preferences.tagAffinity[tag] ?? 0.5)-0.5)*exp(-age/60)
                l.preferences.tagAffinity[tag]=min(1,max(0,old+delta)); if l.preferences.tagUpdatedAt == nil {l.preferences.tagUpdatedAt=[:]}; l.preferences.tagUpdatedAt?[tag]=Date()
            }}
        }) { message = "这一段由你决定。随时可以再回来。"; fillQueueIfNeeded() }
    }
    func loadDemo() { if commit({ $0.items.append(contentsOf:DemoLibrary.make().filter { d in !library.items.contains { Targets.key($0.target) == Targets.key(d.target) } }) }) { fillQueueIfNeeded() } }
    func removeDemo() {
        if commit({ l in let ids = Set(l.items.filter(\.isDemo).map(\.id)); l.items.removeAll { ids.contains($0.id) }; l.sessions.removeAll { ids.contains($0.itemID) }; l.exposures?.removeAll {ids.contains($0.itemID)};l.researchEvents?.removeAll {ids.contains($0.itemID)} }) { fillQueueIfNeeded() }
    }
    func importFiles(_ urls: [URL]) {
        let newItems = urls.filter { !$0.hasDirectoryPath }.map { ReadingItem(title:$0.deletingPathExtension().lastPathComponent, target:$0.path, tags:["本地文件"]) }
        mergeItems(newItems)
    }
    @discardableResult func mergeItems(_ items: [ReadingItem], label:String = "本地文件") -> Bool {
        let batch=UUID(),importedAt=Date()
        var added = 0
        if commit({ l in var keys = Set(l.items.map { Targets.key($0.target) }); for item in items where !keys.contains(Targets.key(item.target)) { var saved=item;saved.importBatchID=batch;saved.importBatchLabel=label;saved.createdAt=importedAt;l.items.append(saved); keys.insert(Targets.key(item.target)); added += 1 } }) {
            message = "收下 \(added) 篇，跳过 \(items.count-added) 篇重复内容。"; fillQueueIfNeeded(); return true
        }
        return false
    }
    func pickFiles() {
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = false; p.message = "PDF、Markdown、纯文本、HTML 与 RTF 可在漫读里阅读。"
        if p.runModal() == .OK { importFiles(p.urls) }
    }
    func importObsidian() {
        let p = NSOpenPanel(); p.canChooseFiles = false; p.canChooseDirectories = true; p.message = "选择 Obsidian 仓库根目录。只收录 Markdown 笔记的位置，不修改笔记。"
        guard p.runModal() == .OK, let selected = p.url else { return }
        let root:URL
        do {root=try ObsidianLinks.root(containing:selected)} catch {self.error=error.localizedDescription;return}
        importing = true
        DispatchQueue.global(qos:.userInitiated).async {
            var items: [ReadingItem] = []
            let enumerator = FileManager.default.enumerator(at:selected, includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey], options:[.skipsHiddenFiles,.skipsPackageDescendants])
            while let file = enumerator?.nextObject() as? URL {
                guard file.pathExtension.lowercased() == "md", let values = try? file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey]), values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let relative = String(file.path.dropFirst(root.path.count+1)).dropLast(3)
                let target=ObsidianLinks.uri(file:file)
                let parent = (String(relative) as NSString).deletingLastPathComponent
                let topic = parent.isEmpty ? "Obsidian" : (parent as NSString).lastPathComponent
                items.append(ReadingItem(title:file.deletingPathExtension().lastPathComponent, target:target, tags:[topic]))
                if items.count >= 5000 { break }
            }
            DispatchQueue.main.async { self.importing = false; self.mergeItems(items,label:"Obsidian · "+root.lastPathComponent); if items.count >= 5000 { self.message = "本次收录前 5000 篇。可分批添加其他笔记。" } }
        }
    }
    func exportBackup() {
        let p = NSSavePanel(); p.nameFieldStringValue = "漫读备份.json"; p.allowedContentTypes = [.json]
        if p.runModal() == .OK, let url = p.url {
            do { try LibraryIO.encode(library).write(to:url, options:.atomic); message = "备份已导出，包含收藏、偏好与停留记录。" } catch { self.error = error.localizedDescription }
        }
    }
    func importBackup() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.json,.data]; p.message = "选择导出的 JSON 备份，或本机保留的 library.json.bak。"
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            var incoming = try LibraryIO.decode(Data(contentsOf:url))
            for i in incoming.sessions.indices { incoming.sessions[i].runningSince = nil }
            let alert = NSAlert(); alert.messageText = "恢复这个备份？"; alert.informativeText = "备份中有 \(incoming.items.count) 篇收藏。将替换当前资料；替换前的资料会保留为 library.json.bak。"; alert.addButton(withTitle:"恢复备份"); alert.addButton(withTitle:"取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let wasRecovery = recoveryRequired; recoveryRequired = false
            if commit({ $0 = incoming }) { if library.roamingQueue == nil { refresh() }; message = "备份已恢复。" } else { recoveryRequired = wasRecovery }
        } catch { self.error = "备份未能导入，当前资料没有改动。\n\(error.localizedDescription)" }
    }
}
