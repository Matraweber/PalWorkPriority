import copy
import hashlib
import importlib.util
from pathlib import Path
import unittest
import subprocess
import sys

spec = importlib.util.spec_from_file_location('accept_file', Path(__file__).resolve().parents[1]/'tools/accept_native_file_probe.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def fixture():
    lines = ['2026-10-04T11:00:00Z test ARMED test']
    receipts = {}
    for phase, second, values in [('initial', 10, [0,0,2,100,200,2382238981,1000]), ('conflict', 25, [2,183,2,1000,1200,3713148193,1000])]:
        prefix = f'2026-10-04T11:01:{second}Z test '
        tick = values[4]+1
        lines.extend([prefix+'START phase='+phase+' game=1',
                      prefix+'RESULT phase='+phase+' values='+','.join(map(str,values))+f' game=1 completion=1 completion_tick={tick}',
                      prefix+'COMPLETE phase='+phase+'; checked'])
        receipts[phase] = {'nonce':'test','phase':phase,'result':values,'game_tid':1,'completion_tid':1,'completion_tick':tick,
                           'whole_byte_comparison':True,'durable_ack':False,'bytes':262144,
                           'sha256':hashlib.sha256(bytes(range(256))*1024).hexdigest(),
                           'readback_utc':f'2026-10-04T11:01:{second}.500000Z','target':m.TARGET}
    return '\n'.join(lines), receipts


class AcceptanceTests(unittest.TestCase):
    def run_accept(self, log, receipts, ready='2026-10-04T11:01:00Z'):
        return m.accept(log,'test',ready,receipts)

    def test_valid(self):
        self.assertTrue(self.run_accept(*fixture())['passed'])

    def test_missing_each_event_and_inert(self):
        log, receipts = fixture()
        lines = log.splitlines()
        for bad in ['',log+'\n'+log,*['\n'.join(lines[:i]+lines[i+1:]) for i in range(len(lines))]]:
            with self.subTest(bad=bad), self.assertRaises(AssertionError):
                self.run_accept(bad,receipts)

    def test_false_receipts(self):
        log, original = fixture()
        cases = [('nonce','other'),('phase','conflict'),('game_tid',2),('completion_tick',0),
                 ('whole_byte_comparison',False),('durable_ack',True),('bytes',35),('sha256','0'*64),
                 ('readback_utc','2026-10-04T11:01:26Z'),('result',[0]*7),('target','other')]
        for key,value in cases:
            receipts=copy.deepcopy(original);receipts['initial'][key]=value
            with self.subTest(key=key), self.assertRaises(AssertionError):
                self.run_accept(log,receipts)

    def test_bad_raw_and_world_state(self):
        log, receipts=fixture()
        for bad in [log.replace(' COMPLETE ',' FAIL '),log.replace('values=0,0,2','values=0,0,1'),
                    log.replace('values=2,183','values=0,0'),log.replace('checksum','unknown')+'\n2026-10-04T11:02:00Z test FAIL late']:
            with self.subTest(bad=bad), self.assertRaises(AssertionError):self.run_accept(bad,receipts)
        with self.assertRaises(AssertionError):self.run_accept(log,receipts,'2026-10-04T11:02:00Z')

    def test_both_targets_wrong(self):
        log, receipts=fixture()
        for receipt in receipts.values():receipt['target']='unrelated'
        with self.assertRaises(AssertionError):self.run_accept(log,receipts)

    def test_optimized_python_refused(self):
        code="import sys;sys.path.insert(0,'tools');from accept_native_file_probe import accept;accept('', 'test', '', {})"
        result=subprocess.run([sys.executable,'-O','-c',code],cwd=Path(__file__).resolve().parents[1],capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('refuse optimized Python',result.stderr)


if __name__=='__main__':unittest.main()
