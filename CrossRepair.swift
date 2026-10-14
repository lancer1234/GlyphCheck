import SwiftUI
import AppKit
import CoreText
import UniformTypeIdentifiers

extension Checker {
    func importRepairSource(_ url: URL, postscript:String?=nil) {
        busy = true
        Task {
            defer { busy = false }
            do {
                let data = try await run(["inspect",url.path,folder.appendingPathComponent("RepairSources").path]+(postscript.map { [$0] } ?? []))
                let imported = try JSONDecoder().decode(ImportResult.self,from:data)
                var sources = session.repairSources ?? []
                for f in imported.fonts where !sources.contains(where:{$0.sha256 == f.sha256 && $0.face == f.face}) { sources.append(f) }
                session.repairSources = sources
                donorID = sources.last?.id ?? ""; loadRepairSources(); save()
            } catch { self.error = error.localizedDescription }
        }
    }
    func loadRepairSources() {
        donorFonts = [:]
        for f in session.repairSources ?? [] {
            if let p = CGDataProvider(url:URL(fileURLWithPath:f.preview) as CFURL), let cg = CGFont(p) { donorFonts[f.id] = CTFontCreateWithGraphicsFont(cg,36,nil,nil) }
        }
        if !(session.repairSources ?? []).contains(where:{$0.id == donorID}) { donorID = session.repairSources?.first?.id ?? "" }
    }
    func chooseRepairFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = ["ttf","otf","ttc","otc"].compactMap { UTType(filenameExtension:$0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }; importRepairSource(url)
    }
    func chooseInstalledRepair() {
        let font = CTFontCreateWithName(installedDonor as CFString,36,nil)
        guard let url = CTFontCopyAttribute(font,kCTFontURLAttribute) as? URL else { error = "無法取得這個本機字體的字檔。請選擇字檔匯入。"; return }
        importRepairSource(url,postscript:CTFontCopyPostScriptName(font) as String)
    }
    func stageExternal(_ targetFont:FontRecord) {
        guard let source = session.repairSources?.first(where:{$0.id == donorID}) else { return }
        let targets = CharacterList.parse(donorTargets,codepointLines:true)
        guard !targets.isEmpty else { error = "請輸入要補入或替換的字。"; return }
        let valid = targets.filter { source.visible[String($0)] == true }
        for cp in valid { session.externalRepairs = session.externalRepairs ?? [:]; session.externalRepairs![targetFont.id,default:[:]][String(cp)] = ExternalRepair(sourceID:source.id,codepoint:cp) }
        session.domain = Array(Set(session.domain).union(valid)).sorted()
        save(); preparePreview()
        if valid.count != targets.count { error = "來源字體有部分缺字，僅加入有實際輪廓的候選。" }
    }
    func removeExternal(_ font:String,_ cp:Int) { session.externalRepairs?[font]?[String(cp)] = nil; save(); preparePreview() }
}

@MainActor struct CrossRepairPicker: View {
    @EnvironmentObject var m:Checker
    var font:FontRecord
    var body:some View {
        DisclosureGroup(m.t("跨字檔補字／替換")) {
          VStack(alignment:.leading,spacing:10) {
            HStack {
                Button(m.t("選擇字檔…")) { m.chooseRepairFile() }
                Picker(m.t("本機字體"),selection:$m.installedDonor) { ForEach(NSFontManager.shared.availableFonts.sorted(),id:\.self) { Text($0).tag($0) } }.frame(maxWidth:300)
                Button(m.t("載入本機字體")) { m.chooseInstalledRepair() }
            }
            if !(m.session.repairSources ?? []).isEmpty {
                Picker(m.t("修復來源／字面"),selection:$m.donorID) { ForEach(m.session.repairSources ?? []) { Text("\($0.name) · \($0.face+1)").tag($0.id) } }
                HStack { TextField(m.t("輸入要補字／替換的字，或逐行 U+ 字碼"),text:$m.donorTargets).textFieldStyle(.roundedBorder); Button(m.t("加入修復候選")) { m.stageExternal(font) }.disabled(m.busy) }
                if let source=m.session.repairSources?.first(where:{$0.id == m.donorID}), let ct=m.donorFonts[source.id] {
                    ProofView(font:ct,text:m.donorTargets.isEmpty ? m.t("字體預覽 ABC abc 123") : m.donorTargets,size:28,syncGroup:"source-\(font.id)").frame(height:90)
                }
            }
            Text(m.t("來源輪廓縮放至原字檔單位，保留來源字寬；逐字驗收後匯出。可修復靜態 TrueType；變動／彩色字體與 CFF 目標暫不輸出。")).font(.caption).foregroundStyle(.secondary)
          }.padding(.top,8)
        }.padding(12).background(.quaternary,in:RoundedRectangle(cornerRadius:10)).onAppear { m.loadRepairSources() }
    }
}
