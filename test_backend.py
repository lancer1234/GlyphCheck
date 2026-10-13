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

class Tests(unittest.TestCase):
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
            r=backend.export(sp,root/'out',True)['fonts'][0]
            self.assertEqual(len(r['repaired']),2);self.assertTrue(r['output'].endswith('.otf'))
            check=TTFont(root/'out'/r['output']);self.assertTrue(check['CFF '].cff.fontNames[0].startswith('GlyphCheck-'))
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
            repaired=backend.export(sp,root/'repaired',True)['fonts'][0]
            self.assertEqual(len(repaired['repaired']),2);self.assertTrue(repaired['isPartial'])
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
