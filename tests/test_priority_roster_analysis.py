import sys
import unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from analyze_priority_roster_probe import analyze

def log():
    def line(e,**f):return 'time\tnonce\t'+e+''.join('\t'+k+'='+str(v) for k,v in f.items())+'\n'
    out=line('armed',activation_allowed='false',read_only='true')
    for i in range(1,4):
        out+=line('pal',sample=i,key='pal',camp='camp',capable='1,2')
        out+=line('saved_key',sample=i,key='pal',observed='true',camp='camp')
        out+=line('saved_key',sample=i,key='absent',observed='false',camp='unknown')
        out+=line('sample',sample=i,activation_allowed='false',complete='true',second_complete='true',stable='true',
                  expected_camps_observed='true',camps=2,target_camps=2,pals=1,saved=2,matched=1,unknown=1,
                  storage='world',guild='guild',world_membership_proven='false')
    return out+line('done',samples=3,activation_allowed='false')

class Tests(unittest.TestCase):
    def test_direct_route(self):
        text=log().replace('\tpal\t','\tguild_key\t').replace('camp=camp','camp=guild-roster')
        text='\n'.join(line for line in text.splitlines() if 'key=absent' not in line)+'\n'
        text=text.replace('camps=2','camps=0').replace('pals=1','pals=1\troute=direct\tarray_address=0')
        text=text.replace('saved=2','saved=1').replace('unknown=1','unknown=0')
        for i in range(1,4):
            token='time\tnonce\tguild_key\tsample='+str(i)
            row='time\tnonce\townership\tsample='+str(i)+'\tkey=pal\taccepted=true\n'
            text=text.replace(token,row+token)
        result=analyze(text,'nonce',['pal'],'direct')
        extra=text.replace('time\tnonce\tsample\tsample=1',
            'time\tnonce\tguild_key\tsample=1\tkey=extra\n'+'time\tnonce\tsample\tsample=1').replace('pals=1','pals=2',1)
        with self.assertRaises(AssertionError):analyze(extra,'nonce',['pal'],'direct')
        self.assertTrue(result['diagnostic_complete'])
        self.assertFalse(result['activation_allowed'])
        for a,b in [('accepted=true','accepted=false'),('route=direct','route=world'),
                    ('array_address=0','array_address=9'),('key=pal\taccepted=true','key=other\taccepted=true')]:
            with self.subTest(a=a),self.assertRaises(AssertionError):
                analyze(text.replace(a,b,1),'nonce',['pal'],'direct')
        with self.assertRaises(AssertionError):
            analyze('\n'.join(line for line in text.splitlines() if '\townership\t' not in line),'nonce',['pal'],'direct')
    def test_guild_route_is_separate(self):
        text=log().replace('\tpal\t','\tguild_key\t').replace('camp=camp','camp=guild-roster')
        text=text.replace('camps=2','camps=0').replace('pals=1','pals=1\troute=guild\tarray_address=10')
        result=analyze(text,'nonce',['pal','absent'],'guild')
        self.assertEqual(result['samples'][0]['unknown_keys'],['absent'])
        self.assertFalse(result['activation_allowed'])
        with self.assertRaises(AssertionError):analyze(text,'nonce',['pal','absent'])
        with self.assertRaises(AssertionError):analyze(text.replace('array_address=10','array_address=0'),'nonce',['pal','absent'],'guild')
    def test_parameter_route(self):
        guild='a'*32
        text=log().replace('\tpal\t','\tguild_key\t').replace('camp=camp','camp=guild-roster')
        text=text.replace('camps=2','camps=0').replace('pals=1','pals=1\troute=parameter\tarray_address=10').replace('guild=guild','guild='+guild)
        for i in range(1,4):
            token='time\tnonce\tguild_key\tsample='+str(i)
            row='time\tnonce\tparameter\tsample='+str(i)+'\tkey=pal\tgroup='+guild+'\tmatches=true\taddress=123\n'
            text=text.replace(token,row+token)
        self.assertEqual(analyze(text,'nonce',['pal','absent'],'parameter')['samples'][0]['matched'],1)
        world=text.replace('route=parameter','route=world').replace('address=123','address=123\tworld_resolved=true')
        self.assertEqual(analyze(world,'nonce',['pal','absent'],'world')['samples'][0]['matched'],1)
        with self.assertRaises(AssertionError):analyze(world.replace('world_resolved=true','world_resolved=false'),'nonce',['pal','absent'],'world')
        for a,b in [('address=123','address=0'),('matches=true','matches=false'),('group='+guild,'group='+'b'*32)]:
            with self.assertRaises(AssertionError):analyze(text.replace(a,b),'nonce',['pal','absent'],'parameter')
    def test_unknown_is_preserved(self):
        result=analyze(log(),'nonce',['pal','absent'])
        self.assertFalse(result['activation_allowed'])
        self.assertEqual(result['samples'][2]['unknown_keys'],['absent'])
    def test_reject_invalid(self):
        for before,after in [('complete=true','complete=false'),('second_complete=true','second_complete=false'),
            ('stable=true','stable=false'),('matched=1','matched=2'),('world_membership_proven=false','world_membership_proven=true'),
            ('camp=unknown','camp=camp'),('sample=2','sample=1'),('observed=false','observed=true'),
            ('\tdone\t','\tfailed\t'),('nonce','other')]:
            with self.subTest(before=before),self.assertRaises(AssertionError):
                analyze(log().replace(before,after,1),'nonce',['pal','absent'])
    def test_no_missing_or_duplicate_tail(self):
        text=log()
        with self.assertRaises(AssertionError):analyze(text.rsplit('\n',2)[0],'nonce',['pal','absent'])
        with self.assertRaises(AssertionError):analyze(text+text,'nonce',['pal','absent'])
        with self.assertRaises(AssertionError):analyze(text+text.splitlines()[-1]+'\n','nonce',['pal','absent'])
if __name__=='__main__':unittest.main()
