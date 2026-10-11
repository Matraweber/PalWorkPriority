"""Independent Python encoder versus native parser, disposable fixtures only."""
import hashlib
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

EXE=os.environ.get('PWP_NATIVE_RECORD_EXE')
SCOPE='PWP-SCOPE-1:'+ 'a'*32+':'+ 'b'*32+':priorities'

def record(data=b'old',generation=1,scope=SCOPE):
    body=b'PWPJNL1\n'+struct.pack('<HII',len(scope),generation,len(data))+scope.encode()+data
    return body+hashlib.sha256(body).digest()

@unittest.skipUnless(EXE and os.name=='nt','requires built native record CLI')
class Records(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='pwp-record-');self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name)
    def recover(self,a,b):
        args=[]
        for name,data in [('a',a),('b',b)]:
            if isinstance(data,str):args.append(data)
            else:
                p=self.root/name;p.write_bytes(data);args.append(str(p))
        return subprocess.run([EXE,'recover',SCOPE,*args],capture_output=True,timeout=10)
    def test_independent_encoding_binary_and_empty(self):
        for data in [b'',b'1|X\n',bytes(range(256))*1024]:
            r=subprocess.run([EXE,'encode',SCOPE,'25'],input=data,capture_output=True,timeout=10)
            self.assertEqual(r.returncode,0);self.assertEqual(r.stdout,record(data,25))
            r=self.recover(r.stdout,'MISSING');self.assertEqual(r.stdout,b'0\n25\n'+data)
    def test_newest_and_equal_conflicts(self):
        self.assertEqual(self.recover(record(),record(b'new',2)).stdout,b'1\n2\nnew')
        self.assertEqual(self.recover(record(b'new',2),record()).stdout,b'0\n2\nnew')
        self.assertEqual(self.recover(record(),record()).returncode,0)
        self.assertEqual(self.recover(record(),record(b'different')).returncode,2)
    def test_missing_and_unreadable(self):
        self.assertEqual(self.recover('MISSING','MISSING').stdout,b'-1\n')
        for a,b in [('UNREADABLE','MISSING'),(record(),'UNREADABLE'),(b'', 'MISSING'),(b'',b'')]:
            self.assertEqual(self.recover(a,b).returncode,2)
    def test_foreign_newer_oversize_blocks_older(self):
        for bad in [record(scope=SCOPE.replace('a','c')),record().replace(b'PWPJNL1',b'PWPJNL2'),
                    record(b'x'*262145),record(generation=2147483647),b'unrecognized-format']:
            for a,b in [(record(),bad),(bad,record())]:self.assertEqual(self.recover(a,b).returncode,2)
    def test_corrupt_payload_and_digest_recovers_other(self):
        good=record(b'new',2)
        for index in [len(good)-33,len(good)-1]:
            bad=bytearray(good);bad[index]^=1
            self.assertEqual(self.recover(record(),bad).stdout,b'0\n1\nold')
            self.assertEqual(self.recover(bad,'MISSING').returncode,2)
    def test_truncated_or_extended_never_selected(self):
        good=record(b'new',2)
        for cut in range(len(good)):
            r=self.recover(good[:cut],'MISSING');self.assertEqual(r.returncode,2)
        self.assertEqual(self.recover(good+b'extra','MISSING').returncode,2)
    def test_invalid_input_rejected(self):
        for scope,gen,data in [(SCOPE,'0',b'x'),(SCOPE,'2147483647',b'x'),(SCOPE,'4294967297',b'x'),(SCOPE,'1junk',b'x'),('unknown','1',b'x'),(SCOPE,'1',b'x'*262145)]:
            self.assertNotEqual(subprocess.run([EXE,'encode',scope,gen],input=data,capture_output=True,timeout=10).returncode,0)
    def test_header_mutations_never_selected(self):
        good=record(b'new',2)
        for index in range(18+len(SCOPE)):
            bad=bytearray(good);bad[index]^=1
            with self.subTest(index=index):
                self.assertEqual(self.recover(bad,'MISSING').returncode,2)
    def test_classification_matrix(self):
        variants={'valid':record(),'missing':'MISSING','corrupt':b'',
                  'unsupported':record().replace(b'PWPJNL1',b'PWPJNL2'),
                  'foreign':record(scope=SCOPE.replace('a','c')),'unreadable':'UNREADABLE'}
        for ka,a in variants.items():
            for kb,b in variants.items():
                allowed=not ({ka,kb}&{'unsupported','foreign','unreadable'}) and ('valid' in (ka,kb) or ka==kb=='missing')
                with self.subTest(a=ka,b=kb):self.assertEqual(self.recover(a,b).returncode,0 if allowed else 2)

if __name__=='__main__':unittest.main()
