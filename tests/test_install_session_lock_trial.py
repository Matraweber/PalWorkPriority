"""Disposable filesystem tests. Never use the installed game or real journals."""
from pathlib import Path
import hashlib
import json
import sys
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO/'tools'))
import install_session_lock_trial as I
import settings_migration_backup as B


def write(path, raw):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(raw)


def document(path, value):
    write(path, json.dumps(value).encode())


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


class InstallerTests(unittest.TestCase):
    def setUp(self):
        current_closure = I.closure()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        home = Path(self.tmp.name)
        root, mod = home/'repo', home/'runtime/Mods/PalWorkPriority'
        paths = dict(ROOT=root, MOD=mod, BASE=root/'base', LOCK=root/'lock', NORMAL=root/'normal',
                     RESTORED=root/'restored', STORE=root/'store', BACKUP=root/'backup', RECEIPT=root/'receipt.lua')
        for p in paths.values():
            (p.parent if p.suffix else p).mkdir(parents=True, exist_ok=True)
        self.patch = patch.multiple(I, **paths); self.patch.start(); self.addCleanup(self.patch.stop)
        self.closed = patch.object(B, 'game_closed', return_value=True)
        self.guard = self.closed.start(); self.addCleanup(self.closed.stop)
        for p in (REPO/'Scripts').iterdir():
            if p.is_file():
                write(root/'Scripts'/p.name, p.read_bytes())
                write(mod/'Scripts'/p.name, p.read_bytes())
        for rel in current_closure:
            write(root/rel, (REPO/rel).read_bytes())
        # This historical installer is deliberately schema-3-only. Its offline
        # protocol fixture is explicit, independent of the current release's
        # schema. These tests compile/stage code; they do not execute a protocol
        # or establish runtime compatibility. Never relabel release code as 3.
        write(root/'Scripts/protocol.lua', b'return { SCHEMA = 3, WORKS = 14 }\n')
        # Remaining candidate Lua/closure, historical installed Scripts and
        # chained settings-lock overrides retain real receipt verification.
        for name in I.ALLOW:
            write(mod/'Scripts'/(name+'.lua'), b'return {} -- old installed code\n')
        self.stage = mod/'async-trial/combined-original'; self.stage.mkdir(parents=True)
        sources = {}
        for rel in current_closure:
            write(self.stage/rel, (root/rel).read_bytes()); sources[rel] = I.sha(self.stage/rel)
        protected = {'Scripts/'+p.name: I.sha(p) for p in (mod/'Scripts').iterdir()}
        write(mod/'config.lua', b'return {}\n'); protected['config.lua'] = I.sha(mod/'config.lua')
        changes = []
        for target, rel in ((mod/'Scripts/settings_gate.lua', 'Scripts/settings_gate.lua'),
                            (mod/'Scripts/ui.lua', 'Scripts/ui.lua'),
                            (self.stage/'experiments/settings_startup_gate_group.lua',
                             'experiments/settings_startup_gate_group.lua')):
            old = digest(b'prior historical source '+rel.encode())
            changes.append(dict(target=str(target), before=old, after=I.sha(target)))
            if target.is_relative_to(self.stage): sources[rel] = old
            else: protected[rel] = old
        write(self.stage/'pwp_draining_bridge.dll', b'normal DLL fixture')
        write(mod.parent.parent/'UE4SS.dll', b'runtime fixture')
        write(I.RECEIPT, b'return {}\n'); write(mod/'async-trial/receipt.lua', I.RECEIPT.read_bytes())
        self.launch = ("return dofile('"+(self.stage/I.ENTRY).as_posix()+"').install{enabled=true,"
                       "storage='"+'1'*32+"',guild='"+'2'*32+"',dll='"+
                       (self.stage/'pwp_draining_bridge.dll').as_posix()+"'}\n").encode()
        write(mod/'async-trial/launch.lua', self.launch)
        native = {k: True for k in I.FLAGS}
        native.update(compiled_root=str(I.STORE), probe_sha256=I.sha(self.stage/'pwp_draining_bridge.dll'),
                      staged_runtime_sha256=I.sha(mod.parent.parent/'UE4SS.dll'))
        document(I.BASE/'installed.json', dict(native=native, stage=str(self.stage), protected=protected,
                 updates={}, sources=sources, launcher_sha256=digest(self.launch)))
        document(I.LOCK/'installed.json', dict(changes=changes))
        rows, journals = [], {}
        for stream, maximum in (('limits', 7), ('priorities', 8)):
            for slot, generation in (('A', maximum-1), ('B', maximum)):
                name = f'pwp-record-v1-{"1"*32}-{"2"*32}-{stream}-{slot}.record'
                raw = f'opaque fixture journal {stream} {generation}'.encode()
                write(I.STORE/name, raw); write(I.RESTORED/name, raw)
                journals[name] = digest(raw)
                rows.append(dict(file=name, stream=stream, generation=generation, sha256=digest(raw), decoded={}))
        document(I.RESTORED/'decoded.json', rows)
        document(I.NORMAL/'restored-launch.json', dict(restored=True, journal=journals))
        document(I.NORMAL/'typed-restoration.json', dict(exact_original_typed_state=True,
                                                       generations=dict(limits=7, priorities=8)))
        document(I.NORMAL/'acceptance.json', {k: True for k in ('normal_restart_verified',
                 'normal_launcher_restored', 'all_settings_equal_original', 'legacy_paths_unchanged',
                 'durable_recovery_verified')})
        write(mod/'caps.txt', b'local caps unchanged'); write(mod/'priorities.txt', b'local X unchanged')
        I.BACKUP.rmdir(); B.backup(mod, I.BACKUP, lambda: True)
        self.evidence = root/'candidate-install'
        self.logs = {name: b'offline fixture test evidence' for name in ('lua.log', 'structural.log', 'installer.log')}

    def test_preflight_is_read_only_exact_allowlist(self):
        before = I.tree(Path(self.tmp.name))
        result = I.preflight()
        self.assertEqual(result['generations'], dict(limits=7, priorities=8))
        self.assertEqual(len(result['closure']), 36)
        self.assertEqual(set(result['updates']), {'Scripts/'+n+'.lua' for n in I.ALLOW})
        self.assertEqual(I.tree(Path(self.tmp.name)), before)

    def test_installs_launcher_last_preserves_originals_and_all_data(self):
        before = I.preflight(); old_stage = I.tree(self.stage)
        events = []; replace = I.os.replace
        def observed(source, target):
            self.assertTrue((self.evidence/'intent.json').is_file())
            self.assertEqual((self.evidence/'previous-launch.lua').read_bytes(), self.launch)
            events.append(Path(target)); replace(source, target)
        with patch.object(I.os, 'replace', side_effect=observed):
            I.install(before, self.evidence, self.logs)
        self.assertEqual(events[-1], I.MOD/'async-trial/launch.lua')
        self.assertEqual(len(events), len(I.ALLOW)+1)
        record = I.load(self.evidence/'installed.json')
        self.assertFalse(record['live_acceptance'])
        self.assertEqual(I.tree(Path(record['stage'])), before['closure'])
        self.assertEqual(I.tree(self.stage), old_stage)
        self.assertEqual(I.tree(I.STORE), before['journal'])
        B.verify(I.BACKUP, B.capture(I.MOD))
        self.assertIn((self.stage/'pwp_draining_bridge.dll').as_posix(), record['launcher'])
        for rel in before['updates']:
            self.assertEqual(I.sha(self.evidence/'code-before'/Path(rel).name), before['code'][str(I.MOD/rel)])

    def test_installed_tamper_even_allowlisted_refused(self):
        write(I.MOD/'Scripts/net.lua', b'unknown local modification')
        with self.assertRaisesRegex(ValueError, 'installed code differs'): I.preflight()

    def test_unknown_candidate_difference_refused(self):
        write(I.ROOT/'Scripts/store.lua', b'return {} -- unreviewed')
        with self.assertRaisesRegex(ValueError, 'unreviewed Lua difference'): I.preflight()

    def test_unknown_installed_script_refused(self):
        write(I.MOD/'Scripts/unknown.lua', b'return {}')
        with self.assertRaisesRegex(ValueError, 'inventory'): I.preflight()

    def test_native_runtime_launcher_and_stage_tamper(self):
        for target in (self.stage/'pwp_draining_bridge.dll', I.MOD.parent.parent/'UE4SS.dll',
                       I.MOD/'async-trial/launch.lua', self.stage/'experiments/settings_live_combined.lua'):
            with self.subTest(target=target):
                old = target.read_bytes(); target.write_bytes(old+b'tamper')
                with self.assertRaises(ValueError): I.preflight()
                target.write_bytes(old)

    def test_receipt_chain_and_acceptance_refused(self):
        p = I.LOCK/'installed.json'; old = p.read_bytes(); value = I.load(p)
        value['changes'][0]['before'] = '0'*64; document(p, value)
        with self.assertRaisesRegex(ValueError, 'receipt chain'): I.preflight()
        p.write_bytes(old)
        p = I.NORMAL/'acceptance.json'; value = I.load(p); value['normal_restart_verified'] = False
        document(p, value)
        with self.assertRaisesRegex(ValueError, 'normal acceptance'): I.preflight()

    def test_journal_tamper_extra_or_missing_refused(self):
        p = next(I.STORE.iterdir()); raw = p.read_bytes()
        p.write_bytes(raw+b'x')
        with self.assertRaisesRegex(ValueError, 'current journal'): I.preflight()
        p.unlink()
        with self.assertRaisesRegex(ValueError, 'current journal'): I.preflight()
        p.write_bytes(raw); write(I.STORE/'orphan.tmp', b'x')
        with self.assertRaisesRegex(ValueError, 'current journal'): I.preflight()

    def test_all_eight_legacy_paths_protected(self):
        for index, name in enumerate(B.NAMES):
            with self.subTest(name=name):
                backup = I.ROOT/('legacy-case-'+str(index))
                B.backup(I.MOD, backup, lambda: True)
                p = I.MOD/name; old = p.read_bytes() if p.exists() else None
                p.write_bytes(b'changed')
                with patch.object(I, 'BACKUP', backup):
                    with self.assertRaisesRegex(ValueError, 'backup differs'): I.preflight()
                if old is None: p.unlink()
                else: p.write_bytes(old)

    def test_current_game_blocks_preflight_and_install(self):
        before = I.preflight(); self.guard.return_value = False
        with self.assertRaisesRegex(ValueError, 'game/server'): I.preflight()
        with self.assertRaisesRegex(ValueError, 'game/server'): I.install(before, self.evidence, self.logs)
        self.assertFalse(self.evidence.exists())

    def test_staging_game_start_or_tamper_never_arms(self):
        before = I.preflight(); real_write = B.write_new
        def interrupt(path, raw):
            real_write(path, raw)
            if Path(path).name == 'intent.json': self.guard.return_value = False
        with patch.object(B, 'write_new', side_effect=interrupt):
            with self.assertRaisesRegex(ValueError, 'game/server'): I.install(before, self.evidence, self.logs)
        self.assertEqual((I.MOD/'async-trial/launch.lua').read_bytes(), self.launch)
        self.assertTrue((self.evidence/'intent.json').exists())
        self.assertFalse((self.evidence/'installed.json').exists())

    def test_changed_candidate_after_preflight_refused(self):
        before = I.preflight(); write(I.ROOT/'Scripts/net.lua', b'return {}')
        with self.assertRaises(ValueError): I.install(before, self.evidence, self.logs)
        self.assertFalse(self.evidence.exists())

    def test_other_protocol_schemas_are_refused_without_writes(self):
        for schema in (2, 4):
            with self.subTest(schema=schema):
                write(I.ROOT/'Scripts/protocol.lua', f'return {{ SCHEMA = {schema}, WORKS = 14 }}\n'.encode())
                before = I.tree(Path(self.tmp.name))
                with self.assertRaisesRegex(ValueError, 'candidate is not schema 3'):
                    I.preflight()
                self.assertEqual(I.tree(Path(self.tmp.name)), before)
                self.assertFalse(self.evidence.exists())

    def test_schema_change_after_preflight_never_arms(self):
        before = I.preflight()
        write(I.ROOT/'Scripts/protocol.lua', b'return { SCHEMA = 4, WORKS = 14 }\n')
        unchanged = I.tree(Path(self.tmp.name))
        with self.assertRaisesRegex(ValueError, 'source inventory changed'):
            I.install(before, self.evidence, self.logs)
        self.assertEqual(I.tree(Path(self.tmp.name)), unchanged)
        self.assertEqual((I.MOD/'async-trial/launch.lua').read_bytes(), self.launch)
        self.assertFalse(self.evidence.exists())

    def test_staged_tamper_after_intent_never_arms(self):
        before = I.preflight(); real_write = B.write_new
        def corrupt(path, raw):
            real_write(path, raw)
            if Path(path).name == 'intent.json':
                stage = Path(I.load(path)['stage'])
                write(stage/I.ENTRY, b'return {} -- corrupted stage')
        with patch.object(B, 'write_new', side_effect=corrupt):
            with self.assertRaisesRegex(ValueError, 'candidate stage differs'):
                I.install(before, self.evidence, self.logs)
        self.assertEqual((I.MOD/'async-trial/launch.lua').read_bytes(), self.launch)
        self.assertFalse((self.evidence/'installed.json').exists())

    def test_post_activation_mismatch_cannot_issue_success_receipt(self):
        before = I.preflight(); replace = I.os.replace
        def corrupt(source, target):
            replace(source, target)
            if Path(target).name == 'launch.lua':
                write(I.MOD/'Scripts/net.lua', b'return {} -- unexpected postwrite')
        with patch.object(I.os, 'replace', side_effect=corrupt):
            with self.assertRaisesRegex(ValueError, 'code mismatch'):
                I.install(before, self.evidence, self.logs)
        self.assertTrue((self.evidence/'intent.json').exists())
        self.assertFalse((self.evidence/'installed.json').exists())
        self.assertEqual(I.tree(I.STORE), before['journal'])

    def test_interrupted_activation_retains_intent_and_backups(self):
        before = I.preflight(); replace = I.os.replace
        def interrupt(source, target):
            if Path(target).name == 'launch.lua': raise OSError('lost activation')
            replace(source, target)
        with patch.object(I.os, 'replace', side_effect=interrupt):
            with self.assertRaisesRegex(OSError, 'lost activation'): I.install(before, self.evidence, self.logs)
        self.assertTrue((self.evidence/'intent.json').exists())
        self.assertFalse((self.evidence/'installed.json').exists())
        self.assertEqual((I.MOD/'async-trial/launch.lua').read_bytes(), self.launch)
        self.assertEqual(I.tree(I.STORE), before['journal'])


if __name__ == '__main__':
    unittest.main()
