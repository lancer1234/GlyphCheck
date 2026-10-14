import hashlib
import json
import tempfile
import os
import unittest
from pathlib import Path
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.pens.t2CharStringPen import T2CharStringPen
from fontTools.ttLib import TTFont, TTCollection
import backend
import glyph_audit

def fixture(path):
    fb=FontBuilder(1000,isTTF=True); names=['.notdef','gA','gB','empty','gC']
    fb.setupGlyphOrder(names); fb.setupCharacterMap({65:'gA',66:'gB',67:'gC',68:'empty',0x20000:'gC'})
    glyphs={}
    for i,name in enumerate(names):
        p=TTGlyphPen(None)
        if name!='empty':
            p.moveTo((50,0));p.lineTo((100+i*20,700));p.lineTo((400,0));p.closePath()
        glyphs[name]=p.glyph()
    fb.setupGlyf(glyphs);fb.setupHorizontalMetrics({n:(1000,50) for n in names})
    fb.setupHorizontalHeader(ascent=800,descent=-200)
    fb.setupNameTable({'familyName':'Test','styleName':'Regular','psName':'Test-Regular','fullName':'Test Regular'})
    fb.setupOS2();fb.setupPost();fb.setupMaxp();fb.save(path)

def accept_candidates(session_path,root):
    result=backend.export(session_path,root/'candidate-preview',True,preview=True)
    session=json.loads(session_path.read_text())
    session['repairApprovals']={font['id']:{str(ord(row['character'])):dict(fingerprint=row['fingerprint'],decision='accepted',reviewer='Fixture reviewer',reviewedAt='2026-10-14T00:00:00Z') for row in font['suggestions']} for font in result['fonts']}
    session_path.write_text(json.dumps(session))

