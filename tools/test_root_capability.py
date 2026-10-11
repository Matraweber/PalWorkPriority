"""Bounded root-capability tests: disposable directories, no game or save IO."""
from datetime import datetime, timezone
from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
FILES = ['native/save_core/root_capability.hpp', 'native/save_core/root_capability.cpp',
         'native/save_core/root_capability_cli.cpp', 'tools/build_root_capability.ps1',
         'tools/test_root_capability.py']
OUTPUT = None


class Roots(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pwp-root-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.parent = self.base / 'parent'
        self.root = self.parent / 'journal'
        self.root.mkdir(parents=True)

    def start(self, root=None, label='profile-one', variant='normal'):
        p = subprocess.Popen([str(OUTPUT / f'root-{variant}.exe'), str(root or self.root), label],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             text=True)
        def finish():
            if p.poll() is None:
                try:
                    p.communicate('quit\n', timeout=5)
                except subprocess.TimeoutExpired:
                    p.kill(); p.communicate(timeout=5)
            else:
                p.communicate(timeout=5)
        self.addCleanup(finish)
        line = p.stdout.readline().strip()
        return p, line

    def command(self, p, command):
        p.stdin.write(command + '\n'); p.stdin.flush()
        result = p.stdout.readline().strip()
        self.assertTrue(result, command)
        return result

    def denied(self, path):
        with self.assertRaises(OSError) as caught:
            path.rename(path.with_name(path.name + '-moved'))
        self.assertIn(caught.exception.winerror, (5, 32))

    def test_root_and_ancestor_pinned_until_last_capture(self):
        p, line = self.start()
        self.assertTrue(line.startswith('READY '), line)
        self.denied(self.root); self.denied(self.parent)
        self.assertEqual(self.command(p, 'capture'), 'CAPTURED')
        self.assertTrue(self.command(p, 'drop').startswith('STATE 2 0 '))
        self.assertEqual(self.command(p, 'captured-path'), 'MATCH')
        self.denied(self.root); self.denied(self.parent)
        self.assertTrue(self.command(p, 'retire').startswith('STATE 3 0 '))
        self.assertEqual(self.command(p, 'reopen'), 'DENIED')
        self.assertEqual(self.command(p, 'captured-path'), 'MATCH')
        self.denied(self.root)
        self.assertTrue(self.command(p, 'uncapture').startswith('STATE 4 0 '))
        self.assertEqual(self.command(p, 'reopen'), 'DENIED')
        moved = self.root.with_name('moved')
        self.root.rename(moved); moved.rename(self.root)
        moved = self.parent.with_name('moved-parent')
        self.parent.rename(moved); moved.rename(self.parent)

    def test_same_root_identity_independent_instances(self):
        p, a = self.start()
        q, b = self.start()
        self.assertTrue(a.startswith('READY '), a)
        self.assertEqual(a, b)
        self.assertEqual(a.split()[3], 'profile-one')
        self.assertEqual(len(a.split()[2]), 32)
        self.assertNotEqual(a.split()[2], '0'*32)
        self.assertEqual(self.command(p, 'reopen'), 'DENIED')
        other = self.parent / 'other'
        other.mkdir()
        _, c = self.start(other)
        self.assertNotEqual(a.split()[1:3], c.split()[1:3])

    def test_invalid_nonexistent_and_file_roots(self):
        file = self.base / 'ordinary-file'; file.write_bytes(b'unchanged')
        roots = ['relative', str(self.root)+'\\', str(self.root)+'\\..', str(self.root)+'\\bad.',
                 str(self.root)+'\\bad ', str(self.root)+'\\a:b', str(self.root)+'\\'+'x'*141,
                 str(self.base/'absent'), str(file), r'\\unknown\share\root']
        for root in roots:
            with self.subTest(root=root):
                p, line = self.start(root)
                self.assertTrue(line.startswith('REJECT STATE 6 '), line)
                self.assertEqual(p.wait(timeout=5), 0)
        self.assertFalse((self.base/'absent').exists())
        self.assertEqual(file.read_bytes(), b'unchanged')

    def test_unknown_or_invalid_namespace(self):
        for label in ('', '../escape', 'Uppercase', 'a'*65, 'a/b', 'a:b', '0profile'):
            with self.subTest(label=label):
                p, line = self.start(label=label)
                self.assertTrue(line.startswith('REJECT STATE 6 '), line)
                self.assertEqual(p.wait(timeout=5), 0)

    def test_reparse_root_and_ancestor_rejected(self):
        link = self.base/'alias'
        result = subprocess.run(['cmd', '/d', '/c', 'mklink', '/J', str(link), str(self.parent)],
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.addCleanup(os.rmdir, link)
        self.assertTrue(link.lstat().st_file_attributes & 0x400)
        for root in (link, link/'journal'):
            p, line = self.start(root)
            self.assertTrue(line.startswith('REJECT STATE 6 '), line)
            self.assertEqual(p.wait(timeout=5), 0)
        moved = self.parent.with_name('moved')
        self.parent.rename(moved); moved.rename(self.parent)

    def test_final_drop_without_retire_checks_release(self):
        p, line = self.start()
        self.assertTrue(line.startswith('READY '), line)
        self.assertTrue(self.command(p, 'drop').startswith('STATE 4 0 '))
        self.assertEqual(self.command(p, 'reopen'), 'DENIED')
        moved = self.root.with_name('moved')
        self.root.rename(moved); moved.rename(self.root)

    def test_close_uncertainty_retained_bounded_no_retry(self):
        p, line = self.start(variant='fault')
        self.assertTrue(line.startswith('READY '), line)
        self.assertEqual(self.command(p, 'fail-close'), 'FAULT-ARMED')
        self.assertEqual(self.command(p, 'drop'), 'STATE 5 29 1')
        for _ in range(5):
            self.assertEqual(self.command(p, 'reopen'), 'DENIED')
            self.assertEqual(self.command(p, 'retire'), 'STATE 5 29 1')
            self.assertEqual(self.command(p, 'status'), 'STATE 5 29 1')
        self.denied(self.root); self.denied(self.parent)
        p.communicate('quit\n', timeout=5)
        self.assertEqual(p.returncode, 0)
        moved = self.root.with_name('moved')
        self.root.rename(moved); moved.rename(self.root)


def hashes():
    return {f: hashlib.sha256((ROOT/f).read_bytes()).hexdigest() for f in FILES}


def main():
    global OUTPUT
    OUTPUT = ROOT/'test-results'/('root-capability-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'))
    OUTPUT.mkdir(parents=True)
    before = hashes()
    receipt = {'passed': False, 'game_io': False, 'sources_before': before}
    try:
        run = subprocess.run(['powershell', '-NoProfile', '-File', str(ROOT/'tools/build_root_capability.ps1'),
                              '-OutputDirectory', str(OUTPUT)], capture_output=True, timeout=120)
        (OUTPUT/'build.log').write_bytes(run.stdout+run.stderr)
        if run.returncode:
            raise RuntimeError('build failed')
        with (OUTPUT/'tests.log').open('w') as output:
            result = unittest.TextTestRunner(stream=output, verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Roots))
        after = hashes()
        receipt.update(tests=result.testsRun, errors=len(result.errors), failures=len(result.failures),
                       skipped=len(result.skipped), sources_after=after, sources_stable=before==after,
                       executable_hashes={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in OUTPUT.glob('*.exe')})
        receipt['passed'] = result.wasSuccessful() and result.testsRun==7 and not result.skipped and before==after
    except Exception as error:
        receipt['error'] = str(error)
    (OUTPUT/'receipt.json').write_text(json.dumps(receipt, indent=2))
    print(json.dumps({k:v for k,v in receipt.items() if not k.startswith('sources_')}, indent=2))
    print(OUTPUT)
    return 0 if receipt['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
