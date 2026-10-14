import SwiftUI
import AppKit
import CoreText

struct GlyphNameList:Codable { var name:String;var entries:[String];var sha256:String }
struct GlyphListImport:Codable { var lists:[GlyphNameList] }
struct GlyphReview:Codable { var fingerprint:String;var decision:String;var note:String }
struct GlyphAuditRow:Codable,Identifiable {
    var id:String;var list:String;var name:String;var codepoint:String;var character:String
    var glyph:String;var glyphID:Int?;var present:Bool;var status:String;var reason:String
    var fingerprint:String;var decision:String;var note:String
}
struct GlyphAuditFont:Codable,Identifiable { var id:String;var font:String;var sha256:String;var rows:[GlyphAuditRow] }
struct GlyphAuditResult:Codable { var fonts:[GlyphAuditFont] }

extension Checker {
    func importGlyphLists() {
        let p=NSOpenPanel();p.allowedContentTypes=[.plainText];p.allowsMultipleSelection=true;p.title=t("匯入 Glyphs 字形名稱清單")
        guard p.runModal() == .OK else { return }
        importGlyphLists(p.urls)
    }
    func importGlyphLists(_ urls:[URL]) {
        busy=true
        Task {
            defer { busy=false }
            do {
                let data=try await run(["glyphlist"]+urls.map(\.path))
                let incoming=try JSONDecoder().decode(GlyphListImport.self,from:data)
                var lists=session.glyphLists ?? []
                for item in incoming.lists where !lists.contains(where:{$0.sha256==item.sha256}) { lists.append(item) }
                session.glyphLists=lists;selectedAuditRow="";save()
                openWorkbench("charset")
                if !session.fonts.isEmpty { await refreshGlyphAudit() }
            } catch { self.error=error.localizedDescription }
        }
    }
    func refreshGlyphAudit() async {
        save()
        do { glyphAudit=try JSONDecoder().decode(GlyphAuditResult.self,from:try await run(["audit",saveURL.path])) }
        catch { self.error=error.localizedDescription }
    }
    func updateGlyphAudit() { busy=true; Task { await refreshGlyphAudit();busy=false } }
    func judgeGlyph(_ font:String,_ row:GlyphAuditRow,_ decision:String,note:String?=nil) {
        session.glyphReviews=session.glyphReviews ?? [:]
        session.glyphReviews![font,default:[:]][row.id]=GlyphReview(fingerprint:row.fingerprint,decision:decision,note:note ?? row.note)
        if let index=glyphAudit?.fonts.firstIndex(where:{$0.id==font}),let ri=glyphAudit?.fonts[index].rows.firstIndex(where:{$0.id==row.id}) {
            glyphAudit?.fonts[index].rows[ri].decision=decision
            glyphAudit?.fonts[index].rows[ri].status=row.present ? (decision=="correct" ? "found" : "pending") : row.status
            glyphAudit?.fonts[index].rows[ri].note=note ?? row.note
        }
        save()
    }
    func exportGlyphAudit() {
        let p=NSOpenPanel();p.canChooseFiles=false;p.canChooseDirectories=true;p.canCreateDirectories=true
        guard p.runModal() == .OK,let url=p.url else { return }
        save();busy=true
        Task {
            defer {busy=false}
            do {
                let out=url.appendingPathComponent("GlyphCheck-字集驗收-"+UUID().uuidString.prefix(8))
                _=try await run(["audit",saveURL.path,out.path]);NSWorkspace.shared.open(out)
                status="字集驗收報告已匯出。"
            } catch { self.error=error.localizedDescription }
        }
    }
}

