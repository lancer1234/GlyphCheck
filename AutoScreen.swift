import Foundation
import CoreText
import CoreGraphics
import Vision

struct AutoFinding:Codable {
    var fingerprint:String;var kind:String;var observed:String;var confidence:Double;var reason:String
    var engineVersion:Int? = nil
}
enum GlyphOCR {
    static let engineVersion=2
    // Low-confidence isolated text cannot accuse a font by itself. This floor only
    // permits additional rendering + independent shape checks, not a mismatch verdict.
    static let candidateFloor=0.25
    static func image(_ font:CTFont,_ glyph:CGGlyph,repeated:Bool) -> CGImage? {
        image(font,glyph,count:repeated ? 3 : 1)
    }
    static func image(_ font:CTFont,_ glyph:CGGlyph,count:Int,cell:Int=280) -> CGImage? {
        guard let path=CTFontCreatePathForGlyph(font,glyph,nil) else {return nil}
        let b=path.boundingBoxOfPath
        guard b.width>0,b.height>0 else{return nil}
        let width=count*cell
        guard let ctx=CGContext(data:nil,width:width,height:320,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else{return nil}
        ctx.setFillColor(CGColor(gray:1,alpha:1));ctx.fill(CGRect(x:0,y:0,width:width,height:320));ctx.setFillColor(CGColor(gray:0,alpha:1))
        let scale=min(CGFloat(cell-60)/b.width,220/b.height)
        for n in 0..<count {ctx.saveGState();ctx.translateBy(x:CGFloat(n*cell+cell/2),y:160);ctx.scaleBy(x:scale,y:scale);ctx.translateBy(x:-b.midX,y:-b.midY);ctx.addPath(path);ctx.fillPath();ctx.restoreGState()}
        return ctx.makeImage()
    }
    static func recognize(_ image:CGImage) throws -> (String,Double) {
        let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate;request.usesLanguageCorrection=false
        let supported=try request.supportedRecognitionLanguages()
        request.recognitionLanguages=["zh-Hant","zh-Hans","en-US"].filter{supported.contains($0)}
        guard !request.recognitionLanguages.isEmpty else{throw NSError(domain:"GlyphOCR",code:1,userInfo:[NSLocalizedDescriptionKey:"這台 Mac 沒有可用的文字辨識語言。"])}
        // Never search rotated orientations or inject the expected character as an OCR hint.
        try VNImageRequestHandler(cgImage:image,orientation:.up,options:[:]).perform([request])
        let candidates=(request.results ?? []).compactMap{$0.topCandidates(1).first}
        let chars=candidates.flatMap{$0.string.unicodeScalars.filter{!$0.properties.isWhitespace}}
        guard let first=chars.first,chars.allSatisfy({$0==first}) else{return ("",0)}
        return (String(first),Double(candidates.map(\.confidence).min() ?? 0))
    }
    static func classify(expected:String,first:(String,Double),second:(String,Double),fingerprint:String,third:(String,Double)?=nil,shapeSupported:Bool=false) -> AutoFinding {
        let observed=first.0==second.0 ? first.0 : [first.0,second.0].filter{!$0.isEmpty}.joined(separator:" / ")
        let confidence=min(first.1,second.1)
        func finding(_ kind:String,_ reason:String)->AutoFinding {AutoFinding(fingerprint:fingerprint,kind:kind,observed:observed,confidence:confidence,reason:reason,engineVersion:engineVersion)}
        // Confidence measures the recognizer, not font correctness. Matching low-confidence
        // readings must not flood the mismatch list or become human-approved judgments.
        if first.0==expected && second.0==expected {return finding("agree","兩種正向渲染皆辨識相符；即使 OCR 信心偏低，也不列為疑似誤植。這不是人工確認。")}
        if first.0.isEmpty || second.0.isEmpty {return finding("unreadable","辨識資料不足，歸入無法判定；不是字檔錯誤證據。")}
        if first.0==second.0,confidence>=candidateFloor,let third,third.0==first.0,third.1>=candidateFloor,shapeSupported {
            return finding("mismatch","三種正向渲染穩定辨識為另一字，且至少兩種系統參考字體的輪廓比較支持該候選；仍需人工確認，可能是異體或誤判。")
        }
        return finding("uncertain","辨識不一致、信心不足，或缺乏輪廓佐證；歸入無法判定，不列為疑似誤植。")
    }
}

/// Normalized silhouette distance is only a veto/corroboration signal, never a semantic verdict.
enum GlyphShape {
    static let side=64
    static func mask(_ font:CTFont,_ glyph:CGGlyph)->[UInt8]? {
        guard let path=CTFontCreatePathForGlyph(font,glyph,nil) else{return nil}
        let b=path.boundingBoxOfPath;guard b.width>0,b.height>0 else{return nil}
        var pixels=[UInt8](repeating:255,count:side*side)
        let ok=pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let c=CGContext(data:raw.baseAddress,width:side,height:side,bitsPerComponent:8,bytesPerRow:side,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue) else{return false}
            c.setFillColor(CGColor(gray:1,alpha:1));c.fill(CGRect(x:0,y:0,width:side,height:side));c.setFillColor(CGColor(gray:0,alpha:1))
            let scale=min(54/b.width,54/b.height)
            c.translateBy(x:32,y:32);c.scaleBy(x:scale,y:scale);c.translateBy(x:-b.midX,y:-b.midY);c.addPath(path);c.fillPath();return true
        }
        return ok ? pixels.map{$0<160 ? 1 : 0} : nil
    }
    static func distance(_ a:[UInt8],_ b:[UInt8])->Double {
        guard a.count==side*side,b.count==a.count,a.contains(1),b.contains(1) else{return 1}
        func field(_ mask:[UInt8])->[Double] {
            var d=mask.map{$0==1 ? 0.0 : 128.0}
            for y in 0..<side {for x in 0..<side {let i=y*side+x;if x>0 {d[i]=min(d[i],d[i-1]+1)};if y>0 {d[i]=min(d[i],d[i-side]+1)};if x>0 && y>0 {d[i]=min(d[i],d[i-side-1]+1.414)}}}
            for y in (0..<side).reversed() {for x in (0..<side).reversed() {let i=y*side+x;if x+1<side {d[i]=min(d[i],d[i+1]+1)};if y+1<side {d[i]=min(d[i],d[i+side]+1)};if x+1<side && y+1<side {d[i]=min(d[i],d[i+side+1]+1.414)}}}
            return d
        }
        let da=field(a),db=field(b)
        let ab=a.indices.filter{a[$0]==1}.map{db[$0]}.reduce(0,+)/Double(a.filter{$0==1}.count)
        let ba=b.indices.filter{b[$0]==1}.map{da[$0]}.reduce(0,+)/Double(b.filter{$0==1}.count)
        return (ab+ba)/128
    }
    static func reference(_ character:String,_ family:String)->(CTFont,CGGlyph)? {
        guard character.unicodeScalars.count==1,let scalar=character.unicodeScalars.first else{return nil}
        let font=CTFontCreateWithName(family as CFString,64,nil)
        let actual=CTFontCopyFamilyName(font) as String
        guard actual.localizedCaseInsensitiveContains(family.replacingOccurrences(of:" TC",with:"")) else{return nil}
        var chars=Array(String(scalar).utf16),glyphs=[CGGlyph](repeating:0,count:chars.count)
        guard CTFontGetGlyphsForCharacters(font,&chars,&glyphs,chars.count),glyphs.count==1,glyphs[0]>0 else{return nil}
        return (font,glyphs[0])
    }
    static func supports(_ font:CTFont,_ glyph:CGGlyph,expected:String,candidate:String)->Bool {
        guard expected != candidate,let target=mask(font,glyph) else{return false}
        var support=0
        let flippedY=(0..<side).flatMap{y in Array(target[((side-1-y)*side)..<((side-y)*side)])}
        let rotated=Array(target.reversed())
        for family in ["PingFang TC","Kaiti TC","Songti TC","Helvetica","Times"] {
            guard let e=reference(expected,family),let c=reference(candidate,family),let em=mask(e.0,e.1),let cm=mask(c.0,c.1) else{continue}
            let ed=distance(target,em),cd=distance(target,cm)
            // If the expected glyph is comparably close, or a flipped expected reference
            // explains the candidate, do not promote the OCR guess to a mismatch.
            if cd<0.065,cd<ed*0.72,ed-cd>0.015,
               distance(flippedY,em)>cd+0.01,distance(rotated,em)>cd+0.01 {support+=1}
        }
        return support>=2
    }
}

