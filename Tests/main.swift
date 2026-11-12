import Foundation
import AppKit

var checks = 0
func check(_ condition: @autoclosure () throws -> Bool, _ name: String) {
    checks += 1
    let passed: Bool
    do { passed = try condition() } catch { print("FAIL: \(name): \(error)"); exit(1) }
    guard passed else { print("FAIL: \(name)"); exit(1) }
    print("PASS: \(name)")
}
func rejects(_ action: () throws -> Void, _ name: String) {
    do { try action(); check(false,name) } catch { check(true,name) }
}
var seed: UInt64 = 42
func random() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(UInt64(1) << 53) }
let now = Date(timeIntervalSince1970:1_793_000_000)
var p = Preferences(); p.exploration = 0
var high = ReadingItem(title:"高兴趣",target:"https://example.com/high",minutes:15,difficulty:2,interest:5,createdAt:now.addingTimeInterval(-86400*40))
var low = ReadingItem(title:"低兴趣",target:"https://example.com/low",minutes:15,difficulty:2,interest:1,createdAt:now.addingTimeInterval(-86400*40))
let base = [high,low]
let picks = AttentionEngine.draw(items:base,preferences:p,excluding:[],now:now,random:random)
check(picks.count == 2 && Set(picks.map(\.id)).count == 2,"单批次不重复且不补虚构内容")
check(AttentionEngine.draw(items:base,preferences:p,excluding:Set(base.map(\.id)),now:now).isEmpty,"本轮看完后停下，不偷偷循环")
check(AttentionEngine.draw(items:[],preferences:p,excluding:[],now:now).isEmpty,"空库安全")
var sleeping = high; sleeping.snoozedUntil = now.addingTimeInterval(3600); sleeping.state = .resting
var archived = low; archived.state = .archived
check(AttentionEngine.draw(items:[sleeping,archived],preferences:p,excluding:[],now:now).isEmpty,"休息和归档是严格边界")
check(AttentionEngine.eligible(sleeping,now:now.addingTimeInterval(3601)),"休息自然结束")
var counts: [UUID:Int] = [:]
for _ in 0..<12000 { let id=AttentionEngine.draw(items:base,preferences:p,excluding:[],count:1,now:now,random:random)[0].id; counts[id,default:0] += 1 }
check(counts[high.id,default:0] > counts[low.id,default:0] * 13/10,"兴趣影响概率")
check(counts[low.id,default:0] > 1000,"低权重内容仍有机会")
p.exploration = 1; counts = [:]
for _ in 0..<12000 { let id=AttentionEngine.draw(items:base,preferences:p,excluding:[],count:1,now:now,random:random)[0].id; counts[id,default:0] += 1 }
check(abs(counts[high.id,default:0]-counts[low.id,default:0]) < 700,"全探索模式不被兴趣排序支配")
var recent = high; recent.lastShown = now
check(AttentionEngine.weight(recent,preferences:p,now:now) < AttentionEngine.weight(high,preferences:p,now:now)*0.2,"近期曝光会降温")
check(AttentionEngine.weight(recent,preferences:p,now:now.addingTimeInterval(86400*3)) > AttentionEngine.weight(recent,preferences:p,now:now)*5,"曝光抑制会随时间恢复")
var deep = high; deep.difficulty=3
var light = high; light.difficulty=1
p.energy = .light
check(AttentionEngine.weight(light,preferences:p,now:now) > AttentionEngine.weight(deep,preferences:p,now:now),"精力匹配有影响")
var long = high; long.minutes=600
check(AttentionEngine.draw(items:[long],preferences:p,excluding:[],now:now).count == 1,"长文不会因时间片较短被排除")
check(AttentionEngine.weight(high,preferences:p,now:now,selectedTags:[]) > 0,"无主题冷启动正常")
var tagged = high; tagged.tags=["哲学"]
check(AttentionEngine.weight(tagged,preferences:p,now:now,selectedTags:["哲学"]) < AttentionEngine.weight(tagged,preferences:p,now:now),"同批内容抑制主题拥挤")
check((try Targets.normalize(" /tmp/中文 文件.pdf ")) == "/tmp/中文 文件.pdf","中文文件路径可保留")
check((try Targets.normalize("obsidian://open?vault=研究&file=阅读" )).hasPrefix("obsidian:"),"Obsidian 深链接")
rejects({ _ = try Targets.normalize("javascript:alert(1)") },"拒绝脚本链接")
rejects({ _ = try Targets.normalize("https:///invalid") },"拒绝无域名网址")
check(Targets.key("https://EXAMPLE.com/a?utm_source=x#p") == Targets.key("https://example.com/a"),"跟踪参数与片段不产生重复收藏")
var captureComponents=URLComponents(); captureComponents.scheme="wanderread"; captureComponents.host="add"; captureComponents.queryItems=[URLQueryItem(name:"url",value:"https://example.com/article?q=one&next=two#section"),URLQueryItem(name:"title",value:"关于好奇与阅读 & 探索")]
let capture=try CaptureLink.parse(captureComponents.url!)
check(capture.title == "关于好奇与阅读 & 探索" && capture.target == "https://example.com/article?q=one&next=two#section","浏览器收录入口保留中文、查询和片段")
rejects({ _=try CaptureLink.parse(URL(string:"wanderread://add?url=javascript%3Aalert(1)")!) },"外部收录入口同样拒绝脚本链接")
rejects({ _=try CaptureLink.parse(URL(string:"wanderread://add?title=missing")!) },"不完整的外部入口不写入")
var l=Library(); l.items=base
check(try LibraryIO.decode(LibraryIO.encode(l)).items == l.items,"备份往返无损")
var invalid=l; invalid.version=99
rejects({ _=try LibraryIO.decode(LibraryIO.encode(invalid)) },"未知数据版本不覆盖")
invalid=l; invalid.items[0].interest = -1
rejects({ _=try LibraryIO.decode(LibraryIO.encode(invalid)) },"备份指标越界拒绝")
invalid=l; invalid.items.append(high)
rejects({ _=try LibraryIO.decode(LibraryIO.encode(invalid)) },"重复条目拒绝")
invalid=Library(); invalid.items=[ReadingItem(title:"路径",target:"/tmp/same.pdf"),ReadingItem(title:"文件链接",target:"file:///tmp/same.pdf")]
rejects({ _=try LibraryIO.decode(LibraryIO.encode(invalid)) },"备份入口规范化后仍检查重复")
invalid=l; invalid.sessions=[ReadingSession(itemID:UUID(),title:"不存在",startedAt:now)]
rejects({ _=try LibraryIO.decode(LibraryIO.encode(invalid)) },"悬空停留记录拒绝")
invalid=l; invalid.sessions=[ReadingSession(itemID:high.id,title:high.title,startedAt:now),ReadingSession(itemID:low.id,title:low.title,startedAt:now)]
rejects({ _=try LibraryIO.decode(LibraryIO.encode(invalid)) },"备份不能包含两个未结束的停留")
let temp=FileManager.default.temporaryDirectory.appendingPathComponent("wander-tests-\(UUID().uuidString)")
let store=ReadingStore(directory:temp)
check(store.library.items.isEmpty,"真实首次启动空库")
check(store.add(title:"测试",target:"https://example.com/a",note:"好奇",tags:"哲学，科学",minutes:15,difficulty:2,interest:3),"新增收藏并保存")
check(!store.add(title:"重复",target:"https://example.com/a#heading",note:"",tags:"",minutes:15,difficulty:2,interest:3),"重复添加不会增加内容")
let storedID=store.library.items[0].id
check(store.library.items[0].interest == 3 && store.library.items[0].choices == 0,"曝光与刷新不冒充兴趣反馈或阅读")
check(store.add(title:"测试改名",target:"https://example.com/updated",note:"好奇",tags:"哲学，科学",minutes:15,difficulty:2,interest:3,editing:storedID),"修改资料保留条目身份")
check(store.recommendations.first?.item.target == "https://example.com/updated","编辑后当前推荐立即使用新入口")
let reloaded=ReadingStore(directory:temp)
check(reloaded.library.items.count == 1 && reloaded.library.items[0].note == "好奇","重启恢复收藏")
store.snooze(storedID)
check(store.library.items[0].interest == 3 && store.eligibleCount == 0,"放一放不降低兴趣")
store.restore(storedID)
check(store.eligibleCount == 1,"休息条目可手动找回")
store.commit { $0.sessions.append(ReadingSession(itemID:storedID,title:"测试",startedAt:now,seconds:60,runningSince:Date().addingTimeInterval(-30))) }
store.pauseResume()
check((store.activeSession?.seconds ?? 0) >= 89 && store.activeSession?.runningSince == nil,"暂停累积时长")
store.pauseResume()
check(store.activeSession?.runningSince != nil,"继续记录")
let beforeAffinity=store.library.preferences.tagAffinity["哲学"] ?? 0.5
store.finish(outcome:"想接着读",bookmark:"第 23 页")
check(store.activeSession == nil && store.library.items[0].bookmark == "第 23 页","收尾保存位置并结束停留")
check((store.library.preferences.tagAffinity["哲学"] ?? 0) > beforeAffinity,"明确正反馈改变主题偏好")
check(store.library.items[0].snoozedUntil! > Date(),"刚读过的内容先休息")
check(FileManager.default.fileExists(atPath:store.dataURL.appendingPathExtension("bak").path),"保留上一版备份")
store.archive(storedID); store.restore(storedID)
check(store.library.items[0].state == .inbox,"归档可恢复")
store.commit { $0.sessions.append(ReadingSession(itemID:storedID,title:"测试",startedAt:now,runningSince:Date().addingTimeInterval(-100))) }
let resume=ReadingStore(directory:temp)
check(resume.activeSession?.runningSince == nil,"重启不累计离线或过夜时长")
let bad=FileManager.default.temporaryDirectory.appendingPathComponent("wander-corrupt-\(UUID().uuidString)")
try FileManager.default.createDirectory(at:bad,withIntermediateDirectories:true)
try Data("broken".utf8).write(to:bad.appendingPathComponent("library.json"))
let corrupt=ReadingStore(directory:bad)
check(corrupt.recoveryRequired && !corrupt.commit { $0.items=base },"损坏资料停止写入")
check(try String(contentsOf:bad.appendingPathComponent("library.json")) == "broken","损坏原件保持不动")
let blocked=ReadingStore(directory:URL(fileURLWithPath:"/dev/null/unwritable"))
check(!blocked.commit { $0.items=base } && blocked.library.items.isEmpty,"保存失败回滚内存，不假报成功")
try runVersionTwoChecks()
try runVersionThreeChecks()
try runAlignmentProtectionChecks()
try runCleanupChecks()
try runObsidianRepairChecks()
try runRegisteredVaultChecks()
try runPDFReadingChecks()
try runReadingInspectionChecks()
try runRoamingQueueChecks()
try runRelatedReadingChecks()
try runReadingWorkspaceChecks()
try runNotebookDeliveryChecks()
try runPDFChapterScanChecks()
try runPDFChineseChecks()
try runPDFOutlineBuilderChecks()
let large=(0..<10000).map { ReadingItem(title:"内容 \($0)",target:"https://example.com/\($0)",tags:["主题 \($0%100)"]) }
let start=Date(); let batch=AttentionEngine.draw(items:large,preferences:p,excluding:[],now:now,random:random)
check(batch.count == 3 && Set(batch.map(\.id)).count == 3,"一万条内容推荐保持唯一")
print("10k 推荐耗时：\(Int(Date().timeIntervalSince(start)*1000)) ms")
print("\(checks) 项检查通过。测试资料位于 \(temp.path)")
