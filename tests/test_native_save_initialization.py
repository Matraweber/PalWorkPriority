"""Real Windows native first-publication tests. Disposable directories only.

Set PWP_NATIVE_INIT_EXE to the binary built by build_save_initialization.ps1.
These tests are not UE4SS integration, active-world, or power-loss tests.
"""
import ctypes
import hashlib
import struct
from ctypes import wintypes
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid

EXE = os.environ.get('PWP_NATIVE_INIT_EXE')
STORAGE = 'a' * 32
GUILD = 'b' * 32


@unittest.skipUnless(os.name == 'nt' and EXE, 'requires explicitly built native test executable')
class NativeInitialization(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pwp-native-init-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.k = ctypes.WinDLL('kernel32', use_last_error=True)
        self.k.CreateEventW.argtypes = [wintypes.LPVOID, wintypes.BOOL, wintypes.BOOL, wintypes.LPCWSTR]
        self.k.CreateEventW.restype = wintypes.HANDLE
        self.k.SetEvent.argtypes = [wintypes.HANDLE]
        self.k.CloseHandle.argtypes = [wintypes.HANDLE]

    def target(self, root=None, stream='priorities'):
        return (root or self.root) / f'pwp-init-{STORAGE}-{GUILD}-{stream}.record'

    def args(self, hook='none', root=None, storage=STORAGE, guild=GUILD, stream='priorities'):
        return [EXE, str(root or self.root), storage, guild, stream, hook]

    def run_write(self, data=b'first', **kwargs):
        return subprocess.run(self.args(**kwargs), input=data, capture_output=True, timeout=20)

    def pause(self, data, point='before_publish'):
        name = 'Local\\PWPInitTest-' + uuid.uuid4().hex
        event = self.k.CreateEventW(None, True, False, name)
        self.assertTrue(event)
        self.addCleanup(self.k.CloseHandle, event)
        child = subprocess.Popen(self.args('pause:' + point), stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 env={**os.environ, 'PWP_TEST_GATE': name})
        def finish():
            if child.poll() is None:
                child.kill()  # disposable helper only, never the game
            child.wait(timeout=20)
            child.stdout.close()
            child.stderr.close()
        self.addCleanup(finish)
        child.stdin.write(data)
        child.stdin.close()
        child.stdin = None
        # Child has its own bounded wait; an early exit returns EOF and fails.
        self.assertEqual(child.stdout.readline().strip(), b'READY')
        return child, event

    def release(self, child, event):
        self.assertTrue(self.k.SetEvent(event))
        out, err = child.communicate(timeout=20)
        return child.returncode, out, err

    def test_binary_and_maximum_payload(self):
        data = bytes(range(256)) * 1024
        self.assertEqual(self.run_write(data).returncode, 0)
        self.assertEqual(self.target().read_bytes(), data)
        self.assertEqual(list(self.root.glob('*.tmp')), [])

    def test_empty_and_oversize_rejected_without_files(self):
        for data in (b'', b'x' * 262451):
            self.assertEqual(self.run_write(data).returncode, 1)
            self.assertEqual(list(self.root.iterdir()), [])

    def test_encoded_capacity_and_full_settings_envelope(self):
        scope=('PWP-SCOPE-1:'+STORAGE+':'+GUILD+':priorities').encode()
        payload=bytes(range(256))*1024
        body=b'PWPJNL1\n'+struct.pack('<HII',len(scope),1,len(payload))+scope+payload
        encoded=body+hashlib.sha256(body).digest()
        self.assertEqual(len(encoded),262282)
        self.assertEqual(self.run_write(encoded).returncode,0)
        self.assertEqual(self.target().read_bytes(),encoded)
        self.assertEqual(self.run_write(b'x'*262450,stream='limits').returncode,0)
        self.assertEqual(self.target(stream='limits').read_bytes(),b'x'*262450)

    def test_existing_empty_and_nonempty_preserved(self):
        for data in (b'', b'previous save'):
            self.target().write_bytes(data)
            self.assertEqual(self.run_write().returncode, 2)
            self.assertEqual(self.target().read_bytes(), data)
        self.assertEqual(len(list(self.root.glob('*.tmp'))), 2)

    def test_existing_directory_preserved(self):
        self.target().mkdir()
        result = self.run_write()
        self.assertIn(result.returncode, (2, 3))
        self.assertTrue(self.target().is_dir())

    def test_scopes_and_streams_are_isolated(self):
        self.assertEqual(self.run_write(b'p').returncode, 0)
        self.assertEqual(self.run_write(b'l', stream='limits').returncode, 0)
        self.assertEqual(self.target().read_bytes(), b'p')
        self.assertEqual(self.target(stream='limits').read_bytes(), b'l')
        for storage, guild, data in [('c' * 32, GUILD, b'storage'), (STORAGE, 'd' * 32, b'guild')]:
            self.assertEqual(self.run_write(data, storage=storage, guild=guild).returncode, 0)
            target = self.root / f'pwp-init-{storage}-{guild}-priorities.record'
            self.assertEqual(target.read_bytes(), data)
        self.assertEqual(self.target().read_bytes(), b'p')

    def test_invalid_identifiers_and_paths(self):
        for args in ({'storage': '../x'}, {'guild': 'B' * 32}, {'stream': '../limits'},
                     {'root': str(self.root) + '\\..'}, {'root': str(self.root) + '\\'},
                     {'root': str(self.root) + ':stream'}, {'root': '.'}):
            self.assertNotEqual(self.run_write(**args).returncode, 0)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_missing_parent_is_not_created(self):
        self.assertEqual(self.run_write(root=self.root / 'missing').returncode, 3)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_junction_root_and_ancestor_refused(self):
        real = self.root / 'real'
        real.mkdir()
        (real / 'child').mkdir()
        link = self.root / 'junction'
        # Native PowerShell creates the junction; no string-built shell paths.
        script = "$ErrorActionPreference = 'Stop'; New-Item -ItemType Junction -Path $env:PWP_TEST_LINK -Target $env:PWP_TEST_REAL | Out-Null"
        subprocess.run(['powershell', '-NoProfile', '-Command', script], check=True,
                       env={**os.environ, 'PWP_TEST_LINK': str(link), 'PWP_TEST_REAL': str(real)},
                       capture_output=True, timeout=20)
        self.assertTrue(link.exists())
        self.assertTrue(link.stat(follow_symlinks=False).st_file_attributes & 0x400)
        self.assertTrue(os.path.samefile(link, real))
        for root in (link, link / 'child'):
            self.assertEqual(self.run_write(root=root).returncode, 3)
        self.assertEqual(list(real.glob('*.record')), [])
        self.assertEqual(list((real / 'child').iterdir()), [])

    def test_two_process_publishers_exactly_one_wins(self):
        a, ga = self.pause(b'A' * 262144)
        b, gb = self.pause(b'B' * 262144)
        self.k.SetEvent(ga)
        self.k.SetEvent(gb)
        ra = a.communicate(timeout=20)
        rb = b.communicate(timeout=20)
        self.assertEqual(sorted((a.returncode, b.returncode)), [0, 2], (ra, rb))
        expected = b'A' if a.returncode == 0 else b'B'
        self.assertEqual(self.target().read_bytes(), expected * 262144)
        stages = list(self.root.glob('*.tmp'))
        self.assertEqual(len(stages), 1)
        self.assertEqual(stages[0].read_bytes(), (b'B' if expected == b'A' else b'A') * 262144)

    def test_external_winner_created_after_staging_is_preserved(self):
        child, gate = self.pause(b'ours')
        self.target().write_bytes(b'external')
        self.assertEqual(self.release(child, gate)[0], 2)
        self.assertEqual(self.target().read_bytes(), b'external')

    def test_winning_file_still_open_cannot_be_replaced(self):
        child, gate = self.pause(b'winner', point='after_publish')
        self.assertIn(self.run_write(b'loser').returncode, (2, 3))
        self.assertEqual(self.release(child, gate)[0], 0)
        self.assertEqual(self.target().read_bytes(), b'winner')

    def test_stage_cannot_be_changed_or_substituted_before_publish(self):
        child, gate = self.pause(b'owned bytes')
        stage, = self.root.glob('*.tmp')
        with self.assertRaises(OSError):
            stage.write_bytes(b'corrupt')
        with self.assertRaises(OSError):
            stage.unlink()
        with self.assertRaises(OSError):
            stage.rename(self.root / 'moved')
        self.assertEqual(self.release(child, gate)[0], 0)
        self.assertEqual(self.target().read_bytes(), b'owned bytes')

    def test_root_rename_refused_while_writer_active(self):
        child, gate = self.pause(b'ours')
        with self.assertRaises(OSError):
            self.root.rename(self.root.with_name(self.root.name + '-moved'))
        self.assertEqual(self.release(child, gate)[0], 0)

    def test_failure_boundaries_never_publish(self):
        for point in ('before_write', 'after_write', 'after_flush', 'before_publish'):
            result = self.run_write(hook='fail:' + point)
            self.assertEqual(result.returncode, 3)
            self.assertFalse(self.target().exists())
        self.assertEqual(len(list(self.root.glob('*.tmp'))), 4)

    def test_after_publish_error_is_not_definite_failure(self):
        self.assertEqual(self.run_write(b'committed', hook='fail:after_publish').returncode, 4)
        self.assertEqual(self.target().read_bytes(), b'committed')
        self.assertEqual(self.run_write(b'retry').returncode, 2)
        self.assertEqual(self.target().read_bytes(), b'committed')

    def test_terminated_stager_is_not_a_committed_record(self):
        child, _ = self.pause(b'orphan')
        child.kill()
        child.wait(timeout=20)
        self.assertFalse(self.target().exists())
        self.assertEqual(len(list(self.root.glob('*.tmp'))), 1)
        self.assertEqual(self.run_write(b'new').returncode, 0)
        self.assertEqual(self.target().read_bytes(), b'new')
        self.assertEqual(len(list(self.root.glob('*.tmp'))), 1)


if __name__ == '__main__':
    unittest.main(verbosity=2)
