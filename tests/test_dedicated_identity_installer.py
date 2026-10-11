"""Installer tests use temporary trees and mocked process queries only."""
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
spec = importlib.util.spec_from_file_location('identity_installer', REPO / 'tools/install_dedicated_identity_observer.py')
M = importlib.util.module_from_spec(spec)
spec.loader.exec_module(M)
PROCESS_CHECK = M.stopped


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.server = self.root / 'server'
        self.runtime = self.server / 'Pal/Binaries/Win64/ue4ss'
        self.fixture = self.root / 'test-results/server-identity-20261009'
        self.fixture.mkdir(parents=True)
        (self.runtime / 'Mods').mkdir(parents=True)
        (self.runtime / 'UE4SS.dll').write_bytes(b'test-runtime')
        self.ini = self.server / 'Pal/Saved/Config/WindowsServer/GameUserSettings.ini'
        self.ini.parent.mkdir(parents=True)
        self.directory = 'a' * 32
        self.ini.write_text('[/Script/Pal.PalGameLocalSettings]\nDedicatedServerName=' + self.directory
                            + '\nAdminPassword=SECRET_NEVER_COPY\n')
        level = self.server / 'Pal/Saved/SaveGames/0' / self.directory / 'Level.sav'
        level.parent.mkdir(parents=True);level.write_bytes(b'untouched save')
        moves = []
        backup = self.server / 'PWPTestBackups/identity-20261009'
        for relative, name in [('Mods', 'Mods'), ('Pal/Saved', 'Saved'), ('Pal/Content/Paks/LogicMods', 'LogicMods')]:
            active = self.server / relative
            old = backup / name
            active.mkdir(parents=True, exist_ok=True);old.mkdir(parents=True)
            moves.append({'active': str(active), 'backup': str(old)})
        (self.fixture / 'activation.json').write_text(json.dumps(dict(
            activated=True, restored=False, server_root=str(self.server), backup=str(backup), moves=moves)))
        (self.fixture / 'manual.json').write_text(json.dumps(dict(manual_root=str(self.runtime),
            proxy_path=str(self.server / 'Pal/Binaries/Win64/dwmapi.dll'))))
        for relative in M.SOURCES.values():
            dest = self.root / relative
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes((REPO / relative).read_bytes())
        for key, value in dict(ROOT=self.root, SERVER=self.server, RUNTIME=self.runtime,
                               FIXTURE=self.fixture, EXPECTED_RUNTIME=hashlib.sha256(b'test-runtime').hexdigest()).items():
            p = patch.object(M, key, value);p.start();self.addCleanup(p.stop)
        p = patch.object(M, 'stopped');self.stopped = p.start();self.addCleanup(p.stop)
        self.destination = self.runtime / 'Mods' / M.PROBE_NAME

    def test_preflight_has_no_writes(self):
        before = sorted(str(p) for p in self.root.rglob('*'))
        result = M.prepare(self.runtime)
        self.assertFalse(result['installed'])
        self.assertEqual(before, sorted(str(p) for p in self.root.rglob('*')))

    def test_stages_only_lua_diagnostic_and_redacted_receipt(self):
        result = M.prepare(self.runtime, True)
        self.assertTrue(result['installed'])
        self.assertTrue((self.destination / 'enabled.txt').is_file())
        self.assertEqual(self.stopped.call_count, 3)
        receipt = (self.fixture / 'observer-installation.json').read_text()
        self.assertNotIn('SECRET', receipt)
        self.assertNotIn('AdminPassword', receipt)
        data = json.loads(receipt)
        self.assertFalse(data['verified']);self.assertFalse(data['storage_grant'])
        self.assertFalse(data['writer_loaded'])
        self.assertEqual(set(data['files']), set(M.SOURCES) | {'config.lua'})
        self.assertFalse(list(self.destination.rglob('*.dll')))
        self.assertEqual((self.server / 'Pal/Saved/SaveGames/0' / self.directory / 'Level.sav').read_bytes(), b'untouched save')

    def test_client_root_and_runtime_mismatch_refused(self):
        with self.assertRaises(RuntimeError):M.prepare(self.root / 'client', True)
        (self.runtime / 'UE4SS.dll').write_bytes(b'wrong')
        with self.assertRaises(RuntimeError):M.prepare(self.runtime, True)
        self.assertFalse(self.destination.exists())

    def test_optional_explicit_guild_is_query_only_and_in_manifest(self):
        target = 'd2c75eae4e5c0c4c4d24b89b2010b5eb'
        result = M.prepare(self.runtime, guild=target)
        self.assertEqual(result['query_guild'], target)
        self.assertTrue(result['guild_is_query_only'])
        M.prepare(self.runtime, True, target)
        config = (self.destination / 'Scripts/config.lua').read_text()
        self.assertIn('guild="' + target + '"', config)
        receipt = json.loads((self.fixture / 'observer-installation.json').read_text())
        self.assertEqual(receipt['query_guild'], target)
        self.assertFalse(receipt['authority_grant'])
        self.assertIn('dedicated_guild_probe.lua', receipt['files'])
        self.assertEqual(receipt['files']['dedicated_guild_probe.lua'],
                         hashlib.sha256((REPO/'experiments/dedicated_guild_probe.lua').read_bytes()).hexdigest())
        self.assertNotIn('SECRET', json.dumps(receipt))

    def test_guild_disabled_by_default_and_malformed_input_never_stages(self):
        self.assertIsNone(M.prepare(self.runtime)['query_guild'])
        for target in ['', '0'*32, 'A'*32, '-758686034-1314655308-1294252187-537966059',
                       'a'*31, 'a'*33, 'a'*31+'\n', '"SECRET', 1, False]:
            with self.assertRaises(RuntimeError):M.prepare(self.runtime, True, target)
        self.assertFalse(self.destination.exists())

    def test_parameter_opt_in_requires_guild_and_preserves_default(self):
        self.assertFalse(M.prepare(self.runtime)['parameter_observation'])
        for enabled,guild in [(True,None),('true','a'*32),(1,'a'*32)]:
            with self.assertRaises(RuntimeError):
                M.prepare(self.runtime,True,guild,enabled)
        self.assertFalse(self.destination.exists())

    def test_parameter_package_manifest_config_and_no_save_mutation(self):
        before=self.ini.read_bytes()
        M.prepare(self.runtime,True,'b'*32,True)
        scripts=self.destination/'Scripts'
        self.assertIn('parameters=true',(scripts/'config.lua').read_text())
        receipt=json.loads((self.fixture/'observer-installation.json').read_text())
        self.assertTrue(receipt['parameter_observation'])
        self.assertEqual(receipt['max_parameter_attempts_per_sample'],1)
        self.assertEqual(receipt['max_callbacks'],60)
        self.assertEqual(receipt['parameter_clock'],'GameplayStatics.GetAccurateRealTime')
        for name in ['dedicated_parameter_observer.lua','dedicated_parameter_entry.lua','dedicated_parameter_clock.lua']:
            self.assertEqual(receipt['files'][name],hashlib.sha256((scripts/name).read_bytes()).hexdigest())
        self.assertEqual(self.ini.read_bytes(),before)
        self.assertFalse(list(self.destination.rglob('*.dll')))

    def test_only_configured_world_no_directory_fallback(self):
        self.ini.write_text('[/Script/Pal.PalGameLocalSettings]\nDedicatedServerName=' + 'b' * 32)
        with self.assertRaises(RuntimeError):M.prepare(self.runtime, True)
        self.assertFalse(self.destination.exists())

    def test_duplicate_missing_and_malicious_settings_refused_without_disclosure(self):
        for content in ['SECRET', '[/Script/Pal.PalGameLocalSettings]\nDedicatedServerName=../SECRET',
                        '[/Script/Pal.PalGameLocalSettings]\nDedicatedServerName=' + 'a'*32 + '\nDedicatedServerName=SECRET']:
            with self.assertRaises(RuntimeError) as error:M.configured_directory(content.encode())
            self.assertNotIn('SECRET', str(error.exception))

    def test_restored_or_misbound_fixture_refused(self):
        target = self.fixture / 'activation.json';data = json.loads(target.read_text())
        data['restored'] = True;target.write_text(json.dumps(data))
        with self.assertRaises(RuntimeError):M.prepare(self.runtime, True)
        self.assertFalse(self.destination.exists())

    def test_final_stop_failure_leaves_inactive_package(self):
        self.stopped.side_effect = [None, None, RuntimeError('process appeared')]
        with self.assertRaises(RuntimeError):M.prepare(self.runtime, True)
        self.assertFalse((self.destination / 'enabled.txt').exists())
        self.assertFalse((self.destination / 'Scripts/run.txt').exists())

    def test_raced_existing_destination_not_modified(self):
        original = M.preflight
        calls = 0
        def race(runtime):
            nonlocal calls
            result = original(runtime)
            calls += 1
            if calls == 2:self.destination.mkdir()
            return result
        with patch.object(M, 'preflight', race):
            with self.assertRaises(FileExistsError):M.prepare(self.runtime, True)
        self.assertEqual(list(self.destination.iterdir()), [])

    def test_cli_does_not_print_raw_exception_or_configuration(self):
        output = io.StringIO()
        with patch('sys.argv', ['installer', '--runtime-root', str(self.runtime)]), \
             patch.object(M, 'prepare', side_effect=RuntimeError('SECRET')), contextlib.redirect_stdout(output):
            self.assertEqual(M.main(), 1)
        self.assertNotIn('SECRET', output.getvalue())

    def test_process_query_requires_positive_zero(self):
        # Test the actual read-only query without executing PowerShell.
        for code, output, passes in [(0, '0\n', True), (0, '1', False), (1, '0', False), (0, '', False)]:
            with patch.object(M.subprocess, 'run', return_value=types.SimpleNamespace(returncode=code, stdout=output)):
                if passes:PROCESS_CHECK()
                else:
                    with self.assertRaises(RuntimeError):PROCESS_CHECK()


if __name__ == '__main__':
    unittest.main()
