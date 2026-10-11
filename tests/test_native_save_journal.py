"""Actual disposable Windows A/B updates and process interruptions, never game IO.

Python builds SHA256 envelopes independently; native codec CLI checks recovery.
Hooks simulate error boundaries, not physical disk/flush/power-loss failures.
"""
import ctypes
from ctypes import wintypes
import hashlib
import os
from pathlib import Path
import struct
import stat
import subprocess
import tempfile
import unittest
import uuid

EXE = os.environ.get('PWP_NATIVE_JOURNAL_EXE')
STORAGE, GUILD = 'a' * 32, 'b' * 32
SCOPE = f'PWP-SCOPE-1:{STORAGE}:{GUILD}:priorities'
AUTO = object()


def wire(generation, payload=b'new', scope=SCOPE):
    body = b'PWPJNL1\n' + struct.pack('<HII', len(scope), generation, len(payload)) + scope.encode() + payload
    return body + hashlib.sha256(body).digest()


@unittest.skipUnless(os.name == 'nt' and EXE, 'requires built native journal CLI')
class Journal(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='pwp-journal-')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.root = self.base / 'root'
        self.root.mkdir()
        self.serial = 0
        self.k = ctypes.WinDLL('kernel32', use_last_error=True)
        self.k.CreateEventW.argtypes = [wintypes.LPVOID, wintypes.BOOL, wintypes.BOOL, wintypes.LPCWSTR]
        self.k.CreateEventW.restype = wintypes.HANDLE
        self.k.SetEvent.argtypes = [wintypes.HANDLE]
        self.k.CloseHandle.argtypes = [wintypes.HANDLE]
        self.k.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID,
                                      wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
        self.k.CreateFileW.restype = wintypes.HANDLE

    def slot(self, name, stream='priorities'):
        return self.root / f'pwp-record-v1-{STORAGE}-{GUILD}-{stream}-{name}.record'

    def images(self):
        return tuple(p.read_bytes() if p.is_file() else None for p in (self.slot('A'), self.slot('B')))

    def args(self, expected=AUTO, root=None, stream='priorities', hook=None, production=False):
        if expected is AUTO:
            expected = self.images()
        args = [str(Path(EXE).with_name('journal-cli.exe')) if production else EXE,
                str(root or self.root), STORAGE, GUILD, stream]
        for image in expected:
            if image is None:
                args.append('MISSING')
            else:
                self.serial += 1
                p = self.base / f'preimage-{self.serial}'
                p.write_bytes(image)
                args.append(str(p))
        if hook:
            args.append(hook)
        return args

    def call(self, data, **kwargs):
        p = subprocess.run(self.args(**kwargs), input=data, capture_output=True, timeout=20)
        self.assertIn(p.returncode, range(5), (p.returncode, p.stdout, p.stderr))
        fields = p.stdout.decode().strip().split()
        self.assertEqual(len(fields), 5, p.stdout)
        self.assertEqual(p.returncode, ['initialized', 'updated', 'conflict', 'io_error', 'uncertain'].index(fields[0]))
        if p.returncode in (0, 1):
            self.assertEqual(fields[1], '0')
        else:
            self.assertNotEqual(fields[1], '0')
        self.assertGreaterEqual(int(fields[4]), 0)
        return fields

    def seed(self):
        a, b = wire(1, b'older'), wire(2, b'current')
        self.slot('A').write_bytes(a)
        self.slot('B').write_bytes(b)
        return a, b

    def recovery(self, generation, payload):
        # Verify the native decoder/candidate after handles/processes have exited.
        p = subprocess.run([str(Path(EXE).with_name('journal-recover.exe')), 'recover', SCOPE,
                            *[str(self.slot(s)) if self.slot(s).exists() else 'MISSING' for s in ('A', 'B')]],
                           capture_output=True, timeout=10)
        self.assertEqual(p.returncode, 0, p.stdout)
        _, got_generation, got_payload = p.stdout.split(b'\n', 2)
        self.assertEqual((int(got_generation), got_payload), (generation, payload))

    def artifacts(self, kind='*'):
        return list(self.root.glob(f'pwp-journal-{kind}-*'))

    def pause(self, data, point, expected=AUTO):
        name = 'Local\\PWPJournalTest-' + uuid.uuid4().hex
        gate = self.k.CreateEventW(None, True, False, name)
        self.assertTrue(gate)
        self.addCleanup(self.k.CloseHandle, gate)
        child = subprocess.Popen(self.args(expected=expected, hook='pause:' + point),
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 env={**os.environ, 'PWP_JOURNAL_TEST_GATE': name})
        def cleanup():
            if child.poll() is None:
                child.kill()  # only this disposable test helper
            child.wait(timeout=20)
            child.stdout.close()
            child.stderr.close()
        self.addCleanup(cleanup)
        child.stdin.write(data)
        child.stdin.close()
        child.stdin = None
        self.assertEqual(child.stdout.readline(), b'READY\n')
        return child, gate

    def resume(self, child, gate):
        self.assertTrue(self.k.SetEvent(gate))
        out, err = child.communicate(timeout=20)
        self.assertIn(child.returncode, range(5), err)
        return child.returncode, out.decode().split()[0]

    def test_initialize_then_alternate_and_cleanup_exact_backup(self):
        first, second, third = wire(1, b'one'), wire(2, b'two'), wire(3, b'three')
        self.assertEqual(self.call(first, production=True)[0], 'initialized')
        self.assertEqual(self.slot('A').read_bytes(), first)
        self.assertFalse(self.slot('B').exists())
        self.assertEqual(self.call(second)[0], 'updated')
        self.assertEqual(self.images(), (first, second))
        self.assertEqual(self.call(third)[0], 'updated')
        self.assertEqual(self.images(), (third, second))
        self.assertEqual(self.artifacts('backup'), [])
        self.assertEqual(self.artifacts('stage'), [])
        self.recovery(3, b'three')

    def test_maximum_encoded_payload(self):
        payload = bytes(range(256)) * 1024
        data = wire(1, payload)
        self.assertEqual(len(data), 262282)
        self.assertEqual(self.call(data)[0], 'initialized')
        self.assertEqual(self.slot('A').read_bytes(), data)
        self.recovery(1, payload)

    def test_stale_preimage_never_overwrites(self):
        old = self.seed()
        external = wire(4, b'external')
        self.slot('A').write_bytes(external)
        self.assertEqual(self.call(wire(3), expected=old)[0], 'conflict')
        self.assertEqual(self.images(), (external, old[1]))
        self.assertEqual(self.artifacts(), [])

    def test_missing_preimage_conflicts_with_existing_empty_file(self):
        self.slot('A').write_bytes(b'')
        self.assertEqual(self.call(wire(1), expected=(None, None))[0], 'conflict')
        self.assertEqual(self.slot('A').read_bytes(), b'')

    def test_expected_present_but_disappeared_conflicts(self):
        self.assertEqual(self.call(wire(2), expected=(wire(1), None))[0], 'conflict')
        self.assertEqual(list(self.root.iterdir()), [])

    def test_invalid_scope_generation_and_envelope(self):
        self.seed()
        before = self.images()
        for data in [wire(2), wire(4), wire(3, scope=SCOPE.replace('a'*32, 'c'*32)),
                     wire(3)[:-1], b'', wire(2147483647)]:
            with self.subTest(data=data[:18]):
                self.assertEqual(self.call(data)[0], 'conflict')
                self.assertEqual(self.images(), before)
                self.assertEqual(self.artifacts(), [])

    def test_initial_generation_must_be_one(self):
        self.assertEqual(self.call(wire(2))[0], 'conflict')
        self.assertEqual(list(self.root.iterdir()), [])

    def test_generation_exhaustion_refuses(self):
        self.slot('A').write_bytes(wire(2147483646))
        self.assertEqual(self.call(wire(1))[0], 'conflict')
        self.assertEqual(self.artifacts(), [])

    def test_blocked_slot_classifications_in_both_orders(self):
        for bad in [wire(3, scope=SCOPE.replace('a'*32, 'c'*32)), b'UNKNOWN!', b'x'*262451]:
            for slot in ('A', 'B'):
                with self.subTest(size=len(bad), slot=slot):
                    other = 'B' if slot == 'A' else 'A'
                    self.slot(slot).write_bytes(bad)
                    self.slot(other).write_bytes(wire(1))
                    # Oversized bytes cannot be supplied as a bounded preimage;
                    # still verify actual on-disk classification blocks writes.
                    expected = tuple(None if len(x) > 262450 else x for x in self.images())
                    self.assertEqual(self.call(wire(2), expected=expected)[0], 'conflict')
                    self.assertEqual(self.slot(slot).read_bytes(), bad)
                    self.assertEqual(self.artifacts(), [])

    def test_same_generation_conflict_and_identical_tie(self):
        self.slot('A').write_bytes(wire(1, b'one'))
        self.slot('B').write_bytes(wire(1, b'other'))
        self.assertEqual(self.call(wire(2))[0], 'conflict')
        self.assertEqual(self.artifacts(), [])
        self.slot('B').write_bytes(wire(1, b'one'))
        self.assertEqual(self.call(wire(2, b'next'))[0], 'updated')
        self.assertEqual(self.slot('A').read_bytes(), wire(1, b'one'))
        self.recovery(2, b'next')

    def test_corrupt_inactive_cleanup_only_after_success(self):
        self.slot('A').write_bytes(wire(1))
        self.slot('B').write_bytes(b'broken')
        self.assertEqual(self.call(wire(2))[0], 'updated')
        self.assertEqual(self.artifacts('backup'), [])
        self.recovery(2, b'new')

    def test_no_good_record_blocks_without_initializing(self):
        for a, b in [(b'', None), (b'broken', b''), (None, b'broken')]:
            with self.subTest(a=a, b=b):
                # Distinct disposable roots avoid resetting any journal evidence.
                self.serial += 1
                self.root = self.base / f'bad-{self.serial}'
                self.root.mkdir()
                for slot, data in zip(('A', 'B'), (a, b)):
                    if data is not None:
                        self.slot(slot).write_bytes(data)
                self.assertEqual(self.call(wire(1))[0], 'conflict')
                self.assertEqual(self.artifacts(), [])

    def test_missing_root_no_creation(self):
        absent = self.base / 'absent'
        self.assertEqual(self.call(wire(1), expected=(None, None), root=absent)[0], 'io_error')
        self.assertFalse(absent.exists())

    def test_directory_leaf_unreadable(self):
        self.slot('A').mkdir()
        self.assertEqual(self.call(wire(1), expected=(None, None))[0], 'io_error')
        self.assertTrue(self.slot('A').is_dir())
        self.assertEqual(self.artifacts(), [])

    def test_exclusive_sharing_denial_is_not_missing(self):
        self.seed()
        expected = self.images()
        handle = self.k.CreateFileW(str(self.slot('B')), 0x80000000, 0, None, 3, 0x80, None)
        self.assertNotEqual(handle, ctypes.c_void_p(-1).value)
        try:
            self.assertEqual(self.call(wire(3), expected=expected)[:2], ['io_error', '32'])
        finally:
            self.k.CloseHandle(handle)
        self.assertEqual(self.images(), expected)

    def test_both_slots_and_root_remain_locked(self):
        expected = self.seed()
        child, gate = self.pause(wire(3), 'before_backup')
        for slot in ('A', 'B'):
            with self.assertRaises(OSError):
                self.slot(slot).write_bytes(b'hostile')
            with self.assertRaises(OSError):
                self.slot(slot).rename(self.base / f'moved-{slot}')
        with self.assertRaises(OSError):
            self.root.rename(self.base / 'moved-root')
        self.assertEqual(self.resume(child, gate), (1, 'updated'))
        self.assertEqual(self.slot('B').read_bytes(), expected[1])

    def test_target_appearance_before_publish_is_never_replaced(self):
        child, gate = self.pause(wire(1), 'before_publish', expected=(None, None))
        external = wire(8, b'external')
        self.slot('A').write_bytes(external)
        self.assertEqual(self.resume(child, gate), (2, 'conflict'))
        self.assertEqual(self.slot('A').read_bytes(), external)
        self.assertEqual(len(self.artifacts('stage')), 1)

    def test_other_initial_slot_appearance_is_uncertain(self):
        child, gate = self.pause(wire(1), 'after_publish', expected=(None, None))
        self.slot('B').write_bytes(wire(9, b'external'))
        self.assertEqual(self.resume(child, gate), (4, 'uncertain'))
        self.assertEqual(self.images(), (wire(1), wire(9, b'external')))

    def test_other_initial_slot_sharing_denial_is_uncertain(self):
        child, gate = self.pause(wire(1), 'after_publish', expected=(None, None))
        self.slot('B').write_bytes(wire(9))
        handle = self.k.CreateFileW(str(self.slot('B')), 0x80000000, 0, None, 3, 0x80, None)
        self.assertNotEqual(handle, ctypes.c_void_p(-1).value)
        try:
            self.assertEqual(self.resume(child, gate), (4, 'uncertain'))
        finally:
            self.k.CloseHandle(handle)

    def test_external_fill_after_backup_does_not_replace(self):
        a, b = self.seed()
        child, gate = self.pause(wire(3), 'after_backup')
        self.slot('A').write_bytes(wire(10, b'external'))
        self.assertEqual(self.resume(child, gate), (2, 'conflict'))
        self.assertEqual(self.images(), (wire(10, b'external'), b))
        self.assertEqual([p.read_bytes() for p in self.artifacts('backup')], [a])

    def test_fault_boundaries_preserve_current(self):
        for point in ['after_read', 'before_write', 'after_write', 'after_flush', 'before_backup',
                      'after_backup', 'before_publish', 'after_publish', 'before_cleanup',
                      'before_disposition', 'after_disposition', 'before_backup_close',
                      'after_backup_close', 'after_close']:
            with self.subTest(point=point):
                self.root = self.base / point
                self.root.mkdir()
                a, b = self.seed()
                result = self.call(wire(3), hook='fail:' + point)
                warning = point in ('before_cleanup', 'before_disposition')
                ambiguous = point in ('after_publish', 'after_disposition', 'before_backup_close',
                                      'after_backup_close', 'after_close')
                published = warning or ambiguous
                self.assertEqual(result[0], 'updated' if warning else 'uncertain' if ambiguous else 'io_error')
                self.assertEqual(result[4], '29' if point in ('before_cleanup', 'before_disposition',
                                 'after_disposition', 'before_backup_close', 'after_backup_close') else '0')
                self.assertEqual(self.slot('B').read_bytes(), b)
                self.recovery(3 if published else 2, b'new' if published else b'current')
                if point in ('after_backup', 'before_publish'):
                    self.assertFalse(self.slot('A').exists())
                    self.assertEqual([p.read_bytes() for p in self.artifacts('backup')], [a])
                if point in ('after_publish', 'before_cleanup', 'before_disposition'):
                    self.assertEqual([p.read_bytes() for p in self.artifacts('backup')], [a])
                if point in ('after_disposition', 'before_backup_close', 'after_backup_close', 'after_close'):
                    self.assertEqual(self.artifacts('backup'), [])

    def test_process_interruptions_recover_newest(self):
        for point in ['before_write', 'after_flush', 'before_backup', 'after_backup', 'before_publish',
                      'after_publish', 'before_cleanup', 'before_disposition', 'after_disposition',
                      'before_backup_close', 'after_backup_close', 'after_close']:
            with self.subTest(point=point):
                self.root = self.base / ('crash-' + point)
                self.root.mkdir()
                a, b = self.seed()
                p = subprocess.run(self.args(hook='crash:' + point), input=wire(3), capture_output=True, timeout=20)
                self.assertEqual(p.returncode, 91)
                self.assertEqual(self.slot('B').read_bytes(), b)
                published = point in ('after_publish', 'before_cleanup', 'before_disposition',
                                      'after_disposition', 'before_backup_close', 'after_backup_close', 'after_close')
                self.recovery(3 if published else 2, b'new' if published else b'current')
                if point in ('after_backup', 'before_publish', 'after_publish', 'before_cleanup', 'before_disposition'):
                    self.assertEqual([p.read_bytes() for p in self.artifacts('backup')], [a])
                if point in ('after_disposition', 'before_backup_close', 'after_backup_close', 'after_close'):
                    self.assertEqual(self.artifacts('backup'), [])
                self.assertLessEqual(len(self.artifacts()), 2)
                # Process exit releases the gate; a fresh transaction can continue
                # using fresh preimages, never pretending this was an automatic retry.
                gen = 4 if published else 3
                self.assertEqual(self.call(wire(gen, b'recovered'))[0], 'updated')
                self.recovery(gen, b'recovered')

    def test_retained_budget_refuses_before_stage_or_backup(self):
        before = self.seed()
        for i in range(31):
            (self.root / f'pwp-journal-retained-{i}').write_bytes(b'evidence')
        self.assertEqual(self.call(wire(3))[:2], ['conflict', '4'])
        self.assertEqual(self.images(), before)
        self.assertEqual(len(self.artifacts()), 31)

    def test_retained_budget_exact_headroom(self):
        self.seed()
        for i in range(30):
            (self.root / f'pwp-journal-retained-{i}').write_bytes(b'evidence')
        self.assertEqual(self.call(wire(3))[0], 'updated')
        self.assertEqual(len(self.artifacts()), 30)
        self.assertEqual(self.call(wire(4))[0], 'updated')
        self.assertEqual(len(self.artifacts()), 30)
        self.recovery(4, b'new')

    def test_300_successful_updates_preserve_unknown_artifacts(self):
        unknown = {
            self.root / 'pwp-journal-backup-preexisting.record': b'unknown backup',
            self.root / 'pwp-journal-stage-preexisting.tmp': b'unknown stage',
            self.root / 'unrelated.txt': b'not ours',
        }
        for path, data in unknown.items():
            path.write_bytes(data)
        directory = self.root / 'pwp-journal-unknown-directory'
        directory.mkdir()
        nested = directory / 'evidence'
        nested.write_bytes(b'preserve directory content')
        for generation in range(1, 301):
            payload = f'cycle-{generation}'.encode()
            result = self.call(wire(generation, payload), production=True)
            self.assertEqual(result, ['initialized' if generation == 1 else 'updated', '0',
                                    'A' if generation % 2 else 'B', str(generation), '0'])
            self.assertEqual(set(self.artifacts()), set(unknown) - {self.root / 'unrelated.txt'} | {directory})
            for path, data in unknown.items():
                self.assertEqual(path.read_bytes(), data)
            self.assertEqual(nested.read_bytes(), b'preserve directory content')
        self.assertEqual(self.images(), (wire(299, b'cycle-299'), wire(300, b'cycle-300')))
        self.recovery(300, b'cycle-300')

    def test_cleanup_warning_retained_and_never_retried_as_publication(self):
        a, _ = self.seed()
        result = self.call(wire(3), hook='fail:before_disposition')
        self.assertEqual(result, ['updated', '0', 'A', '3', '29'])
        orphan = self.artifacts('backup')[0]
        self.assertEqual(orphan.read_bytes(), a)
        self.assertEqual(self.call(wire(4))[0], 'updated')
        self.assertEqual(self.artifacts('backup'), [orphan])
        self.assertEqual(orphan.read_bytes(), a)
        self.recovery(4, b'new')

    def test_real_readonly_disposition_failure_is_separate_warning(self):
        a, _ = self.seed()
        os.chmod(self.slot('A'), stat.S_IREAD)
        try:
            result = self.call(wire(3), production=True)
            self.assertEqual(result[:4], ['updated', '0', 'A', '3'])
            self.assertNotEqual(result[4], '0')
            self.assertEqual([p.read_bytes() for p in self.artifacts('backup')], [a])
            self.recovery(3, b'new')
        finally:
            for p in self.root.iterdir():
                os.chmod(p, stat.S_IREAD | stat.S_IWRITE)

    def test_cleanup_keeps_new_and_previous_active_locked(self):
        for point in ('before_cleanup', 'after_disposition', 'before_backup_close', 'after_backup_close'):
            with self.subTest(point=point):
                self.root = self.base / ('locked-' + point)
                self.root.mkdir()
                self.seed()
                child, gate = self.pause(wire(3), point)
                for slot in ('A', 'B'):
                    with self.assertRaises(OSError):
                        self.slot(slot).write_bytes(b'overwrite')
                    with self.assertRaises(OSError):
                        self.slot(slot).rename(self.base / ('moved-' + slot))
                self.assertEqual(self.resume(child, gate), (1, 'updated'))
                self.assertEqual(self.artifacts(), [])
                self.recovery(3, b'new')

    def test_accumulated_cleanup_failures_exhaust_budget_without_deletion(self):
        self.seed()
        for generation in range(3, 34):
            self.assertEqual(self.call(wire(generation), hook='fail:before_disposition')[0], 'updated')
        snapshot = {p.name: p.read_bytes() for p in self.root.iterdir()}
        self.assertEqual(len(self.artifacts('backup')), 31)
        self.assertEqual(self.call(wire(34))[:2], ['conflict', '4'])
        self.assertEqual({p.name: p.read_bytes() for p in self.root.iterdir()}, snapshot)
        self.recovery(33, b'new')

    def test_interruption_orphans_remain_after_later_success_and_count_toward_budget(self):
        self.seed()
        expected = self.images()
        for _ in range(30):
            p = subprocess.run(self.args(expected=expected, hook='crash:after_flush'),
                               input=wire(3), capture_output=True, timeout=20)
            self.assertEqual(p.returncode, 91)
        orphans = {p.name: p.read_bytes() for p in self.artifacts()}
        self.assertEqual(len(orphans), 30)
        self.assertEqual(self.call(wire(3))[0], 'updated')
        self.assertEqual({p.name: p.read_bytes() for p in self.artifacts()}, orphans)
        self.assertEqual(self.call(wire(4), hook='fail:before_disposition')[0], 'updated')
        self.assertEqual(len(self.artifacts()), 31)
        self.assertEqual(self.call(wire(5))[:2], ['conflict', '4'])
        for name, data in orphans.items():
            self.assertEqual((self.root / name).read_bytes(), data)
        self.recovery(4, b'new')

    def test_root_gate_excludes_other_scope_process(self):
        child, gate = self.pause(wire(1), 'after_read', expected=(None, None))
        scope = f'PWP-SCOPE-1:{STORAGE}:{GUILD}:limits'
        self.assertEqual(self.call(wire(1, scope=scope), expected=(None, None), stream='limits')[0], 'conflict')
        self.assertEqual(self.artifacts(), [])
        self.assertEqual(self.resume(child, gate), (0, 'initialized'))

    def test_reparse_root_and_leaf_refused(self):
        real = self.base / 'real'
        real.mkdir()
        for link, root in [(self.base / 'alias', self.base / 'alias'), (self.slot('A'), self.root)]:
            p = subprocess.run(['cmd', '/d', '/c', 'mklink', '/J', str(link), str(real)], capture_output=True, timeout=10)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            self.addCleanup(os.rmdir, link)
            self.assertTrue(link.lstat().st_file_attributes & 0x400)
            self.assertTrue(os.path.samefile(link, real))
            self.assertEqual(self.call(wire(1), expected=(None, None), root=root)[0], 'io_error')
            self.assertEqual(list(real.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
