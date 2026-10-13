import SwiftUI
import AppKit
import CoreText
import UniformTypeIdentifiers

struct RepairSuggestion: Codable { var character: String; var donor: String }
struct MappingRelationship: Codable, Identifiable {
    var codepoint: String; var chain: String; var cycle: Bool; var status: String
    var id: String { codepoint }
}
struct RepairFont: Codable, Identifiable {
    var id: String; var font: String; var output: String?; var suggestions: [RepairSuggestion]
    var relationships: [MappingRelationship]
}
struct RepairResult: Codable { var output: String; var fonts: [RepairFont] }

extension Checker {
    func openWorkbench(_ tab: String) { persistDrafts(); save(); previewResult = nil; repairedFonts = [:]; workTab = tab; showWorkbench = true }
    func preparePreview() {
        persistDrafts(); save(); busy = true
        let output = folder.appendingPathComponent("Previews").appendingPathComponent(UUID().uuidString)
        Task {
            defer { busy = false }
            do {
                let data = try await run(["export",saveURL.path,output.path,"repair"])
                let result = try JSONDecoder().decode(RepairResult.self,from: data)
                var fonts: [String: CTFont] = [:]
                for item in result.fonts {
                    if let name = item.output,
                       let provider = CGDataProvider(url: output.appendingPathComponent(name) as CFURL), let cg = CGFont(provider) {
                        fonts[item.id] = CTFontCreateWithGraphicsFont(cg,36,nil,nil)
                    }
                }
                previewResult = result; repairedFonts = fonts
            } catch { self.error = error.localizedDescription }
        }
    }
    func exportReviewTask() {
        guard session.started else { return }
        let name = reviewer.trimmingCharacters(in: .whitespacesAndNewlines)
        let eligible = session.domain.sorted()
        guard !name.isEmpty, name.count <= 200, let offset = Int(taskOffset), let count = Int(taskCount),
              offset >= 1, offset <= eligible.count, count > 0, count <= eligible.count - offset + 1 else {
            error = "請輸入核對者名稱、有效的起始序號及任務字數。"; return
        }
        persistDrafts(); save()
        let chars = Array(eligible[(offset-1)..<(offset-1+count)]); let keys = Set(chars.map(String.init))
        let package = ReviewPackage(reviewer: name,domain: chars,fonts: session.fonts.map { f in
            TaskFont(sha256: f.sha256,face: f.face,answers: (session.answers[f.id] ?? [:]).filter { keys.contains($0.key) },
                conflicts: (session.reviewConflicts?[f.id] ?? [:]).filter { keys.contains($0.key) })
        },referenceDoubts: session.referenceDoubts.filter { chars.contains($0) })
        let panel = NSSavePanel(); panel.nameFieldStringValue = "GlyphCheck-\(offset)-\(offset+count-1).glyphreview"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            try encoder.encode(package).write(to: url,options: .atomic)
            status = "核對任務已匯出，不包含字檔。"
        } catch { self.error = error.localizedDescription }
    }
    func mergeReview(_ package: ReviewPackage) throws {
        try package.validate(against: session)
        if session.importedTasks?.contains(package.id) == true { return }
        persistDrafts()
        var conflicts = session.reviewConflicts ?? [:]
        var history = session.reviewVotes ?? [:]
        for task in package.fonts {
            let f = session.fonts.first { $0.sha256 == task.sha256 && $0.face == task.face }!
            for key in Set(task.answers.keys).union((task.conflicts ?? [:]).keys) {
                var votes = history[f.id]?[key] ?? []
                if let local = session.answers[f.id]?[key], votes.isEmpty { votes.append(ReviewVote(reviewer: "Local",answer: local)) }
                if let incoming = task.answers[key] {
                    let vote = ReviewVote(reviewer: package.reviewer,answer: incoming)
                    if !votes.contains(vote) { votes.append(vote) }
                }
                for vote in task.conflicts?[key] ?? [] where !votes.contains(vote) { votes.append(vote) }
                history[f.id,default: [:]][key] = votes
                let decisions = votes.map(\.answer).filter { ["correct","mismatch"].contains($0.kind) }
                let unique = decisions.reduce(into: [Answer]()) { if !$0.contains($1) { $0.append($1) } }
                if unique.count > 1 || task.conflicts?[key] != nil {
                    conflicts[f.id,default: [:]][key] = votes
                } else if conflicts[f.id]?[key] == nil, let decision = unique.first ?? votes.first?.answer {
                    session.answers[f.id,default: [:]][key] = decision
                }
            }
        }
        session.reviewConflicts = conflicts; session.reviewVotes = history
        session.importedTasks = (session.importedTasks ?? []) + [package.id]
        let wasStarted = session.started
        let targets = package.fonts.flatMap { $0.answers.values }.filter { $0.kind == "mismatch" }.compactMap { $0.actual.unicodeScalars.first.map { Int($0.value) } }
        session.domain = Array(Set(session.domain).union(package.domain).union(targets)).sorted()
        if !wasStarted { session.scope = "核對任務"; session.population = package.domain; session.reviewMode = "task" }
        session.referenceDoubts = Array(Set(session.referenceDoubts).union(package.referenceDoubts)).sorted()
        session.started = true
        // Visiting a returned task does not silently confirm its unanswered characters.
        let pending = Set(package.domain + targets).filter { cp in session.fonts.contains { f in
            f.visible[String(cp)] == true && (session.referenceDoubts.contains(cp) || conflicts[f.id]?[String(cp)] != nil || !["correct","mismatch"].contains(session.answers[f.id]?[String(cp)]?.kind ?? ""))
        }}
        session.remaining = Array(Set(session.remaining).union(pending)).filter { $0 != session.current }.sorted().reversed()
        if session.current == nil { session.current = session.remaining.popLast() }
        undoStack = []; previewResult = nil; repairedFonts = [:]; loadDrafts(); refresh(); save()
    }
    func importReviewTask() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "glyphreview") ?? .json,.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 50000000 else { throw CocoaError(.fileReadCorruptFile) }
            try mergeReview(JSONDecoder().decode(ReviewPackage.self,from: data))
            status = "核對任務已合併；不同答案保留為待複核。"
        } catch { self.error = "無法匯入任務：請先匯入相同原字檔及字面，並確認任務格式。" }
    }
    func about() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "GlyphCheck",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.0",
            .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "3",
            .credits: aboutCredits(),
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 MAKOTO LAB"
        ])
    }
    func aboutCredits() -> NSAttributedString {
        let result = NSMutableAttributedString(string: t("由 MAKOTO LAB 開發與維護。") + "\n\n",attributes: [.font:NSFont.systemFont(ofSize: 13)])
        for (title,url) in [("MAKOTO LAB","https://makotolab.tw/"),("GitHub","https://github.com/lancer1234/GlyphCheck"),("Buy Me a Coffee","https://buymeacoffee.com/MakotoLab")] {
            result.append(NSAttributedString(string: title + "\n",attributes: [.link:URL(string:url)!, .font:NSFont.systemFont(ofSize: 13)]))
        }
        result.append(NSAttributedString(string: "\nMIT License · Python · fontTools\n" + t("字檔留在本機；不自動安裝、不覆寫原檔。"),attributes: [.font:NSFont.systemFont(ofSize: 11)]))
        return result
    }
}

