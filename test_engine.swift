import Foundation
import AppKit

@main struct EngineTests {
    @MainActor static func main() throws {
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
        print("PASS: English, Latin scopes, reviewer conflicts, idempotence, reconciliation undo, invalid tasks, CoreText proof rendering")
        print("PASS: quick confirmation, mismatch priority, undo, input validation, checkpoint, random sampling, script filters, UI conversion, issue navigation, missing issues, legacy session")
    }
}
