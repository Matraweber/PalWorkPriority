from pathlib import Path
import json
import sys
import tempfile
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
import run_staged_recovery_native as N


class NativeStagedGates(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        p=self.root/'Config/WindowsServer';p.mkdir(parents=True)
        self.config=p/'Engine.ini'

    def test_exact_loopback_section_required(self):
        good='[HTTPServer.Listeners]\nDefaultBindAddress=127.0.0.1\nDefaultReuseAddressAndPort=False\n!ListenerOverrides=ClearArray\n'
        self.config.write_text(good);N.loopback_config(self.root)
        for text in ('',good.replace('127.0.0.1','0.0.0.0'),good+good,
                     good+'+ListenerOverrides=(Port=8212,BindAddress="0.0.0.0")\n',
                     good.replace('!ListenerOverrides=ClearArray\n','')):
            self.config.write_text(text)
            with self.assertRaises(ValueError):N.loopback_config(self.root)

    def test_unknown_phase_refuses_without_operations(self):
        with mock.patch.object(N.Base.installer,'stopped') as stopped:
            for fn in (N.stage,N.launch,N.stop):
                with self.assertRaises(ValueError):fn('unknown')
            stopped.assert_not_called()

    def test_fixture_configuration_restored_after_failure(self):
        before=N.Base.FIXTURE,N.Base.BACKUP
        with self.assertRaises(RuntimeError):
            with N.fixture_configuration():
                self.assertEqual((N.Base.FIXTURE,N.Base.BACKUP),(N.EVIDENCE,N.BACKUP))
                raise RuntimeError('injected preflight failure')
        self.assertEqual((N.Base.FIXTURE,N.Base.BACKUP),before)

    def test_recovery_requires_shutdown_receipt_and_unchanged_state(self):
        f=mock.Mock()
        with mock.patch.object(N,'EVIDENCE',self.root),mock.patch.object(N,'load_fixture',return_value=(f,{})),\
             mock.patch.object(N.Base.installer,'stopped'),mock.patch.object(N,'snapshot',return_value={'new':'edit'}):
            with self.assertRaises(FileNotFoundError):N.recover()
            process=[{'pid':1,'path':'fixture','started_ticks':1}]
            (self.root/'fenced-stopped.json').write_text(json.dumps({'settings_unchanged':True,'normal_exit_observed':True,'nonce':'n','processes':process}))
            (self.root/'fenced-install.json').write_text(json.dumps({'nonce':'n','phase':'fenced'}))
            (self.root/'fenced-acceptance.json').write_text(json.dumps({'parser':{'nonce':'n','phase':'fenced'},'processes':process}))
            (self.root/'mixed-state.json').write_text(json.dumps({'old':'value'}))
            with self.assertRaisesRegex(ValueError,'changed since'):N.recover()
            f.resume_rollback.assert_not_called()

    def test_absent_changed_or_wrong_phase_process_cannot_certify_shutdown(self):
        import server
        import server_control
        process=[{'pid':1,'path':'fixture','started_ticks':1}]
        for current,nonce in (([],'n'),([{**process[0],'pid':2}],'n'),(process,'wrong')):
            (self.root/'fenced-install.json').write_text(json.dumps({'nonce':'n','phase':'fenced'}))
            (self.root/'fenced-acceptance.json').write_text(json.dumps({'parser':{'nonce':nonce,'phase':'fenced'},'processes':process}))
            with mock.patch.object(N,'EVIDENCE',self.root),mock.patch.object(server,'server_processes',return_value=current),\
                 mock.patch.object(server_control,'graceful_stop') as stop,mock.patch.object(N,'record') as record:
                with self.assertRaises(ValueError):N.stop('fenced')
                stop.assert_not_called();record.assert_not_called()




class DisposableNativeSetup(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.evidence=Path(self.tmp.name)/'evidence'
        self.patches=[mock.patch.object(N,'EVIDENCE',self.evidence),mock.patch.object(N.Base,'preflight'),
                      mock.patch.object(N,'loopback_config'),mock.patch.object(N.Base,'prepare',return_value={'prepared':True}),
                      mock.patch.object(N.Base.installer,'stopped')]
        for patch in self.patches:patch.start();self.addCleanup(patch.stop)
    def prepared(self):
        self.assertEqual(N.prepare(),{'prepared':True})
        f,r=N.load_fixture();self.addCleanup(f.close)
        return f,r
    def shutdown_receipts(self):
        processes=[{'pid':123,'path':'synthetic','started_ticks':456}]
        for name,obj in {
            'fenced-stopped.json':{'settings_unchanged':True,'normal_exit_observed':True,'nonce':'n','processes':processes,'settings':json.loads((self.evidence/'mixed-state.json').read_text())},
            'fenced-acceptance.json':{'parser':{'nonce':'n','phase':'fenced'},'processes':processes},
            'fenced-install.json':{'nonce':'n','phase':'fenced','settings':json.loads((self.evidence/'mixed-state.json').read_text())},
        }.items():(self.evidence/name).write_text(json.dumps(obj))
    def test_real_child_publish_gap_and_recovery_candidate_semantics(self):
        f,r=self.prepared()
        proof=json.loads((self.evidence/'crash.json').read_text())
        self.assertEqual(proof['exit_code'],73);self.assertEqual(proof['boundary'],N.CRASH_LABEL)
        self.assertFalse((f.root/'reserved-priorities.txt.tmp.json').exists())
        self.assertEqual(f.read('priorities.txt.tmp'),b'')
        self.assertTrue(all(f.read(n) is None for n in N.C.TRIAL))
        self.assertIn('mine|1|X\n',r['expected_priorities']);self.assertIn('|Mining|Stone|OFF\n',r['expected_limits'])
        self.assertIn('unrelated|2|X\n',r['expected_priorities']);self.assertIn('*|Mining|Wood|200\n',r['expected_limits'])
        self.assertNotIn('mine|1|3\n',r['expected_priorities'])
        self.shutdown_receipts()
        result=N.recover();self.assertTrue(result['recovery_result']['fence_retained']);self.assertTrue(result['fixture_final_state']['marker_removed'])
        N.verify_candidate(f,None)
        self.assertEqual(N.snapshot(f),json.loads((self.evidence/'recovered-state.json').read_text()))
        # Expectations come from independent fixture bytes, not the plan encoder.
        plan=f._plan()
        for name,expected in (('priorities.txt',r['expected_priorities']),('caps.txt',r['expected_limits'])):
            self.assertEqual(f.read(name).split(b'\n',1)[1].decode(),expected)
    def test_unfence_refuses_changed_candidate_trial_and_marker(self):
        f,r=self.prepared();N.R.resume(f)
        original=f.read('caps.txt');(f.target/'caps.txt').write_bytes(b'late foreign edit')
        with self.assertRaisesRegex(ValueError,'candidate'):N.unfence_candidate(f)
        self.assertEqual(f.read(N.C.MARKER),f.marker)
        (f.target/'caps.txt').write_bytes(original)
        trial=f.target/N.C.TRIAL[0];trial.write_bytes(b'never execute')
        with self.assertRaisesRegex(ValueError,'trial'):N.unfence_candidate(f)
        self.assertEqual(trial.read_bytes(),b'never execute');trial.unlink()
        (f.target/N.C.MARKER).write_bytes(b'foreign fence')
        with self.assertRaisesRegex(ValueError,'fence'):N.unfence_candidate(f)
        self.assertEqual(f.read(N.C.MARKER),b'foreign fence')
    def test_wrong_shutdown_phase_refuses_before_recovery(self):
        f,r=self.prepared();self.shutdown_receipts()
        path=self.evidence/'fenced-acceptance.json';obj=json.loads(path.read_text());obj['parser']['phase']='recovered';path.write_text(json.dumps(obj))
        with mock.patch.object(N.R,'resume') as resume:
            with self.assertRaisesRegex(ValueError,'shutdown'):N.recover()
            resume.assert_not_called()
        self.assertEqual(f.read(N.C.MARKER),f.marker)


    def test_final_process_check_preserves_fence_and_no_success_record(self):
        f,r=self.prepared();self.shutdown_receipts()
        # recover initial, unfence admission, then final immediately before disposition.
        with mock.patch.object(N.Base.installer,'stopped',side_effect=[None,None,ValueError('new process')]):
            with self.assertRaisesRegex(ValueError,'new process'):N.recover()
        N.verify_candidate(f,f.marker)
        self.assertFalse((self.evidence/'recovered-state.json').exists())
        self.assertFalse((self.evidence/'recovery-result.json').exists())
    def test_shutdown_snapshot_chain_mismatch_prevents_resume(self):
        f,r=self.prepared();self.shutdown_receipts()
        for filename in ('fenced-stopped.json','fenced-install.json'):
            path=self.evidence/filename;before=path.read_bytes();obj=json.loads(before);obj['settings']={'foreign':'value'};path.write_text(json.dumps(obj))
            with mock.patch.object(N.R,'resume') as resume:
                with self.subTest(file=filename),self.assertRaisesRegex(ValueError,'settings chain'):N.recover()
                resume.assert_not_called()
            self.assertEqual(f.read(N.C.MARKER),f.marker);path.write_bytes(before)
    def test_identical_marker_replacement_before_open_refuses(self):
        f,r=self.prepared();N.R.resume(f)
        original=N.D.DestinationLease._open;held=f.target/'held-marker'
        def replaced(guard,path,*args):
            if path==f.target/N.C.MARKER and args[0]==0x80010000:
                path.rename(held);path.write_bytes(f.marker)
            return original(guard,path,*args)
        with mock.patch.object(N.D.DestinationLease,'_open',new=replaced):
            with self.assertRaisesRegex(ValueError,'marker identity'):N.unfence_candidate(f)
        self.assertEqual(f.read(N.C.MARKER),f.marker);self.assertEqual(held.read_bytes(),f.marker)
    def test_launch_requires_active_fixture_and_no_writer_dll(self):
        self.evidence.mkdir()
        runtime=Path(self.tmp.name)/'runtime';writer=runtime/'Mods/foreign/dlls';writer.mkdir(parents=True)
        activation=self.evidence/'activation.json'
        with mock.patch.object(N,'RUNTIME',runtime),mock.patch.object(N,'load_fixture') as load:
            activation.write_text(json.dumps({'activated':True,'restored':True}))
            with self.assertRaisesRegex(ValueError,'inactive'):N.launch('fenced')
            activation.write_text(json.dumps({'activated':True,'restored':False}));(writer/'writer.dll').write_bytes(b'dummy')
            with self.assertRaisesRegex(ValueError,'native writer'):N.launch('fenced')
            load.assert_not_called()

if __name__=='__main__':unittest.main()
