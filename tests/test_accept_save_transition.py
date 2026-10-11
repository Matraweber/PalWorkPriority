"""Adversarial evidence checks; no game or production file access."""
import importlib.util
from pathlib import Path
import unittest
import json
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location('acceptance', Path(__file__).resolve().parents[1]/'tools/accept_save_transition.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def fixture():
    client, host = 'a'*32, 'b'*32
    def sample(world, directory, role, dedicated, loaded, selected):
        return ('SAMPLE status=observed | world='+world+' | directory_status=format_valid | directory='+directory
                +' | role_status=read | role='+role+' | dedicated_status=read | dedicated='+dedicated
                +' | verified=false | instance_world='+world+' | instance_selected_status=format_valid'
                +' | instance_selected='+selected+' | instance_loaded_status=read | instance_loaded_world='+loaded)
    events = [(0, 'ARM_CONSUMED property-only; verified=false'),
              (1, sample(module.GAME,client,'1','true','false',host)),
              (11, f'CLIENT_OBSERVED directory={client} verified=false'),
              (12, sample(module.TITLE,client,'3','false','false',host)),
              (12, 'TITLE_BOUNDARY verified=false'),
              (13, sample(module.GAME,host,'3','false','true',host)),
              (23, f'HOST_OBSERVED directory={host} differs_from_client=true selected_matches_host=true verified=false'),
              (23, 'TRANSITION_COMPLETE observations only samples=24 timer_cancelled=true')]
    log = '\n'.join(f'2026-10-04T00:00:{s:02d}Z PWP world reverse test {e}' for s,e in events)
    process = {'Id':123,'StartTime':'2026-10-04T01:59:00+02:00'}
    return log,process


class AcceptanceTests(unittest.TestCase):
    def test_valid_observation_never_enables_saving(self):
        log,p=fixture()
        r=module.validate(log,'test',p,p)
        self.assertTrue(r['observation_passed'])
        self.assertFalse(r['identity_verified'])
        self.assertFalse(r['async_enable_authorized'])

    def test_damaged_evidence_rejected(self):
        log,p=fixture()
        variants=[
            '', log.replace('TRANSITION_COMPLETE observations only','TIMEOUT transition incomplete'),
            log.replace('timer_cancelled=true','timer_cancelled=false'),
            log.replace('samples=24','samples=601'),
            log.replace('verified=false','verified=true'),
            log.replace('role=1','role=3'),
            log.replace('dedicated=true','dedicated=false'),
            log.replace('instance_loaded_world=true','instance_loaded_world=false'),
            log.replace('instance_loaded_status=read','instance_loaded_status=unknown'),
            log.replace('directory_status=format_valid','directory_status=unavailable'),
            log.replace('differs_from_client=true','differs_from_client=false'),
            log.replace('selected_matches_host=true','selected_matches_host=false'),
            log.replace('2026-10-04T00:00:11Z','2026-10-04T00:00:09Z'),
            log.replace('2026-10-04T00:00:23Z','2026-10-04T00:00:22Z'),
            log.replace('b'*32,'a'*32),
            log.replace('b'*32,'0'*32),
            log.replace(module.TITLE,'World wrong'),
            log+'\n'+log.splitlines()[-1],
        ]
        # Removing any individual event must invalidate this complete fixture.
        lines=log.splitlines()
        variants += ['\n'.join(lines[:i]+lines[i+1:]) for i in range(len(lines))]
        for i,bad in enumerate(variants):
            with self.subTest(case=i), self.assertRaises(ValueError):
                module.validate(bad,'test',p,p)

    def test_wrong_run_or_process_rejected(self):
        log,p=fixture()
        for after in ({},dict(p,Id=124),dict(p,StartTime='2026-10-04T02:00:00+02:00')):
            with self.assertRaises(ValueError): module.validate(log,'test',p,after)
        with self.assertRaises(ValueError): module.validate(log,'other',p,p)
        newer=dict(p,StartTime='2026-10-04T02:01:00+02:00')
        with self.assertRaises(ValueError): module.validate(log,'test',newer,newer)

    def test_cli_incomplete_archive_returns_failure(self):
        log,p=fixture()
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            files={'installation.json':{'nonce':'test'},'process-before.json':p,
                   'process-after.json':p,'acceptance.json':{k:True for k in
                   ('production_unchanged','source_hashes_match','arm_disabled','timer_cancelled')}}
            for name,data in files.items(): (root/name).write_text(json.dumps(data))
            target=root/'world-reverse-final.log'
            command=[sys.executable,str(Path(module.__file__)),str(root)]
            target.write_text(log)
            self.assertEqual(subprocess.run(command,capture_output=True).returncode,0)
            for bad in ('',log.replace('TRANSITION_COMPLETE observations only','TIMEOUT transition incomplete')):
                target.write_text(bad)
                self.assertNotEqual(subprocess.run(command,capture_output=True).returncode,0)
            target.write_text(log)
            for field in files['acceptance.json']:
                bad=dict(files['acceptance.json']);bad[field]=False
                (root/'acceptance.json').write_text(json.dumps(bad))
                self.assertNotEqual(subprocess.run(command,capture_output=True).returncode,0)


if __name__=='__main__':
    unittest.main()
