import Foundation
import AppKit
struct ShareProfile:Codable {
    var nickname=""
    var bio=""
    var avatar:Data?
    var visible=false
}
struct CloudWord:Identifiable {
    var id:String {name}
    var name:String
    var value:Double
    var rect:CGRect
    var font:Double
}
enum TopicCloud {
    static func words(_ topics:[TopicTotal],size:CGSize,showNames:Bool)->[CloudWord] {
        var placed:[CloudWord]=[]
        let maximum=topics.first?.value ?? 1
        for (i,topic) in topics.prefix(16).enumerated() {
            let text=showNames ? String(topic.name.prefix(12)):"主题 \(i+1)"
            let font=15+28*sqrt(topic.value/max(0.01,maximum))
            let measured=(text as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:font,weight:.medium)])
            for n in 0..<1200 {
                let angle=Double(n)*2.399963, radius=Double(n).squareRoot()*5
                let rect=CGRect(x:size.width/2+cos(angle)*radius-measured.width/2,y:size.height/2+sin(angle)*radius-measured.height/2,width:measured.width,height:measured.height)
                if CGRect(origin:.zero,size:size).insetBy(dx:3,dy:3).contains(rect), !placed.contains(where:{$0.rect.insetBy(dx:-6,dy:-5).intersects(rect)}) {placed.append(CloudWord(name:text,value:topic.value,rect:rect,font:font));break}
            }
        }
        return placed
    }
}
extension MilestoneUnlock {
    var certificate:String {"MAN-"+id.uppercased()+"-"+String(Int(earnedAt.timeIntervalSince1970),radix:36).uppercased()}
}
extension ReadingStore {
    @discardableResult func saveProfile(_ profile:ShareProfile)->Bool {
        guard profile.nickname.count<=32,profile.bio.count<=100,(profile.avatar?.count ?? 0)<=1_000_000 else {error="昵称最多 32 字、简介最多 100 字，头像请使用较小图片。";return false}
        return commit {$0.preferences.shareProfile=profile}
    }
}
