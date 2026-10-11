from pathlib import Path
import json
import sys
import tempfile
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
import run_cutover_rollback_native as N


class NativeRollbackGates(unittest.TestCase):
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
            (self.root/'fenced-install.json').write_text(json.dumps({'nonce':'n'}))
            (self.root/'fenced-acceptance.json').write_text(json.dumps({'parser':{'nonce':'n'},'processes':process}))
            (self.root/'mixed-state.json').write_text(json.dumps({'old':'value'}))
            with self.assertRaisesRegex(ValueError,'changed since'):N.recover()
            f.resume_rollback.assert_not_called()

    def test_absent_changed_or_wrong_phase_process_cannot_certify_shutdown(self):
        import server
        import server_control
        process=[{'pid':1,'path':'fixture','started_ticks':1}]
        for current,nonce in (([],'n'),([{**process[0],'pid':2}],'n'),(process,'wrong')):
            (self.root/'fenced-install.json').write_text(json.dumps({'nonce':'n'}))
            (self.root/'fenced-acceptance.json').write_text(json.dumps({'parser':{'nonce':nonce,'phase':'fenced'},'processes':process}))
            with mock.patch.object(N,'EVIDENCE',self.root),mock.patch.object(server,'server_processes',return_value=current),\
                 mock.patch.object(server_control,'graceful_stop') as stop,mock.patch.object(N,'record') as record:
                with self.assertRaises(ValueError):N.stop('fenced')
                stop.assert_not_called();record.assert_not_called()


if __name__=='__main__':unittest.main()
