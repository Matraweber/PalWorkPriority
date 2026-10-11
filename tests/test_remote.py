from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
import remote


class RemoteTests(unittest.TestCase):
    def test_diagnostic_never_deploys_by_default(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)
            trigger, log=root/'remote.txt',root/'priority.log'
            trigger.write_text('old\n')
            log.write_text('history\n')
            def output(_):
                with log.open('a') as f: f.write('new diagnostics\n')
            with patch.multiple(remote,MOD=d,TRIGGER=str(trigger),LOG=str(log)), \
                 patch.object(remote.time,'sleep',side_effect=output), \
                 patch.object(remote.subprocess,'run') as run:
                self.assertEqual(remote.main(['pwp','status']),0)
                run.assert_not_called()
            self.assertIn('pwp status',trigger.read_text())

    def test_missing_channel_does_not_create_or_deploy(self):
        with tempfile.TemporaryDirectory() as d:
            trigger=Path(d)/'remote.txt'
            with patch.multiple(remote,MOD=d,TRIGGER=str(trigger)), \
                 patch.object(remote.subprocess,'run') as run:
                self.assertEqual(remote.main(['pwp','status']),2)
                run.assert_not_called()
            self.assertFalse(trigger.exists())


if __name__=='__main__': unittest.main()
