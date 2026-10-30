"""ftp_session's kept login: Windows Credential Manager round trip, and a kept
login used without any prompt."""
import builtins
import sys
import unittest
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))
import ftp_session  # noqa: E402
import win_credential  # noqa: E402


class FakeStore:
    def __init__(self, ok=True):
        self.ok, self.items = ok, {}

    def available(self):
        return self.ok

    def write(self, target, user, secret):
        self.items[target] = (user, secret)

    def read(self, target):
        return self.items.get(target)


LOGIN = {"host": "ftp.example.test", "port": 2121, "user": "someone", "password": "päss w;rd\""}


class KeptLogin(unittest.TestCase):
    def test_round_trip_through_a_store(self):
        store = FakeStore()
        self.assertIsNone(ftp_session.saved_login(store))
        ftp_session.save_login(LOGIN, store)
        self.assertEqual(ftp_session.saved_login(store), LOGIN)
        user, secret = store.items[ftp_session.CREDENTIAL]
        self.assertEqual(user, "someone")
        self.assertNotIn("someone", secret)  # the user name lives in its own field

    def test_no_store_means_no_kept_login(self):
        self.assertIsNone(ftp_session.saved_login(FakeStore(ok=False)))

    def test_a_kept_login_asks_nothing(self):
        asked = []
        real_input, real_connect = builtins.input, ftp_session.Session.connect
        builtins.input = lambda *a: asked.append(a) or ""
        ftp_session.Session.connect = lambda self: None
        try:
            s = ftp_session.Session(False, dict(LOGIN))
        finally:
            builtins.input, ftp_session.Session.connect = real_input, real_connect
        self.assertEqual(asked, [])
        self.assertEqual((s.host, s.port, s.user), ("ftp.example.test", 2121, "someone"))


@unittest.skipUnless(win_credential.available(), "Windows only")
class CredentialManager(unittest.TestCase):
    def test_write_read_delete(self):
        target = "PalWorkPriority test credential " + uuid.uuid4().hex
        try:
            self.assertIsNone(win_credential.read(target))
            win_credential.write(target, "user", "sécret ✓")
            self.assertEqual(win_credential.read(target), ("user", "sécret ✓"))
            win_credential.write(target, "user2", "other")
            self.assertEqual(win_credential.read(target), ("user2", "other"))
        finally:
            removed = win_credential.delete(target)
        self.assertTrue(removed)
        self.assertIsNone(win_credential.read(target))
        self.assertFalse(win_credential.delete(target))


if __name__ == "__main__":
    unittest.main()
