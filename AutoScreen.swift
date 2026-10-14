import Foundation
import CoreText
import CoreGraphics
import Vision

struct AutoFinding:Codable {
    var fingerprint:String;var kind:String;var observed:String;var confidence:Double;var reason:String
}
enum GlyphOCR {
    static func image(_ font:CTFont,_ glyph:CGGlyph,repeated:Bool) -> CGImage? {
        guard let path=CTFontCreatePathForGlyph(font,glyph,nil) else {return nil}
        let b=path.boundingBoxOfPath
        guard b.width>0,b.height>0 else{return nil}
        let count=repeated ? 3 : 1,width=count*280
        guard let ctx=CGContext(data:nil,width:width,height:320,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else{return nil}
        ctx.setFillColor(CGColor(gray:1,alpha:1));ctx.fill(CGRect(x:0,y:0,width:width,height:320));ctx.setFillColor(CGColor(gray:0,alpha:1))
        let scale=min(220/b.width,220/b.height)
        for n in 0..<count {ctx.saveGState();ctx.translateBy(x:CGFloat(n*280+140),y:160);ctx.scaleBy(x:scale,y:scale);ctx.translateBy(x:-b.midX,y:-b.midY);ctx.addPath(path);ctx.fillPath();ctx.restoreGState()}
        return ctx.makeImage()
    }
    static func recognize(_ image:CGImage) throws -> (String,Double) {
        let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate;request.usesLanguageCorrection=false
        let supported=try request.supportedRecognitionLanguages()
        request.recognitionLanguages=["zh-Hant","zh-Hans","en-US"].filter{supported.contains($0)}
        guard !request.recognitionLanguages.isEmpty else{throw NSError(domain:"GlyphOCR",code:1,userInfo:[NSLocalizedDescriptionKey:"這台 Mac 沒有可用的文字辨識語言。"])}
        try VNImageRequestHandler(cgImage:image,options:[:]).perform([request])
        let candidates=(request.results ?? []).compactMap{$0.topCandidates(1).first}
        let chars=candidates.flatMap{$0.string.unicodeScalars.filter{!$0.properties.isWhitespace}}
        guard let first=chars.first,chars.allSatisfy({$0==first}) else{return ("",0)}
        return (String(first),Double(candidates.map(\.confidence).min() ?? 0))
    }
    static func classify(expected:String,first:(String,Double),second:(String,Double),fingerprint:String) -> AutoFinding {
        let observed=first.0==second.0 ? first.0 : [first.0,second.0].filter{!$0.isEmpty}.joined(separator:" / ")
        let confidence=min(first.1,second.1)
        if first.0.isEmpty || second.0.isEmpty {return AutoFinding(fingerprint:fingerprint,kind:"unreadable",observed:observed,confidence:confidence,reason:"至少一種渲染無法可靠辨識，保留人工核對。")}
        if first.0 != second.0 || confidence<0.55 {return AutoFinding(fingerprint:fingerprint,kind:"uncertain",observed:observed,confidence:confidence,reason:"不同渲染的辨識不一致或信心偏低；不作錯字定論。")}
        return AutoFinding(fingerprint:fingerprint,kind:first.0==expected ? "agree" : "mismatch",observed:observed,confidence:confidence,reason:first.0==expected ? "兩種渲染辨識一致；仍未經人工確認。" : "單字與重複字渲染均辨識成另一個字；可能是誤植、異體或 OCR 誤判。")
    }
}

extension Checker {
    func autoFinding(_ font:String,_ row:GlyphAuditRow)->AutoFinding? {
        guard let result=session.autoFindings?[font]?[row.id],result.fingerprint==row.fingerprint else{return nil};return result
    }
    func startAutoScreen(_ fontID:String) {
        guard !autoRunning,!busy,let audit=glyphAudit?.fonts.first(where:{$0.id==fontID}),let meta=session.fonts.first(where:{$0.id==fontID}) else{return}
        let all=autoLimit.trimmingCharacters(in:.whitespacesAndNewlines)=="0"
        guard let limit=Int(autoLimit),limit>=0 else{auditError="請輸入正整數，0 代表全部。";return}
        let eligible=audit.rows.filter {row in row.present && (row.glyphID ?? -1)>=0 && (row.glyphID ?? 65536)<=65535 && row.character.unicodeScalars.count==1 && row.character.unicodeScalars.first?.properties.isWhitespace != true && autoFinding(fontID,row)==nil}
        let rows=all ? eligible : Array(eligible.prefix(limit))
        guard !rows.isEmpty else{auditError="沒有尚未初篩且有獨立字碼的字形。無字碼變體需人工核對。";return}
        let sessionID=session.id,runID=UUID();autoRunID=runID
        autoProgress=0;autoTotal=rows.count;autoRunning=true;auditError=nil
        autoTask=Task.detached(priority:.utility) { [self] in
            guard let provider=CGDataProvider(url:URL(fileURLWithPath:meta.preview) as CFURL),let cg=CGFont(provider) else{
                await MainActor.run{guard self.autoRunID==runID else{return};self.auditError="無法讀取初篩字檔。";self.autoRunning=false;self.autoTask=nil};return
            }
            let font=CTFontCreateWithGraphicsFont(cg,256,nil,nil)
            var cache:[Int:((String,Double),(String,Double))]=[:]
            for row in rows {
                if Task.isCancelled {break}
                var result:AutoFinding
                do {
                    let gid=row.glyphID!
                    if cache[gid]==nil {
                        guard let single=GlyphOCR.image(font,CGGlyph(gid),repeated:false),let repeated=GlyphOCR.image(font,CGGlyph(gid),repeated:true) else{throw NSError(domain:"GlyphOCR",code:2,userInfo:[NSLocalizedDescriptionKey:"字形沒有可辨識輪廓。"])}
                        cache[gid]=(try GlyphOCR.recognize(single),try GlyphOCR.recognize(repeated))
                    }
                    let pair=cache[gid]!
                    result=GlyphOCR.classify(expected:row.character,first:pair.0,second:pair.1,fingerprint:row.fingerprint)
                } catch {result=AutoFinding(fingerprint:row.fingerprint,kind:"unreadable",observed:"",confidence:0,reason:error.localizedDescription)}
                if result.kind=="agree",let scalar=row.character.unicodeScalars.first,meta.scan?.contains(where:{$0.cp==Int(scalar.value) && $0.kind=="duplicate"})==true {result.kind="uncertain";result.reason="預掃描發現不同字碼共用輪廓；可能是合法共用設計，需人工核對。"}
                let finding=result
                await MainActor.run {
                    guard self.session.id==sessionID,self.autoRunID==runID else{return}
                    self.session.autoFindings=self.session.autoFindings ?? [:]
                    self.session.autoFindings![fontID,default:[:]][row.id]=finding
                    self.autoProgress+=1
                    if self.autoProgress % 20==0 {self.save()}
                }
            }
            await MainActor.run {guard self.session.id==sessionID,self.autoRunID==runID else{return};self.autoRunning=false;self.autoTask=nil;self.save()}
        }
    }
    func stopAutoScreen(){autoTask?.cancel()}
}
