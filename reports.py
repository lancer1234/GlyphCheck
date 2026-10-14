"""Self-contained, script-free visual report. No fonts or local paths are embedded."""
import base64
import html
import unicodedata
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.ttLib import TTFont

def esc(value):
    return html.escape(str(value),quote=True)

def glyph_image(font,cm,cp,glyphset=None):
    name=cm.get(cp)
    if not name or name=='.notdef': return '<div class="missing">缺字／空白 · Missing / blank</div>'
    glyphset=font.getGlyphSet() if glyphset is None else glyphset
    bounds=BoundsPen(glyphset); glyphset[name].draw(bounds)
    if bounds.bounds is None: return '<div class="missing">空白字形 · Blank outline</div>'
    x0,y0,x1,y1=bounds.bounds
    scale=170/max(x1-x0,y1-y0,1)
    pen=SVGPathPen(glyphset); glyphset[name].draw(pen)
    svg=f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 220 220"><path fill="#172033" transform="translate(110 110) scale({scale} {-scale}) translate({-(x0+x1)/2} {-(y0+y1)/2})" d="{esc(pen.getCommands())}"/></svg>'
    data=base64.b64encode(svg.encode()).decode()
    return f'<img class="glyph" alt="Original outline at U+{cp:04X}" src="data:image/svg+xml;base64,{data}">'

def context(text,cp):
    index=text.find(chr(cp))
    if index<0: return ''
    return text[max(0,index-16):index+17]

