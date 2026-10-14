"""Glyph-name list coverage. Suffixes are never silently collapsed to base characters."""
import csv
import hashlib
import html
import json
import re
from pathlib import Path
from fontTools.agl import toUnicode
from fontTools.ttLib import TTFont
from reports import glyph_image

def parse_lists(paths):
    lists=[]
    for path in paths:
        p=Path(path);raw=p.read_bytes()
        if len(raw)>10000000: raise ValueError('字集清單過大')
        text=raw.decode('utf-8-sig') if not raw.startswith((b'\xff\xfe',b'\xfe\xff')) else raw.decode('utf-16')
        names=list(dict.fromkeys(line.strip() for line in text.splitlines() if line.strip() and not line.lstrip().startswith('#')))
        if not names or len(names)>100000 or any(not re.fullmatch(r'[A-Za-z0-9_.-]{1,200}',n) for n in names):
            raise ValueError('請選擇每行一個字形名稱的 Glyphs 清單；不是 .glyphs 設計檔。')
        lists.append(dict(name=p.stem,entries=names,sha256=hashlib.sha256(raw).hexdigest()))
    return dict(lists=lists)

def unicode_for(name):
    if '.' in name or '_' in name: return None
    value=toUnicode(name)
    if len(value)==1: return ord(value)
    match=re.fullmatch(r'uni([0-9A-Fa-f]{4})|u([0-9A-Fa-f]{4,6})',name)
    if match:
        cp=int(match.group(1) or match.group(2),16)
        if cp<=0x10ffff and not 0xd800<=cp<=0xdfff: return cp
    return None

def audit(session_path,out=None):
    session=json.loads(Path(session_path).read_text());result=[];figures=[]
    lists=session.get('glyphLists') or []
    for meta in session['fonts']:
        raw=Path(meta['source']).read_bytes()
        if hashlib.sha256(raw).hexdigest()!=meta['sha256']: raise ValueError('原字檔已變動，請重新匯入。')
        f=TTFont(meta['source'],fontNumber=meta['face']);gs=f.getGlyphSet();cm=TTFont(meta['preview']).getBestCmap() or {}
        rows=[]; votes=(session.get('glyphReviews') or {}).get(meta['id'],{})
        for group in lists:
            for name in group['entries']:
                cp=unicode_for(name);glyph=name if name in gs else cm.get(cp) if cp is not None else None
                visible=False
                if glyph and glyph!='.notdef':
                    from fontTools.pens.boundsPen import BoundsPen
                    pen=BoundsPen(gs);gs[glyph].draw(pen);visible=pen.bounds is not None or (cp is not None and chr(cp).isspace())
                key=group['sha256']+':'+name
                fp=hashlib.sha256(f'{meta["sha256"]}:{meta["face"]}:{key}:{glyph}'.encode()).hexdigest()
                vote=votes.get(key,{}) if votes.get(key,{}).get('fingerprint')==fp else {}
                status=('found' if vote.get('decision')=='correct' else 'pending') if visible else ('missing' if cp is not None or name in gs else 'unresolved')
                reason=('原字檔含同名字形' if name in gs else '依明確 Unicode／標準 AGL 對應') if glyph else ('已知字碼但字檔缺少' if cp is not None else '字檔沒有同名項目，且無可靠單字碼對應；不猜測變體')
                rows.append(dict(id=key,list=group['name'],name=name,codepoint=f'U+{cp:04X}' if cp is not None else '',character=chr(cp) if cp is not None else '',glyph=glyph or '',glyphID=f.getGlyphID(glyph) if glyph else None,present=visible,status=status,reason=reason,fingerprint=fp,decision=vote.get('decision',''),note=vote.get('note','')))
        result.append(dict(id=meta['id'],font=meta['name'],sha256=meta['sha256'],rows=rows))
        figures.append((f,gs))
    if out:
        out=Path(out);out.mkdir(parents=True,exist_ok=True)
        (out/'字集驗收.json').write_text(json.dumps(dict(fonts=result,lists=lists),ensure_ascii=False,indent=2))
        labels=dict(found='已找到／已人工確認',missing='缺少',unresolved='無法判定',pending='待人工核對')
        body=['<!doctype html><html lang="zh-Hant"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><meta http-equiv="Content-Security-Policy" content="default-src \'none\'; img-src data:; style-src \'unsafe-inline\'"><title>GlyphCheck 字集驗收</title><style>body{font:16px/1.6 system-ui;margin:32px;color:#172033}article{border:1px solid #ddd;border-radius:12px;padding:16px;margin:16px 0;break-inside:avoid}img{width:140px}h3,p{overflow-wrap:anywhere}</style><h1>字集驗收 · GlyphCheck</h1><p>包含命名字形與 Unicode 字元。實際存在不代表字義正確；無可靠對應的名稱保留，不轉成英文字母，不剝除變體後綴。分享前檢查註記及字集授權。</p>']
        for info,(f,gs) in zip(result,figures):
            body.append('<h2>'+html.escape(info['font'])+'</h2>')
            body.append('<p>'+html.escape(' · '.join(labels[k]+': '+str(sum(r['status']==k for r in info['rows'])) for k in labels))+'</p><p>SHA-256: '+info['sha256']+'</p>')
            with (out/(info['id'][:6]+'-字集驗收.csv')).open('w',encoding='utf-8-sig',newline='') as fp:
                writer=csv.DictWriter(fp,fieldnames=list(info['rows'][0]) if info['rows'] else ['name']);writer.writeheader();writer.writerows(info['rows'])
            for row in info['rows']:
                body.append('<article><h3>'+html.escape(row['list']+' · '+row['name']+' '+row['codepoint'])+'</h3><p>'+html.escape(labels[row['status']]+' · '+row['reason']+' · '+row['note'])+'</p>')
                if row['present']: body.append(glyph_image(f,{0:row['glyph']},0,gs))
                body.append('</article>')
        body.append('<footer>© MAKOTO LAB · 不包含完整字檔，原檔未修改。</footer></html>')
        (out/'字集驗收.html').write_text('\n'.join(body))
    return dict(fonts=result)
