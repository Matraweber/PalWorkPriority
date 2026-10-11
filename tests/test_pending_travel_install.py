"""Installer contracts in temporary directories only; no game/native actions."""
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import install_pending_travel_trial as I


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.mod = self.root / 'runtime/Mods/PalWorkPriority'
        self.base = self.root / 'baseline'
        self.lock = self.root / 'lock'
        self.store = self.root / 'store'
        self.stage = self.mod / 'async-trial/normal'
        self.launch = self.mod / 'async-trial/launch.lua'
        self.receipt = self.root / 'barrier.json'
        for name, value in dict(ROOT=self.root, MOD=self.mod, BASE=self.base,
                                LOCK=self.lock, STORE=self.store, LAUNCH=self.launch).items():
            p = patch.object(I, name, value); p.start(); self.addCleanup(p.stop)
        for name, value in [('game_closed', True), ('capture', {}), ('verify', {})]:
            p = patch.object(I.B, name, return_value=value)
            mock = p.start(); self.addCleanup(p.stop)
            setattr(self, name, mock)
        self.write(self.mod / 'Scripts/main.lua', b'checked main')
        self.write(self.mod / 'config.lua', b'config')
        self.write(self.stage / 'experiments/live.lua', b'launcher module')
        self.write(self.stage / 'pwp_draining_bridge.dll', b'normal DLL fixture')
        self.write(self.mod.parent.parent / 'UE4SS.dll', b'runtime fixture')
        self.write(self.mod / 'Scripts/settings_gate.lua', b'new gate')
        self.write(self.root / 'test-results/limits-startup-receipt-20261007.lua', b'checked receipt')
        self.write(self.mod / 'async-trial/receipt.lua', b'checked receipt')
        original = dict(stage=str(self.stage), protected={
            'Scripts/main.lua': I.sha(self.mod / 'Scripts/main.lua'),
            'Scripts/settings_gate.lua': 'old gate digest',
            'config.lua': I.sha(self.mod / 'config.lua')}, updates={},
            sources={'experiments/live.lua': I.sha(self.stage / 'experiments/live.lua')},
            native={'probe_sha256': I.sha(self.stage / 'pwp_draining_bridge.dll'),
                    'staged_runtime_sha256': I.sha(self.mod.parent.parent / 'UE4SS.dll')})
        self.normal = ("return install{dll='" + (self.stage / 'pwp_draining_bridge.dll').as_posix() + "'}\n").encode()
        self.write(self.launch, self.normal)
        original['launcher_sha256'] = I.sha(self.launch)
        self.original = original
        self.json(self.base / 'installed.json', original)
        self.json(self.lock / 'installed.json', {'changes': [{
            'target': str(self.mod / 'Scripts/settings_gate.lua'),
            'after': I.sha(self.mod / 'Scripts/settings_gate.lua')}]})
        rows = []
        for n in range(4):
            p = self.store / ('journal%d.record' % n)
            self.write(p, ('generation5-%d' % n).encode())
            rows.append({'file': p.name, 'sha256': I.sha(p)})
        self.json(self.base / 'restored/decoded.json', rows)
        self.write(self.root / 'native/source.cpp', b'checked barrier source')
        self.write(self.root / 'barrier.dll', b'TEST ONLY DLL fixture')
        self.native = dict(test_only=True, tests_passed=True, source_stable=True,
            bounded_hold_ms=60000, compiled_root=str(self.store),
            staged_runtime_sha256=original['native']['staged_runtime_sha256'],
            artifact=str(self.root / 'barrier.dll'), probe_sha256=I.sha(self.root / 'barrier.dll'),
            sources={'native/source.cpp': I.sha(self.root / 'native/source.cpp')},
            evidence_path=str(self.root / 'native-evidence.log'))
        self.json(self.receipt, self.native)

    def write(self, path, raw):
        path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(raw)

    def json(self, path, value):
        self.write(path, json.dumps(value).encode())

    def snapshot(self):
        return {str(p.relative_to(self.root)): p.read_bytes()
                for p in self.root.rglob('*') if p.is_file()}

    def test_default_preflight_is_read_only(self):
        before = self.snapshot()
        with patch.object(sys, 'argv', ['installer', '--receipt', str(self.receipt)]), contextlib.redirect_stdout(io.StringIO()):
            I.main()
        self.assertEqual(before, self.snapshot())
        self.verify.assert_called()

    def test_bad_native_contract_rejected_without_writes(self):
        for field, value in [('test_only', False), ('tests_passed', False),
                ('source_stable', False), ('bounded_hold_ms', 0), ('bounded_hold_ms', 60001),
                ('bounded_hold_ms', True), ('bounded_hold_ms', False),
                ('bounded_hold_ms', 1.5), ('bounded_hold_ms', 60000.0),
                ('compiled_root', str(self.root)), ('staged_runtime_sha256', 'bad'),
                ('probe_sha256', 'bad'), ('sources', {})]:
            with self.subTest(field=field, value=value):
                self.json(self.receipt, dict(self.native, **{field: value}))
                before = self.snapshot()
                with self.assertRaises(ValueError): I.preflight(self.receipt)
                self.assertEqual(before, self.snapshot())

    def test_changed_inputs_and_prior_evidence_rejected(self):
        for path in [self.launch, self.mod / 'Scripts/main.lua',
                     self.mod / 'async-trial/receipt.lua',
                     self.mod / 'Scripts/settings_gate.lua', self.root / 'native/source.cpp',
                     self.store / 'journal0.record']:
            with self.subTest(path=path):
                old = path.read_bytes(); path.write_bytes(old + b'changed')
                with self.assertRaises(ValueError): I.preflight(self.receipt)
                path.write_bytes(old)
        self.write(Path(self.native['evidence_path']), b'previous evidence')
        with self.assertRaises(ValueError): I.preflight(self.receipt)

    def test_running_game_and_legacy_failure_rejected(self):
        self.game_closed.return_value = False
        with self.assertRaises(ValueError): I.preflight(self.receipt)
        self.game_closed.return_value = True
        self.verify.side_effect = ValueError('legacy mismatch')
        with self.assertRaises(ValueError): I.preflight(self.receipt)

    def prepare_restore(self):
        before = I.preflight(self.receipt)
        trial = b'return install{dll="test-only.dll"}\n'
        self.write(self.launch, trial)
        evidence = self.root / 'restore-evidence'
        self.write(evidence / 'previous-launch.lua', self.normal)
        self.json(evidence / 'installed.json', dict(before, launcher_sha256=I.sha(self.launch)))
        # Restoring the normal DLL must preserve newer journal contents.
        self.write(self.store / 'journal0.record', b'new accepted generation')
        return evidence

    def restore(self, evidence):
        with patch.object(sys, 'argv', ['installer', '--restore', str(evidence)]), contextlib.redirect_stdout(io.StringIO()):
            I.main()

    def test_restore_preserves_current_journals(self):
        evidence = self.prepare_restore(); before = self.snapshot()
        self.restore(evidence)
        after = self.snapshot()
        changed = {p for p in before.keys() | after.keys() if before.get(p) != after.get(p)}
        self.assertEqual(changed, {str(self.launch.relative_to(self.root)),
                                  str(Path('restore-evidence') / 'restored-launch.json')})
        self.assertEqual(self.launch.read_bytes(), self.normal)

    def test_restore_refuses_changed_launcher_or_backup_or_code(self):
        evidence = self.prepare_restore()
        for path in [self.launch, evidence / 'previous-launch.lua', self.mod / 'Scripts/main.lua']:
            with self.subTest(path=path):
                old = path.read_bytes(); path.write_bytes(old + b'changed')
                before = self.snapshot()
                with self.assertRaises(ValueError): self.restore(evidence)
                self.assertEqual(before, self.snapshot()); path.write_bytes(old)

    def test_restore_requires_closed_game(self):
        evidence = self.prepare_restore()
        self.game_closed.return_value = False
        before = self.snapshot()
        with self.assertRaises(ValueError): self.restore(evidence)
        self.assertEqual(before, self.snapshot())

    def test_restore_from_intent_after_activation(self):
        evidence = self.prepare_restore()
        (evidence / 'installed.json').rename(evidence / 'intent.json')
        journals = I.journals()
        self.restore(evidence)
        self.assertEqual(self.launch.read_bytes(), self.normal)
        self.assertEqual(I.journals(), journals)
        before = self.snapshot()
        with patch.object(I, 'replace_launcher', side_effect=AssertionError('already restored')):
            self.restore(evidence)
        self.assertEqual(before, self.snapshot())

    def test_restore_from_intent_before_activation(self):
        evidence = self.prepare_restore()
        (evidence / 'installed.json').rename(evidence / 'intent.json')
        self.write(self.launch, self.normal)
        before = self.snapshot()
        with patch.object(I, 'replace_launcher', side_effect=AssertionError('normal launcher')):
            self.restore(evidence)
        after = self.snapshot()
        changed = {p for p in before.keys() | after.keys() if before.get(p) != after.get(p)}
        self.assertEqual(changed, {str(Path('restore-evidence') / 'restored-launch.json')})

    def test_preflight_rejects_extra_journal_or_script(self):
        for path in [self.store / 'extra.record', self.mod / 'Scripts/extra.lua']:
            with self.subTest(path=path):
                self.write(path, b'unexpected')
                before = self.snapshot()
                with self.assertRaises(ValueError): I.preflight(self.receipt)
                self.assertEqual(before, self.snapshot())
                path.unlink()


if __name__ == '__main__':
    unittest.main()
