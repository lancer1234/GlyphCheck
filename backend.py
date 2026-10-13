"""Local-only font inspector. No OCR guesses and no network calls."""
import csv
import hashlib
import json
import struct
import sys
import unicodedata
import uuid
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from fontTools.ttLib import TTFont, TTCollection
from fontTools.ttLib.tables._c_m_a_p import CmapSubtable
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.recordingPen import DecomposingRecordingPen
from fontTools.agl import toUnicode

def prescan(font, cm, visible):
    """Heuristics only: shared outlines and aliases can be intentional."""
    shapes=defaultdict(list); issues=[]; glyphset=font.getGlyphSet(); cache={}
    for cp,g in sorted(cm.items()):
        if unicodedata.category(chr(cp)) in ('Zs','Zl','Zp','Cc','Cf','Cs'): continue
        if not visible.get(str(cp),False):
            issues.append(dict(cp=cp,kind='blank',detail='Blank or .notdef outline')); continue
        try:
            if g not in cache:
                pen=DecomposingRecordingPen(glyphset); glyphset[g].draw(pen)
                cache[g]=hashlib.sha256(repr(pen.value).encode()).hexdigest()
            shapes[cache[g]].append(cp)
        except Exception:
            issues.append(dict(cp=cp,kind='outline',detail='Outline could not be compared'))
        named=toUnicode(g)
        if len(named)==1 and ord(named)!=cp:
            issues.append(dict(cp=cp,kind='name',detail=f'Glyph name {g} suggests U+{ord(named):04X}'))
    for group in shapes.values():
        if len(group)>1:
            detail=' / '.join(f'U+{cp:04X}' for cp in group[:20])
            for cp in group: issues.append(dict(cp=cp,kind='duplicate',detail=detail))
    return issues

def relationships(answers, plan, conflicts=()):
    edges={int(cp):ord(a['actual']) for cp,a in answers.items() if a.get('kind')=='mismatch' and len(a.get('actual',''))==1}
    rows=[]
    for start in sorted(edges):
        chain=[]; seen=set(); cp=start
        while cp in edges and cp not in seen:
            seen.add(cp); chain.append(cp); cp=edges[cp]
        chain.append(cp)
        rows.append(dict(expected=chr(start),codepoint=f'U+{start:04X}',chain=' → '.join(chr(c) for c in chain),
            cycle=cp in seen,status='conflict' if str(start) in conflicts else 'confirmed_donor' if start in plan else 'needs_confirmation'))
    return rows

def mapping(font, raw, face=0):
    result = dict(font.getBestCmap() or {})
    notes = []
    # Legacy Windows Big5 is not Unicode. Decode rather than treating bytes as scalars.
    if not result:
        for table in font['cmap'].tables:
            if (table.platformID, table.platEncID) == (3, 4):
                for code, name in table.cmap.items():
                    try:
                        s = code.to_bytes(2, 'big').decode('big5hkscs') if code > 255 else bytes([code]).decode('ascii')
                        if len(s) == 1:
                            result[ord(s)] = name
                    except (UnicodeError, OverflowError):
                        pass
        if result:
            notes.append('Windows Big5 字碼已轉為 Unicode；原檔不變。')
    # Recover malformed format 4 whose 16-bit length overflowed. Bound every read.
    if not result:
        u16 = lambda o: struct.unpack_from('>H', raw, o)[0]
        u32 = lambda o: struct.unpack_from('>I', raw, o)[0]
        base = u32(12 + face * 4) if raw[:4] == b'ttcf' else 0
        for i in range(u16(base + 4)):
            p = base + 12 + 16 * i
            if raw[p:p+4] != b'cmap':
                continue
            c, length = u32(p+8), u32(p+12)
            end = min(c+length, len(raw))
            order = font.getGlyphOrder()
            for j in range(u16(c+2)):
                p = c+4+8*j
                platform, encoding, offset = u16(p), u16(p+2), u32(p+4)
                q = c+offset
                if not (platform == 0 or (platform == 3 and encoding in (1,10))):
                    continue
                if q+16 > end or u16(q) != 4:
                    continue
                n = u16(q+6)//2
                ends = q+14; starts = ends+2*n+2; deltas = starts+2*n; ranges = deltas+2*n
                if n == 0 or ranges+2*n > end:
                    continue
                for k in range(n):
                    a,z,d,r = u16(starts+2*k),u16(ends+2*k),u16(deltas+2*k),u16(ranges+2*k)
                    for cp in range(a,z+1):
                        o = ranges+2*k+r+2*(cp-a)
                        if r and o+2 > end:
                            continue
                        gid = (cp+d)&65535 if not r else u16(o)
                        if r and gid: gid=(gid+d)&65535
                        if 0 < gid < len(order) and cp != 65535:
                            result[cp]=order[gid]
            if result: notes.append('已復原異常 format-4 字碼表；仍須人工確認字義。')
    return {cp:g for cp,g in result.items() if 0 <= cp <= 0x10ffff and not 0xd800 <= cp <= 0xdfff}, notes

