import SwiftUI
import AppKit
import CoreText
import UniformTypeIdentifiers

struct FontRecord: Codable, Identifiable {
    var id: String
    var name: String
    var filename: String
    var source: String
    var preview: String
    var face: Int
    var sha256: String
    var glyphs: [String: Int]
    var visible: [String: Bool]
    var notes: [String]
    var upem: Int
}
struct Answer: Codable, Equatable {
    var kind: String
    var actual: String = ""
}
struct Session: Codable {
    var version = 1
    var id = UUID().uuidString
    var fonts: [FontRecord] = []
    var scope = "字檔所有字元"
    var domain: [Int] = []
    var remaining: [Int] = []
    var current: Int? = nil
    var answers: [String: [String: Answer]] = [:]
    var followed: [String] = []
    var referenceDoubts: [Int] = []
    var started = false
    // Optional fields keep 1.0 progress files readable.
    var population: [Int]? = nil
    var sampled: [Int]? = nil
    var reviewMode: String? = nil
    var requestedSampleSize: Int? = nil
    var scriptVariant: String? = nil
    var uiLanguage: String? = nil
}
struct ImportResult: Codable { var fonts: [FontRecord] }
struct UndoEntry { var cp: Int; var answers: [String: Answer]; var remaining: [Int]; var followed: [String]; var doubts: [Int] }
struct ReviewIssue: Identifiable {
    var font: String; var cp: Int; var kind: String; var actual: String
    var id: String { "\(font):\(cp):\(kind)" }
}
struct Selection {
    var population: [Int]; var selected: [Int]
    static func allows(_ cp: Int, variant: String) -> Bool {
        guard variant != "all", let scalar = UnicodeScalar(cp), scalar.properties.isIdeographic else { return true }
        let s = char(cp)
        let transform = StringTransform(variant == "traditional" ? "Simplified-Traditional" : "Traditional-Simplified")
        return (s.applyingTransform(transform, reverse: false) ?? s) == s
    }
    static func make(fonts: [FontRecord], scope: String, custom: String, variant: String, sampleSize: Int?) throws -> Selection {
        let pool: Set<Int>
        switch scope {
        case "漢字基本區": pool = Set(0x4e00...0x9fff)
        case "漢字基本＋擴展 A": pool = Set(0x3400...0x4dbf).union(0x4e00...0x9fff)
        case "自訂文字": pool = Set(custom.unicodeScalars.map { Int($0.value) })
        default: pool = Set(fonts.flatMap { $0.glyphs.keys.compactMap(Int.init) })
        }
        let population = pool.filter { reviewable($0) && allows($0,variant: variant) }.sorted()
        if population.isEmpty { throw NSError(domain: "GlyphCheck", code: 4,userInfo: [NSLocalizedDescriptionKey: "這個範圍沒有可檢查的字元。"] ) }
        if let sampleSize {
            let available = population.filter { cp in fonts.contains { $0.visible[String(cp)] == true } }
            guard sampleSize > 0 && sampleSize <= available.count else {
                throw NSError(domain: "GlyphCheck",code: 4,userInfo: [NSLocalizedDescriptionKey: "抽樣數量請輸入 1 至 \(available.count.formatted()) 的整數。"])
            }
            return Selection(population: population,selected: Array(available.shuffled().prefix(sampleSize)).sorted())
        }
        return Selection(population: population,selected: population)
    }
}

func char(_ cp: Int) -> String { UnicodeScalar(cp).map { String($0) } ?? "�" }
func pinyin(_ cp: Int) -> String {
    let s = char(cp)
    let transformed = s.applyingTransform(.mandarinToLatin, reverse: false) ?? s
    return transformed == s ? "無單字拼音" : transformed
}
func reviewable(_ cp: Int) -> Bool {
    guard let s = UnicodeScalar(cp) else { return false }
    switch s.properties.generalCategory {
    case .control, .format, .surrogate, .spaceSeparator, .lineSeparator, .paragraphSeparator: return false
    default: return true
    }
}

