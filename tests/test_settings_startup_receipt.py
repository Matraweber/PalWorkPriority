import sys
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'tools'))
sys.path.insert(0, str(ROOT/'.test-deps'))
import settings_migration_backup as Backup
import settings_startup_receipt as Receipt
from lupa.lua54 import LuaRuntime


class ReceiptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.source, self.backup, self.output = root/'source', root/'backup', root/'receipt.lua'
        self.source.mkdir()
        self.binary = b"\x00\xff'); error('injection') --\r\n"
        (self.source/'caps.txt').write_bytes(self.binary)
        (self.source/'priorities.txt').write_bytes(b'')
        Backup.backup(self.source, self.backup, lambda: True)

    def prepare(self):
        return Receipt.prepare(self.backup, self.output, lambda: True)

    def test_lossless_inert_data_and_actual_reader(self):
        self.assertFalse(self.prepare()['activation_allowed'])
        lua = LuaRuntime(encoding=None)
        data = lua.execute(self.output.read_bytes())
        self.assertEqual(data[b'files'][b'caps.txt'], self.binary)
        self.assertEqual(data[b'files'][b'priorities.txt'], b'')
        self.assertIs(data[b'files'][b'caps.txt.bak'], False)
        self.assertEqual(data[b'manifest'], (self.backup/'manifest.json').read_bytes())
        self.assertNotIn(b'enabled', dict(data.items()))
        # Real runtime reader over real temporary files on this Windows host.
        if sys.platform == 'win32':
            lua.globals()[b'options'] = data
            lua.globals()[b'reader_path'] = str(ROOT/'experiments/settings_startup_files.lua').encode()
            self.assertTrue(lua.execute(b"options.enabled=true; local r=assert(dofile(reader_path).new(options)); return r.verify_receipt(options.files) and r.read_source('caps.txt')==options.files['caps.txt']"))

    def test_changed_source_refused(self):
        (self.source/'caps.txt').write_bytes(b'changed')
        with self.assertRaises(ValueError): self.prepare()
        self.assertFalse(self.output.exists())

    def test_corrupt_backup_refused(self):
        (self.backup/'caps.txt').write_bytes(b'changed')
        with self.assertRaises(ValueError): self.prepare()

    def test_existing_and_protected_destinations(self):
        self.prepare()
        original = self.output.read_bytes()
        with self.assertRaises(ValueError): self.prepare()
        self.assertEqual(self.output.read_bytes(), original)
        for target in (self.source/'receipt.lua', self.backup/'receipt.lua'):
            with self.assertRaises(ValueError): Receipt.prepare(self.backup, target, lambda: True)
            self.assertFalse(target.exists())

    def test_running_or_ambiguous_process(self):
        for value in (False, None, 1):
            with self.assertRaises(ValueError): Receipt.prepare(self.backup, self.output, lambda: value)
        self.assertFalse(self.output.exists())

    def test_changed_source_during_publication_preserves_unapproved_file(self):
        original = Backup.write_new
        def publish(path, raw):
            original(path, raw)
            (self.source/'caps.txt').write_bytes(b'changed')
        with patch.object(Backup, 'write_new', publish):
            with self.assertRaises(ValueError): self.prepare()
        self.assertTrue(self.output.exists())

    def test_directory_identity_alias_refused(self):
        alias = self.source.parent/'alias'
        alias.mkdir()
        self.output = alias/'receipt.lua'
        stat = Path.stat
        original = stat(self.source)
        def mapped(path, *args, **kwargs):
            if path == alias: return original
            return stat(path, *args, **kwargs)
        with patch.object(Path, 'stat', mapped):
            with self.assertRaisesRegex(ValueError, 'aliases'): self.prepare()
        self.assertFalse(self.output.exists())

    def test_non_ascii_runtime_roots_refused(self):
        source = self.source.parent/'source_\u00e9'
        source.mkdir()
        (source/'caps.txt').write_bytes(b'test')
        backup = self.source.parent/'backup_\u00e9'
        Backup.backup(source, backup, lambda: True)
        with self.assertRaisesRegex(ValueError, 'ASCII'):
            Receipt.prepare(backup, self.output, lambda: True)
        self.assertFalse(self.output.exists())

    @unittest.skipUnless(sys.platform == 'win32', 'Windows 8.3 paths')
    def test_real_short_path_alias_refused(self):
        import ctypes
        get_short = ctypes.windll.kernel32.GetShortPathNameW
        get_short.argtypes = [ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_uint32]
        get_short.restype = ctypes.c_uint32
        output = ctypes.create_unicode_buffer(32768)
        self.assertGreater(get_short(str(self.source), output, len(output)), 0)
        alias = Path(output.value)
        if str(alias).casefold() == str(self.source).casefold():
            self.skipTest('8.3 alias not available on this filesystem')
        with self.assertRaises(ValueError):
            Receipt.prepare(self.backup, alias/'receipt.lua', lambda: True)
        self.assertFalse((self.source/'receipt.lua').exists())


if __name__ == '__main__': unittest.main()
