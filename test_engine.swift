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
        print("PASS: repeated confirmation, mismatch priority, undo, invalid input, uncertainty, same-character input, checkpoint")
    }
}