def write_html(session,drawings,out):
    mode=session.get('reviewMode') or 'full'
    titles={'sample':'隨機抽樣 / Random sample','priority':'問題優先 / Problem-first','full':'完整檢查 / Full review','task':'多人任務 / Team task'}
    status={'mismatch':'確定是另一個字 / Mismatch','variant':'字形不同，可能合理 / Possible valid variant','uncertain':'無法辨認 / Unsure','not_reviewed':'尚未確認 / Unreviewed','correct':'已確認正確 / Correct','missing':'缺字或空白 / Missing or blank','flag':'技術提示，不代表誤植 / Technical flag','conflict':'答案衝突 / Conflicting reviews','reference':'參考存疑 / Reference doubt'}
    parts=['<!doctype html><html lang="zh-Hant"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src \'none\'; img-src data:; style-src \'unsafe-inline\'; base-uri \'none\'; form-action \'none\'"><title>GlyphCheck — 字形核對報告</title><style>body{font:16px/1.65 -apple-system,BlinkMacSystemFont,Arial,sans-serif;color:#172033;background:#f4f6fa;margin:0}main{max-width:1000px;margin:auto;padding:32px 20px}h1{font-size:32px}h2{margin-top:40px}header,.card,details{background:white;border:1px solid #dfe4ee;border-radius:14px;padding:22px;margin:16px 0}p{overflow-wrap:anywhere}.muted{color:#64748b;font-size:14px}.grid{display:grid;grid-template-columns:180px 1fr;gap:24px}.glyph{width:180px;height:180px}.missing{border:1px dashed #cbd5e1;padding:20px;color:#b45309}.row{border-bottom:1px solid #e2e8f0;padding:10px 0}code{font-size:14px}summary{cursor:pointer;font-weight:600}@media(max-width:560px){.grid{grid-template-columns:1fr}.glyph{width:140px;height:140px}main{padding:16px}}@media print{body{background:white}.card{break-inside:avoid}}</style></head><body><main>']
    parts[0]=parts[0].replace('<style>','<style>figure{margin:0}h3,h4{overflow-wrap:anywhere}')
    ordering=session.get('queueMode') or mode
    parts.append(f'<header><p class="muted">MAKOTO LAB · GlyphCheck</p><h1>字形核對報告 / Glyph review report</h1><p>{esc(session.get("scope",""))} · {esc(titles.get(mode,mode))}</p><p>本次檢查 {len(session.get("domain",[]))} 字；選定字集 {len(session.get("population") or session.get("domain",[]))} 字。出題：{esc(titles.get(ordering,ordering))}</p><p>未確認、未抽樣與字形差異不視為錯字或正確保證。隨機樣本與問題優先出題不能混為同一種統計。</p><p class="muted">輪廓圖片來自這次匯入的字檔，不使用備援字體。報告不包含整份字檔或本機路徑；分享前請確認文字片段及檔名沒有私人資料。</p></header>')
    text=session.get('inputText') or session.get('proofText') or ''
    for font,cm,meta,info in drawings:
        glyphset=font.getGlyphSet(); cache={}; source_cache={}
        def image(cp):
            if cp not in cache: cache[cp]=glyph_image(font,cm,cp,glyphset)
            return cache[cp]
        fid=meta['id']; answers=session.get('answers',{}).get(fid,{})
        flags={item['cp'] for item in meta.get('scan',[]) if item['cp'] in session.get('domain',[])}
        conflicts=session.get('reviewConflicts',{}).get(fid,{})
        doubts=set(session.get('referenceDoubts',[]))
        issues=set(int(cp) for cp,a in answers.items() if a['kind'] in ('mismatch','variant','uncertain'))
        issues.update(ord(row['character']) for row in info['missing']);issues.update(flags);issues.update(map(int,conflicts));issues.update(doubts)
        parts.append(f'<h2>{esc(info["font"])}</h2><p>{esc(meta["filename"])} · {esc(info["fontVersion"])} · face {meta["face"]+1} (index {meta["face"]})</p><p class="muted">SHA-256: <code>{esc(meta["sha256"])}</code></p>')
        parts.append(f'<p>缺字 {len(info["missing"])} · 待確認 {len(info["pending"])} · 未抽樣 {len(info["unsampled"])} · 已驗收並輸出 {len(info["repaired"])} · 未驗收預覽 {len(info["previewChanges"])}</p>')
        for cp in sorted(issues):
            a=answers.get(str(cp),{}); kind='missing' if not meta['visible'].get(str(cp),False) else a.get('kind','flag')
            if str(cp) in conflicts: kind='conflict'
            elif cp in doubts: kind='reference'
            actual=a.get('actual',''); excerpt=context(text,cp)
            parts.append(f'<article class="card"><div class="grid"><figure>{image(cp)}<figcaption class="muted">原字檔輪廓 / Original</figcaption></figure><div><h3>預期字碼：{esc(chr(cp))} · U+{cp:04X}</h3><p class="muted">{esc(unicodedata.name(chr(cp),"Unnamed character"))}</p><p>{esc(status.get(kind,kind))}</p>')
            if cp in flags: parts.append('<p class="muted">預掃描（不是錯字判定）：'+esc(' / '.join(item['detail'] for item in meta.get('scan',[]) if item['cp']==cp))+'</p>')
            if actual: parts.append(f'<p>人工看到的字：{esc(actual)} · U+{ord(actual):04X}</p>')
            if excerpt: parts.append(f'<p>文字片段：{esc(excerpt)}</p>')
            if str(cp) in conflicts: parts.append('<p>'+esc(' / '.join(v['reviewer']+': '+v['answer']['kind']+' '+v['answer'].get('actual','') for v in conflicts[str(cp)]))+'</p>')
            parts.append('</div></div></article>')
        parts.append('<h3>修復候選與驗收 / Repair candidates</h3>')
        for row in info['suggestions']:
            cp=ord(row['character']); donor=ord(row['donor'])
            donor_image=image(donor); source_note='原檔內候選，依人工字碼判定。'
            if row.get('sourceID'):
                source=next(m for m in session['repairSources'] if m['id']==row['sourceID'])
                if source['id'] not in source_cache:
                    sf=TTFont(source['preview']);source_cache[source['id']]=(sf,sf.getBestCmap(),sf.getGlyphSet())
                sf,scm,sgs=source_cache[source['id']]; donor_image=glyph_image(sf,scm,donor,sgs)
                source_note=f'跨字檔來源：{row["sourceFont"]} · SHA-256 {row["sourceSHA256"]} · face {row["sourceFace"]}；驗收代表使用者確認來源字形。'
            parts.append(f'<article class="card"><h4>{esc(row["character"])} · {row["codepoint"]} ← {esc(row["donor"])} · {row["donorCodepoint"]}</h4><p>{esc(row["status"])} · {esc(row["reviewer"])} · {esc(row["reviewedAt"])}</p><p>{esc(source_note)}</p><div class="grid">{image(cp)}{donor_image}</div><p class="muted">左：原對應；右：候選來源。未驗收預覽不等於已修復。</p></article>')
        for label,rows in [('尚未確認 / Pending',info['pending']),('尚未抽樣 / Unsampled',info['unsampled']),('未修正 / Unresolved',info['unresolved'])]:
            parts.append(f'<details><summary>{label} ({len(rows)})</summary>')
            for row in rows: parts.append('<div class="row">'+esc(' · '.join(str(row.get(k,'')) for k in ('character','expected','codepoint','status','reason')) )+'</div>')
            parts.append('</details>')
    parts.append('<footer><p class="muted">© MAKOTO LAB · 原檔對應修復／跨字檔輪廓補字只正式輸出已驗收候選；不自動修正排版表或繪製新字形。完整資料請使用同資料夾的 JSON / CSV。</p></footer></main></body></html>')
    (out/'圖文核對報告.html').write_text('\n'.join(parts),encoding='utf-8')
