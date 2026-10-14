"""Append independent outline glyphs, never overwrite donor or original files."""
import hashlib
import json
from pathlib import Path
from fontTools.ttLib import TTFont
from fontTools.pens.recordingPen import DecomposingRecordingPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.pens.cu2quPen import Cu2QuPen

def validate_target(font):
    if 'glyf' not in font or 'fvar' in font or any(t in font for t in ('COLR','CBDT','sbix','SVG ')):
        raise ValueError('跨字檔輸出目前只支援靜態、非彩色 TrueType 目標；原檔未更動。')

def source_font(meta):
    raw=Path(meta['source']).read_bytes()
    if hashlib.sha256(raw).hexdigest()!=meta['sha256']: raise ValueError('修復來源字檔已變動，請重新匯入。')
    font=TTFont(meta['source'],fontNumber=meta['face'],lazy=False)
    if 'fvar' in font or any(t in font for t in ('COLR','CBDT','sbix','SVG ')):
        raise ValueError('變動或彩色來源目前不支援跨字檔輸出。')
    return font,raw

def fingerprint(target,source,cp,donor,glyph):
    evidence=dict(targetHash=target['sha256'],targetFace=target['face'],sourceHash=source['sha256'],sourceFace=source['face'],target=cp,donor=donor,glyph=glyph,policy='decompose-upem-source-width-v1')
    return hashlib.sha256(json.dumps(evidence,sort_keys=True).encode()).hexdigest()

def append_outline(target,source,name,new_name):
    validate_target(target)
    gs=source.getGlyphSet(); recording=DecomposingRecordingPen(gs); gs[name].draw(recording)
    if not recording.value: raise ValueError('來源沒有可補入的輪廓。')
    ratio=target['head'].unitsPerEm/source['head'].unitsPerEm
    pen=TTGlyphPen(None)
    converter=Cu2QuPen(pen,max_err=1.0,reverse_direction='CFF ' in source)
    recording.replay(TransformPen(converter,(ratio,0,0,ratio,0,0)))
    glyph=pen.glyph(); glyph.recalcBounds(target['glyf'])
    order=list(target.getGlyphOrder())
    target['glyf'][new_name]=glyph
    target.setGlyphOrder(order+[new_name])
    width,_=source['hmtx'][name]
    target['hmtx'][new_name]=(round(width*ratio),getattr(glyph,'xMin',0))
    if 'vmtx' in target:
        target['vmtx'][new_name]=tuple(round(v*ratio) for v in source['vmtx'][name]) if 'vmtx' in source else (target['head'].unitsPerEm,0)
    return new_name
