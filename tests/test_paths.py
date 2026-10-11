"""Path discovery fixtures: no installed filesystem or registry is accessed."""
import io
import os
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import paths


class PathsTests(unittest.TestCase):
    def setUp(self):
        self.files = {}
        self.directories = set()
        self.steam = os.path.abspath("fixture-steam")
        self.library = os.path.abspath("fixture-library")
        self.root = os.path.join(self.library, "steamapps", "common", "Palworld")
        self.registry = types.SimpleNamespace(
            HKEY_CURRENT_USER=1, HKEY_LOCAL_MACHINE=2,
            OpenKey=MagicMock(side_effect=FileNotFoundError), QueryValueEx=MagicMock())
        for mock in (
            patch.dict(os.environ, {}, clear=True),
            patch.dict(sys.modules, {"winreg": self.registry}),
            patch.object(paths.os.path, "isfile", side_effect=lambda p: p in self.files),
            patch.object(paths.os.path, "isdir", side_effect=lambda p: p in self.directories),
            patch("builtins.open", side_effect=self.read_file),
        ):
            mock.start()
            self.addCleanup(mock.stop)

    def read_file(self, filename, mode="r", **kwargs):
        self.assertEqual(mode, "r", "discovery must never write")
        if filename not in self.files:
            raise FileNotFoundError(filename)
        value = self.files[filename]
        if isinstance(value, Exception):
            raise value
        return io.StringIO(value)

    def install(self, root=None):
        self.files[os.path.join(root or self.root, "Palworld.exe")] = ""

    def library_metadata(self, value=None):
        value = self.library if value is None else value
        escaped = value.replace("\\", "\\\\")
        self.files[os.path.join(self.steam, "steamapps", "libraryfolders.vdf")] = (
            '"libraryfolders"\n{\n "0"\n {\n "path" "' + escaped
            + '"\n "apps"\n {\n "1623730" "123456"\n }\n }\n}\n')

    def discover(self, argv=None):
        with patch.object(paths, "_steam_roots", return_value=[self.steam]):
            return paths.resolve(argv)

    def test_secondary_library_and_return_contract(self):
        self.library_metadata()
        self.install()
        os.environ["LOCALAPPDATA"] = os.path.abspath("fixture-local")
        argv = ["status", "--other"]
        result, remaining = self.discover(argv)
        self.assertEqual(remaining, argv)
        self.assertIsNot(remaining, argv)
        ue4ss = os.path.join(self.root, "Mods", "NativeMods", "UE4SS")
        mod = os.path.join(ue4ss, "Mods", "PalWorkPriority")
        self.assertEqual(result, {
            "server": False, "root": self.root, "ue4ss_log": os.path.join(ue4ss, "UE4SS.log"),
            "mod": mod, "log": os.path.join(mod, "priority.log"),
            "trace": os.path.join(mod, "trace.txt"), "remote": os.path.join(mod, "remote.txt"),
            "crashes": os.path.join(os.environ["LOCALAPPDATA"], "Pal", "Saved", "Crashes"),
            "process": "Palworld*", "exe": None,
        })

    def test_legacy_library_metadata(self):
        self.files[os.path.join(self.steam, "steamapps", "libraryfolders.vdf")] = (
            '"LibraryFolders"\n{\n"1" "' + self.library.replace("\\", "\\\\") + '"\n}')
        self.install()
        self.assertEqual(self.discover()[0]["root"], self.root)

    def test_primary_library_needs_no_metadata(self):
        root = os.path.join(self.steam, "steamapps", "common", "Palworld")
        self.install(root)
        self.assertEqual(self.discover()[0]["root"], root)

    def test_manifest_custom_directory(self):
        root = os.path.join(self.steam, "steamapps", "common", "Palworld Custom")
        self.files[os.path.join(self.steam, "steamapps", "appmanifest_1623730.acf")] = (
            '"AppState"\n{\n"installdir" "Palworld Custom"\n}')
        self.install(root)
        self.assertEqual(self.discover()[0]["root"], root)

    def test_manifest_alone_is_not_installation_evidence(self):
        self.files[os.path.join(self.steam, "steamapps", "appmanifest_1623730.acf")] = (
            '"installdir" "Palworld"')
        with self.assertRaisesRegex(ValueError, "No verified.*PWP_CLIENT_ROOT"):
            self.discover()

    def test_manifest_traversal_is_ignored(self):
        for value in ("..", "../outside", "C:\\outside", "/outside"):
            with self.subTest(value=value):
                self.files[os.path.join(self.steam, "steamapps", "appmanifest_1623730.acf")] = (
                    '"installdir" "' + value.replace("\\", "\\\\") + '"')
                with self.assertRaises(ValueError):
                    self.discover()

    def test_unicode_library(self):
        self.library = os.path.abspath("Spiele-ä-日本語")
        self.root = os.path.join(self.library, "steamapps", "common", "Palworld")
        self.library_metadata()
        self.install()
        self.assertEqual(self.discover()[0]["root"], self.root)

    def test_stale_and_unreadable_metadata(self):
        for value in (PermissionError(), "not valid metadata", "x" * (1024 * 1024 + 1)):
            with self.subTest(value=type(value).__name__):
                self.files[os.path.join(self.steam, "steamapps", "libraryfolders.vdf")] = value
                with self.assertRaisesRegex(ValueError, "No verified"):
                    self.discover()

    def test_relative_library_is_ignored(self):
        self.library_metadata("relative-library")
        self.install(os.path.join("relative-library", "steamapps", "common", "Palworld"))
        with self.assertRaises(ValueError):
            self.discover()

    def test_duplicate_libraries_are_not_ambiguous(self):
        self.library_metadata(self.steam)
        self.install(os.path.join(self.steam, "steamapps", "common", "Palworld"))
        self.assertFalse(self.discover()[0]["server"])

    def test_multiple_installs_require_override(self):
        self.library_metadata()
        self.install()
        self.install(os.path.join(self.steam, "steamapps", "common", "Palworld"))
        with self.assertRaisesRegex(ValueError, "Multiple.*PWP_CLIENT_ROOT"):
            self.discover()
        os.environ["PWP_CLIENT_ROOT"] = self.root
        self.assertEqual(self.discover()[0]["root"], self.root)

    def test_override_skips_discovery(self):
        self.install()
        os.environ["PWP_CLIENT_ROOT"] = self.root
        with patch.object(paths, "_steam_roots", side_effect=AssertionError("discovery")):
            self.assertEqual(paths.resolve()[0]["root"], self.root)

    def test_invalid_override_never_falls_back(self):
        self.install(os.path.join(self.steam, "steamapps", "common", "Palworld"))
        for value in ("", "relative", self.root):
            with self.subTest(value=value):
                os.environ["PWP_CLIENT_ROOT"] = value
                with self.assertRaisesRegex(ValueError, "PWP_CLIENT_ROOT must"):
                    self.discover()

    def test_shipping_executable_is_evidence(self):
        self.library_metadata()
        self.files[os.path.join(self.root, "Pal", "Binaries", "Win64",
                                "Palworld-Win64-Shipping.exe")] = ""
        self.assertEqual(self.discover()[0]["root"], self.root)

    def test_specific_mod_directory_is_evidence(self):
        self.library_metadata()
        self.directories.add(os.path.join(self.root, "Mods", "NativeMods", "UE4SS"))
        with self.assertRaises(ValueError):
            self.discover()
        self.directories.add(os.path.join(self.root, "Mods", "NativeMods", "UE4SS",
                                          "Mods", "PalWorkPriority"))
        self.assertEqual(self.discover()[0]["root"], self.root)

    def test_registry_discovery_uses_read_only_keys(self):
        handle = MagicMock()
        self.registry.OpenKey.side_effect = None
        self.registry.OpenKey.return_value = handle
        self.registry.QueryValueEx.return_value = (self.steam, 1)
        self.install(os.path.join(self.steam, "steamapps", "common", "Palworld"))
        self.assertEqual(paths.resolve()[0]["root"],
                         os.path.join(self.steam, "steamapps", "common", "Palworld"))
        for call in self.registry.OpenKey.call_args_list:
            self.assertEqual(len(call.args), 2)  # OpenKey defaults to KEY_READ.
            self.assertFalse(call.kwargs)
        self.assertEqual(handle.__exit__.call_count, 3)

    def test_conventional_location_is_only_a_probe(self):
        os.environ["ProgramFiles(x86)"] = os.path.abspath("fixture-programs")
        root = os.path.join(os.environ["ProgramFiles(x86)"], "Steam", "steamapps", "common", "Palworld")
        with self.assertRaises(ValueError):
            paths.resolve()
        self.install(root)
        self.assertEqual(paths.resolve()[0]["root"], root)

    def test_server_contract_bypasses_all_client_discovery(self):
        os.environ["PWP_CLIENT_ROOT"] = "invalid"
        for argv, env in ((["--server", "status", "--server"], ""), (["status"], "server")):
            with self.subTest(argv=argv):
                os.environ["PWP_TARGET"] = env
                with patch.object(paths, "_client_root", side_effect=AssertionError("client")):
                    result, remaining = paths.resolve(argv)
                self.assertEqual(remaining, ["status"])
                self.assertTrue(result["server"])
                self.assertEqual(result["root"], paths.SERVER_ROOT)
                self.assertEqual(result["exe"], os.path.join(paths.SERVER_ROOT, "PalServer.exe"))
                self.assertEqual(result["process"], "PalServer*")
                self.assertEqual(result["crashes"], os.path.join(paths.SERVER_ROOT, "Pal", "Saved", "Crashes"))


if __name__ == "__main__":
    unittest.main()
