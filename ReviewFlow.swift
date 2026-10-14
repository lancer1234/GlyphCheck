import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CharacterList: Codable, Identifiable {
    var format = "GlyphCheck.charset.v1"
    var id = UUID().uuidString
    var name: String
    var characters: [Int]
    static func parse(_ text:String,codepointLines:Bool=true) -> [Int] {
        let text=text.trimmingCharacters(in:CharacterSet(charactersIn:"\u{FEFF}"))
        let lines = text.split(whereSeparator:\.isNewline).map { $0.trimmingCharacters(in:.whitespaces) }.filter { !$0.isEmpty }
        let pattern = #"(?i)^(U\+|0x)[0-9a-f]{4,6}$"#
        let numeric = codepointLines && !lines.isEmpty && lines.allSatisfy { $0.range(of:pattern,options:.regularExpression) != nil }
        let values = numeric ? lines.compactMap { Int(String($0.dropFirst(2)),radix:16) } : text.unicodeScalars.map { Int($0.value) }
        return Set(values.filter(reviewable)).sorted()
    }
    func validate() throws {
        guard format == "GlyphCheck.charset.v1", !name.isEmpty, name.count <= 200, !characters.isEmpty,
              characters.count <= 1000000, Set(characters).count == characters.count,
              characters.allSatisfy(reviewable) else { throw CocoaError(.fileReadCorruptFile) }
    }
}

struct ReviewQueue {
    static func score(_ cp:Int,session:Session) -> Int {
        let key=String(cp)
        if session.referenceDoubts.contains(cp) || session.fonts.contains(where:{ session.reviewConflicts?[$0.id]?[key] != nil }) { return 100 }
        if session.fonts.contains(where:{ f in (session.answers[f.id] ?? [:]).values.contains { $0.kind == "mismatch" && $0.actual == char(cp) } }) { return 90 }
        if session.fonts.contains(where:{ ($0.scan ?? []).contains { $0.cp == cp } }) { return 80 }
        if (session.inputText ?? "").contains(char(cp)) { return 60 }
        return 0
    }
    static func make(session:Session,characters:[Int]) -> [Int] {
        let mixed=Array(Set(characters)).shuffled()
        guard (session.queueMode ?? session.reviewMode) == "priority" else { return mixed }
        let conflicts=Set(session.referenceDoubts).union((session.reviewConflicts ?? [:]).values.flatMap { $0.keys.compactMap(Int.init) })
        let targets=Set(session.fonts.flatMap { (session.answers[$0.id] ?? [:]).values.filter { $0.kind=="mismatch" }.compactMap { $0.actual.unicodeScalars.first.map { Int($0.value) } } })
        let flags=Set(session.fonts.flatMap { ($0.scan ?? []).map(\.cp) })
        let text=Set((session.inputText ?? "").unicodeScalars.map { Int($0.value) })
        // The next question is popped from the end. Preserve random order within tiers.
        let scored=mixed.enumerated().map { index,cp in (index,cp,conflicts.contains(cp) ? 100 : targets.contains(cp) ? 90 : flags.contains(cp) ? 80 : text.contains(cp) ? 60 : 0) }
        return scored.sorted { $0.2 == $1.2 ? $0.0 < $1.0 : $0.2 < $1.2 }.map { $0.1 }
    }
}