// CoreText runs preserve shaping and font metrics. Missing characters are marked,
// never silently supplied by another font in the target proof.
struct ProofView: NSViewRepresentable {
    var font: CTFont; var text: String; var size: Double
    var allowFallback = false
    func makeNSView(context: Context) -> ProofCanvas { ProofCanvas() }
    func updateNSView(_ view: ProofCanvas,context: Context) { view.font = font; view.text = text; view.size = size; view.allowFallback = allowFallback; view.needsDisplay = true }
}
final class ProofCanvas: NSView {
    var font: CTFont?; var text = ""; var size = 36.0
    var allowFallback = false
    override var isFlipped: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let base = font else { return }
        let font = CTFontCreateCopyWithAttributes(base,size,nil,nil)
        let attributes: [NSAttributedString.Key:Any] = [NSAttributedString.Key(kCTFontAttributeName as String):font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):NSColor.labelColor.cgColor]
        let text = NSAttributedString(string: text,attributes: attributes)
        let setter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: bounds.insetBy(dx: 14,dy: 14),transform: nil)
        let frame = CTFramesetterCreateFrame(setter,CFRange(location: 0,length: 0),path,nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]; var origins = Array(repeating: CGPoint.zero,count: lines.count)
        CTFrameGetLineOrigins(frame,CFRange(location: 0,length: 0),&origins)
        ctx.saveGState(); ctx.textMatrix = .identity
        for (index,line) in lines.enumerated() {
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let count = CTRunGetGlyphCount(run)
                var positions = Array(repeating: CGPoint.zero,count: count); var glyphs = Array(repeating: CGGlyph(0),count: count)
                CTRunGetPositions(run,CFRange(location: 0,length: 0),&positions); CTRunGetGlyphs(run,CFRange(location: 0,length: 0),&glyphs)
                let attrs = CTRunGetAttributes(run) as NSDictionary
                let runFont = attrs[kCTFontAttributeName] as! CTFont
                let exact = CFEqual(CTFontCopyPostScriptName(runFont),CTFontCopyPostScriptName(font))
                if exact || allowFallback {
                    let points = positions.map { CGPoint(x: $0.x + origins[index].x + 14,y: $0.y + origins[index].y + 14) }
                    ctx.setFillColor(NSColor.labelColor.cgColor)
                    CTFontDrawGlyphs(allowFallback ? runFont : font,glyphs,points,count,ctx)
                }
                var indices = Array(repeating:CFIndex(0),count:count)
                CTRunGetStringIndices(run,CFRange(location:0,length:0),&indices)
                let units = Array(text.string.utf16)
                for n in 0..<count where (!exact && !allowFallback) || glyphs[n] == 0 {
                    if indices[n] >= 0 && indices[n] < units.count,
                       let scalar = UnicodeScalar(units[indices[n]]), scalar.properties.isWhitespace { continue }
                    ctx.setStrokeColor(NSColor.systemOrange.cgColor)
                    ctx.stroke(CGRect(x:positions[n].x+origins[index].x+14,y:positions[n].y+origins[index].y+14,width:size*0.6,height:size*0.8))
                }
            }
        }
        ctx.restoreGState()
        let visible = CTFrameGetVisibleStringRange(frame)
        if visible.location + visible.length < text.length {
            NSAttributedString(string:"…",attributes:[.font:NSFont.systemFont(ofSize:18),.foregroundColor:NSColor.systemOrange]).draw(at:CGPoint(x:bounds.width-30,y:4))
        }
    }
}

