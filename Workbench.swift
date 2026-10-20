import SwiftUI
import AppKit
import CoreText
import UniformTypeIdentifiers

struct RepairSuggestion: Codable, Identifiable {
    var character: String; var donor: String; var fingerprint: String; var decision: String
    var sourceID: String? = nil
    var sourceFont: String? = nil
    var id: String { character }
}
struct MappingRelationship: Codable, Identifiable {
    var codepoint: String; var chain: String; var cycle: Bool; var status: String
    var id: String { codepoint }
}
struct RepairFont: Codable, Identifiable {
    var id: String; var font: String; var output: String?; var suggestions: [RepairSuggestion]
    var relationships: [MappingRelationship]
    var unresolved: [RepairFailure]? = nil
}
struct RepairFailure: Codable { var codepoint:String; var reason:String }
struct RepairResult: Codable { var output: String; var fonts: [RepairFont] }

extension Checker {
    func openWorkbench(_ tab: String) { persistDrafts(); save(); previewResult = nil; repairedFonts = [:]; workTab = tab; showWorkbench = true }
    func preparePreview() {
        persistDrafts(); save(); busy = true
        let output = folder.appendingPathComponent("Previews").appendingPathComponent(UUID().uuidString)
        Task {
            defer { busy = false }
            do {
                let data = try await run(["export",saveURL.path,output.path,"preview"])
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
                let decisions = votes.map(\.answer).filter { ["correct","mismatch","variant"].contains($0.kind) }
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
        result.append(NSAttributedString(string: "\nFree Use & Modification · No Resale\nPython · fontTools\n" + t("字檔留在本機；不自動安裝、不覆寫原檔。"),attributes: [.font:NSFont.systemFont(ofSize: 11)]))
        return result
    }
}

// CoreText runs preserve shaping and font metrics. Missing characters are marked,
// never silently supplied by another font in the target proof.
struct ProofView: NSViewRepresentable {
    var font: CTFont; var text: String; var size: Double
    var allowFallback = false
    var syncGroup = ""
    func makeNSView(context: Context) -> ProofScroll { ProofScroll() }
    func updateNSView(_ view: ProofScroll,context: Context) { if view.canvas.text != text { view.resetTop = true; view.canvas.selection = NSRange(location:0,length:0) }; view.canvas.font = font; view.canvas.text = text; view.canvas.size = size; view.canvas.allowFallback = allowFallback; view.group = syncGroup; view.resizeProof() }
}
final class ProofScroll: NSScrollView {
    let canvas = ProofCanvas(); var group = ""; var syncing = false
    var resetTop = true
    var observers:[NSObjectProtocol] = []
    override init(frame:NSRect) {
        super.init(frame:frame); hasVerticalScroller = true; drawsBackground = false; documentView = canvas
        contentView.postsBoundsChangedNotifications = true
        canvas.onSelection = { [weak self] range in guard let self else { return }; self.broadcast(range:range) }
        observers.append(NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:contentView,queue:.main) { [weak self] _ in self?.broadcast() })
        observers.append(NotificationCenter.default.addObserver(forName:Notification.Name("GlyphCheck.proofSync"),object:nil,queue:.main) { [weak self] note in
            guard let self, !self.group.isEmpty, note.object as AnyObject? !== self, note.userInfo?["group"] as? String == self.group else { return }
            if let range = note.userInfo?["range"] as? NSRange { self.canvas.selection = range; self.canvas.needsDisplay = true }
            if let cp = note.userInfo?["anchor"] as? Int {
                self.syncing = true
                let y = self.canvas.scrollY(for:cp)
                self.contentView.scroll(to:NSPoint(x:0,y:min(max(0,y),max(0,self.canvas.bounds.height-self.contentView.bounds.height))))
                self.reflectScrolledClipView(self.contentView); self.syncing = false
            }
        })
    }
    required init?(coder:NSCoder) { fatalError() }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    override func layout() { super.layout(); resizeProof() }
    func resizeProof() {
        let width=max(50,contentView.bounds.width)
        let height=max(contentView.bounds.height,canvas.requiredHeight(width:width))
        if canvas.frame.size != NSSize(width:width,height:height) { canvas.setFrameSize(NSSize(width:width,height:height)) }
        if resetTop && width > 50 { syncing=true; contentView.scroll(to:NSPoint(x:0,y:max(0,height-contentView.bounds.height))); reflectScrolledClipView(contentView); syncing=false; resetTop=false }
        canvas.needsDisplay = true
    }
    func broadcast(range:NSRange?=nil) {
        guard !syncing, !group.isEmpty else { return }
        var info:[String:Any] = ["group":group]
        if let range { info["range"] = range } else { info["anchor"] = canvas.index(at:NSPoint(x:14,y:contentView.bounds.maxY-18)) }
        NotificationCenter.default.post(name:Notification.Name("GlyphCheck.proofSync"),object:self,userInfo:info)
    }
}
final class ProofCanvas: NSView {
    var font: CTFont?; var text = ""; var size = 36.0
    var allowFallback = false
    var selection = NSRange(location:0,length:0); var anchor = 0
    var onSelection:((NSRange)->Void)?
    func attributed() -> NSAttributedString {
        guard let base=font else { return NSAttributedString(string:"") }
        return NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):CTFontCreateCopyWithAttributes(base,size,nil,nil)])
    }
    func requiredHeight(width:CGFloat) -> CGFloat {
        let setter=CTFramesetterCreateWithAttributedString(attributed())
        return ceil(CTFramesetterSuggestFrameSizeWithConstraints(setter,CFRange(location:0,length:0),nil,CGSize(width:max(1,width-28),height:.greatestFiniteMagnitude),nil).height)+40
    }
    func lines() -> ([CTLine],[CGPoint]) {
        let setter=CTFramesetterCreateWithAttributedString(attributed())
        let frame=CTFramesetterCreateFrame(setter,CFRange(location:0,length:0),CGPath(rect:bounds.insetBy(dx:14,dy:14),transform:nil),nil)
        let lines=CTFrameGetLines(frame) as! [CTLine]; var origins=Array(repeating:CGPoint.zero,count:lines.count)
        CTFrameGetLineOrigins(frame,CFRange(location:0,length:0),&origins); return (lines,origins)
    }
    func index(at point:NSPoint) -> Int {
        let (lines,origins)=lines(); guard let row=origins.indices.min(by:{abs(origins[$0].y+14-point.y)<abs(origins[$1].y+14-point.y)}) else { return 0 }
        let n=CTLineGetStringIndexForPosition(lines[row],CGPoint(x:point.x-14,y:0)); return max(0,min((text as NSString).length,n == kCFNotFound ? CTLineGetStringRange(lines[row]).location : n))
    }
    func scrollY(for index:Int) -> CGFloat {
        let (lines,origins)=lines()
        for (i,line) in lines.enumerated() { let r=CTLineGetStringRange(line); if index < r.location+r.length { return origins[i].y+CGFloat(size)+14-(enclosingScrollView?.contentView.bounds.height ?? 0) } }
        return 0
    }
    override func mouseDown(with event:NSEvent) { window?.makeFirstResponder(self); anchor=index(at:convert(event.locationInWindow,from:nil)); selection=NSRange(location:anchor,length:0); onSelection?(selection); needsDisplay=true }
    override func mouseDragged(with event:NSEvent) { autoscroll(with:event); let end=index(at:convert(event.locationInWindow,from:nil)); selection=NSRange(location:min(anchor,end),length:abs(end-anchor)); onSelection?(selection); needsDisplay=true }
    override var acceptsFirstResponder:Bool { true }
    override func keyDown(with event:NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c", selection.length > 0 { NSPasteboard.general.clearContents(); NSPasteboard.general.setString((text as NSString).substring(with:selection),forType:.string) } else { super.keyDown(with:event) }
    }
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
            let r=CTLineGetStringRange(line), start=max(r.location,selection.location), end=min(r.location+r.length,selection.location+selection.length)
            if end>start {
                let x0=CTLineGetOffsetForStringIndex(line,start,nil),x1=CTLineGetOffsetForStringIndex(line,end,nil)
                ctx.setFillColor(NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35).cgColor)
                ctx.fill(CGRect(x:min(x0,x1)+14,y:origins[index].y+14-CGFloat(size)*0.25,width:max(2,abs(x1-x0)),height:CGFloat(size)*1.2))
            }
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
    let sections=[("scan","預掃描","magnifyingglass"),("charset","字集驗收","checklist"),("mapping","對應追查","arrow.triangle.branch"),("proof","詞句檢查","text.alignleft"),("repair","修復對照","wrench.and.screwdriver"),("team","多人核對","person.2")]
    var body: some View {
        HStack(spacing:0) {
          VStack(alignment:.leading,spacing:16) {
            Text("GlyphCheck").font(.headline).padding(.horizontal,16).padding(.top,24)
            ScrollView {
                VStack(spacing:6) {
                    ForEach(sections,id:\.0) { section in
                        Button { m.workTab=section.0 } label: {
                            Label(m.t(section.1),systemImage:section.2)
                                .frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,12).padding(.vertical,10)
                                .foregroundStyle(m.workTab==section.0 ? Color.white : Color.primary)
                                .background(m.workTab==section.0 ? Color.accentColor : Color.clear,in:RoundedRectangle(cornerRadius:8))
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal,10)
            }.disabled(m.busy)
          }.frame(width:174).background(Color(nsColor:.controlBackgroundColor))
          Divider()
          VStack(alignment:.leading,spacing:20) {
            HStack { Text(m.t(sections.first(where:{$0.0==m.workTab})?.1 ?? "檢查工作台")).font(.title2.bold());Spacer();if m.busy {ProgressView().controlSize(.small)};Button(m.t("完成")){m.showWorkbench=false}.disabled(m.busy) }
            Group {
                switch m.workTab {
                case "scan": scan
                case "charset": GlyphAuditView().environmentObject(m)
                case "mapping": mapping
                case "proof", "repair": proof
                default: team
                }
            }.frame(maxWidth: .infinity,maxHeight: .infinity,alignment: .topLeading)
          }.padding(24)
        }.frame(width:1040,height:720)
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
                        HStack { Text(relation.chain).font(.title3); Spacer(); Text(m.t(relation.status == "confirmed_donor" ? "已確認來源，待驗收" : "待確認")); if relation.cycle { Image(systemName:"arrow.triangle.2.circlepath") } }
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
                        if m.workTab == "repair" { CrossRepairPicker(font:f).environmentObject(m) }
                        HStack(alignment:.top) {
                            if let font = m.loadedFonts[f.id] { proofCard(m.t("原版"),font:font,group:f.id) }
                            if m.workTab == "repair" {
                                if let font = m.repairedFonts[f.id] { proofCard(m.t("未驗收候選預覽"),font:font,group:f.id) }
                                else { Text(m.t("尚無候選。可選擇跨字檔補字／替換來源，或核對原檔內對應。")).frame(maxWidth:.infinity,minHeight:180).foregroundStyle(.secondary) }
                            } else { proofCard(m.t("系統參考"),font:CTFontCreateWithName(m.reference as CFString,36,nil),allowFallback:true,group:f.id) }
                        }
                        if m.workTab == "repair", let item = m.previewResult?.fonts.first(where: { $0.id == f.id }) {
                            ForEach(Array((item.unresolved ?? []).enumerated()),id:\.offset) { _,failure in Text("\(failure.codepoint) · \(failure.reason)").font(.caption).foregroundStyle(.orange) }
                            ForEach(item.suggestions) { suggestion in RepairAcceptanceRow(font:f,suggestion:suggestion).environmentObject(m) }
                        }
                    }.padding(.bottom,14)
                }
            }
            if m.workTab == "repair" {
                HStack { Text(m.t("逐項查看原對應與候選來源；只匯出已驗收項目。")).font(.caption).foregroundStyle(.secondary); Spacer(); Button(m.t("匯出已驗收修復…")) { m.export(attempt:true) }.disabled(!m.hasAcceptedRepairs || m.busy) }
            }
        }
    }
    func proofCard(_ title:String,font:CTFont,allowFallback:Bool=false,group:String="") -> some View {
        VStack(alignment:.leading) { Text(title).font(.caption).foregroundStyle(.secondary); ProofView(font:font,text:m.proofText,size:m.proofSize,allowFallback:allowFallback,syncGroup:group).frame(height:300).background(.background,in:RoundedRectangle(cornerRadius:8)) }.frame(maxWidth:.infinity)
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
    @AppStorage("checkUpdatesOnLaunch") var autoUpdates=false
    var body: some View {
        Form {
            Picker(m.t("介面語言"),selection:Binding(get:{m.uiLanguage},set:{m.setLanguage($0)})) {
                Text("繁體中文").tag("traditional"); Text("简体中文").tag("simplified"); Text("English").tag("english")
            }
            Text(m.t("介面語言不會改變檢查範圍或字檔編碼。")).font(.caption).foregroundStyle(.secondary)
            Button(m.t("關於 GlyphCheck")) { m.about() }
            Section(m.t("更新")) {
                Text(m.t("目前版本")+"："+m.currentAppVersion).font(.caption).foregroundStyle(.secondary)
                Toggle(m.t("啟動時檢查正式版本"),isOn:$autoUpdates)
                HStack {Button(m.t("檢查更新…")){m.checkForUpdates()}.disabled(m.checkingUpdates);if m.checkingUpdates {ProgressView().controlSize(.small)};if let url=m.availableUpdateURL {Link(m.t("開啟下載頁"),destination:url)}}
                if !m.updateStatus.isEmpty {Text(m.updateStatus).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
                Text(m.t("只查詢 GitHub 版本資訊；不傳送字檔、不自動下載或安裝。")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
        }.formStyle(.grouped).padding(12).frame(width:480,height:390)
    }
}
