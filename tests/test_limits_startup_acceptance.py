from pathlib import Path
import hashlib
import struct
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
import accept_limits_startup_trial as Accept


class Acceptance(unittest.TestCase):
    def fixture(self, recovery=False):
        tmp=tempfile.TemporaryDirectory();self.addCleanup(tmp.cleanup)
        store=Path(tmp.name)
        scope=f'PWP-SCOPE-1:{Accept.Trial.W}:{Accept.Trial.G}:limits'.encode()
        body=b'body'
        payload=f'PWP-SETTINGS-1\n{Accept.Trial.W}\n{Accept.Trial.G}\nlimits\n4\n'.encode()+body
        record=b'PWPJNL1\n'+struct.pack('<HII',len(scope),1,len(payload))+scope+payload
        path=store/f'pwp-record-v1-{Accept.Trial.W}-{Accept.Trial.G}-limits-A.record'
        path.write_bytes(record+hashlib.sha256(record).digest())
        log='\n'.join('PWP_ASYNC_TRIAL\tnonce\t'+s for s in [
            'armed\tdefault_enabled=false',
            'started\tstorage='+Accept.Trial.W+'\tguild='+Accept.Trial.G,
            'state\tstate=active\tinitialization='+str(not recovery).lower()+'\tgeneration=1\tcommitted='+('0' if recovery else '1'),
            'active\tlimits='+body.hex(),
            'lifecycle\tevent=closing\towner_retained=true',
            'lifecycle\tevent=cleanup_complete\tcleanup_verified=true\towner_retained=false\tuncertain=false\treason=quit',
            'native_exit\tphase=closed\tjoined=true\tcleaned=true\tgeneration=1\taccepted='+('0' if recovery else '1')+'\tcommitted='+('0' if recovery else '1')])
        return store,path,log,body

    def test_both_paths(self):
        for recovery in (False,True):
            store,_,log,body=self.fixture(recovery)
            self.assertTrue(Accept.inspect(log,'nonce',store,body,body,recovery)['accepted'])

    def test_missing_or_failed_cleanup(self):
        store,_,log,body=self.fixture()
        for changed in (log.replace('cleanup_complete','closing'),log.replace('cleanup_verified=true','cleanup_verified=false'),
                        log.replace('reason=quit','reason=load_pre'),log.replace('cleaned=true','cleaned=false'),
                        log+'\nPWP_ASYNC_TRIAL\tnonce\tfailed\treason=oops'):
            with self.assertRaises(ValueError):Accept.inspect(changed,'nonce',store,body,body)

    def test_return_to_title_requires_explicit_observation(self):
        store,_,log,body=self.fixture()
        log=log.replace('reason=quit','reason=load_pre')
        with self.assertRaises(ValueError):Accept.inspect(log,'nonce',store,body,body)
        self.assertTrue(Accept.inspect(log,'nonce',store,body,body,exit_reason='load_pre')['accepted'])

    def test_corruption_and_extra_paths(self):
        store,path,log,body=self.fixture()
        raw=path.read_bytes();path.write_bytes(raw[:-1]+bytes([raw[-1]^1]))
        with self.assertRaises(ValueError):Accept.inspect(log,'nonce',store,body,body)
        path.write_bytes(raw);(store/'unexpected').write_bytes(b'')
        with self.assertRaises(ValueError):Accept.inspect(log,'nonce',store,body,body)

    def test_wrong_nonce_path_and_data(self):
        store,_,log,body=self.fixture()
        for nonce,expected,recovery in [('other',body,False),('nonce',b'changed',False),('nonce',body,True)]:
            with self.assertRaises(ValueError):Accept.inspect(log,nonce,store,expected,body,recovery)

    def test_order_missing_and_duplicate_events(self):
        store,_,log,body=self.fixture()
        rows=log.splitlines()
        variants=['\n'.join(reversed(rows)), '\n'.join(rows[1:]),log+'\n'+rows[-1],
                  log.replace('storage='+Accept.Trial.W,'storage='+Accept.Trial.G)]
        for changed in variants:
            with self.assertRaises(ValueError):Accept.inspect(changed,'nonce',store,body,body)

    def test_real_edits_and_recovery_need_exact_both_generations(self):
        for recovery in (False,True):
            store,path,log,_=self.fixture(True)
            body=(Accept.Trial.G+'|Mining|Stone|35000\n').encode()
            runtime=body
            scope=f'PWP-SCOPE-1:{Accept.Trial.W}:{Accept.Trial.G}:limits'.encode()
            for slot,generation,b in [('A',3,body),('B',2,body.replace(b'35000',b'35001'))]:
                payload=f'PWP-SETTINGS-1\n{Accept.Trial.W}\n{Accept.Trial.G}\nlimits\n{len(b)}\n'.encode()+b
                envelope=b'PWPJNL1\n'+struct.pack('<HII',len(scope),generation,len(payload))+scope+payload
                (store/path.name.replace('-A.record','-'+slot+'.record')).write_bytes(envelope+hashlib.sha256(envelope).digest())
            log=log.replace('limits='+b'body'.hex(),'limits='+body.hex())
            if recovery: log=log.replace('state=active\tinitialization=false\tgeneration=1','state=active\tinitialization=false\tgeneration=3')
            log=log.replace('cleaned=true\tgeneration=1\taccepted=0\tcommitted=0',
                'cleaned=true\tgeneration=3\taccepted='+('0' if recovery else '2')+'\tcommitted='+('0' if recovery else '2'))
            self.assertTrue(Accept.inspect(log,'nonce',store,body,runtime,recovery,edits=True)['accepted'])
            with self.assertRaises(ValueError):Accept.inspect(log.replace('committed=2','committed=1') if not recovery else log.replace('generation=3','generation=2'),
                'nonce',store,body,runtime,recovery,edits=True)


if __name__=='__main__':unittest.main()