class Tests(unittest.TestCase):
    def test_glyph_name_list_audit(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);font=root/'sample.ttf';fixture(font)
            names=root/'names.txt';names.write_text('A\nuni0042\nu20000\nA.vert\ngA\nuni0044\nuni0045\nunknownGlyph\nA\nspace\n')
            lists=glyph_audit.parse_lists([names])['lists'];self.assertEqual(len(lists[0]['entries']),9)
            self.assertIsNone(glyph_audit.unicode_for('A.vert'));self.assertIsNone(glyph_audit.unicode_for('one_zero.circled'))
            meta=backend.inspect(font,root/'fonts')['fonts'][0]
            session=dict(fonts=[meta],glyphLists=lists);path=root/'session.json';path.write_text(json.dumps(session))
            rows=glyph_audit.audit(path)['fonts'][0]['rows'];byname={r['name']:r for r in rows}
            self.assertEqual(byname['A']['status'],'pending');self.assertEqual(byname['gA']['glyph'],'gA')
            self.assertEqual(byname['u20000']['codepoint'],'U+20000');self.assertEqual(byname['A.vert']['status'],'unresolved')
            self.assertEqual(byname['uni0044']['status'],'missing');self.assertEqual(byname['uni0045']['status'],'missing')
            session['glyphReviews']={meta['id']:{byname['A']['id']:dict(fingerprint=byname['A']['fingerprint'],decision='correct',note='<script>private</script>')}}
            path.write_text(json.dumps(session));result=glyph_audit.audit(path,root/'report')
            self.assertEqual(result['fonts'][0]['rows'][0]['status'],'found')
            report=(root/'report'/'字集驗收.html').read_text();self.assertNotIn('<script>',report);self.assertIn('&lt;script&gt;',report)
            self.assertNotIn(str(root),report)
            self.assertEqual(len(result['fonts'][0]['rows']),len(lists[0]['entries']))
            names.write_text('文章不是字形名稱');self.assertRaises(ValueError,glyph_audit.parse_lists,[names])

    def test_cross_font_accepted_only_and_integrity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); original=root/'original.ttf'; donor=root/'donor.ttf'
            fixture(original); fixture(donor)
            sf=TTFont(donor); sf['head'].unitsPerEm=2000; sf['hmtx']['gB']=(1600,50); sf.save(donor)
            meta=backend.inspect(original,root/'fonts')['fonts'][0]
            source=backend.inspect(donor,root/'sources')['fonts'][0]
            session=dict(fonts=[meta],domain=[66,69],answers={},repairSources=[source],externalRepairs={meta['id']:{'66':dict(sourceID=source['id'],codepoint=66),'69':dict(sourceID=source['id'],codepoint=66)}})
            path=root/'session.json'; path.write_text(json.dumps(session))
            hashes=[hashlib.sha256(p.read_bytes()).hexdigest() for p in (original,donor)]
            preview=backend.export(path,root/'preview',True,True)['fonts'][0]
            self.assertEqual(len(preview['suggestions']),2); self.assertFalse(preview['repaired'])
            row=preview['suggestions'][0]
            session['repairApprovals']={meta['id']:{'66':dict(fingerprint=row['fingerprint'],decision='accepted')}}
            path.write_text(json.dumps(session))
            result=backend.export(path,root/'repair',True)['fonts'][0]
            self.assertEqual(len(result['repaired']),1)
            fixed=TTFont(root/'repair'/result['output']); cm=fixed.getBestCmap()
            self.assertNotEqual(cm[66],'gB'); self.assertNotIn(69,cm)
            self.assertEqual(fixed['hmtx'][cm[66]][0],800)
            self.assertEqual(cm[65],'gA')
            self.assertEqual(len(fixed.getGlyphOrder()),len(TTFont(original).getGlyphOrder())+1)
            self.assertEqual(hashes,[hashlib.sha256(p.read_bytes()).hexdigest() for p in (original,donor)])
            html=(root/'repair'/'圖文核對報告.html').read_text()
            self.assertIn(source['sha256'],html); self.assertNotIn(str(root),html)
            session['externalRepairs'][meta['id']]['66']['codepoint']=65; path.write_text(json.dumps(session))
            changed=backend.export(path,root/'changed',True)['fonts'][0]
            self.assertFalse(changed['repaired'])

    def test_preflight_and_relationships(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'font.ttf';fixture(p)
            m=backend.inspect(p,Path(tmp)/'faces')['fonts'][0]
            flags={(x['cp'],x['kind']) for x in m['scan']}
            self.assertIn((68,'blank'),flags)
            self.assertIn((67,'duplicate'),flags)
            self.assertIn((0x20000,'duplicate'),flags)
            self.assertNotIn((65,'duplicate'),flags)
        a={'65':{'kind':'mismatch','actual':'B'},'66':{'kind':'mismatch','actual':'A'}}
        rows=backend.relationships(a,{65:66,66:65})
        self.assertTrue(all(row['cycle'] for row in rows));self.assertEqual(rows[0]['chain'],'A → B → A')
    def test_disputed_donors_and_reference_doubts_block_repair(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);p=root/'sample.ttf';fixture(p)
            m=backend.inspect(p,root/'fonts')['fonts'][0]
            s={'fonts':[m],'domain':[65,66],'population':[65,66,69],
               'answers':{m['id']:{'65':{'kind':'mismatch','actual':'B'},'66':{'kind':'mismatch','actual':'A'}}},
               'reviewConflicts':{m['id']:{'66':[{'reviewer':'other','answer':{'kind':'correct'}}]}}}
            sp=root/'s.json';sp.write_text(json.dumps(s))
            r=backend.export(sp,root/'out',True)['fonts'][0]
            self.assertFalse(r['repaired']);self.assertEqual(len(r['populationMissing']),1)
            self.assertEqual(r['relationships'][1]['status'],'conflict')
            s.pop('reviewConflicts');s['referenceDoubts']=[66];sp.write_text(json.dumps(s))
            r=backend.export(sp,root/'doubts',True)['fonts'][0]
            self.assertFalse(r['repaired'])
    def test_cycle_and_open_chain(self):
        cm={65:'a',66:'b',67:'c'};visible={str(c):True for c in cm}
        plan,issues=backend.repair_plan(cm,visible,{'65':{'kind':'mismatch','actual':'B'},'66':{'kind':'mismatch','actual':'A'}})
        self.assertEqual(plan,{65:66,66:65});self.assertFalse(issues)
        plan,issues=backend.repair_plan(cm,visible,{'65':{'kind':'mismatch','actual':'B'}})
        self.assertEqual(plan,{});self.assertEqual(len(issues),1)
    def test_conflicts_not_guessed(self):
        cm={65:'a',66:'b',67:'c'};v={str(c):True for c in cm}
        a={'65':{'kind':'mismatch','actual':'B'},'66':{'kind':'mismatch','actual':'A'},'67':{'kind':'mismatch','actual':'A'}}
        p,i=backend.repair_plan(cm,v,a);self.assertNotIn(65,p);self.assertEqual(len(i),2)
    def test_roundtrip_export(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);p=root/'sample.ttf';fixture(p);before=p.read_bytes()
            m=backend.inspect(p,root/'fonts')['fonts'][0]
            self.assertTrue(m['visible']['65']);self.assertFalse(m['visible']['68']);self.assertIn(str(0x20000),m['glyphs'])
            s={'version':1,'fonts':[m],'scope':'test','domain':[65,66,67,68,69],
               'answers':{m['id']:{'65':{'kind':'mismatch','actual':'B'},'66':{'kind':'mismatch','actual':'A'}}}}
            session=root/'s.json';session.write_text(json.dumps(s))
            accept_candidates(session,root)
            r=backend.export(session,root/'out',True)['fonts'][0]
            self.assertEqual(len(r['repaired']),2);self.assertEqual(len(r['missing']),2);self.assertEqual(len(r['pending']),1)
            check=TTFont(root/'out'/r['output']);original=TTFont(p)
            self.assertEqual(check.getBestCmap()[65],original.getBestCmap()[66]);self.assertEqual(p.read_bytes(),before)
            self.assertNotEqual(check['name'].getDebugName(1),original['name'].getDebugName(1))
            report=backend.export(session,root/'report',False)['fonts'][0]
            self.assertIsNone(report['output']);self.assertEqual(len(report['unresolved']),2)
    def test_collection(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);p=root/'s.ttf';fixture(p)
            collection=TTCollection();collection.fonts=[TTFont(p),TTFont(p)];collection.save(root/'s.ttc')
            self.assertEqual(len(backend.inspect(root/'s.ttc',root/'faces')['fonts']),2)
    def test_cff_outline(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); p=root/'sample.otf'
            fb=FontBuilder(1000,isTTF=False);fb.setupGlyphOrder(['.notdef','A','B'])
            fb.setupCharacterMap({65:'A',66:'B'})
            fb.setupHorizontalMetrics({n:(1000,0) for n in ['.notdef','A','B']})
            fb.setupHorizontalHeader(ascent=800,descent=-200)
            fb.setupNameTable({'familyName':'CFF Test','styleName':'Regular','fullName':'CFF Test','psName':'CFFTest'})
            fb.setupOS2();fb.setupPost()
            shapes={}
            for i,n in enumerate(['.notdef','A','B']):
                pen=T2CharStringPen(1000,None);pen.moveTo((0,0));pen.lineTo((500,500+i*10));pen.lineTo((600,0));pen.closePath();shapes[n]=pen.getCharString()
            fb.setupCFF('CFFTest',{'FullName':'CFF Test','FamilyName':'CFF Test','Weight':'Regular'},shapes,{})
            fb.save(p)
            m=backend.inspect(p,root/'fonts')['fonts'][0]
            s={'fonts':[m],'domain':[65,66],'answers':{m['id']:{'65':{'kind':'mismatch','actual':'B'},'66':{'kind':'mismatch','actual':'A'}}}}
            sp=root/'s.json';sp.write_text(json.dumps(s))
            accept_candidates(sp,root)
            r=backend.export(sp,root/'out',True)['fonts'][0]
            self.assertEqual(len(r['repaired']),2);self.assertTrue(r['output'].endswith('.otf'))
            check=TTFont(root/'out'/r['output']);self.assertTrue(check['CFF '].cff.fontNames[0].startswith('GlyphCheck-'))
            target=root/'target.ttf';fixture(target)
            tm=backend.inspect(target,root/'targets')['fonts'][0]
            cross=dict(fonts=[tm],domain=[65],answers={},repairSources=[m],externalRepairs={tm['id']:{'65':dict(sourceID=m['id'],codepoint=65)}})
            sp.write_text(json.dumps(cross));accept_candidates(sp,root)
            repaired=backend.export(sp,root/'cross',True)['fonts'][0]
            self.assertEqual(len(repaired['repaired']),1)
            tf=TTFont(root/'cross'/repaired['output']);self.assertIn('glyf',tf)
            bad=dict(fonts=[m],domain=[65],answers={},repairSources=[tm],externalRepairs={m['id']:{'65':dict(sourceID=tm['id'],codepoint=65)}})
            sp.write_text(json.dumps(bad));blocked=backend.export(sp,root/'blocked',True,True)['fonts'][0]
            self.assertIsNone(blocked['output']);self.assertIn('TrueType',blocked['unresolved'][0]['reason'])
    def test_missing_recovered_from_confirmed_donor(self):
        cm={65:'a'};v={'65':True}
        p,i=backend.repair_plan(cm,v,{'65':{'kind':'mismatch','actual':'B'}},[66])
        self.assertEqual(p,{66:65});self.assertEqual(len(i),1)
    def test_partial_sample_report_and_suggestions(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);p=root/'sample.ttf';fixture(p)
            m=backend.inspect(p,root/'fonts')['fonts'][0]
            s={'fonts':[m],'scope':'test','reviewMode':'sample','requestedSampleSize':2,'scriptVariant':'traditional',
               'population':[65,66,67,68,69],'sampled':[65,66],'domain':[65,66,67],
               'answers':{m['id']:{'65':{'kind':'mismatch','actual':'B'},'66':{'kind':'mismatch','actual':'A'}}}}
            sp=root/'s.json';sp.write_text(json.dumps(s))
            r=backend.export(sp,root/'out',False)['fonts'][0]
            self.assertEqual(len(r['suggestions']),2);self.assertEqual(len(r['unsampled']),2)
            self.assertEqual(r['extraReviewCount'],1);self.assertEqual(r['sampledCount'],2)
            self.assertTrue(r['isPartial']);self.assertEqual(len(r['pending']),1)
            self.assertTrue((root/'out'/(m['id'][:6]+'-修正建議.csv')).exists())
            self.assertFalse(any((root/'out').glob('*-repaired.*')))
            accept_candidates(sp,root)
            repaired=backend.export(sp,root/'repaired',True)['fonts'][0]
            self.assertEqual(len(repaired['repaired']),2);self.assertTrue(repaired['isPartial'])
    def test_acceptance_required_and_evidence_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);p=root/'font.ttf';fixture(p);m=backend.inspect(p,root/'fonts')['fonts'][0]
            s={'fonts':[m],'domain':[65,66,67,68], 'answers':{m['id']:{'65':{'kind':'mismatch','actual':'B'},'66':{'kind':'mismatch','actual':'A'},'67':{'kind':'variant'}}}, 'inputText':'A<script>alert(1)</script> & B'}
            sp=root/'s.json';sp.write_text(json.dumps(s))
            result=backend.export(sp,root/'unaccepted',True)['fonts'][0]
            self.assertIsNone(result['output']);self.assertFalse(result['repaired'])
            preview=backend.export(sp,root/'preview',True,preview=True)['fonts'][0]
            self.assertEqual(len(preview['previewChanges']),2);self.assertFalse(preview['repaired']);self.assertIn('-preview',preview['output'])
            page=(root/'preview'/'圖文核對報告.html').read_text()
            self.assertIn('data:image/svg+xml;base64,',page);self.assertIn('&lt;script&gt;',page);self.assertNotIn('<script>',page);self.assertNotIn(m['source'],page)
            self.assertIn('Possible valid variant',page);self.assertTrue(preview['isPartial'])
            accept_candidates(sp,root)
            s=json.loads(sp.read_text());s['repairApprovals'][m['id']]['66']['decision']='excluded';sp.write_text(json.dumps(s))
            accepted=backend.export(sp,root/'accepted',True)['fonts'][0]
            self.assertEqual(len(accepted['repaired']),1)
            self.assertTrue(accepted['isRepairPartial'])
            old=TTFont(p).getBestCmap();new=TTFont(root/'accepted'/accepted['output']).getBestCmap()
            self.assertEqual(new[65],old[66]);self.assertEqual(new[66],old[66])
            s['answers'][m['id']]['67']={'kind':'correct'};sp.write_text(json.dumps(s))
            stale=backend.export(sp,root/'stale',True)['fonts'][0]
            self.assertIsNone(stale['output']);self.assertTrue(all(row['decision']=='pending' for row in stale['suggestions']))
    @unittest.skipUnless(os.environ.get('GLYPHCHECK_ORIGINAL_TEST_DIR'), 'Optional local authorized font fixtures are not distributed')
    def test_local_originals(self):
        with tempfile.TemporaryDirectory() as tmp:
            for p in Path(os.environ['GLYPHCHECK_ORIGINAL_TEST_DIR']).glob('*.ttf'):
                before=hashlib.sha256(p.read_bytes()).hexdigest()
                m=backend.inspect(p,Path(tmp)/p.name)['fonts'][0]
                self.assertGreater(sum(m['visible'].values()),0)
                self.assertEqual(hashlib.sha256(p.read_bytes()).hexdigest(),before)
                f=TTFont(m['preview'])
                for cp,gid in m['glyphs'].items(): self.assertEqual(f.getGlyphID(f.getBestCmap()[int(cp)]),gid)

if __name__=='__main__': unittest.main(verbosity=2)
