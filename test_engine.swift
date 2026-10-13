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
        print("PASS: quick confirmation, mismatch priority, undo, input validation, checkpoint, random sampling, script filters, UI conversion, issue navigation, missing issues, legacy session")
    }
}