@MainActor struct GlyphAuditView:View {
    @EnvironmentObject var m:Checker
    @State var fontSelection=""
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Button(m.t("匯入 Glyphs 清單…")) { m.importGlyphLists() };Button(m.t("更新驗收")) { m.updateGlyphAudit() }.disabled(m.session.fonts.isEmpty || m.busy);Button(m.t("清除清單")){m.session.glyphLists=[];m.glyphAudit=nil;m.selectedAuditRow="";m.save()}.disabled(m.busy);Spacer();Button(m.t("匯出字集驗收…")) {m.exportGlyphAudit()}.disabled(m.glyphAudit==nil || m.busy) }
            DisclosureGroup(m.t("字集與判定說明")) {
                Text((m.session.glyphLists ?? []).map {"\($0.name) · \($0.entries.count)"}.joined(separator:"　")).font(.caption).foregroundStyle(.secondary)
                Text(m.t("字形存在不代表字義正確；命名變體不會自動換成基本字。無可靠對應的項目保留為無法判定。")).font(.caption).foregroundStyle(.secondary)
            }
            Picker(m.t("顯示"),selection:$m.glyphAuditFilter) {Text(m.t("全部")).tag("all");Text(m.t("已找到／已確認")).tag("found");Text(m.t("缺少")).tag("missing");Text(m.t("無法判定")).tag("unresolved");Text(m.t("待人工核對")).tag("pending")}.pickerStyle(.segmented)
            if let audit=m.glyphAudit {
                let active=audit.fonts.contains(where:{$0.id==fontSelection}) ? fontSelection : audit.fonts.first?.id ?? ""
                Picker(m.t("字檔"),selection:Binding(get:{active},set:{fontSelection=$0;m.selectedAuditRow=""})) {ForEach(audit.fonts){Text($0.font).tag($0.id)}}
                ForEach(audit.fonts.filter{$0.id==active}) { font in
                    Text(summary(font)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    HStack(alignment:.top,spacing:16) {
                        List(selection:$m.selectedAuditRow) {
                            ForEach(font.rows.filter {m.glyphAuditFilter=="all" || $0.status==m.glyphAuditFilter}) { row in
                                VStack(alignment:.leading,spacing:4) {Text(row.name).font(.body.monospaced());Text("\(row.list) · \(row.codepoint) · \(label(row.status))").font(.caption).foregroundStyle(.secondary)}.tag(font.id+"|"+row.id)
                            }
                        }.listStyle(.inset).frame(width:280).background(.background,in:RoundedRectangle(cornerRadius:10))
                        if let row=font.rows.first(where:{font.id+"|"+$0.id==m.selectedAuditRow}) { detail(font,row).frame(maxWidth:.infinity) }
                        else { Text(m.t("選擇一個項目查看實際字形。")).foregroundStyle(.secondary).frame(maxWidth:.infinity) }
                    }.frame(minHeight:180)
                }
            } else { Text(m.t("匯入字檔與字形名稱清單，開始字集驗收。")).foregroundStyle(.secondary);Spacer() }
        }.task { if !m.session.fonts.isEmpty && !(m.session.glyphLists ?? []).isEmpty { m.updateGlyphAudit() } }
    }
    func label(_ status:String)->String {m.t(["found":"已找到／已確認","missing":"缺少","unresolved":"無法判定","pending":"待人工核對"][status] ?? status)}
    func summary(_ f:GlyphAuditFont)->String { ["found","missing","unresolved","pending"].map { status in "\(label(status)) \(f.rows.filter{$0.status==status}.count)"}.joined(separator:" · ") }
    func detail(_ font:GlyphAuditFont,_ row:GlyphAuditRow)->some View {
        ScrollView { VStack(alignment:.leading,spacing:14) {
            Text(row.name).font(.title2.monospaced());Text(row.codepoint).foregroundStyle(.secondary)
            HStack(alignment:.top,spacing:12) {
                VStack(spacing:8) {Text(m.t("原字檔字形")).font(.caption).foregroundStyle(.secondary);GlyphPicture(font:m.loadedFonts[font.id],glyph:row.glyphID,zoom:1).frame(height:130)}.frame(maxWidth:.infinity)
                if let cp=row.character.unicodeScalars.first {VStack(spacing:8) {Text(m.t("系統參考")).font(.caption).foregroundStyle(.secondary);Text(row.character).font(.system(size:64)).frame(height:100);Text(m.t(pinyin(Int(cp.value)))).font(.caption).lineLimit(3)}.frame(maxWidth:.infinity) }
            }.padding(16).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:12))
            Text(row.reason).font(.callout).foregroundStyle(.secondary)
            Text(label(row.status)).font(.headline)
            HStack {Button(m.t("確認正確")){m.judgeGlyph(font.id,row,"correct")}.disabled(!row.present);Button(m.t("標記問題")){m.judgeGlyph(font.id,row,"issue")}.disabled(!row.present);Button(m.t("重設")){m.judgeGlyph(font.id,row,"")} }
            TextField(m.t("核對註記"),text:Binding(get:{row.note},set:{m.judgeGlyph(font.id,row,row.decision,note:$0)})).textFieldStyle(.roundedBorder)
            if row.decision=="issue" {Text(m.t("已標記問題，仍待人工核對。")).foregroundStyle(.orange)}
        }.padding(.horizontal,4).padding(.bottom,16) }
    }
}
