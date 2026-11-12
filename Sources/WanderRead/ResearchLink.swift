// Local communication contract shared with Paste for Research. No network listener.
import Foundation

struct ResearchLinkRequest:Codable {
    var version=1
    var id:String
    var token:String
    var itemID:String
    var title:String
    var pdfPath:String
    var created:Date
}
struct ResearchLinkUpdate:Codable {
    var version=1
    var id:String
    var token:String
    var itemID:String
    var status:String
    var noteURL:String?
    var title:String?
    var error:String?
    var created:Date
}
enum ResearchLink {
    static var root:URL {FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("WanderRead/ResearchLink")}
    static func read<T:Decodable>(_ type:T.Type,at url:URL)->T? {
        guard let size=(try? url.resourceValues(forKeys:[.fileSizeKey]))?.fileSize,size<=32_000, let data=try? Data(contentsOf:url) else{return nil}
        let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type,from:data)
    }
    static func write<T:Encodable>(_ value:T,at url:URL) throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601
        let data=try encoder.encode(value);try data.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    static func token(at root:URL=ResearchLink.root,create:Bool=false) throws -> String {
        let file=root.appendingPathComponent("pair.json")
        if let data=try? Data(contentsOf:file),let json=try? JSONSerialization.jsonObject(with:data) as? [String:Any], json["version"] as? Int == 1, let token=json["token"] as? String, UUID(uuidString:token) != nil {return token}
        guard create else {throw NSError(domain:"ResearchLink",code:1,userInfo:[NSLocalizedDescriptionKey:"尚未建立漫读与研贴的本地通道。"])}
        if FileManager.default.fileExists(atPath:file.path) {throw NSError(domain:"ResearchLink",code:2,userInfo:[NSLocalizedDescriptionKey:"通信配置无法读取，已保留原文件。"])}
        let token=UUID().uuidString.lowercased()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try JSONSerialization.data(withJSONObject:["version":1,"token":token] as [String:Any]).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        return token
    }
    static func enqueue(itemID:UUID,title:String,pdf:URL,root:URL=ResearchLink.root,now:Date=Date()) throws -> URL {
        guard pdf.isFileURL,pdf.pathExtension.lowercased()=="pdf", FileManager.default.fileExists(atPath:pdf.path) else {throw NSError(domain:"ResearchLink",code:3,userInfo:[NSLocalizedDescriptionKey:"研贴通信目前需要可访问的本地 PDF。"])}
        let token=try self.token(at:root,create:true),id=UUID().uuidString.lowercased()
        let request=ResearchLinkRequest(id:id,token:token,itemID:itemID.uuidString.lowercased(),title:String(title.prefix(500)),pdfPath:pdf.standardizedFileURL.path,created:now)
        try write(request,at:root.appendingPathComponent("requests/\(id).json"))
        var c=URLComponents();c.scheme="pfr";c.host="prepare";c.queryItems=[URLQueryItem(name:"id",value:id)]
        return c.url!
    }
    static func request(_ url:URL,root:URL=ResearchLink.root,now:Date=Date()) throws -> ResearchLinkRequest {
        guard url.scheme=="pfr",url.host=="prepare",let c=URLComponents(url:url,resolvingAgainstBaseURL:false),let id=c.queryItems?.first(where:{$0.name=="id"})?.value,UUID(uuidString:id) != nil,
              let request=read(ResearchLinkRequest.self,at:root.appendingPathComponent("requests/\(id).json")),request.version==1,request.id==id,request.token == (try token(at:root)),UUID(uuidString:request.itemID) != nil,
              now.timeIntervalSince(request.created)>=(-10),now.timeIntervalSince(request.created)<=300,request.pdfPath.hasPrefix("/"),request.pdfPath.count<=4096,request.title.count<=500,URL(fileURLWithPath:request.pdfPath).pathExtension.lowercased()=="pdf" else {throw NSError(domain:"ResearchLink",code:4,userInfo:[NSLocalizedDescriptionKey:"漫读请求无效或已过期，请回到漫读重新发起。"])}
        return request
    }
    static func acknowledge(_ request:ResearchLinkRequest,error:String?=nil,root:URL=ResearchLink.root) throws {
        let update=ResearchLinkUpdate(id:request.id,token:request.token,itemID:request.itemID,status:error == nil ? "ready":"error",title:request.title,error:error,created:Date())
        try write(update,at:root.appendingPathComponent("updates/\(request.id).json"))
        try? FileManager.default.removeItem(at:root.appendingPathComponent("requests/\(request.id).json"))
    }
    static func saved(excerptID:UUID,itemID:String,token:String,title:String,noteURL:String,root:URL=ResearchLink.root) throws {
        guard token == (try self.token(at:root)), UUID(uuidString:itemID) != nil, URL(string:noteURL)?.scheme=="obsidian",URL(string:noteURL)?.host=="pfr-excerpt" else {return}
        let value=ResearchLinkUpdate(id:excerptID.uuidString.lowercased(),token:token,itemID:itemID,status:"saved",noteURL:noteURL,title:title,created:Date())
        try write(value,at:root.appendingPathComponent("updates/\(value.id).json"))
    }
    static func updates(root:URL=ResearchLink.root)->[(URL,ResearchLinkUpdate)] {
        guard let token=try? self.token(at:root),let files=try? FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("updates"),includingPropertiesForKeys:nil) else{return []}
        return files.compactMap {url in
            guard UUID(uuidString:url.deletingPathExtension().lastPathComponent) != nil,let update=read(ResearchLinkUpdate.self,at:url),update.version==1,update.token==token,url.lastPathComponent==update.id+".json",UUID(uuidString:update.itemID) != nil,["ready","error","saved"].contains(update.status),update.noteURL.map({URL(string:$0)?.scheme=="obsidian" && URL(string:$0)?.host=="pfr-excerpt"}) ?? true else{return nil}
            return (url,update)
        }
    }
}