def set_cmap(font, cm):
    tables=[]
    # Format 12 avoids oversized format 4 (common in repaired CJK fonts).
    for platform, encoding in [(0,4),(3,10)]:
        t=CmapSubtable.newSubtable(12); t.platformID=platform; t.platEncID=encoding; t.language=0; t.cmap=dict(cm)
        tables.append(t)
    # Keep variation-selector mappings; cmap repair must not discard them.
    font['cmap'].tables=tables+[t for t in font['cmap'].tables if t.format==14]

def inspect(path, dest):
    path=Path(path); dest=Path(dest); dest.mkdir(parents=True,exist_ok=True)
    raw=path.read_bytes()
    count=struct.unpack_from('>I',raw,8)[0] if raw[:4]==b'ttcf' else 1
    if count > 64: raise ValueError('字體集合過大（最多 64 個字面）。')
    fonts=[]
    for face in range(count):
        f=TTFont(path,fontNumber=face,lazy=False)
        cm,notes=mapping(f,raw,face)
        if not cm: raise ValueError('找不到可復原的 Unicode／Big5 字碼表。')
        glyphset=f.getGlyphSet(); visible={}; bounds_cache={}
        for cp,g in cm.items():
            if g not in bounds_cache:
                pen=BoundsPen(glyphset); glyphset[g].draw(pen); bounds_cache[g]=pen.bounds is not None
            visible[str(cp)]=bool(bounds_cache[g] and g != '.notdef')
        fid=str(uuid.uuid4()); original=dest/(fid+path.suffix.lower()); original.write_bytes(raw)
        title=f['name'].getDebugName(4) or f['name'].getDebugName(1) or path.stem
        preview=dest/(fid+'.preview.otf')
        set_cmap(f,cm)
        # Loading CGFont from exact preview bytes bypasses installed family-name caches.
        f.flavor=None; f.save(preview)
        fonts.append(dict(id=fid,name=title,filename=path.name,source=str(original),preview=str(preview),face=face,
            sha256=hashlib.sha256(raw).hexdigest(),glyphs={str(cp):f.getGlyphID(g) for cp,g in cm.items()},
            visible=visible,notes=notes,upem=f['head'].unitsPerEm,scan=prescan(f,cm,visible)))
    return {'fonts':fonts}

def repair_plan(cm, visible, answers, missing_targets=()):
    # A verified displayed shape gives a donor for what the user SAW, not for the expected label.
    donors=defaultdict(list); errors={}; unresolved=[]
    for key,a in answers.items():
        cp=int(key)
        if a['kind']=='correct' and cp in cm and visible.get(str(cp),False): donors[cp].append(cp)
        elif a['kind']=='mismatch':
            actual=a.get('actual', '')
            if len(actual)==1 and cp in cm and visible.get(str(cp),False):
                donors[ord(actual)].append(cp); errors[cp]=ord(actual)
    replacements={}
    targets = dict(errors)
    for cp in missing_targets:
        if cp in donors: targets.setdefault(cp,None)
    for target,seen in targets.items():
        options=donors.get(target,[])
        # Shared glyph aliases are not evidence of different shapes.
        by_glyph=defaultdict(list)
        for cp in options: by_glyph[cm[cp]].append(cp)
        if len(by_glyph)==1:
            donor=next(iter(by_glyph.values()))[0]
            replacements[target]=donor
        else:
            unresolved.append(dict(expected=chr(target),codepoint=f'U+{target:04X}',seen=chr(seen) if seen is not None else '',
                reason='沒有經人工確認的原字形來源' if not by_glyph else '多個相異來源衝突，需要再次確認',candidates=options))
    return replacements,unresolved