@MainActor final class Checker: ObservableObject {
    @Published var session = Session()
    @Published var scope = "字檔所有字元"
    @Published var custom = ""
    @Published var drafts: [String: Answer] = [:]
    @Published var typed: [String: String] = [:]
    @Published var busy = false
    @Published var status = "匯入字檔，開始逐字確認。"
    @Published var error: String?
    @Published var completed = 0
    @Published var reference = "PingFang TC"
    @Published var zoom: Double = 1
    @Published var faceChoices: [FontRecord] = []
    @Published var selectedFace = ""
    @Published var showFaces = false
    @Published var showIssues = false
    @Published var issueFilter = "mismatch"
    @Published var sampleMode = false
    @Published var sampleCount = "200"
    @Published var scriptVariant = "all"
    @Published var uiLanguage = "traditional"
    var translations: [String: String] = [:]
    var undoStack: [UndoEntry] = []
    var loadedFonts: [String: CTFont] = [:]
    let base: URL
    var folder: URL { base.appendingPathComponent(session.id, isDirectory: true) }
    var saveURL: URL { folder.appendingPathComponent("進度.glyphcheck") }
    let resources = Bundle.main.resourceURL!
    let persistRecent: Bool
    init(storageRoot: URL? = nil, persistRecent: Bool = true) {
        self.persistRecent = persistRecent
        if persistRecent { uiLanguage = UserDefaults.standard.string(forKey: "uiLanguage") ?? "traditional" }
        base = storageRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("字形檢查器/Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    func t(_ value: String) -> String {
        guard uiLanguage == "simplified" else { return value }
        if let cached = translations[value] { return cached }
        let converted = value.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? value
        translations[value] = converted; return converted
    }
    func setLanguage(_ value: String) {
        uiLanguage = value
        if persistRecent { UserDefaults.standard.set(value,forKey: "uiLanguage") }
    }
    func run(_ args: [String]) async throws -> Data {
        let root = resources
        return try await Task.detached {
            let p = Process()
            p.executableURL = root.appendingPathComponent("runtime/bin/python3")
            p.arguments = [root.appendingPathComponent("backend.py").path] + args
            var env = ProcessInfo.processInfo.environment
            env["PYTHONHOME"] = root.appendingPathComponent("runtime").path
            env["PYTHONPATH"] = root.appendingPathComponent("packages").path
            env["PYTHONDONTWRITEBYTECODE"] = "1"
            p.environment = env
            let pipe = Pipe(); p.standardOutput = pipe
            let err = Pipe(); p.standardError = err
            // Drain stderr concurrently to avoid blocking on verbose font diagnostics.
            let stderrTask = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let diagnostic = await stderrTask.value
            if p.terminationStatus != 0 {
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                throw NSError(domain: "GlyphCheck", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    obj?["error"] as? String ?? String(data: diagnostic, encoding: .utf8) ?? "無法讀取字檔"])
            }
            return data
        }.value
    }
    func importPanel() {
        guard !busy && !session.started && session.fonts.count < 2 else { return }
        let p = NSOpenPanel(); p.title = t("匯入一或兩個字檔"); p.allowsMultipleSelection = true
        p.allowedContentTypes = ["ttf","otf","ttc","otc"].compactMap { UTType(filenameExtension: $0) }
        if p.runModal() == .OK {
            let urls = Array(p.urls.prefix(2 - session.fonts.count))
            Task { for url in urls { await importURL(url) } }
        }
    }
    func importURL(_ url: URL) async {
        guard session.fonts.count < 2 && !session.started else { return }
        busy = true; status = "正在讀取字碼與實際字形…"
        do {
            let data = try await run(["inspect",url.path,folder.appendingPathComponent("Fonts").path])
            let result = try JSONDecoder().decode(ImportResult.self, from: data)
            if result.fonts.count > 1 {
                faceChoices = result.fonts; selectedFace = result.fonts[0].id; showFaces = true
                status = "請選擇字體集合中的字面。"
            } else { try add(result.fonts[0]) }
        } catch { self.error = error.localizedDescription }
        busy = false
    }
    func add(_ f: FontRecord) throws {
        if session.fonts.contains(where: { $0.sha256 == f.sha256 && $0.face == f.face }) {
            throw NSError(domain: "GlyphCheck", code: 2, userInfo: [NSLocalizedDescriptionKey: "這個字檔與字面已匯入。"])
        }
        guard let provider = CGDataProvider(url: URL(fileURLWithPath: f.preview) as CFURL),
              let cg = CGFont(provider) else {
            throw NSError(domain: "GlyphCheck", code: 2, userInfo: [NSLocalizedDescriptionKey: "macOS 無法載入這個字面的輪廓。"])
        }
        loadedFonts[f.id] = CTFontCreateWithGraphicsFont(cg, CGFloat(f.upem), nil, nil)
        session.fonts.append(f); status = "已匯入 \(session.fonts.count) 個字檔。"
        save()
    }
    func chooseFace() {
        guard let f = faceChoices.first(where: { $0.id == selectedFace }) else { return }
        do { try add(f) } catch { self.error = error.localizedDescription }
        showFaces = false; faceChoices = []
    }
    func remove(_ f: FontRecord) { session.fonts.removeAll { $0.id == f.id }; loadedFonts[f.id] = nil; save() }
    func start() {
        guard !busy, !session.fonts.isEmpty else { return }
        let requested = sampleMode ? Int(sampleCount.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
        if sampleMode && (requested == nil || requested! <= 0) { error = "抽樣數量請輸入大於 0 的整數。"; return }
        let fonts = session.fonts, selectedScope = scope, input = custom, variant = scriptVariant
        busy = true; status = "正在準備檢查字元…"
        Task {
            do {
                let selection = try await Task.detached { try Selection.make(fonts: fonts,scope: selectedScope,custom: input,variant: variant,sampleSize: requested) }.value
                session.scope = selectedScope; session.domain = selection.selected; session.population = selection.population
                session.sampled = requested == nil ? nil : selection.selected
                session.reviewMode = requested == nil ? "full" : "sample"; session.requestedSampleSize = requested
                session.scriptVariant = variant; session.uiLanguage = uiLanguage; session.started = true
                session.remaining = selection.selected.filter { cp in fonts.contains { $0.visible[String(cp)] == true } }.shuffled()
                session.current = session.remaining.popLast(); reference = variant == "simplified" ? "PingFang SC" : "PingFang TC"
                loadDrafts(); refresh(); save(); status = requested == nil ? "檢查已開始。" : "抽樣檢查已開始。"
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
    func loadDrafts() {
        drafts = [:]; typed = [:]
        guard let cp = session.current else { return }
        for f in session.fonts {
            if let a = session.answers[f.id]?[String(cp)] {
                drafts[f.id] = a; typed[f.id] = a.actual
            }
        }
    }
    func mark(_ f: FontRecord, _ kind: String) {
        if kind == "mismatch" {
            let actual = (typed[f.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard actual.unicodeScalars.count == 1 else { error = "請只輸入一個你實際看到的字（不是拼音或說明）。"; return }
            if actual == char(session.current ?? 0) { error = "輸入的字與題目相同；若字形正確請按「正確」。"; return }
            drafts[f.id] = Answer(kind: kind, actual: actual)
        } else { typed[f.id] = ""; drafts[f.id] = Answer(kind: kind) }
    }
    func quickAdvance() {
        guard let cp = session.current, !busy, !showFaces, error == nil else { return }
        for f in session.fonts where f.visible[String(cp)] == true {
            let actual = (typed[f.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !actual.isEmpty {
                guard actual.unicodeScalars.count == 1 else { error = "請只輸入一個你看到的字。"; return }
                if actual == char(cp) { drafts[f.id] = Answer(kind: "correct") }
                else { drafts[f.id] = Answer(kind: "mismatch", actual: actual) }
            } else if drafts[f.id] == nil { drafts[f.id] = Answer(kind: "correct") }
        }
        NSApp.keyWindow?.makeFirstResponder(nil)
        submit()
    }
    func help() {
        let a = NSAlert(); a.messageText = "字形檢查器"
        a.informativeText = "Enter：確認並進入下一題。沒有輸入時視為正確；輸入一個字時記錄為你看到的字，接著追查該字。中文輸入法選字時，Enter 只確認選字。\n\n進度自動保存在本機，可用「繼續上次檢查」恢復。缺字以選定範圍為準；空白及控制字元不出題。\n\n拼音是系統的單字轉寫，多音字和罕見字可能不完整。參考字存疑時，可切換字體或保留待確認。\n\n修正只使用人工確認的字形來源；不猜補字、不覆寫原檔、不安裝字體。來源衝突、尚未確認及缺字會列入報告。"
        a.messageText = t(a.messageText); a.informativeText = t(a.informativeText)
        a.addButton(withTitle: t("好")); a.runModal()
    }
    var canNext: Bool {
        guard let cp = session.current else { return false }
        return session.fonts.allSatisfy { $0.visible[String(cp)] != true || drafts[$0.id] != nil }
    }
    func submit(allCorrect: Bool = false, uncertain: Bool = false, referenceDoubt: Bool = false) {
        guard let cp = session.current, !busy else { return }
        for f in session.fonts where f.visible[String(cp)] == true {
            if allCorrect { drafts[f.id] = Answer(kind: "correct") }
            if uncertain { drafts[f.id] = Answer(kind: "uncertain") }
        }
        guard canNext else { error = "請分別判定每個字檔，或按「確認，下一題」。"; return }
        var old: [String: Answer] = [:]
        for f in session.fonts { old[f.id] = session.answers[f.id]?[String(cp)] }
        undoStack.append(UndoEntry(cp: cp, answers: old, remaining: session.remaining, followed: session.followed, doubts: session.referenceDoubts))
        if referenceDoubt && !session.referenceDoubts.contains(cp) { session.referenceDoubts.append(cp) }
        var targets: [Int] = []
        for f in session.fonts {
            guard let a = drafts[f.id] else { continue }
            session.answers[f.id, default: [:]][String(cp)] = a
            if a.kind == "mismatch", let seen = a.actual.unicodeScalars.first {
                let target = Int(seen.value); let edge = "\(f.id):\(cp):\(target)"
                if !session.followed.contains(edge) && !targets.contains(target) {
                    session.followed.append(edge); targets.append(target)
                    if !session.domain.contains(target) { session.domain.append(target); session.domain.sort() }
                }
            }
        }
        for target in targets { session.remaining.removeAll { $0 == target } }
        // Stack order ensures the first observed character is the very next question.
        session.remaining.append(contentsOf: targets.reversed())
        session.current = session.remaining.popLast()
        if !referenceDoubt && drafts.values.allSatisfy({ $0.kind != "uncertain" }) { session.referenceDoubts.removeAll { $0 == cp } }
        status = targets.isEmpty ? "判定已保存。" : "接著追查回報字的字碼對應。"
        loadDrafts(); refresh(); save()
    }
    func undo() {
        guard let entry = undoStack.popLast() else { return }
        for f in session.fonts { session.answers[f.id, default: [:]][String(entry.cp)] = entry.answers[f.id] }
        session.remaining = entry.remaining; session.current = entry.cp; session.followed = entry.followed; session.referenceDoubts = entry.doubts
        loadDrafts(); refresh(); save(); status = "已回到上一題，可重新判定。"
    }
    func refresh() {
        completed = session.domain.filter { cp in session.fonts.allSatisfy { f in
            f.visible[String(cp)] != true || ["correct","mismatch"].contains(session.answers[f.id]?[String(cp)]?.kind ?? "")
        }}.count
    }
    func retry() {
        session.remaining = session.domain.filter { cp in session.fonts.contains { f in
            f.visible[String(cp)] == true && !["correct","mismatch"].contains(session.answers[f.id]?[String(cp)]?.kind ?? "")
        }}.shuffled()
        session.current = session.remaining.popLast(); loadDrafts(); save()
    }
    func jump() {
        let a = NSAlert(); a.messageText = t("指定要複查的字"); a.addButton(withTitle: t("前往")); a.addButton(withTitle: t("取消"))
        let field = NSTextField(frame: NSRect(x: 0,y: 0,width: 240,height: 28)); field.placeholderString = t("例如：") + "常"
        a.accessoryView = field
        guard a.runModal() == .alertFirstButtonReturn, field.stringValue.unicodeScalars.count == 1,
              let scalar = field.stringValue.unicodeScalars.first else { return }
        let cp = Int(scalar.value)
        visit(cp)
    }
    func persistDrafts() {
        guard let cp = session.current else { return }
        for (id,answer) in drafts { session.answers[id,default: [:]][String(cp)] = answer }
        refresh()
    }
    func visit(_ cp: Int) {
        guard !busy else { return }
        if session.current == cp { showIssues = false; return }
        for (id,value) in typed where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if drafts[id]?.actual != value && drafts[id]?.kind != "correct" {
                showIssues = false; error = "請先提交目前輸入的字，或清空輸入，再複查其他字。"; return
            }
        }
        persistDrafts()
        if let previous = session.current, !session.remaining.contains(previous) { session.remaining.append(previous) }
        session.remaining.removeAll { $0 == cp }; session.current = cp
        if !session.domain.contains(cp) { session.domain.append(cp); session.domain.sort() }
        showIssues = false; loadDrafts(); refresh(); save()
    }
    var knownIssues: [ReviewIssue] {
        var result: [ReviewIssue] = []
        for f in session.fonts {
            var answers = session.answers[f.id] ?? [:]
            if let cp = session.current, let draft = drafts[f.id] { answers[String(cp)] = draft }
            for cp in session.domain {
                if f.visible[String(cp)] != true {
                    result.append(ReviewIssue(font: f.id,cp: cp,kind: "missing",actual: ""))
                } else if let a = answers[String(cp)], ["mismatch","uncertain"].contains(a.kind) {
                    result.append(ReviewIssue(font: f.id,cp: cp,kind: a.kind,actual: a.actual))
                }
            }
        }
        for cp in session.referenceDoubts { result.append(ReviewIssue(font: "reference",cp: cp,kind: "reference",actual: "")) }
        return result.sorted { $0.cp == $1.cp ? $0.id < $1.id : $0.cp < $1.cp }
    }
    func save() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            session.uiLanguage = uiLanguage
            try encoder.encode(session).write(to: saveURL, options: .atomic)
            if persistRecent { UserDefaults.standard.set(saveURL.path, forKey: "lastSession") }
        } catch { self.error = "保存進度失敗：\(error.localizedDescription)" }
    }
    func saveCopy() {
        persistDrafts(); save(); let p = NSSavePanel(); p.nameFieldStringValue = "字形檢查進度.glyphcheck"
        if p.runModal() == .OK, let url = p.url {
            do { try Data(contentsOf: saveURL).write(to: url, options: .atomic) } catch { self.error = error.localizedDescription }
        }
    }
    func openSession(_ url: URL? = nil) {
        var target = url
        if target == nil {
            let p = NSOpenPanel(); p.title = t("開啟檢查進度"); p.allowedContentTypes = [UTType(filenameExtension: "glyphcheck") ?? .json,.json]
            if p.runModal() == .OK { target = p.url }
        }
        guard let target else { return }
        do {
            let s = try JSONDecoder().decode(Session.self, from: Data(contentsOf: target))
            guard s.version == 1 && (1...2).contains(s.fonts.count) else { throw CocoaError(.fileReadCorruptFile) }
            var loaded: [String: CTFont] = [:]
            for f in s.fonts {
                guard FileManager.default.fileExists(atPath: f.source), let provider = CGDataProvider(url: URL(fileURLWithPath: f.preview) as CFURL), let cg = CGFont(provider) else {
                    throw NSError(domain: "GlyphCheck",code: 3,userInfo: [NSLocalizedDescriptionKey: "找不到保存的字檔。請保留工作階段資料夾，或重新匯入原檔。"])
                }
                loaded[f.id] = CTFontCreateWithGraphicsFont(cg,CGFloat(f.upem),nil,nil)
            }
            session = s; loadedFonts = loaded; scope = s.scope; undoStack = []
            scriptVariant = s.scriptVariant ?? "all"; sampleMode = s.reviewMode == "sample"
            sampleCount = String(s.requestedSampleSize ?? 200); uiLanguage = s.uiLanguage ?? uiLanguage
            reference = scriptVariant == "simplified" ? "PingFang SC" : "PingFang TC"
            loadDrafts(); refresh(); status = "已恢復保存的進度。"
        } catch { self.error = error.localizedDescription }
    }
    func resume() {
        if let p = UserDefaults.standard.string(forKey: "lastSession") { openSession(URL(fileURLWithPath: p)) }
    }
    func newSession() {
        let a = NSAlert(); a.messageText = t("建立新的檢查？"); a.informativeText = t("目前進度會保留，不會刪除原字檔。"); a.addButton(withTitle: t("建立")); a.addButton(withTitle: t("取消"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        persistDrafts(); save(); session = Session(); loadedFonts = [:]; drafts = [:]; typed = [:]; undoStack = []; completed = 0; showIssues = false; status = "匯入新的字檔。"
    }
    func export(attempt: Bool) {
        let p = NSOpenPanel(); p.title = t(attempt ? "選擇修正字檔與報告的保存位置" : "選擇報告保存位置")
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        guard p.runModal() == .OK, let root = p.url else { return }
        persistDrafts(); save(); busy = true; status = "正在匯出目前建議與報告…"
        let date = DateFormatter(); date.dateFormat = "yyyyMMdd-HHmmss"
        let output = root.appendingPathComponent("字形檢查-\(date.string(from: Date()))-\(UUID().uuidString.prefix(4))")
        Task {
            do {
                _ = try await run(["export",saveURL.path,output.path,attempt ? "repair" : "report"])
                status = "報告已保存；尚未確認的字也已列出。"
                NSWorkspace.shared.open(output)
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

struct GlyphPicture: NSViewRepresentable {
    var font: CTFont?
    var glyph: Int?
    var zoom: Double
    func makeNSView(context: Context) -> GlyphView { GlyphView() }
    func updateNSView(_ view: GlyphView, context: Context) { view.font = font; view.glyph = glyph; view.zoom = zoom; view.needsDisplay = true }
}
final class GlyphView: NSView {
    var font: CTFont?; var glyph: Int?; var zoom = 1.0
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let font, let glyph, glyph > 0, glyph <= Int(UInt16.max),
              let path = CTFontCreatePathForGlyph(font, CGGlyph(glyph), nil) else { return }
        let b = path.boundingBoxOfPath
        guard b.width > 0 && b.height > 0 else { return }
        let scale = min(bounds.width * 0.75 / b.width,bounds.height * 0.75 / b.height) * zoom
        ctx.saveGState(); ctx.translateBy(x: bounds.midX - b.midX * scale,y: bounds.midY - b.midY * scale)
        ctx.scaleBy(x: scale,y: scale); ctx.setFillColor(NSColor.labelColor.cgColor); ctx.addPath(path); ctx.fillPath(); ctx.restoreGState()
    }
}
func referenceGlyph(_ cp: Int, family: String) -> (CTFont,Int,String) {
    let s = char(cp)
    let base = CTFontCreateWithName(family as CFString,256,nil)
    let font = CTFontCreateForString(base,s as CFString,CFRange(location: 0,length: s.utf16.count))
    let chars = Array(s.utf16); var gids = Array(repeating: CGGlyph(0),count: chars.count)
    CTFontGetGlyphsForCharacters(font,chars,&gids,chars.count)
    return (font,Int(gids.first(where: { $0 != 0 }) ?? 0),CTFontCopyFamilyName(font) as String)
}

@MainActor struct ContentView: View {
    @EnvironmentObject var m: Checker
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "character.book.closed.fill").foregroundStyle(.tint).font(.title2)
                Text(m.t("字形檢查器")).font(.headline)
                Spacer()
                if m.busy { ProgressView().controlSize(.small) }
                Menu { Button(m.t("開啟檢查進度…")) { m.openSession() }; Button(m.t("保存進度副本…")) { m.saveCopy() }; Button(m.t("顯示工作階段資料夾")) { NSWorkspace.shared.open(m.folder) }; Divider(); Button(m.t("使用說明")) { m.help() }; Button(m.t("新的檢查…")) { m.newSession() } } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 26)
            }.padding(22)
            Divider()
            if m.session.started { review } else { welcome }
            Divider()
            HStack { Text(m.t(m.status)).font(.caption).foregroundStyle(.secondary).lineLimit(1); Spacer() }.padding(.horizontal,22).padding(.vertical,10)
        }
        .frame(minWidth: 900,minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(EnterHandler(checker: m).frame(width: 0,height: 0))
        .disabled(m.busy)
        .alert(m.t("請確認"),isPresented: Binding(get: { m.error != nil },set: { if !$0 { m.error = nil } })) { Button(m.t("好")) { m.error = nil } } message: { Text(m.t(m.error ?? "")) }
        .sheet(isPresented: $m.showFaces) {
            VStack(alignment: .leading,spacing: 20) {
                Text(m.t("選擇字面")).font(.title2)
                Text(m.t("這是包含多個字面的集合。請選一個；可再匯入一次比較另一字面。")).foregroundStyle(.secondary)
                Picker(m.t("字面"),selection: $m.selectedFace) { ForEach(m.faceChoices) { Text("\($0.face + 1). \($0.name)").tag($0.id) } }
                HStack { Button(m.t("取消")) { m.showFaces = false }; Spacer(); Button(m.t("匯入")) { m.chooseFace() }.buttonStyle(.borderedProminent) }
            }.padding(28).frame(width: 500)
        }
        .sheet(isPresented: $m.showIssues) { issuesPanel }
        .onOpenURL { url in if url.pathExtension == "glyphcheck" { m.openSession(url) } else { Task { await m.importURL(url) } } }
        .onDrop(of: [.fileURL],isTargeted: nil) { providers in
            guard !m.session.started else { return false }
            for provider in providers.prefix(2 - m.session.fonts.count) {
                _ = provider.loadObject(ofClass: URL.self) { url,_ in if let url { Task { @MainActor in await m.importURL(url) } } }
            }; return true
        }
    }
    var welcome: some View {
        ScrollView {
            VStack(spacing: 25) {
                VStack(spacing: 12) { Image(systemName: "character.magnify").font(.system(size: 48,weight: .light)).foregroundStyle(.tint); Text(m.t("讓字形對回正確的字")).font(.largeTitle.bold()) }.padding(.top,32)
                HStack(spacing: 14) {
                    ForEach(m.session.fonts) { f in
                        VStack(alignment: .leading,spacing: 9) {
                            HStack { Image(systemName: "doc.text").foregroundStyle(.tint); Text(f.name).font(.headline).lineLimit(2); Spacer(); Button { m.remove(f) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                            Text(f.filename).font(.caption).foregroundStyle(.secondary)
                            Text(m.t("\(f.visible.values.filter { $0 }.count.formatted()) 個非空白字形")).font(.subheadline)
                        }.padding(18).frame(maxWidth: .infinity,alignment: .leading).background(.background,in: RoundedRectangle(cornerRadius: 14))
                    }
                    if m.session.fonts.count < 2 {
                        Button { m.importPanel() } label: { VStack(spacing: 10) { Image(systemName: "plus.circle").font(.title); Text(m.t(m.session.fonts.isEmpty ? "匯入字檔" : "加入第二個字檔")); Text(m.t("TTF · OTF · TTC · 可拖曳")).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity,minHeight: 108) }.buttonStyle(.bordered)
                    }
                }
                VStack(alignment: .leading,spacing: 12) {
                    Picker(m.t("介面語言"), selection: Binding(get: { m.uiLanguage },set: { m.setLanguage($0) })) {
                        Text(m.t("繁體中文")).tag("traditional"); Text(m.t("简体中文")).tag("simplified")
                    }.frame(maxWidth: 380)
                    Picker(m.t("檢查範圍"),selection: $m.scope) { ForEach(["字檔所有字元","漢字基本區","漢字基本＋擴展 A","自訂文字"],id: \.self) { Text(m.t($0)) } }.frame(maxWidth: 380)
                    Picker(m.t("字元篩選"),selection: $m.scriptVariant) {
                        Text(m.t("全部（繁簡皆含）")).tag("all"); Text(m.t("繁體")).tag("traditional"); Text(m.t("簡體")).tag("simplified")
                    }.frame(maxWidth: 380).help(m.t("繁簡篩選使用系統單字轉換，共用字保留；部分一對多或古字需人工判斷，不改動字檔編碼。"))
                    Picker(m.t("檢查方式"),selection: $m.sampleMode) { Text(m.t("完整檢查")).tag(false); Text(m.t("隨機抽樣")).tag(true) }.pickerStyle(.segmented).frame(maxWidth: 380)
                    if m.sampleMode {
                        HStack { Text(m.t("抽樣字數")); TextField(m.t("數量"),text: $m.sampleCount).textFieldStyle(.roundedBorder).frame(width: 100) }
                    }
                    if m.scope == "自訂文字" { TextField(m.t("貼上想檢查的文字；會去除重複字"),text: $m.custom).textFieldStyle(.roundedBorder) }
                }.padding(18).background(.background,in: RoundedRectangle(cornerRadius: 14))
                HStack { Button(m.t("繼續上次檢查")) { m.resume() }; Spacer(); Button(m.t("開始檢查")) { m.start() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(m.session.fonts.isEmpty) }
            }.padding(.horizontal,40).padding(.bottom,28).frame(maxWidth: 850)
            .frame(maxWidth: .infinity)
        }
    }
    var review: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading,spacing: 5) { Text(m.t(m.session.scope + (m.session.reviewMode == "sample" ? " · 隨機抽樣" : ""))).font(.headline); Text(m.t("已處理 \(m.completed.formatted()) / \(m.session.domain.count.formatted()) 字（含追查與缺字）")).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(m.t("問題字")) { m.showIssues = true }
                Button(m.t("指定字複查")) { m.jump() }
                Menu(m.t("匯出")) { Button(m.t("匯出目前建議與報告…")) { m.export(attempt: false) }; Button(m.t("嘗試修正並匯出…")) { m.export(attempt: true) } }
            }
            ProgressView(value: Double(m.completed),total: Double(max(1,m.session.domain.count)))
            if let cp = m.session.current {
                ScrollView {
                    HStack(alignment: .top,spacing: 16) {
                        referenceCard(cp)
                        ForEach(m.session.fonts) { f in fontCard(f,cp) }
                    }.padding(.vertical,4)
                }
                HStack {
                    Button { m.undo() } label: { Label(m.t("上一題"),systemImage: "arrow.uturn.backward") }.disabled(m.undoStack.isEmpty)
                    Button(m.t("暫時不確定")) { m.submit(uncertain: true) }
                    Spacer()
                    Button(m.t("下一題")) { m.submit() }.disabled(!m.canNext)
                    Button(m.t("確認，下一題 ↵")) { m.quickAdvance() }.buttonStyle(.borderedProminent).help(m.t("直接按 Enter；沒有輸入時確認正確，有輸入時回報看到的字"))
                }
                HStack { Spacer(); Image(systemName: "minus.magnifyingglass"); Slider(value: $m.zoom,in: 0.7...1.3).frame(width: 100); Image(systemName: "plus.magnifyingglass") }
            } else {
                Spacer()
                Image(systemName: m.completed == m.session.domain.count ? "checkmark.seal" : "pause.circle").font(.system(size: 56,weight: .light)).foregroundStyle(.tint)
                Text(m.t(m.completed == m.session.domain.count ? (m.session.reviewMode == "sample" ? "這次抽樣已判定完成" : "這個範圍已判定完成") : "已走完一輪，還有待確認的字")).font(.title2.bold())
                HStack { if m.completed < m.session.domain.count { Button(m.t("繼續待確認字")) { m.retry() } }; Button(m.t("嘗試修正並匯出報告")) { m.export(attempt: true) }.buttonStyle(.borderedProminent) }
                Spacer()
            }
        }.padding(24)
    }
    var issuesPanel: some View {
        let issues = m.knownIssues
        let shown = issues.filter { m.issueFilter == "all" || $0.kind == m.issueFilter }
        return VStack(alignment: .leading,spacing: 16) {
            HStack { Text(m.t("問題字")).font(.title2.bold()); Spacer(); Button(m.t("匯出目前建議")) { m.export(attempt: false) }; Button(m.t("完成")) { m.showIssues = false } }
            Picker(m.t("類型"),selection: $m.issueFilter) {
                Text(m.t("誤植")).tag("mismatch"); Text(m.t("待確認")).tag("uncertain"); Text(m.t("缺字")).tag("missing"); Text(m.t("參考存疑")).tag("reference"); Text(m.t("全部")).tag("all")
            }.pickerStyle(.segmented)
            if shown.isEmpty { Text(m.t("目前沒有這類問題字。")).foregroundStyle(.secondary).frame(maxWidth: .infinity,maxHeight: .infinity) }
            else {
                List(shown) { issue in
                    Button { m.visit(issue.cp) } label: {
                        HStack(spacing: 15) {
                            Text(char(issue.cp)).font(.system(size: 28)).frame(width: 42)
                            VStack(alignment: .leading,spacing: 4) {
                                Text(issue.font == "reference" ? m.t("系統參考") : m.session.fonts.first(where: { $0.id == issue.font })?.name ?? issue.font).font(.headline)
                                Text(String(format: "U+%04X",issue.cp)).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if issue.kind == "mismatch" { Text("→ " + issue.actual).font(.title3) }
                            else { Text(m.t(issue.kind == "missing" ? "缺字" : issue.kind == "reference" ? "參考存疑" : "待確認")).foregroundStyle(.secondary) }
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }.padding(.vertical,5).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }.listStyle(.inset)
            }
        }.padding(24).frame(width: 650,height: 520)
    }
    func referenceCard(_ cp: Int) -> some View {
        let ref = referenceGlyph(cp,family: m.reference)
        return VStack(spacing: 14) {
            Text(m.t("系統參考")).font(.headline)
            GlyphPicture(font: ref.0,glyph: ref.1,zoom: m.zoom).frame(height: 200).accessibilityLabel("參考字：\(char(cp))")
            Text(m.t(pinyin(cp))).font(.title3).foregroundStyle(.tint).textSelection(.enabled)
            Text(String(format: "U+%04X",cp)).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            Picker(m.t("參考"),selection: $m.reference) { Text(m.t("黑體")).tag(m.scriptVariant == "simplified" ? "PingFang SC" : "PingFang TC"); Text(m.t("宋體")).tag(m.scriptVariant == "simplified" ? "Songti SC" : "Songti TC"); Text(m.t("楷體")).tag(m.scriptVariant == "simplified" ? "Kaiti SC" : "Kaiti TC") }.labelsHidden()
            if ref.1 == 0 { Text(m.t("系統也沒有這個字形")).font(.caption).foregroundStyle(.orange) }
            Button(m.t("參考字也存疑")) { m.submit(uncertain: true,referenceDoubt: true) }.font(.caption)
        }.padding(18).frame(maxWidth: .infinity).background(Color.accentColor.opacity(0.06),in: RoundedRectangle(cornerRadius: 16))
    }
    func fontCard(_ f: FontRecord,_ cp: Int) -> some View {
        let has = f.visible[String(cp)] == true
        let a = m.drafts[f.id]
        return VStack(alignment: .leading,spacing: 14) {
            Text(f.name).font(.headline).lineLimit(2).frame(height: 38,alignment: .topLeading)
            if has {
                GlyphPicture(font: m.loadedFonts[f.id],glyph: f.glyphs[String(cp)],zoom: m.zoom).frame(height: 200)
                    .accessibilityLabel("待檢查字形，題目 \(char(cp))")
                HStack { Button { m.mark(f,"correct") } label: { Label(m.t("正確"),systemImage: a?.kind == "correct" ? "checkmark.circle.fill" : "checkmark.circle") }.tint(a?.kind == "correct" ? .green : .accentColor); Spacer(); Text(m.t(a?.kind == "correct" ? "已選正確" : a?.kind == "mismatch" ? "已回報誤植" : a?.kind == "uncertain" ? "待確認" : "尚未判定")).font(.caption).foregroundStyle(.secondary) }
                TextField(m.t("我看到的字是…"),text: Binding(get: { m.typed[f.id] ?? "" },set: { m.typed[f.id] = $0; m.drafts[f.id] = nil })).textFieldStyle(.roundedBorder)
                    .onSubmit { m.quickAdvance() }
                HStack { Button(m.t("回報誤植")) { m.mark(f,"mismatch") }; Button(m.t("無法辨認")) { m.mark(f,"uncertain") } }.font(.subheadline)
                if a?.kind == "mismatch" { Text("→ \(a?.actual ?? "")").font(.caption).foregroundStyle(.orange) }
            } else {
                VStack(spacing: 12) { Image(systemName: "square.dashed").font(.system(size: 44,weight: .light)); Text(m.t("缺字／空白字形")).font(.headline) }.foregroundStyle(.secondary).frame(maxWidth: .infinity,minHeight: 280)
            }
        }.padding(18).frame(maxWidth: .infinity,alignment: .topLeading).background(.background,in: RoundedRectangle(cornerRadius: 16))
    }
}

struct EnterHandler: NSViewRepresentable {
    var checker: Checker
    func makeCoordinator() -> Coordinator { Coordinator(checker) }
    func makeNSView(context: Context) -> NSView { context.coordinator.install(); return NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.remove() }
    @MainActor final class Coordinator {
        weak var checker: Checker?
        var monitor: Any?
        init(_ checker: Checker) { self.checker = checker }
        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let checker = self?.checker, [36,76].contains(event.keyCode),
                      event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty,
                      let window = NSApp.keyWindow, window.title == "字形檢查器", window.attachedSheet == nil,
                      checker.session.current != nil, !checker.busy, checker.error == nil, !checker.showFaces, !checker.showIssues else { return event }
                // Enter during IME composition must only commit the selected character.
                if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
                if !event.isARepeat { checker.quickAdvance() }
                return nil
            }
        }
        func remove() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
}

#if !TESTING
@MainActor @main struct GlyphCheckApp: App {
    @StateObject var checker = Checker()
    var body: some Scene {
        WindowGroup("字形檢查器") { ContentView().environmentObject(checker) }
            .defaultSize(width: 1080,height: 760)
            .commands { CommandGroup(replacing: .newItem) { Button(checker.t("新的檢查")) { checker.newSession() }.keyboardShortcut("n"); Button(checker.t("匯入字檔…")) { checker.importPanel() }.keyboardShortcut("o"); Button(checker.t("保存進度")) { checker.persistDrafts(); checker.save() }.keyboardShortcut("s") } }
    }
}
#endif