extension Checker {
    func chooseGoal(_ goal:String) {
        taskGoal=goal
        if goal == "text" { scope="自訂文字" }
        else if scope == "自訂文字" && custom.isEmpty { scope="字檔所有字元" }
    }
    func setStrategy(_ strategy:String) { reviewStrategy=strategy; sampleMode=strategy == "sample" }
    func useCharacterList(_ id:String) {
        selectedCharacterSet=id
        if let list=characterSets.first(where:{$0.id == id}) { scope="自訂文字"; custom=list.characters.map(char).joined() }
    }
    func storeCharacterList(_ list:CharacterList) throws {
        try list.validate()
        let values=characterSets+[list]
        let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(values).write(to:base.appendingPathComponent("CharacterSets.json"),options:.atomic)
        characterSets=values; useCharacterList(list.id)
    }
    func importCharacterList() {
        let panel=NSOpenPanel(); panel.allowedContentTypes=[.plainText,.json,UTType(filenameExtension:"glyphset") ?? .json]
        guard panel.runModal() == .OK, let url=panel.url else { return }
        do {
            let data=try Data(contentsOf:url); guard data.count <= 10000000 else { throw CocoaError(.fileReadCorruptFile) }
            var list:CharacterList
            if ["json","glyphset"].contains(url.pathExtension.lowercased()) { list=try JSONDecoder().decode(CharacterList.self,from:data); list.id=UUID().uuidString }
            else {
                guard let text=String(data:data,encoding:.utf8) ?? String(data:data,encoding:.utf16) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
                let lines=text.split(whereSeparator:\.isNewline).map(String.init)
                if lines.allSatisfy({$0.range(of:#"^[A-Za-z0-9_.-]+$"#,options:.regularExpression) != nil}), lines.contains(where:{$0.range(of:#"^(uni[0-9A-Fa-f]{4}|u[0-9A-Fa-f]{4,6})$|\.vert$"#,options:.regularExpression) != nil || ["space","exclam","quotedbl"].contains($0)}) { importGlyphLists([url]);return }
                list=CharacterList(name:url.deletingPathExtension().lastPathComponent,characters:CharacterList.parse(text))
            }
            try storeCharacterList(list); status="字集已加入，可重複使用。"
        } catch { self.error="無法匯入字集：請使用文字檔、逐行 U+ 字碼或 GlyphCheck 字集 JSON。" }
    }
    func saveCharacterList() {
        let values=CharacterList.parse(custom,codepointLines:taskGoal != "text")
        guard !values.isEmpty else { error="請先貼入文字或匯入字集。"; return }
        let alert=NSAlert(); alert.messageText=t("保存字集"); alert.addButton(withTitle:t("保存")); alert.addButton(withTitle:t("取消"))
        let input=NSTextField(frame:NSRect(x:0,y:0,width:260,height:28)); input.placeholderString=t("字集名稱"); alert.accessoryView=input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try storeCharacterList(CharacterList(name:input.stringValue.trimmingCharacters(in:.whitespacesAndNewlines),characters:values)) }
        catch { self.error="請輸入有效的字集名稱。" }
    }
    func exportCharacterList() {
        let list=CharacterList(name:characterSets.first(where:{$0.id==selectedCharacterSet})?.name ?? "Custom",characters:CharacterList.parse(custom,codepointLines:taskGoal != "text"))
        do {
            try list.validate()
            let panel=NSSavePanel(); panel.nameFieldStringValue="Character-list.glyphset"
            guard panel.runModal() == .OK, let url=panel.url else { return }
            let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
            try encoder.encode(list).write(to:url,options:.atomic)
        } catch { self.error="請先貼入文字或匯入字集。" }
    }
    var hasAcceptedRepairs:Bool {
        previewResult?.fonts.contains { f in f.suggestions.contains { approvalDecision(font:f.id,suggestion:$0)=="accepted" } } ?? false
    }
    func approvalDecision(font:String,suggestion:RepairSuggestion) -> String {
        guard let record=session.repairApprovals?[font]?[String(suggestion.character.unicodeScalars.first!.value)],record.fingerprint==suggestion.fingerprint else { return "pending" }
        return record.decision
    }
    func acceptRepair(font:String,suggestion:RepairSuggestion,decision:String) {
        guard ["accepted","excluded","pending"].contains(decision) else { return }
        var values=session.repairApprovals ?? [:]
        values[font,default:[:]][String(suggestion.character.unicodeScalars.first!.value)] = RepairApproval(fingerprint:suggestion.fingerprint,decision:decision,reviewedAt:ISO8601DateFormatter().string(from:Date()),reviewer:reviewer.isEmpty ? "Local reviewer" : reviewer)
        session.repairApprovals=values; save()
    }
    func prioritizePending() {
        persistDrafts(); session.queueMode="priority"
        let pending=session.domain.filter { cp in session.fonts.contains { f in
            f.visible[String(cp)] == true && (session.referenceDoubts.contains(cp) || session.reviewConflicts?[f.id]?[String(cp)] != nil || !["correct","mismatch"].contains(session.answers[f.id]?[String(cp)]?.kind ?? ""))
        }}
        session.remaining=ReviewQueue.make(session:session,characters:pending)
        session.current=session.remaining.popLast(); loadDrafts(); refresh(); save()
        status="問題已優先出題；原抽樣範圍與紀錄保留。"
    }
}

@MainActor struct TaskChooser: View {
    @EnvironmentObject var m:Checker
    var body:some View {
        HStack(spacing:12) {
            card("font","檢查這份字檔","找缺字、空白與可疑對應","doc.text")
            card("text","檢查這段文字","只核對文章實際用到的字","text.alignleft")
            card("repair","整理與修復問題","接續進度、追查與驗收","wrench.and.screwdriver")
        }
    }
    func card(_ goal:String,_ title:String,_ description:String,_ symbol:String) -> some View {
        Button { m.chooseGoal(goal) } label: {
            VStack(alignment:.leading,spacing:8) { Image(systemName:symbol).foregroundStyle(.tint); Text(m.t(title)).font(.headline); Text(m.t(description)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
                .padding(16).frame(maxWidth:.infinity,minHeight:94,alignment:.leading)
                .background(m.taskGoal==goal ? Color.accentColor.opacity(0.09) : Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:12))
                .overlay(RoundedRectangle(cornerRadius:12).stroke(m.taskGoal==goal ? Color.accentColor : Color.clear,lineWidth:1.5))
        }.buttonStyle(.plain)
    }
}

@MainActor struct CharacterListControls: View {
    @EnvironmentObject var m:Checker
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                if !m.characterSets.isEmpty {
                    Picker(m.t("已保存字集"),selection:Binding(get:{m.selectedCharacterSet},set:{m.useCharacterList($0)})) { Text(m.t("自訂")).tag(""); ForEach(m.characterSets) { list in Text(list.name).tag(list.id) } }.frame(maxWidth:300)
                }
                Button(m.t("匯入字表…")) { m.importCharacterList() }; Button(m.t("保存字集")) { m.saveCharacterList() }; Button(m.t("匯出字集…")) { m.exportCharacterList() }
            }
            TextEditor(text:Binding(get:{m.custom},set:{m.custom=$0;m.selectedCharacterSet=""})).frame(height:90).overlay(RoundedRectangle(cornerRadius:8).stroke(.separator))
            Text(m.t("貼上文章、字表，或逐行 U+ 字碼；空白與重複字不出題。")).font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor struct RepairAcceptanceRow: View {
    @EnvironmentObject var m:Checker
    var font:FontRecord; var suggestion:RepairSuggestion
    var body:some View {
        let target=Int(suggestion.character.unicodeScalars.first!.value), donor=Int(suggestion.donor.unicodeScalars.first!.value)
        let decision=m.approvalDecision(font:font.id,suggestion:suggestion)
        return VStack(alignment:.leading,spacing:10) {
            HStack { Text("\(suggestion.character) ← \(suggestion.donor)").font(.headline); Text(m.t(decision=="accepted" ? "已驗收" : decision=="excluded" ? "已排除" : "待驗收")).foregroundStyle(decision=="accepted" ? .green : .secondary); Spacer() }
            HStack {
                VStack { Text(m.t("原對應")); GlyphPicture(font:m.loadedFonts[font.id],glyph:font.glyphs[String(target)],zoom:1).frame(height:100) }
                Image(systemName:"arrow.right")
                VStack { Text(suggestion.sourceFont ?? m.t("原檔候選來源")); GlyphPicture(font:suggestion.sourceID.flatMap { m.donorFonts[$0] } ?? m.loadedFonts[font.id],glyph:suggestion.sourceID.flatMap { id in m.session.repairSources?.first(where:{$0.id == id})?.glyphs[String(donor)] } ?? font.glyphs[String(donor)],zoom:1).frame(height:100) }
            }
            if suggestion.sourceID != nil { Button(m.t("移除此跨字檔候選")) { m.removeExternal(font.id,target) } }
            HStack { Text(String(format:"U+%04X ← U+%04X",target,donor)).font(.caption.monospaced()); Spacer(); Button(m.t("接受此修復")) { m.acceptRepair(font:font.id,suggestion:suggestion,decision:"accepted") }; Button(m.t("排除此項")) { m.acceptRepair(font:font.id,suggestion:suggestion,decision:"excluded") }; if decision != "pending" { Button(m.t("重設")) { m.acceptRepair(font:font.id,suggestion:suggestion,decision:"pending") } } }
        }.padding(14).background(.background,in:RoundedRectangle(cornerRadius:10))
    }
}