extension Checker {
    func autoFinding(_ font:String,_ row:GlyphAuditRow)->AutoFinding? {
        guard let result=session.autoFindings?[font]?[row.id],result.fingerprint==row.fingerprint,result.engineVersion==GlyphOCR.engineVersion else{return nil};return result
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
                    var third:(String,Double)?=nil;var shapeSupported=false
                    if pair.0.0==pair.1.0,!pair.0.0.isEmpty,pair.0.0 != row.character,min(pair.0.1,pair.1.1)>=GlyphOCR.candidateFloor {
                        if let image=GlyphOCR.image(font,CGGlyph(gid),count:5,cell:240) {third=try GlyphOCR.recognize(image)}
                        if third?.0==pair.0.0,(third?.1 ?? 0)>=GlyphOCR.candidateFloor {shapeSupported=GlyphShape.supports(font,CGGlyph(gid),expected:row.character,candidate:pair.0.0)}
                    }
                    result=GlyphOCR.classify(expected:row.character,first:pair.0,second:pair.1,fingerprint:row.fingerprint,third:third,shapeSupported:shapeSupported)
                } catch {result=AutoFinding(fingerprint:row.fingerprint,kind:"unreadable",observed:"",confidence:0,reason:error.localizedDescription,engineVersion:GlyphOCR.engineVersion)}
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
