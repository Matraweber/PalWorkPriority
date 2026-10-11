"""Clock installer safety regressions: temporary trees; no native process runs."""
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('clock_installer', REPO / 'tools/install_dedicated_clock_probe.py')
M = importlib.util.module_from_spec(spec)
spec.loader.exec_module(M)
PROCESS_CHECK = M.stopped


class ClockInstallerTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.server = self.root / 'server'
        self.runtime = self.server / 'Pal/Binaries/Win64/ue4ss'
        self.fixture = self.root / 'test-results/dedicated-clock-shared-20261011'
        self.fixture.mkdir(parents=True)
        (self.runtime / 'Mods').mkdir(parents=True)
        (self.runtime / 'UE4SS.dll').write_bytes(b'test-runtime')
        self.ini = self.server / 'Pal/Saved/Config/WindowsServer/GameUserSettings.ini'
        self.ini.parent.mkdir(parents=True)
        self.directory = 'a' * 32
        self.ini.write_text('[/Script/Pal.PalGameLocalSettings]\nDedicatedServerName=' + self.directory
                            + '\nAdminPassword=SECRET_NEVER_COPY\n')
        self.level = self.server / 'Pal/Saved/SaveGames/0' / self.directory / 'Level.sav'
        self.level.parent.mkdir(parents=True)
        self.level.write_bytes(b'untouched save')
        backup = self.server / 'PWPTestBackups/clock-shared-20261011'
        moves = []
        for relative, name in [('Mods', 'Mods'), ('Pal/Saved', 'Saved'), ('Pal/Content/Paks/LogicMods', 'LogicMods')]:
            active, old = self.server / relative, backup / name
            active.mkdir(parents=True, exist_ok=True)
            old.mkdir(parents=True)
            moves.append({'active': str(active), 'backup': str(old)})
        self.activation = self.fixture / 'activation.json'
        self.activation.write_text(json.dumps(dict(activated=True, restored=False,
            server_root=str(self.server), backup=str(backup), moves=moves)))
        (self.fixture / 'manual.json').write_text(json.dumps(dict(manual_root=str(self.runtime),
            proxy_path=str(self.server / 'Pal/Binaries/Win64/dwmapi.dll'))))
        for relative in M.SOURCES.values():
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(('-- inert test source: ' + relative + '\n').encode())
        for key, value in dict(ROOT=self.root, SERVER=self.server, RUNTIME=self.runtime,
                FIXTURE=self.fixture, EXPECTED_RUNTIME=hashlib.sha256(b'test-runtime').hexdigest()).items():
            p = patch.object(M, key, value)
            p.start();self.addCleanup(p.stop)
        p = patch.object(M, 'stopped')
        self.stopped = p.start();self.addCleanup(p.stop)
        self.destination = self.runtime / 'Mods' / 'PWPDedicatedClockProbe'

    def inactive(self):
        self.assertFalse((self.destination / 'enabled.txt').exists())
        self.assertFalse((self.destination / 'Scripts/run.txt').exists())

    def test_exact_clock_source_allowlist(self):
        self.assertEqual(M.SOURCES, {
            'main.lua': 'experiments/dedicated-clock-probe/main.lua',
            'dedicated_clock_entry.lua': 'experiments/dedicated_clock_entry.lua',
            'dedicated_parameter_clock.lua': 'experiments/dedicated_parameter_clock.lua',
            'dedicated_clock_probe.lua': 'experiments/dedicated_clock_probe.lua',
        })

    def test_preflight_does_not_write(self):
        before = {str(p): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        result = M.prepare(self.runtime)
        self.assertFalse(result['installed'])
        self.assertEqual(before, {str(p): p.read_bytes() for p in self.root.rglob('*') if p.is_file()})
        self.assertFalse(self.destination.exists())
        self.assertEqual(self.stopped.call_count, 1)

    def test_install_exact_manifest_nonce_only_config_and_arm_last(self):
        opens = []
        original = Path.open
        def observe(path, mode='r', *args, **kwargs):
            if mode == 'xb':
                opens.append(path)
            return original(path, mode, *args, **kwargs)
        with patch.object(Path, 'open', observe), patch.object(M, 'preflight', wraps=M.preflight) as preflight:
            result = M.prepare(self.runtime, True)
        self.assertEqual(preflight.call_count, 2)
        self.assertEqual(self.stopped.call_count, 3)
        self.assertTrue(result['installed'])
        scripts = self.destination / 'Scripts'
        nonce = result['nonce']
        self.assertEqual((scripts / 'config.lua').read_bytes(), ('return {nonce="' + nonce + '"}\n').encode())
        self.assertEqual((scripts / 'run.txt').read_bytes(), ('PWP_DEDICATED_CLOCK ' + nonce + '\n').encode())
        self.assertEqual(opens[-1], self.destination / 'enabled.txt')
        self.assertEqual((self.destination / 'enabled.txt').read_bytes(), b'')
        receipt = json.loads((self.fixture / M.RECEIPT).read_text())
        self.assertEqual(set(receipt['files']), set(M.SOURCES) | {'config.lua'})
        for name, sha in receipt['files'].items():
            self.assertEqual(sha, hashlib.sha256((scripts / name).read_bytes()).hexdigest())
        for flag in ['verified', 'storage_grant', 'authority_grant', 'coverage_grant', 'writer_loaded', 'elapsed_validated']:
            self.assertIs(receipt[flag], False)
        self.assertEqual({p.name for p in scripts.iterdir()}, set(M.SOURCES) | {'config.lua', 'run.txt'})
        self.assertNotIn('SECRET', json.dumps(receipt))
        self.assertNotIn('AdminPassword', json.dumps(receipt))
        self.assertFalse(list(self.destination.rglob('*.dll')))
        self.assertEqual(self.level.read_bytes(), b'untouched save')
        self.assertFalse((self.fixture / 'observer-installation.json').exists())

    def test_wrong_root_and_runtime_hash_cannot_be_bypassed(self):
        with self.assertRaises(RuntimeError):M.prepare(self.root / 'client', True)
        (self.runtime / 'UE4SS.dll').write_bytes(b'wrong-runtime')
        with self.assertRaises(RuntimeError):M.prepare(self.runtime, True)
        self.assertFalse(self.destination.exists())

    def test_restored_original_fixture_refuses_even_preflight(self):
        data = json.loads(self.activation.read_text());data['restored'] = True
        self.activation.write_text(json.dumps(data))
        for install in [False, True]:
            with self.assertRaises(RuntimeError):M.prepare(self.runtime, install)
        self.assertFalse(self.destination.exists())

    def test_manual_root_or_restoration_plan_mismatch_refuses(self):
        manual = self.fixture / 'manual.json'
        original = manual.read_bytes()
        manual.write_text('{}')
        with self.assertRaises(RuntimeError):M.prepare(self.runtime, True)
        manual.write_bytes(original)
        data = json.loads(self.activation.read_text());data['moves'] = []
        self.activation.write_text(json.dumps(data))
        with self.assertRaises(RuntimeError):M.prepare(self.runtime, True)
        self.assertFalse(self.destination.exists())

    def test_no_world_enumeration_or_fallback(self):
        self.ini.write_text('[/Script/Pal.PalGameLocalSettings]\nDedicatedServerName=' + 'b' * 32)
        with self.assertRaises(RuntimeError):M.prepare(self.runtime, True)
        self.assertFalse(self.destination.exists())

    def test_sensitive_malformed_ini_errors_redacted(self):
        for text in ['SECRET', '[/Script/Pal.PalGameLocalSettings]\nDedicatedServerName=../SECRET',
                     '[/Script/Pal.PalGameLocalSettings]\nDedicatedServerName=' + 'a'*32 + '\nDedicatedServerName=SECRET']:
            with self.assertRaises(RuntimeError) as error:M.configured_directory(text.encode())
            self.assertNotIn('SECRET', str(error.exception))

    def test_second_preflight_source_change_refuses_before_creation(self):
        def change():
            if self.stopped.call_count == 2:
                (self.root / M.SOURCES['main.lua']).write_bytes(b'changed')
        self.stopped.side_effect = change
        with self.assertRaises(RuntimeError):M.prepare(self.runtime, True)
        self.assertFalse(self.destination.exists())

    def test_final_stop_failure_leaves_inactive(self):
        self.stopped.side_effect = [None, None, RuntimeError('process appeared')]
        with self.assertRaises(RuntimeError):M.prepare(self.runtime, True)
        self.inactive()

    def test_final_fixture_revocation_leaves_inactive(self):
        def revoke():
            if self.stopped.call_count == 3:
                data = json.loads(self.activation.read_text());data['restored'] = True
                self.activation.write_text(json.dumps(data))
        self.stopped.side_effect = revoke
        with self.assertRaises(RuntimeError):M.prepare(self.runtime, True)
        self.inactive()

    def test_existing_destination_and_receipt_never_overwritten(self):
        receipt = self.fixture / M.RECEIPT
        receipt.write_bytes(b'original')
        with self.assertRaises(RuntimeError):M.prepare(self.runtime, True)
        self.assertEqual(receipt.read_bytes(), b'original')
        receipt.unlink();self.destination.mkdir()
        with self.assertRaises(RuntimeError):M.prepare(self.runtime, True)
        self.assertEqual(list(self.destination.iterdir()), [])

    def test_reparse_parent_refused(self):
        original = Path.lstat
        def reparse(path, *args, **kwargs):
            if path == self.runtime:
                return types.SimpleNamespace(st_mode=original(path).st_mode,
                    st_file_attributes=M.stat.FILE_ATTRIBUTE_REPARSE_POINT)
            return original(path, *args, **kwargs)
        with patch.object(Path, 'lstat', reparse):
            with self.assertRaises(RuntimeError):M.prepare(self.runtime, True)
        self.assertFalse(self.destination.exists())

    def failing_io(self, target, fault):
        original = Path.open
        class Broken:
            def __init__(self, handle):self.handle = handle
            def __enter__(self):return self
            def write(self, data):
                if fault == 'short':return self.handle.write(data[:-1])
                if fault == 'write':raise OSError('SECRET write failure')
                return self.handle.write(data)
            def __exit__(self, *args):
                self.handle.close()
                if fault == 'close':raise OSError('SECRET close failure')
        def open_file(path, mode='r', *args, **kwargs):
            handle = original(path, mode, *args, **kwargs)
            return Broken(handle) if mode == 'xb' and path.name == target else handle
        return patch.object(Path, 'open', open_file)

    def test_payload_short_write_leaves_inactive(self):
        with self.failing_io('main.lua', 'short'), self.assertRaises(RuntimeError):M.prepare(self.runtime, True)
        self.inactive()

    def test_payload_close_failure_leaves_inactive(self):
        with self.failing_io('main.lua', 'close'), self.assertRaises(OSError):M.prepare(self.runtime, True)
        self.inactive()

    def test_receipt_write_failure_leaves_inactive(self):
        with self.failing_io(M.RECEIPT, 'write'), self.assertRaises(OSError):M.prepare(self.runtime, True)
        self.inactive()

    def test_receipt_close_failure_leaves_inactive(self):
        with self.failing_io(M.RECEIPT, 'close'), self.assertRaises(OSError):M.prepare(self.runtime, True)
        self.inactive()

    def test_arm_short_write_removes_arm(self):
        with self.failing_io('run.txt', 'short'), self.assertRaises(RuntimeError):M.prepare(self.runtime, True)
        self.inactive()

    def test_arm_close_failure_removes_arm(self):
        with self.failing_io('run.txt', 'close'), self.assertRaises(OSError):M.prepare(self.runtime, True)
        self.inactive()

    def test_enabled_close_failure_revokes_both_markers(self):
        with self.failing_io('enabled.txt', 'close'), self.assertRaises(OSError):M.prepare(self.runtime, True)
        self.inactive()

    def test_actual_process_query_requires_positive_zero_without_native_execution(self):
        for code, output, passes in [(0, '0\n', True), (0, '1', False), (1, '0', False), (0, '', False)]:
            with patch.object(M.subprocess, 'run', return_value=types.SimpleNamespace(returncode=code, stdout=output)):
                if passes:PROCESS_CHECK()
                else:
                    with self.assertRaises(RuntimeError):PROCESS_CHECK()
        with patch.object(M.subprocess, 'run', side_effect=OSError('unavailable')):
            with self.assertRaises(OSError):PROCESS_CHECK()

    def test_cli_default_preflight_and_redacted_failure(self):
        output = io.StringIO()
        with patch('sys.argv', ['installer', '--runtime-root', str(self.runtime)]), contextlib.redirect_stdout(output):
            self.assertEqual(M.main(), 0)
        self.assertFalse(json.loads(output.getvalue())['installed'])
        output = io.StringIO()
        with patch('sys.argv', ['installer', '--runtime-root', str(self.runtime)]), \
             patch.object(M, 'prepare', side_effect=RuntimeError('SECRET')), contextlib.redirect_stdout(output):
            self.assertEqual(M.main(), 1)
        self.assertNotIn('SECRET', output.getvalue())
        self.inactive()


if __name__ == '__main__':
    unittest.main()