def export(session_path,out,attempt):
    s=json.loads(Path(session_path).read_text()); out=Path(out); out.mkdir(parents=True,exist_ok=True)
    domain=s.get('domain',[]); population=s.get('population') or domain
    sampled=s.get('sampled') or []; mode=s.get('reviewMode') or 'full'; result=[]
    for meta in s['fonts']:
        if hashlib.sha256(Path(meta['source']).read_bytes()).hexdigest() != meta['sha256']:
            raise ValueError('保存的原字檔已變動，為避免錯用字形，已停止輸出。請重新匯入。')
        f=TTFont(meta['source'],fontNumber=meta['face'],lazy=False)
        cm,notes=mapping(f,Path(meta['source']).read_bytes(),meta['face'])
        answers=s.get('answers',{}).get(meta['id'],{})
        conflicts=s.get('reviewConflicts',{}).get(meta['id'],{})
        # Disputed labels must not become donors, even when a local answer exists.
        doubts={str(cp) for cp in s.get('referenceDoubts',[])}
        safe_answers={cp:a for cp,a in answers.items() if cp not in conflicts and cp not in doubts}
        absent=[cp for cp in domain if not meta['visible'].get(str(cp),False)]
        plan,unresolved=repair_plan(cm,meta['visible'],safe_answers,absent)
        unresolved.extend(dict(expected=chr(int(cp)),codepoint=f'U+{int(cp):04X}',reason='Reviewers disagree; manual reconciliation required',candidates=values) for cp,values in conflicts.items())
        repaired=[]; missing=[]; pending=[]; issues=[]
        suggestions=[dict(character=chr(target),codepoint=f'U+{target:04X}',donor=chr(donor),donorCodepoint=f'U+{donor:04X}',glyph=cm[donor],status='有已確認來源，可重編碼') for target,donor in sorted(plan.items())]
        unsampled=[dict(character=chr(cp),codepoint=f'U+{cp:04X}',status='未抽樣，不視為正確') for cp in sorted(set(population)-set(domain))] if mode=='sample' else []
        for cp in domain:
            a=answers.get(str(cp)); char=chr(cp)
            if not meta['visible'].get(str(cp),False) and unicodedata.category(char) not in ('Zs','Zl','Zp','Cc','Cf','Cs'):
                missing.append(dict(character=char,codepoint=f'U+{cp:04X}',reason='沒有字碼' if cp not in cm else '空白或 .notdef 字形'))
            elif str(cp) in conflicts or str(cp) in doubts or not a or a['kind'] in ('uncertain','skipped'):
                pending.append(dict(character=char,codepoint=f'U+{cp:04X}',status=a['kind'] if a else 'not_reviewed'))
            if a: issues.append(dict(character=char,codepoint=f'U+{cp:04X}',status=a['kind'],observed=a.get('actual','')))
        output=None
        if attempt and plan:
            new=dict(cm)
            for target,donor in plan.items():
                new[target]=cm[donor]
                repaired.append(dict(character=chr(target),codepoint=f'U+{target:04X}',donor=chr(donor),glyph=cm[donor]))
            set_cmap(f,new); f.flavor=None
            suffix=datetime.now().strftime('%Y%m%d-%H%M%S')+'-'+meta['id'][:6]
            family=meta['name']+' 檢查修正版 '+suffix
            identity_ids=(1,3,4,6,16,21)
            f['name'].names=[n for n in f['name'].names if n.nameID not in identity_ids]
            for nid in (1,4,16,21):
                f['name'].setName(family,nid,3,1,0x409)
                f['name'].setName(family,nid,0,4,0)
            ps='GlyphCheck-'+suffix
            f['name'].setName(ps,6,3,1,0x409); f['name'].setName(ps,6,0,4,0)
            f['name'].setName(ps,3,3,1,0x409)
            if 'CFF ' in f:
                cff=f['CFF '].cff; cff.fontNames=[ps]
                # CFF strings are Latin-1; Unicode display names remain in the OpenType name table.
                cff.topDictIndex[0].FamilyName=ps; cff.topDictIndex[0].FullName=ps
            # Signature and layout caches cannot describe the modified cmap.
            for tag in ('DSIG',):
                if tag in f: del f[tag]
            output=meta['id'][:6]+'-repaired'+('.ttf' if 'glyf' in f else '.otf')
            f.save(out/output)
            check=TTFont(out/output)
            assert check.getBestCmap()==new, '修正輸出字碼驗證失敗'
        elif not attempt:
            for target,donor in plan.items():
                unresolved.append(dict(expected=chr(target),codepoint=f'U+{target:04X}',seen=answers.get(str(target),{}).get('actual',''),donor=chr(donor),reason='已找到來源，但尚未執行修正'))
        info=dict(id=meta['id'],font=meta['name'],filename=meta['filename'],sha256=meta['sha256'],face=meta['face'],
            scope=s.get('scope',''),scopeCount=len(domain),missing=missing,repaired=repaired,unresolved=unresolved,
            pending=pending,answers=issues,output=output,notes=notes,suggestions=suggestions,unsampled=unsampled,
            reviewMode=mode,populationCount=len(population),requestedSampleSize=s.get('requestedSampleSize'),sampledCount=len(sampled),
            extraReviewCount=len(set(domain)-set(sampled)) if mode=='sample' else 0,
            scriptVariant=s.get('scriptVariant') or 'all',isPartial=bool(pending or unsampled),
            limitations=['僅依使用者人工標註修正 cmap；不自動補畫字形。','未檢查 GSUB/GPOS 連字、變體選擇符、垂直字形或複雜排版。','缺字僅針對本次選定／抽樣及追加字元，不代表整個 Unicode。','繁簡篩選採系統單字轉換，古字與一對多轉換可能需人工判斷；不會改寫原字碼。'])
        for item in missing:
            item['status']='已由確認來源恢復' if attempt and ord(item['character']) in plan else '待補字'
        info['referenceDoubts']=[{'character':chr(cp),'codepoint':f'U+{cp:04X}'} for cp in s.get('referenceDoubts',[])]
        info['relationships']=relationships(answers,plan,conflicts)
        info['reviewConflicts']=conflicts
        info['reviewVotes']=s.get('reviewVotes',{}).get(meta['id'],{})
        info['preflight']=meta.get('scan',[])
        info['populationMissing']=[dict(character=chr(cp),codepoint=f'U+{cp:04X}',reason='Absent or blank in selected population') for cp in population if not meta['visible'].get(str(cp),False) and unicodedata.category(chr(cp)) not in ('Zs','Zl','Zp','Cc','Cf','Cs')]
        result.append(info)
        prefix=meta['id'][:6]
        for name,rows in [('缺字',missing),('已修正',repaired),('未修正',unresolved),('待確認',pending),('人工判定',issues),('參考存疑',info['referenceDoubts']),('修正建議',suggestions),('未抽樣',unsampled),('對應追查',info['relationships']),('預掃描',info['preflight']),('範圍缺字',info['populationMissing'])]:
            with (out/(prefix+'-'+name+'.csv')).open('w',encoding='utf-8-sig',newline='') as fp:
                fields=list(dict.fromkeys(k for row in rows for k in row)) or ['character','codepoint','status']
                writer=csv.DictWriter(fp,fieldnames=fields); writer.writeheader(); writer.writerows(rows)
    (out/'檢查報告.json').write_text(json.dumps({'version':1,'fonts':result},ensure_ascii=False,indent=2))
    (out/'檢查進度.glyphcheck').write_text(json.dumps(s,ensure_ascii=False,indent=2))
    lines=['字形檢查報告','',f'檢查範圍：{s.get("scope","")}（本次 {len(domain)} 字）',f'檢查方式：{"隨機抽樣" if mode=="sample" else "完整檢查／可中途匯出"}',f'選定範圍總數：{len(population)}；原始抽樣：{len(sampled)}；額外追查／複查：{len(set(domain)-set(sampled)) if mode=="sample" else 0}','未抽樣與尚未確認的字，不視為正確。','原檔未改動。這份報告不是全字庫正確保證。','']
    for r in result:
        lines += [r['font'],f'缺字 {len(r["missing"])}／已修正 {len(r["repaired"])}／未修正 {len(r["unresolved"])}／待確認 {len(r["pending"])}',f'修正建議 {len(r["suggestions"])}／未抽樣 {len(r["unsampled"])}',f'輸出字檔：{r["output"] or "無（僅匯出報告，或沒有安全修正來源）"}','']
    lines += ['修正只重編碼已人工確認的來源，不猜補字。部分修正可在檢查未完成時輸出，但必須連同待確認清單使用。','多音字拼音為系統單字轉寫，不保證所有讀音。','進度檔引用本機保存的原檔；跨電腦續接請一併複製整個工作階段資料夾。','字體的原有授權仍適用，請先確認有權修改及分享。']
    (out/'報告摘要.txt').write_text('\n'.join(lines))
    return {'output':str(out),'fonts':result}

if __name__=='__main__':
    try:
        if sys.argv[1]=='inspect': value=inspect(sys.argv[2],sys.argv[3])
        elif sys.argv[1]=='export': value=export(sys.argv[2],sys.argv[3],sys.argv[4]=='repair')
        else: raise ValueError('未知操作')
        print(json.dumps(value,ensure_ascii=False))
    except Exception as exc:
        print(json.dumps({'error':str(exc)},ensure_ascii=False)); sys.exit(1)
