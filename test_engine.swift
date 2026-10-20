import Foundation
import AppKit
import CryptoKit

final class UpdateFixtureProtocol:URLProtocol {
    static var payload=Data()
    static var status=200
    static var fail=false
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        if Self.fail {client?.urlProtocol(self,didFailWithError:URLError(.notConnectedToInternet));return}
        let response=HTTPURLResponse(url:request.url!,statusCode:Self.status,httpVersion:"HTTP/1.1",headerFields:[:])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Self.payload);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct EngineTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GlyphCheck-tests-" + UUID().uuidString)
        let m = Checker(storageRoot: root,persistRecent: false)
        func record(_ id: String) -> FontRecord {
            FontRecord(id: id,name: id,filename: "test.ttf",source: "test",preview: "test",face: 0,sha256: "fixture",glyphs: ["65":1,"66":2,"67":3],visible: ["65":true,"66":true,"67":true],notes: [],upem: 1000)
        }
        let a = record("A"),b = record("B")
        func reset() {
            m.session = Session(); m.session.fonts = [a,b]; m.session.domain = [65,66,67]
            m.session.remaining = [67,66]; m.session.current = 65; m.session.started = true
            m.drafts = [:]; m.typed = [:]; m.undoStack = []; m.error = nil
        }
        reset(); m.quickAdvance()
        precondition(m.session.current == 66 && m.session.answers["A"]?["65"]?.kind == "correct" && m.session.answers["B"]?["65"]?.kind == "correct")
        m.quickAdvance(); precondition(m.session.current == 67)
        m.quickAdvance(); precondition(m.session.current == nil && m.completed == 3)
        reset(); m.typed["A"] = "B"; m.quickAdvance()
        precondition(m.session.current == 66 && m.session.answers["A"]?["65"]?.actual == "B" && m.session.answers["B"]?["65"]?.kind == "correct")
        m.undo(); precondition(m.session.current == 65 && m.session.answers["A"]?["65"] == nil)
        reset(); m.typed["A"] = "AB"; m.quickAdvance()
        precondition(m.session.current == 65 && m.error != nil && m.session.answers.isEmpty)
        reset(); m.drafts["A"] = Answer(kind: "uncertain"); m.quickAdvance()
        precondition(m.session.answers["A"]?["65"]?.kind == "uncertain")
        reset(); m.typed["A"] = "A"; m.quickAdvance(); precondition(m.session.answers["A"]?["65"]?.kind == "correct")
        let checkpoint = try JSONDecoder().decode(Session.self,from: Data(contentsOf: m.saveURL))
        precondition(checkpoint.current == m.session.current && checkpoint.answers == m.session.answers)
        let selected = try Selection.make(fonts: [a,b],scope: "字檔所有字元",custom: "",variant: "all",sampleSize: 2)
        precondition(selected.population.count == 3 && selected.selected.count == 2 && Set(selected.selected).count == 2)
        do { _ = try Selection.make(fonts: [a],scope: "字檔所有字元",custom: "",variant: "all",sampleSize: 4); preconditionFailure("Oversized sample must fail") } catch {}
        do { _ = try Selection.make(fonts: [a],scope: "字檔所有字元",custom: "",variant: "all",sampleSize: 0); preconditionFailure("Zero sample must fail") } catch {}
        precondition(Selection.allows(0x66f8,variant: "traditional") && !Selection.allows(0x66f8,variant: "simplified"))
        precondition(!Selection.allows(0x4e66,variant: "traditional") && Selection.allows(0x4e66,variant: "simplified"))
        precondition(Selection.allows(0x4e00,variant: "traditional") && Selection.allows(0x4e00,variant: "simplified"))
        m.uiLanguage = "simplified"; precondition(m.t("匯出目前建議") == "汇出目前建议")
        reset(); m.drafts["A"] = Answer(kind: "mismatch",actual: "B")
        precondition(m.knownIssues.contains { $0.cp == 65 && $0.kind == "mismatch" })
        m.visit(66); precondition(m.session.current == 66 && m.session.answers["A"]?["65"]?.actual == "B" && m.session.remaining.contains(65))
        m.session.fonts[0].visible["67"] = false
        precondition(m.knownIssues.contains { $0.cp == 67 && $0.kind == "missing" })
        reset(); m.typed["A"] = "B"; m.mark(a,"correct"); m.quickAdvance()
        precondition(m.session.answers["A"]?["65"]?.kind == "correct" && m.typed["A"] != "B")
        let old = #"{"version":1,"id":"legacy","fonts":[],"scope":"old","domain":[65],"remaining":[],"answers":{},"followed":[],"referenceDoubts":[],"started":false}"#
        let legacy = try JSONDecoder().decode(Session.self,from: Data(old.utf8))
        precondition(legacy.population == nil && legacy.reviewMode == nil && legacy.uiLanguage == nil)
        m.uiLanguage = "english"; precondition(m.t("詞句檢查") == "Text proof")
        precondition(m.t("已匯入 2 個字檔。") == "Imported 2 fonts.")
        precondition(pinyin(65).contains("LATIN CAPITAL LETTER A"))
        let latin = try Selection.make(fonts:[a],scope:"英文／基本拉丁",custom:"",variant:"all",sampleSize:nil)
        precondition(latin.population.count == 94 && latin.population.contains(97))
        let accents = try Selection.make(fonts:[a],scope:"拉丁字母與重音",custom:"",variant:"all",sampleSize:nil)
        precondition(accents.population.contains(233))
        reset(); m.session.fonts[1].sha256 = "fixture-B"
        let foreign = ReviewPackage(reviewer:"Alex",domain:[65,66],fonts:[TaskFont(sha256:"fixture",face:0,answers:["65":Answer(kind:"mismatch",actual:"B")])],referenceDoubts:[])
        m.session.answers["A"] = ["65":Answer(kind:"correct")]
        try m.mergeReview(foreign)
        precondition(m.session.reviewConflicts?["A"]?["65"]?.count == 2)
        precondition(m.completed == 0)
        let imports = m.session.importedTasks!.count; try m.mergeReview(foreign)
        precondition(m.session.importedTasks!.count == imports)
        m.session.current = 65; m.loadDrafts(); m.quickAdvance()
        precondition(m.session.reviewConflicts?["A"]?["65"] == nil)
        m.undo(); precondition(m.session.reviewConflicts?["A"]?["65"]?.count == 2)
        var wrong = foreign; wrong.fonts[0].sha256 = "wrong"
        do { try m.mergeReview(wrong); preconditionFailure("Wrong original must be rejected") } catch {}
        wrong = foreign; wrong.fonts[0].answers["99"] = Answer(kind:"correct")
        do { try m.mergeReview(wrong); preconditionFailure("Out-of-task answer must be rejected") } catch {}
        wrong = foreign; wrong.fonts[0].answers["65"] = Answer(kind:"mismatch",actual:"AB")
        do { try m.mergeReview(wrong); preconditionFailure("Invalid character must be rejected") } catch {}
        let view = ProofCanvas(frame:NSRect(x:0,y:0,width:400,height:240))
        view.font = CTFontCreateWithName("Helvetica" as CFString,36,nil); view.text = "AV To fi fl Il1 O0 漢字 😀"
        let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds)!
        view.cacheDisplay(in:view.bounds,to:bitmap)
        precondition(bitmap.pixelsWide > 0)
        precondition(CharacterList.parse("U+0041\nU+0041\nU+20000") == [65,0x20000])
        precondition(CharacterList.parse("常常 A\nB") == [65,66,0x5e38])
        do { try CharacterList(name:"bad",characters:[0xd800]).validate(); preconditionFailure("Invalid scalar list") } catch {}
        try m.storeCharacterList(CharacterList(name:"Sample",characters:[65,66]))
        let restored = Checker(storageRoot:root,persistRecent:false)
        precondition(restored.characterSets.count==1 && m.custom=="AB")
        m.chooseGoal("text");precondition(m.scope=="自訂文字")
        reset();m.mark(a,"variant");m.quickAdvance()
        precondition(m.session.answers["A"]?["65"]?.kind=="variant" && m.completed==0)
        precondition(m.knownIssues.contains { $0.kind=="variant" })
        reset();m.session.reviewMode="priority";m.session.fonts[0].scan=[ScanIssue(cp:67,kind:"duplicate",detail:"fixture")]
        m.session.answers["A"]=["65":Answer(kind:"mismatch",actual:"B")]
        precondition(ReviewQueue.make(session:m.session,characters:[65,66,67]).last==66)
        m.session.referenceDoubts=[67]
        precondition(ReviewQueue.make(session:m.session,characters:[65,66,67]).last==67)
        m.session.reviewMode="sample";m.session.sampled=[65,66];m.prioritizePending()
        precondition(m.session.reviewMode=="sample" && m.session.sampled==[65,66] && m.session.queueMode=="priority")
        let candidate = RepairSuggestion(character:"A",donor:"B",fingerprint:"evidence",decision:"pending")
        m.previewResult=RepairResult(output:"fixture",fonts:[RepairFont(id:"A",font:"A",output:nil,suggestions:[candidate],relationships:[])])
        precondition(!m.hasAcceptedRepairs)
        m.acceptRepair(font:"A",suggestion:candidate,decision:"accepted");precondition(m.hasAcceptedRepairs)
        var changed=candidate;changed.fingerprint="changed"
        precondition(m.approvalDecision(font:"A",suggestion:changed)=="pending")
        m.acceptRepair(font:"A",suggestion:candidate,decision:"excluded");precondition(!m.hasAcceptedRepairs)
        reset();m.chooseGoal("text");m.custom="U+0041";m.setStrategy("full");m.start()
        while m.busy { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(m.session.inputText=="U+0041" && m.session.domain.contains(85) && !m.session.domain.contains(65))
        precondition(m.session.taskGoal=="text" && m.session.reviewMode=="full")
        let left=ProofScroll(frame:NSRect(x:0,y:0,width:300,height:220)),right=ProofScroll(frame:NSRect(x:0,y:0,width:300,height:220))
        for view in [left,right] {
            view.canvas.font=CTFontCreateWithName("Helvetica" as CFString,24,nil)
            view.canvas.text=(1...60).map { "Paragraph \($0): long article selection and scroll comparison." }.joined(separator:"\n\n")
            view.canvas.size=24; view.group="unit-scroll"; view.resizeProof()
            precondition(view.canvas.bounds.height>2200)
        }
        left.canvas.selection=NSRange(location:30,length:20);left.broadcast(range:left.canvas.selection)
        precondition(right.canvas.selection==left.canvas.selection)
        left.contentView.scroll(to:NSPoint(x:0,y:left.canvas.bounds.height/2));left.broadcast()
        let li=left.canvas.index(at:NSPoint(x:14,y:left.contentView.bounds.maxY-18))
        let ri=right.canvas.index(at:NSPoint(x:14,y:right.contentView.bounds.maxY-18))
        precondition(abs(li-ri)<100)
        precondition(left.canvas.scrollY(for:0)>left.canvas.scrollY(for:1000))
        print("PASS: complete long-article layout, bidirectional scroll anchor and synchronized selection")
        let auditRow=GlyphAuditRow(id:"group:A",list:"demo",name:"A",codepoint:"U+0041",character:"A",glyph:"A",glyphID:1,present:true,status:"pending",reason:"fixture",fingerprint:"test",decision:"",note:"")
        m.glyphAudit=GlyphAuditResult(fonts:[GlyphAuditFont(id:"A",font:"demo",sha256:"test",rows:[auditRow])])
        m.judgeGlyph("A",auditRow,"correct",note:"confirmed")
        precondition(m.glyphAudit?.fonts[0].rows[0].status=="found")
        let persisted=try JSONDecoder().decode(Session.self,from:Data(contentsOf:m.saveURL))
        precondition(persisted.glyphReviews?["A"]?["group:A"]?.note=="confirmed")
        m.judgeGlyph("A",auditRow,"issue");precondition(m.glyphAudit?.fonts[0].rows[0].status=="pending")
        print("PASS: glyph-name audit review, issue flags and persisted notes")
        let agree=GlyphOCR.classify(expected:"常",first:("常",0.9),second:("常",0.8),fingerprint:"ocr")
        precondition(agree.kind=="agree")
        precondition(GlyphOCR.classify(expected:"常",first:("悄",0.9),second:("悄",0.8),fingerprint:"ocr").kind=="uncertain")
        precondition(GlyphOCR.classify(expected:"常",first:("悄",0.9),second:("悄",0.8),fingerprint:"ocr",third:("悄",0.85),shapeSupported:true).kind=="mismatch")
        precondition(GlyphOCR.classify(expected:"常",first:("悄",0.9),second:("悄",0.8),fingerprint:"ocr",third:("常",0.85),shapeSupported:true).kind=="uncertain")
        precondition(GlyphOCR.classify(expected:"常",first:("",0),second:("常",0.8),fingerprint:"ocr").kind=="unreadable")
        precondition(GlyphOCR.classify(expected:"常",first:("常",0.3),second:("常",0.8),fingerprint:"ocr").kind=="agree")
        for character in ["丙","与","%","1","u"] {
            precondition(GlyphOCR.classify(expected:character,first:(character,0.3),second:(character,0.5),fingerprint:"screenshot").kind=="agree")
        }
        precondition(GlyphOCR.classify(expected:"u",first:("n",0.99),second:("n",0.99),fingerprint:"orientation",third:("n",0.99),shapeSupported:false).kind=="uncertain")
        let u=referenceGlyph(117,family:"Helvetica"),n=referenceGlyph(110,family:"Helvetica")
        let um=GlyphShape.mask(u.0,CGGlyph(u.1))!,nm=GlyphShape.mask(n.0,CGGlyph(n.1))!
        precondition(GlyphShape.distance(um,um)==0 && GlyphShape.distance(um,nm)>0)
        precondition(!GlyphShape.supports(u.0,CGGlyph(u.1),expected:"u",candidate:"n"))
        precondition(!GlyphShape.supports(n.0,CGGlyph(n.1),expected:"u",candidate:"n"))
        let actualB=referenceGlyph(66,family:"Helvetica")
        precondition(GlyphShape.supports(actualB.0,CGGlyph(actualB.1),expected:"Z",candidate:"B"))
        precondition(GlyphOCR.classify(expected:"常",first:("悄",0.9),second:("常",0.8),fingerprint:"ocr").kind=="uncertain")
        m.session.autoFindings=["A":[auditRow.id:AutoFinding(fingerprint:auditRow.fingerprint,kind:"mismatch",observed:"B",confidence:0.9,reason:"fixture")]]
        precondition(m.autoFinding("A",auditRow)==nil)
        m.session.autoFindings?["A"]?[auditRow.id]?.engineVersion=GlyphOCR.engineVersion
        precondition(m.autoFinding("A",auditRow)?.observed=="B")
        var changedRow=auditRow;changedRow.fingerprint="changed";precondition(m.autoFinding("A",changedRow)==nil)
        m.save();let screenedSession=try JSONDecoder().decode(Session.self,from:Data(contentsOf:m.saveURL));precondition(screenedSession.autoFindings?["A"]?[auditRow.id]?.kind=="mismatch")
        if ProcessInfo.processInfo.environment["GLYPHCHECK_OCR_SMOKE"]=="1" {
            let ref=referenceGlyph(65,family:"Helvetica")
            let one=GlyphOCR.image(ref.0,CGGlyph(ref.1),repeated:false)!,three=GlyphOCR.image(ref.0,CGGlyph(ref.1),repeated:true)!
            let r1=try GlyphOCR.recognize(one),r2=try GlyphOCR.recognize(three)
            print("OCR smoke:",r1,r2,GlyphOCR.classify(expected:"B",first:r1,second:r2,fingerprint:"smoke").kind)
            precondition(r1.0=="A" || r2.0=="A")
            let chinese=referenceGlyph(0x5e38,family:"Kaiti TC")
            let c1=try GlyphOCR.recognize(GlyphOCR.image(chinese.0,CGGlyph(chinese.1),repeated:false)!)
            let c2=try GlyphOCR.recognize(GlyphOCR.image(chinese.0,CGGlyph(chinese.1),repeated:true)!)
            print("OCR Chinese smoke:",c1,c2)
            let c3=try GlyphOCR.recognize(GlyphOCR.image(chinese.0,CGGlyph(chinese.1),count:5,cell:240)!)
            let evidence=GlyphShape.supports(chinese.0,CGGlyph(chinese.1),expected:"悄",candidate:"常")
            print("Wrong-CJK specimen (悄 → 常):",c1,c2,c3,"shape",evidence,GlyphOCR.classify(expected:"悄",first:c1,second:c2,fingerprint:"wrong-cjk",third:c3,shapeSupported:evidence).kind)
            let printed=referenceGlyph(0x5e38,family:"PingFang TC")
            let p1=try GlyphOCR.recognize(GlyphOCR.image(printed.0,CGGlyph(printed.1),repeated:false)!)
            let p2=try GlyphOCR.recognize(GlyphOCR.image(printed.0,CGGlyph(printed.1),repeated:true)!)
            let wrong=GlyphOCR.classify(expected:"悄",first:p1,second:p2,fingerprint:"intentional-wrong-mapping")
            print("OCR intentional wrong mapping (悄 → 常):",p1,p2,wrong.kind,wrong.observed)
            precondition(wrong.kind != "agree")
        }
        if ProcessInfo.processInfo.environment["GLYPHCHECK_OCR_BENCHMARK"]=="1" {
            var totals:[String:Int]=[:];var legacyFlags=0
            for family in ["Kaiti TC","PingFang TC"] {
                for character in ["丙","与","%","u","常","永"] {
                    let ref=referenceGlyph(Int(character.unicodeScalars.first!.value),family:family)
                    let one=try GlyphOCR.recognize(GlyphOCR.image(ref.0,CGGlyph(ref.1),repeated:false)!)
                    let three=try GlyphOCR.recognize(GlyphOCR.image(ref.0,CGGlyph(ref.1),repeated:true)!)
                    var five:(String,Double)?=nil;var supported=false
                    if one.0==three.0,one.0 != character,min(one.1,three.1)>=GlyphOCR.candidateFloor {
                        five=try GlyphOCR.recognize(GlyphOCR.image(ref.0,CGGlyph(ref.1),count:5,cell:240)!)
                        supported=GlyphShape.supports(ref.0,CGGlyph(ref.1),expected:character,candidate:one.0)
                    }
                    let result=GlyphOCR.classify(expected:character,first:one,second:three,fingerprint:"benchmark",third:five,shapeSupported:supported)
                    totals[result.kind,default:0]+=1
                    if one.0 != character || three.0 != character || min(one.1,three.1)<0.55 {legacyFlags+=1}
                    print("Ground-truth specimen:",family,character,one,three,result.kind)
                    precondition(result.kind != "mismatch","Known-correct specimen flagged")
                }
            }
            print("Ground-truth totals (not a general accuracy benchmark):",totals,"old flags",legacyFlags)
        }
        print("PASS: conservative OCR classification, no automatic acceptance, and evidence-bound persistence")
        func release(_ tag:String="v1.5.0",_ url:String="https://github.com/lancer1234/GlyphCheck/releases/tag/v1.5.0",draft:Bool=false,prerelease:Bool=false)->Data {
            try! JSONSerialization.data(withJSONObject:["tag_name":tag,"html_url":url,"draft":draft,"prerelease":prerelease])
        }
        precondition(AppVersion("v1.10.0")!>AppVersion("1.9.9")!)
        precondition(AppVersion("1.5.0")!>AppVersion("1.5.0-preview.1")!)
        precondition(AppVersion("1.5.0-preview.10")!>AppVersion("1.5.0-preview.2")!)
        precondition(AppVersion("bad")==nil && AppVersion("1.2")==nil && AppVersion("01.2.3")==nil)
        let newer=try ReleaseUpdates.interpret(release(),status:200,current:"1.5.0-preview.1")
        let equal=try ReleaseUpdates.interpret(release(),status:200,current:"1.5.0")
        let older=try ReleaseUpdates.interpret(release(),status:200,current:"1.6.0")
        let absent=try ReleaseUpdates.interpret(Data(),status:404,current:"1.5.0")
        precondition(newer == .available("v1.5.0",URL(string:"https://github.com/lancer1234/GlyphCheck/releases/tag/v1.5.0")!))
        precondition(equal == .current && older == .current && absent == .noRelease)
        for (data,status) in [(release("v1.5.0","https://example.com/evil"),200),(release(draft:true),200),(release(prerelease:true),200),(Data("bad".utf8),200),(Data(),403),(Data(),429),(Data(),500)] {
            do {_=try ReleaseUpdates.interpret(data,status:status,current:"1.4.0");preconditionFailure("Unsafe update accepted")}catch {}
        }
        print("PASS: stable-release ordering, prerelease-to-stable, no downgrades, invalid/foreign releases and HTTP errors")
        let updateConfig=URLSessionConfiguration.ephemeral;updateConfig.protocolClasses=[UpdateFixtureProtocol.self]
        let updateSession=URLSession(configuration:updateConfig)
        UpdateFixtureProtocol.payload=release()
        let fetched=try await ReleaseUpdates.fetch(current:"1.4.0",session:updateSession)
        precondition(fetched==newer)
        UpdateFixtureProtocol.fail=true
        do {_=try await ReleaseUpdates.fetch(current:"1.4.0",session:updateSession);preconditionFailure("Offline request reported success")}catch {}
        updateSession.invalidateAndCancel()
        if ProcessInfo.processInfo.environment["GLYPHCHECK_UPDATE_SMOKE"]=="1" {
            print("GitHub live update check:",try await ReleaseUpdates.fetch(current:"1.5.0-preview.1"))
        }
        print("PASS: URLSession update transport and offline-error handling")
        precondition(InterfaceLanguage.initial(saved:nil,preferred:["zh-TW"])=="traditional")
        precondition(InterfaceLanguage.initial(saved:nil,preferred:["zh-Hant-CN"])=="traditional")
        precondition(InterfaceLanguage.initial(saved:nil,preferred:["zh-Hans-HK"])=="simplified")
        precondition(InterfaceLanguage.initial(saved:nil,preferred:["zh-CN"])=="simplified")
        precondition(InterfaceLanguage.initial(saved:nil,preferred:["fr-FR","en-GB"])=="english")
        precondition(InterfaceLanguage.initial(saved:"simplified",preferred:["en-US"])=="simplified")
        precondition(InterfaceLanguage.initial(saved:"bad",preferred:["ja-JP"])=="english")
        let firstLaunch=Checker(storageRoot:root.appendingPathComponent("first-launch"),persistRecent:false,preferredLanguages:["en-US"])
        precondition(firstLaunch.uiLanguage=="english")
        firstLaunch.save();precondition(!FileManager.default.fileExists(atPath:firstLaunch.saveURL.path))
        var progress=Session();progress.fonts=[a];progress.title="Repair Review";progress.answers=["A":["65":Answer(kind:"mismatch",actual:"B")]];progress.uiLanguage="traditional"
        let original=root.appendingPathComponent("source.ttf");let originalData=Data("test font bytes".utf8)
        try originalData.write(to:original)
        progress.fonts[0].source=original.path;progress.fonts[0].preview=root.appendingPathComponent("source.preview.otf").path
        progress.fonts[0].sha256=SHA256.hash(data:originalData).map{String(format:"%02x",$0)}.joined()
        let internalFile=root.appendingPathComponent(progress.id).appendingPathComponent("進度.glyphcheck")
        try ProgressStore.save(progress,to:internalFile)
        progress.title="Renamed";try ProgressStore.save(progress,to:internalFile)
        try Data("damaged JSON".utf8).write(to:internalFile)
        let recovered=try ProgressStore.read(internalFile)
        precondition(recovered.recovered && recovered.session.title=="Repair Review")
        try ProgressStore.save(progress,to:internalFile)
        let packed=root.appendingPathComponent("portable.glyphcheck")
        try ProgressStore.export(progress,to:packed,includeFonts:true)
        let moved=root.appendingPathComponent("moved.glyphcheck");try FileManager.default.moveItem(at:packed,to:moved)
        let portable=try ProgressStore.read(moved)
        precondition(portable.packaged && portable.session.fonts[0].preview.isEmpty && portable.session.uiLanguage==nil)
        let embedded=try ProgressStore.source(portable.session.fonts[0],in:portable)!
        try ProgressStore.verify(embedded,for:portable.session.fonts[0])
        let light=root.appendingPathComponent("without-fonts.glyphcheck");try ProgressStore.export(progress,to:light,includeFonts:false)
        let lightDoc=try ProgressStore.read(light)
        let excluded=try ProgressStore.source(lightDoc.session.fonts[0],in:lightDoc)
        precondition(excluded==nil)
        precondition(lightDoc.session.answers==progress.answers)
        var unsafe=lightDoc.session.fonts[0];unsafe.source="../source.ttf"
        do {_=try ProgressStore.source(unsafe,in:lightDoc);preconditionFailure("Traversal accepted")}catch {}
        unsafe.source="Fonts/link.ttf";try FileManager.default.createSymbolicLink(at:light.appendingPathComponent(unsafe.source),withDestinationURL:original)
        do {_=try ProgressStore.source(unsafe,in:lightDoc);preconditionFailure("External symlink accepted")}catch {}
        var badHash=progress.fonts[0];badHash.sha256=String(repeating:"0",count:64)
        do {try ProgressStore.verify(original,for:badHash);preconditionFailure("Wrong original accepted")}catch {}
        precondition(ProgressStore.library(root).contains(where:{$0.id==progress.id && $0.title=="Renamed"}))
        print("PASS: system-language selection, explicit preference, no empty projects, backup recovery, movable bundles, font-free sharing, hash and path protection")
        reset();m.typed["A"]="B";m.save();let pending=try ProgressStore.read(m.saveURL)
        precondition(pending.session.pendingInputs?["A"]=="B" && pending.session.answers["A"]?["65"]==nil)
        m.typed=[:];m.loadDrafts();precondition(m.typed["A"]=="B")
        m.session.started=false;m.scope="自訂文字";m.custom="準備中的文章";m.taskGoal="text";m.save()
        let preparing=try ProgressStore.read(m.saveURL);precondition(preparing.session.inputText=="準備中的文章" && preparing.session.scope=="自訂文字")
        if let resources=ProcessInfo.processInfo.environment["GLYPHCHECK_TEST_RESOURCES"],let fontPath=ProcessInfo.processInfo.environment["GLYPHCHECK_TEST_FONT"] {
            let importer=Checker(storageRoot:root.appendingPathComponent("imported"),persistRecent:false,preferredLanguages:["en-US"],resourceRoot:URL(fileURLWithPath:resources))
            let parsed=try JSONDecoder().decode(ImportResult.self,from:try await importer.run(["inspect",fontPath,root.appendingPathComponent("real-font").path]))
            var actual=Session();actual.fonts=[parsed.fonts[0]];actual.title="Portable Review";actual.current=65;actual.domain=[65,66];actual.answers=[actual.fonts[0].id:["65":Answer(kind:"mismatch",actual:"B")]];actual.uiLanguage="simplified"
            let package=root.appendingPathComponent("real.glyphcheck");try ProgressStore.export(actual,to:package,includeFonts:true)
            let adopted=try await importer.adoptProgress(package)
            precondition(adopted.id != actual.id && adopted.fonts[0].source.hasPrefix(importer.base.path) && adopted.answers==actual.answers && adopted.fonts[0].id==actual.fonts[0].id)
            precondition(FileManager.default.fileExists(atPath:adopted.fonts[0].preview))
            let without=root.appendingPathComponent("real-light.glyphcheck");try ProgressStore.export(actual,to:without,includeFonts:false)
            let linked=try await importer.adoptProgress(without)
            precondition(linked.id != adopted.id && linked.answers==actual.answers && importer.uiLanguage=="english")
            importer.openSession(importer.base.appendingPathComponent(linked.id).appendingPathComponent("進度.glyphcheck"))
            while importer.busy {try await Task.sleep(nanoseconds:10_000_000)}
            precondition(importer.error==nil && importer.session.id==linked.id && importer.uiLanguage=="english")
            print("PASS: real-font bundle import, rebuilt previews, managed copies, hash-matched font-free import and app-language isolation")
        }
        print("PASS: saved character lists, Unicode lists, task goals, possible variants, priority tiers, sample provenance and repair acceptance")
        print("PASS: English, Latin scopes, reviewer conflicts, idempotence, reconciliation undo, invalid tasks, CoreText proof rendering")
        print("PASS: quick confirmation, mismatch priority, undo, input validation, checkpoint, random sampling, script filters, UI conversion, issue navigation, missing issues, legacy session")
    }
}
