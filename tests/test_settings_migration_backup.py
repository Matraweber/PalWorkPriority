import base64
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('backup', Path(__file__).resolve().parents[1]/'tools/settings_migration_backup.py')
b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)

class BackupTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.source=self.root/'settings';self.source.mkdir()
        self.target=self.root/'backup'
        self.original={'priorities.txt':b'# baseline=vanilla\npal|1|X\n',
                       'priorities.txt.pending':b'corrupt but must preserve\x00\xff',
                       'caps.txt':b'guild|Mining|Stone|OFF\n',
                       'caps.txt.bak':b''}
        for n,raw in self.original.items():(self.source/n).write_bytes(raw)
    def run_backup(self, guard=lambda:True):return b.backup(self.source,self.target,guard)
    def unchanged(self):
        self.assertEqual({p.name:p.read_bytes() for p in self.source.iterdir()},self.original)
    def test_exact_bytes_and_missing_are_retained(self):
        result=self.run_backup();self.unchanged()
        self.assertFalse(result['activation_allowed'])
        self.assertEqual(set(result['capture']['entries']),set(b.NAMES))
        for n in b.NAMES:
            e=result['capture']['entries'][n]
            if n in self.original:self.assertEqual(base64.b64decode(e['bytes']),self.original[n])
            else:self.assertEqual(e,{'state':'missing'})
        self.assertEqual(b.verify(self.target),result)
    def test_no_overwrite_or_automatic_partial_reuse(self):
        self.run_backup();(self.target/'caps.txt').write_bytes(b'changed')
        with self.assertRaises(ValueError):self.run_backup()
        with self.assertRaises(ValueError):b.verify(self.target)
        self.assertEqual((self.target/'caps.txt').read_bytes(),b'changed');self.unchanged()
    def test_refuse_active_writer_before_any_creation(self):
        with self.assertRaises(ValueError):self.run_backup(lambda:False)
        self.assertFalse(self.target.exists());self.unchanged()
    def test_writer_restart_during_copy_leaves_no_manifest(self):
        calls=[0]
        def guard():calls[0]+=1;return calls[0]<3
        with self.assertRaises(ValueError):self.run_backup(guard)
        self.assertFalse((self.target/'manifest.json').exists());self.unchanged()
    def test_source_edit_during_copy_is_not_accepted(self):
        original=b.write_new;once=[False]
        def write(path,raw):
            original(path,raw)
            if not once[0]:once[0]=True;(self.source/'caps.txt.tmp').write_bytes(b'new')
        with patch.object(b,'write_new',write),self.assertRaises(ValueError):self.run_backup()
        self.assertFalse((self.target/'manifest.json').exists())
    def test_post_manifest_change_blocks_return_and_reuse(self):
        original=b.write_new
        def write(path,raw):
            original(path,raw)
            if path.name=='manifest.json':(self.source/'caps.txt').write_bytes(b'new')
        with patch.object(b,'write_new',write),self.assertRaises(ValueError):self.run_backup()
        with self.assertRaises(ValueError):b.verify(self.target,b.capture(self.source))
    def test_flush_failure_never_claims_success(self):
        with patch.object(b.os,'fsync',side_effect=OSError('flush failed')),self.assertRaises(OSError):self.run_backup()
        self.assertFalse((self.target/'manifest.json').exists());self.unchanged()
    def test_short_write_and_close_errors(self):
        real=Path.open
        for fail in ('short','close'):
            target=self.root/fail
            class File:
                def __enter__(self):self.f=real(target,'xb');return self
                def write(self,raw):self.f.write(raw);return 0 if fail=='short' else len(raw)
                def flush(self):self.f.flush()
                def fileno(self):return self.f.fileno()
                def __exit__(self,*a):
                    self.f.close()
                    if fail=='close':raise OSError('close failed')
            with patch.object(Path,'open',lambda *a,**k:File()),self.assertRaises((OSError,ValueError)):
                b.write_new(target,b'x')
        self.unchanged()
    def test_read_close_error_is_not_missing(self):
        real=Path.open
        class File:
            def __enter__(self):self.f=real(self.path,'rb');return self
            def read(self,n):return self.f.read(n)
            def fileno(self):return self.f.fileno()
            def __exit__(self,*a):self.f.close();raise OSError('close failed')
        def open_(path,*a,**k):f=File();f.path=path;return f
        with patch.object(Path,'open',open_),self.assertRaises(OSError):b.capture(self.source)
    def test_directory_as_save_and_extra_backup_artifact_rejected(self):
        (self.source/'caps.txt.tmp').mkdir()
        with self.assertRaises(ValueError):b.capture(self.source)
        (self.source/'caps.txt.tmp').rmdir();self.run_backup();(self.target/'unexpected').mkdir()
        with self.assertRaises(ValueError):b.verify(self.target)
    def test_missing_folder_and_oversize_rejected(self):
        with self.assertRaises(ValueError):b.capture(self.root/'missing')
        with patch.object(b,'MAX_BYTES',8),self.assertRaises(ValueError):b.capture(self.source)
    def test_read_replacement_identity_detected(self):
        original=b.read_exact;calls=[0]
        def read(path):
            calls[0]+=1
            if calls[0]==len(b.NAMES)+1:
                p=self.source/'caps.txt';q=self.source/'replacement';q.write_bytes(p.read_bytes());p.unlink();q.rename(p)
            return original(path)
        with patch.object(b,'read_exact',read),self.assertRaises(ValueError):b.capture(self.source)
    def test_malformed_manifest_and_missing_file_refused(self):
        self.run_backup();p=self.target/'manifest.json';obj=json.loads(p.read_bytes());obj['activation_allowed']=True;p.write_text(json.dumps(obj))
        with self.assertRaises(ValueError):b.verify(self.target)
    def test_symlink_or_junction_rejected(self):
        link=self.root/'linked'
        try:link.symlink_to(self.source,target_is_directory=True)
        except OSError:self.skipTest('symlinks unavailable')
        with self.assertRaises(ValueError):b.capture(link)
    def test_unchanged_snapshot_does_not_prove_future_authority(self):
        s=b.capture(self.source);self.run_backup();result=b.verify(self.target,s)
        self.assertIs(result['activation_allowed'],False)

    def test_source_paths_cannot_be_backup_destinations(self):
        for name in ('caps.txt.tmp','caps.txt.pending','backup-folder'):
            with self.assertRaises(ValueError):b.backup(self.source,self.source/name,lambda:True)
            self.assertFalse((self.source/name).exists())
        self.unchanged()
    def test_large_valid_file_and_aggregate_manifest_budget(self):
        data=b'a'*(6*1024*1024)
        (self.source/'priorities.txt').write_bytes(data)
        result=self.run_backup()
        self.assertEqual(base64.b64decode(result['capture']['entries']['priorities.txt']['bytes']),data)
        self.assertGreater(b.MAX_MANIFEST_BYTES,8*((b.MAX_BYTES+2)//3*4)+1024*1024)
    def test_process_failure_and_unknown_output_not_closed(self):
        from subprocess import CompletedProcess
        for status,out in ((2,'CLOSED'),(0,'RUNNING'),(0,''),(0,'noise\nCLOSED')):
            with patch.object(b.os,'name','nt'),patch.object(b.subprocess,'run',return_value=CompletedProcess([],status,out,'')):
                if status:
                    with self.assertRaises(ValueError):b.game_closed()
                else:self.assertFalse(b.game_closed())

    def test_process_guard_only_accepts_explicit_success_and_uses_family_predicate(self):
        result=subprocess.CompletedProcess([],0,'CLOSED\n','')
        with patch.object(b.os,'name','nt'),patch.object(b.subprocess,'run',return_value=result) as run:
            self.assertTrue(b.game_closed())
        args=run.call_args.args[0]
        self.assertEqual(args[:4],['powershell','-NoProfile','-NonInteractive','-Command'])
        self.assertIn('Get-Process -ErrorAction Stop',args[4])
        self.assertIn('Where-Object { '+b.PROCESS_PREDICATE+' }',args[4])
        self.assertNotIn('CommandLine',args[4])
        self.assertEqual(run.call_args.kwargs['timeout'],15)

    def test_process_query_exception_timeout_and_unsupported_host_fail_closed(self):
        for error in (OSError('query unavailable'),subprocess.TimeoutExpired('powershell',15)):
            with patch.object(b.os,'name','nt'),patch.object(b.subprocess,'run',side_effect=error):
                with self.assertRaises(type(error)):b.game_closed()
        with patch.object(b.os,'name','posix'),patch.object(b.subprocess,'run') as run:
            with self.assertRaises(ValueError):b.game_closed()
            run.assert_not_called()

    @unittest.skipUnless(os.name=='nt' and shutil.which('powershell'), 'Windows PowerShell required')
    def test_real_powershell_predicate_on_synthetic_names_only(self):
        # Execute the exact production predicate on inert objects. No Get-Process,
        # actual game query, launcher, or process lifecycle operation is executed.
        names={
            'Palworld':True,'PalServer':True,
            'Palworld-Win64-Shipping':True,'Palworld-Win64-Shipping-Cmd':True,
            'PalServer-Win64-Shipping':True,'PalServer-Win64-Shipping-Cmd':True,
            'PalServer-Win64-Test':True,'Palworld-Win64-Test':True,
            'palserver-win64-shipping-cmd':True,'PALWORLD':True,
            'PalServer-FutureBuild':True,'PalworldLauncher':True,
            'powershell':False,'python':False,'UnrelatedPalServer':False,
            'UnrelatedPalworld':False,'Pal':False,
        }
        literals=','.join("'"+name+"'" for name in names)
        command=("$ErrorActionPreference='Stop'; foreach ($name in @("+literals+")) { "
                 "$found=@([pscustomobject]@{ProcessName=$name} | Where-Object { "
                 +b.PROCESS_PREDICATE+" }); Write-Output ($name+'='+$found.Count) }")
        result=subprocess.run(['powershell','-NoProfile','-NonInteractive','-Command',command],
                              capture_output=True,text=True,timeout=15)
        self.assertEqual(result.returncode,0,result.stderr)
        observed=dict(line.split('=') for line in result.stdout.splitlines())
        self.assertEqual(observed,{name:'1' if blocked else '0' for name,blocked in names.items()})

if __name__=='__main__':unittest.main()
