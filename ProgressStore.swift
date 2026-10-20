import SwiftUI
import AppKit
import CoreText
import CryptoKit
import UniformTypeIdentifiers

enum InterfaceLanguage {
    static func initial(saved:String?,preferred:[String])->String {
        if let saved,["traditional","simplified","english"].contains(saved) {return saved}
        for raw in preferred {
            let code=raw.lowercased().replacingOccurrences(of:"_",with:"-")
            if code=="en" || code.hasPrefix("en-") {return "english"}
            if code=="zh" || code.hasPrefix("zh-") {
                if code.contains("hans") {return "simplified"}
                return code.contains("hant") || code.hasSuffix("-tw") || code.hasSuffix("-hk") || code.hasSuffix("-mo") ? "traditional" : "simplified"
            }
        }
        return "english"
    }
}

struct StoredProgress:Identifiable {
    let id:String;let title:String;let date:Date;let url:URL;let reviewed:Int;let total:Int
}
struct ProgressDocument {
    var session:Session;let root:URL;let packaged:Bool;let recovered:Bool
}
enum ProgressStore {
    static let fm=FileManager.default
    static func title(_ session:Session)->String {
        let value=(session.title ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        return value.isEmpty ? session.fonts.map(\.name).joined(separator:" + ") : value
    }
    static func read(_ url:URL)throws->ProgressDocument {
        var directory:ObjCBool=false
        guard fm.fileExists(atPath:url.path,isDirectory:&directory) || fm.fileExists(atPath:url.appendingPathExtension("backup").path) else{throw CocoaError(.fileNoSuchFile)}
        let packaged=directory.boolValue
        let file=packaged ? url.appendingPathComponent("Session.json") : url
        if packaged {
            let manifest=try JSONSerialization.jsonObject(with:bounded(url.appendingPathComponent("Manifest.json"),limit:4096)) as? [String:Any]
            guard manifest?["format"] as? String=="GlyphCheck.progress.v1" else{throw CocoaError(.fileReadCorruptFile)}
        }
        var recovered=false
        let session:Session
        do {session=try JSONDecoder().decode(Session.self,from:bounded(file,limit:128*1024*1024))}
        catch {
            guard !packaged else{throw error}
            session=try JSONDecoder().decode(Session.self,from:bounded(file.appendingPathExtension("backup"),limit:128*1024*1024));recovered=true
        }
        guard session.version==1,(1...2).contains(session.fonts.count),(session.repairSources?.count ?? 0)<=64,session.domain.count<=1_000_000,session.remaining.count<=1_000_000 else{throw CocoaError(.fileReadCorruptFile)}
        let ids=(session.fonts+(session.repairSources ?? [])).map(\.id)
        guard Set(ids).count==ids.count,ids.allSatisfy({$0.range(of:#"^[A-Za-z0-9_-]{1,80}$"#,options:.regularExpression) != nil}) else{throw CocoaError(.fileReadCorruptFile)}
        return ProgressDocument(session:session,root:packaged ? url : url.deletingLastPathComponent(),packaged:packaged,recovered:recovered)
    }
    static func bounded(_ url:URL,limit:Int)throws->Data {
        let attrs=try fm.attributesOfItem(atPath:url.path)
        guard let size=attrs[.size] as? NSNumber,size.intValue<=limit else{throw CocoaError(.fileReadTooLarge)}
        return try Data(contentsOf:url)
    }
    static func save(_ session:Session,to url:URL)throws {
        guard UUID(uuidString:session.id) != nil else{throw CocoaError(.fileReadCorruptFile)}
        try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        let data=try encoder.encode(session)
        if let prior=try? Data(contentsOf:url),(try? JSONDecoder().decode(Session.self,from:prior)) != nil {
            try prior.write(to:url.appendingPathExtension("backup"),options:.atomic)
        }
        try data.write(to:url,options:.atomic)
    }
    static func library(_ base:URL)->[StoredProgress] {
        let urls=(try? fm.contentsOfDirectory(at:base,includingPropertiesForKeys:nil,options:.skipsHiddenFiles)) ?? []
        return urls.compactMap { folder in
            guard UUID(uuidString:folder.lastPathComponent) != nil else{return nil}
            let file=folder.appendingPathComponent("進度.glyphcheck")
            guard let document=try? read(file) else{return nil}
            let session=document.session
            let date=(try? fm.attributesOfItem(atPath:file.path)[.modificationDate] as? Date) ?? .distantPast
            let reviewed=session.domain.filter {cp in session.fonts.allSatisfy {f in f.visible[String(cp)] != true || ["correct","mismatch","variant"].contains(session.answers[f.id]?[String(cp)]?.kind ?? "")}}.count
            return StoredProgress(id:folder.lastPathComponent,title:title(session),date:date,url:file,reviewed:reviewed,total:session.domain.count)
        }.sorted{$0.date>$1.date}
    }
    static func source(_ font:FontRecord,in document:ProgressDocument)throws->URL? {
        let url:URL
        if document.packaged {
            guard !font.source.hasPrefix("/"),!font.source.split(separator:"/").contains("..") else{throw CocoaError(.fileReadCorruptFile)}
            url=document.root.appendingPathComponent(font.source).resolvingSymlinksInPath()
            guard url.path.hasPrefix(document.root.resolvingSymlinksInPath().path+"/") else{throw CocoaError(.fileReadCorruptFile)}
        } else {url=font.source.hasPrefix("/") ? URL(fileURLWithPath:font.source) : document.root.appendingPathComponent(font.source)}
        return fm.fileExists(atPath:url.path) ? url : nil
    }
    static func verify(_ url:URL,for font:FontRecord)throws {
        let data=try bounded(url,limit:256*1024*1024)
        let sha=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
        guard sha==font.sha256 else{throw NSError(domain:"Progress",code:1,userInfo:[NSLocalizedDescriptionKey:"字檔與原進度不符，請選擇相同的原字檔。"])}
    }
    static func export(_ session:Session,to url:URL,includeFonts:Bool)throws {
        var output=session;output.uiLanguage=nil
        var files:[String:FileWrapper]=[:]
        func portable(_ record:FontRecord)throws->FontRecord {
            var f=record
            guard f.id.range(of:#"^[A-Za-z0-9_-]{1,80}$"#,options:.regularExpression) != nil else{throw CocoaError(.fileReadCorruptFile)}
            let ext=URL(fileURLWithPath:f.source).pathExtension.lowercased()
            guard ["ttf","otf","ttc","otc"].contains(ext) else{throw CocoaError(.fileReadCorruptFile)}
            let name=f.id+"."+ext
            if includeFonts {let source=URL(fileURLWithPath:f.source);try verify(source,for:f);files[name]=FileWrapper(regularFileWithContents:try bounded(source,limit:256*1024*1024))}
            f.source="Fonts/"+name;f.preview="";f.filename=URL(fileURLWithPath:f.filename).lastPathComponent
            return f
        }
        output.fonts=try session.fonts.map(portable)
        output.repairSources=try session.repairSources?.map(portable)
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        let manifest=try JSONSerialization.data(withJSONObject:["format":"GlyphCheck.progress.v1","includesFonts":includeFonts],options:.sortedKeys)
        let package=FileWrapper(directoryWithFileWrappers:["Session.json":FileWrapper(regularFileWithContents:try encoder.encode(output)),"Manifest.json":FileWrapper(regularFileWithContents:manifest),"Fonts":FileWrapper(directoryWithFileWrappers:files)])
        try package.write(to:url,options:.atomic,originalContentsURL:nil)
    }
}

extension Checker {
    func showProgressLibrary() {guard !busy,!autoRunning else{return};persistDrafts();guard save() else{return};storedProgress=ProgressStore.library(base);showProgress=true}
    func renameProgress(_ item:StoredProgress,_ name:String) {
        do {
            var document=try ProgressStore.read(item.url);document.session.title=String(name.trimmingCharacters(in:.whitespacesAndNewlines).prefix(100))
            try ProgressStore.save(document.session,to:item.url)
            if item.id==session.id {session.title=document.session.title}
            storedProgress=ProgressStore.library(base)
        } catch {self.error=error.localizedDescription}
    }
    func exportProgress(share:Bool=false) {
        guard !busy,!autoRunning,!session.fonts.isEmpty else{return}
        persistDrafts();save()
        let panel=NSSavePanel();panel.title=t(share ? "分享檢查進度" : "匯出檢查進度")
        panel.allowedContentTypes=[UTType(filenameExtension:"glyphcheck") ?? .package]
        let name=ProgressStore.title(session).replacingOccurrences(of:"/",with:"-").replacingOccurrences(of:":",with:"-")
        panel.nameFieldStringValue=String(name.prefix(80))+".glyphcheck"
        let include=NSButton(checkboxWithTitle:t("包含原字檔（請確認有權分享）"),target:nil,action:nil);include.state = .off
        let view=NSView(frame:NSRect(x:0,y:0,width:430,height:75));include.frame=NSRect(x:0,y:45,width:430,height:24)
        let text=NSTextField(wrappingLabelWithString:t("預設只含判定、註記與進度，不含字檔。接收者需選擇相同原檔；文章與註記可能包含私人內容。"));text.frame=NSRect(x:0,y:0,width:430,height:43);text.font = .systemFont(ofSize:11);text.textColor = .secondaryLabelColor
        view.addSubview(include);view.addSubview(text);panel.accessoryView=view
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do {
            try ProgressStore.export(session,to:url,includeFonts:include.state == .on)
            status="進度已匯出；原進度仍由 App 管理。"
            if share,let anchor=NSApp.keyWindow?.contentView {let picker=NSSharingServicePicker(items:[url]);progressSharePicker=picker;picker.show(relativeTo:NSRect(x:anchor.bounds.maxX-40,y:anchor.bounds.maxY-40,width:1,height:1),of:anchor,preferredEdge:.minY)}
            else {NSWorkspace.shared.activateFileViewerSelecting([url])}
        } catch {self.error=error.localizedDescription}
    }
    func adoptProgress(_ url:URL)async throws->Session {
        let document=try ProgressStore.read(url)
        progressRecovered=document.recovered
        let expected=base.appendingPathComponent(document.session.id).appendingPathComponent("進度.glyphcheck")
        let managedRoot=expected.deletingLastPathComponent().resolvingSymlinksInPath().path+"/"
        let owned=(document.session.fonts+(document.session.repairSources ?? [])).allSatisfy {URL(fileURLWithPath:$0.source).resolvingSymlinksInPath().path.hasPrefix(managedRoot) && URL(fileURLWithPath:$0.preview).resolvingSymlinksInPath().path.hasPrefix(managedRoot) && FileManager.default.fileExists(atPath:$0.preview)}
        if !document.packaged,owned,UUID(uuidString:document.session.id) != nil,url.standardizedFileURL==expected.standardizedFileURL {
            for f in document.session.fonts+(document.session.repairSources ?? []) {try ProgressStore.verify(URL(fileURLWithPath:f.source),for:f)}
            return document.session
        }
        var imported=document.session;imported.id=UUID().uuidString
        let target=base.appendingPathComponent(imported.id,isDirectory:true)
        let pending=base.appendingPathComponent(".Import-"+imported.id,isDirectory:true)
        try FileManager.default.createDirectory(at:pending,withIntermediateDirectories:true)
        do {
            let cached=ProgressStore.library(base).compactMap{try? ProgressStore.read($0.url).session}.flatMap{$0.fonts+($0.repairSources ?? [])}
            func importFont(_ old:FontRecord)async throws->FontRecord {
                var original=try ProgressStore.source(old,in:document)
                if original==nil {original=cached.first(where:{$0.sha256==old.sha256}).map{URL(fileURLWithPath:$0.source)}}
                if original==nil {
                    let panel=NSOpenPanel();panel.title=t("選擇相同的原字檔")+"："+old.filename
                    panel.allowedContentTypes=["ttf","otf","ttc","otc"].compactMap{UTType(filenameExtension:$0)}
                    guard panel.runModal() == .OK,let selected=panel.url else{throw CocoaError(.userCancelled)};original=selected
                }
                try ProgressStore.verify(original!,for:old)
                let data=try await run(["inspect",original!.path,pending.appendingPathComponent("Fonts").path])
                let inspected=try JSONDecoder().decode(ImportResult.self,from:data)
                guard var fresh=inspected.fonts.first(where:{$0.face==old.face}) else{throw CocoaError(.fileReadCorruptFile)}
                guard let provider=CGDataProvider(url:URL(fileURLWithPath:fresh.preview) as CFURL),CGFont(provider) != nil else{throw CocoaError(.fileReadCorruptFile)}
                fresh.id=old.id;fresh.filename=old.filename
                fresh.source=target.path+String(fresh.source.dropFirst(pending.path.count));fresh.preview=target.path+String(fresh.preview.dropFirst(pending.path.count))
                return fresh
            }
            var fonts:[FontRecord]=[];for f in imported.fonts {fonts.append(try await importFont(f))};imported.fonts=fonts
            var donors:[FontRecord]=[];for f in imported.repairSources ?? [] {donors.append(try await importFont(f))};imported.repairSources=donors
            try ProgressStore.save(imported,to:pending.appendingPathComponent("進度.glyphcheck"))
            try FileManager.default.moveItem(at:pending,to:target)
            return imported
        } catch {
            try? FileManager.default.trashItem(at:pending,resultingItemURL:nil)
            throw error
        }
    }
}

@MainActor struct ProgressLibraryView:View {
    @EnvironmentObject var m:Checker
    @State var selected=""
    @State var name=""
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {Text(m.t("我的檢查進度")).font(.title2.bold());Spacer();Button(m.t("完成")){m.showProgress=false}}
            Text(m.t("進度自動保存在 App 的資料夾；匯出時才建立另外的檔案。")).font(.callout).foregroundStyle(.secondary)
            List(selection:$selected) {ForEach(m.storedProgress) {item in
                VStack(alignment:.leading,spacing:5) {Text(item.title).font(.headline);Text(item.date.formatted(date:.abbreviated,time:.shortened)+" · \(item.reviewed)/\(item.total)").font(.caption).foregroundStyle(.secondary)}.padding(.vertical,5).tag(item.id)
            }}.overlay {if m.storedProgress.isEmpty {Text(m.t("尚無保存的檢查進度。")).foregroundStyle(.secondary)}}
            if let item=m.storedProgress.first(where:{$0.id==selected}) {
                HStack {TextField(m.t("進度名稱"),text:$name).textFieldStyle(.roundedBorder);Button(m.t("重新命名")){m.renameProgress(item,name)};Button(m.t("繼續檢查")){m.showProgress=false;m.openSession(item.url)}.buttonStyle(.borderedProminent)}
            }
            HStack {Button(m.t("匯入進度…")){m.showProgress=false;m.openSession()};Spacer();Label(m.t("自動保存，並保留上一份備份"),systemImage:"checkmark.shield").font(.caption).foregroundStyle(.secondary)}
        }.padding(24).frame(width:650,height:460).onChange(of:selected){_,value in name=m.storedProgress.first(where:{$0.id==value})?.title ?? ""}
    }
}
