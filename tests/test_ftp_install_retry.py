"""ftp_deploy_server.do_install: a dropped upload or read-back is tried again on
a new connection; the backup rename never is (GPortal, 2026-10-30)."""
import ftplib
import io
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))
import ftp_deploy_server as deploy  # noqa: E402

MOD = deploy.MOD_DIR


class Host:
    """The server's files, shared by every connection."""
    def __init__(self):
        self.dirs = {MOD: {"Scripts", "remote.txt"}, MOD + "/Scripts": {"old.lua"}}
        self.data = {}
        self.drops = set()  # (op, name) to fail once
        self.renames = 0


class FakeFTP:
    def __init__(self, host):
        self.host = host

    def _drop(self, op, name):
        if (op, name) in self.host.drops:
            self.host.drops.discard((op, name))
            raise TimeoutError(10060, "dropped")

    def nlst(self, path):
        return sorted(self.host.dirs.get(path, set()))

    def rename(self, src, dst):
        self.host.renames += 1
        parent, old = src.rsplit("/", 1)
        new = dst.rsplit("/", 1)[1]
        self.host.dirs[parent].discard(old)
        self.host.dirs[parent].add(new)
        self.host.dirs[dst] = self.host.dirs.pop(src, set())

    def mkd(self, path):
        parent, name = path.rsplit("/", 1)
        self.host.dirs[parent].add(name)
        self.host.dirs[path] = set()

    def storbinary(self, cmd, fp):
        path = cmd.split(" ", 1)[1]
        name = path.rsplit("/", 1)[1]
        self._drop("STOR", name)
        self.host.data[path] = fp.read()
        self.host.dirs[path.rsplit("/", 1)[0]].add(name)

    def retrbinary(self, cmd, write):
        path = cmd.split(" ", 1)[1]
        self._drop("RETR", path.rsplit("/", 1)[1])
        write(self.host.data[path])


FILES = {"a.lua": b"-- a\n", "b.lua": b"-- b\n", "c.lua": b"-- c\n"}


class InstallRetry(unittest.TestCase):
    def test_a_dropped_upload_and_read_back_are_tried_again(self):
        host = Host()
        host.drops = {("STOR", "b.lua"), ("RETR", "c.lua")}
        connections = []

        def reconnect():
            connections.append(1)
            return FakeFTP(host)
        said = []
        ok = deploy.do_install(FakeFTP(host), FILES, "t1", say=said.append, reconnect=reconnect)
        self.assertTrue(ok, said)
        self.assertEqual(len(connections), 2)
        self.assertEqual(host.renames, 1, "the backup rename ran more than once")
        self.assertIn("Scripts-before-t1", host.dirs[MOD])
        for name, data in FILES.items():
            self.assertEqual(host.data[f"{MOD}/Scripts/{name}"], data)

    def test_without_reconnect_a_drop_stops_the_install(self):
        host = Host()
        host.drops = {("STOR", "b.lua")}
        with self.assertRaises(TimeoutError):
            deploy.do_install(FakeFTP(host), FILES, "t2", say=lambda *_: None)

    def test_a_host_that_keeps_dropping_gives_up(self):
        host = Host()

        class Always(FakeFTP):
            def storbinary(self, cmd, fp):
                raise TimeoutError(10060, "dropped")
        with self.assertRaises(TimeoutError):
            deploy.do_install(Always(host), FILES, "t3", say=lambda *_: None,
                              reconnect=lambda: Always(host))


if __name__ == "__main__":
    unittest.main()