@MainActor struct WorkbenchView: View {
    @EnvironmentObject var m: Checker
    var body: some View {
        VStack(alignment: .leading,spacing: 16) {
            HStack { Text(m.t("檢查工作台")).font(.title2.bold()); Spacer(); if m.busy { ProgressView().controlSize(.small) }; Button(m.t("完成")) { m.showWorkbench = false }.disabled(m.busy) }
            Picker("",selection: $m.workTab) {
                Text(m.t("預掃描")).tag("scan"); Text(m.t("對應追查")).tag("mapping"); Text(m.t("詞句檢查")).tag("proof"); Text(m.t("修復對照")).tag("repair"); Text(m.t("多人核對")).tag("team")
            }.pickerStyle(.segmented).disabled(m.busy)
            Group {
                switch m.workTab {
                case "scan": scan
                case "mapping": mapping
                case "proof", "repair": proof
                default: team
                }
            }.frame(maxWidth: .infinity,maxHeight: .infinity,alignment: .topLeading)
        }.padding(24).frame(width: 880,height: 660)
    }
    var scan: some View {
        VStack(alignment: .leading,spacing: 12) {
            Text(m.t("可疑項目不等於錯字；共用輪廓可能是正常設計。")).font(.callout).foregroundStyle(.secondary)
            List {
                ForEach(m.session.fonts) { f in
                    Section(f.name) {
                        let population = m.session.started ? (m.session.population ?? m.session.domain) : ((try? Selection.make(fonts:m.session.fonts,scope:m.scope,custom:m.custom,variant:m.scriptVariant,sampleSize:nil).population) ?? [])
                        let allowed = Set(population)
                        let missing = population.filter { f.visible[String($0)] != true }
                        Text(m.t("範圍缺字") + ": \(missing.count) / \(population.count)")
                        ForEach(Array(missing.prefix(200)),id:\.self) { cp in
                            Button { m.showWorkbench = false; m.visit(cp) } label: { Text(char(cp) + " · " + String(format:"U+%04X",cp) + " · " + m.t("缺字")) }.buttonStyle(.plain).disabled(!m.session.started)
                        }
                        ForEach(Array((f.scan ?? []).filter { allowed.contains($0.cp) }.prefix(500))) { item in
                            Button { m.showWorkbench = false; m.visit(item.cp) } label: {
                                HStack { Text(char(item.cp)).font(.title2).frame(width: 40); Text(String(format:"U+%04X",item.cp)).font(.caption.monospaced()); Text(m.t(item.kind == "duplicate" ? "重複輪廓" : item.kind == "name" ? "字名／字碼不同" : item.kind == "blank" ? "空白字形" : "輪廓未比較")); Spacer(); Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }.buttonStyle(.plain).disabled(!m.session.started)
                        }
                    }
                }
            }
            Text(m.t("清單顯示前 200 個缺字與 500 個可疑項目；完整資料在匯出報告。開始後可點選複查。")).font(.caption).foregroundStyle(.secondary)
        }
    }
    var mapping: some View {
        VStack(alignment: .leading,spacing: 12) {
            Button(m.t("更新追查與修復建議")) { m.preparePreview() }.disabled(m.busy)
            Text(m.t("只有人工確認的字形來源可修正；來源不明或答案衝突不猜改。")).font(.callout).foregroundStyle(.secondary)
            if let result = m.previewResult {
                List { ForEach(result.fonts) { font in
                    Section(font.font) { ForEach(font.relationships) { relation in
                        HStack { Text(relation.chain).font(.title3); Spacer(); Text(m.t(relation.status == "confirmed_donor" ? "可修正" : "待確認")); if relation.cycle { Image(systemName:"arrow.triangle.2.circlepath") } }
                    } }
                } }
            } else { Text(m.t("按更新查看目前的交換、連鎖與修復來源。")).foregroundStyle(.secondary) }
        }
    }
    var proof: some View {
        VStack(alignment: .leading,spacing: 12) {
            HStack {
                Menu(m.t("範例")) {
                    Button(m.t("中文與標點")) { m.proofText = "常常想起那些字。\n「字形、字碼」：真的一樣嗎？\n春風又綠江南岸，明月何時照我還。" }
                    Button(m.t("英文與易混淆字")) { m.proofText = "AVATAR To WA fi fl ffi\nIl1 O0 rn m — Café naïve résumé\nThe quick brown fox jumps over the lazy dog.\n0123456789 !? @#$%& () [] {}" }
                }
                Slider(value:$m.proofSize,in:14...72).frame(width:160); Text("\(Int(m.proofSize)) pt")
                Spacer()
                if m.workTab == "repair" { Button(m.t("產生最新修復預覽")) { m.preparePreview() }.disabled(m.busy) }
            }
            TextEditor(text:$m.proofText).font(.body).frame(height:90).overlay(RoundedRectangle(cornerRadius:8).stroke(.separator))
            Text(m.t("橘框代表缺字／備援未採用；檢查排版不會自動修正字距或連字。")).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                ForEach(m.session.fonts) { f in
                    VStack(alignment:.leading,spacing:8) {
                        Text(f.name).font(.headline)
                        HStack(alignment:.top) {
                            if let font = m.loadedFonts[f.id] { proofCard(m.t("原版"),font:font) }
                            if m.workTab == "repair" {
                                if let font = m.repairedFonts[f.id] { proofCard(m.t("修正版"),font:font) }
                                else { Text(m.t("尚無修復預覽或沒有安全修正來源。")).frame(maxWidth:.infinity,minHeight:180).foregroundStyle(.secondary) }
                            } else { proofCard(m.t("系統參考"),font:CTFontCreateWithName(m.reference as CFString,36,nil),allowFallback:true) }
                        }
                        if m.workTab == "repair", let item = m.previewResult?.fonts.first(where: { $0.id == f.id }) {
                            Text(item.suggestions.map { "\($0.character) ← \($0.donor)" }.joined(separator:"   ")).font(.caption).textSelection(.enabled)
                        }
                    }.padding(.bottom,14)
                }
            }
        }
    }
    func proofCard(_ title:String,font:CTFont,allowFallback:Bool=false) -> some View {
        VStack(alignment:.leading) { Text(title).font(.caption).foregroundStyle(.secondary); ProofView(font:font,text:m.proofText,size:m.proofSize,allowFallback:allowFallback).frame(height:240).background(.background,in:RoundedRectangle(cornerRadius:8)) }.frame(maxWidth:.infinity)
    }
    var team: some View {
        VStack(alignment:.leading,spacing:16) {
            Text(m.t("任務依原檔 SHA-256 與字面核對，不包含或傳送字檔。")).foregroundStyle(.secondary)
            TextField(m.t("核對者名稱"),text:$m.reviewer).textFieldStyle(.roundedBorder)
            HStack { Text(m.t("起始序號")); TextField("1",text:$m.taskOffset).frame(width:80); Text(m.t("任務字數")); TextField("100",text:$m.taskCount).frame(width:80); Spacer() }.textFieldStyle(.roundedBorder)
            HStack { Button(m.t("匯出核對任務／答案…")) { m.exportReviewTask() }; Button(m.t("匯入任務／合併答案…")) { m.importReviewTask() } }
            Text(m.t("接收者匯入相同字檔後匯入任務，即可核對；完成後匯出同一段序號的答案。分工序號依字碼排序，不是隨機出題順序。")).font(.callout).foregroundStyle(.secondary)
            Divider()
            Text(m.t("答案衝突")).font(.headline)
            List { ForEach(m.session.fonts) { f in
                ForEach((m.session.reviewConflicts?[f.id] ?? [:]).keys.sorted(),id:\.self) { key in
                    if let cp = Int(key) {
                        Button { m.showWorkbench = false; m.visit(cp) } label: {
                            VStack(alignment:.leading) { Text("\(f.name) · \(char(cp))").font(.headline); Text((m.session.reviewConflicts?[f.id]?[key] ?? []).map { "\($0.reviewer): \(m.t($0.answer.kind == "correct" ? "正確" : "誤植")) \($0.answer.actual)" }.joined(separator:" / ")).font(.caption) }
                        }.buttonStyle(.plain)
                    }
                }
            } }
            Text(m.t("點選衝突字，重新提交判定才會解除修復封鎖。")).font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor struct SettingsView: View {
    @EnvironmentObject var m: Checker
    var body: some View {
        Form {
            Picker(m.t("介面語言"),selection:Binding(get:{m.uiLanguage},set:{m.setLanguage($0)})) {
                Text("繁體中文").tag("traditional"); Text("简体中文").tag("simplified"); Text("English").tag("english")
            }
            Text(m.t("介面語言不會改變檢查範圍或字檔編碼。")).font(.caption).foregroundStyle(.secondary)
            Button(m.t("關於 GlyphCheck")) { m.about() }
        }.formStyle(.grouped).padding(12).frame(width:420,height:200)
    }
}
