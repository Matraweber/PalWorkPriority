"""Windows Credential Manager, through advapi32 (no extra package).

A generic credential holds one user name and one secret, encrypted by Windows
for the signed-in user. ftp_session.py keeps the FTP login here so the user
types it once (--save-login) instead of at every start. Nothing is written to
a file, and nothing here prints a secret.
"""
import ctypes
import sys
from ctypes import wintypes

CRED_TYPE_GENERIC = 1
CRED_PERSIST_LOCAL_MACHINE = 2
ERROR_NOT_FOUND = 1168


class _FILETIME(ctypes.Structure):
    _fields_ = [("dwLowDateTime", wintypes.DWORD), ("dwHighDateTime", wintypes.DWORD)]


class _CREDENTIAL(ctypes.Structure):
    _fields_ = [
        ("Flags", wintypes.DWORD),
        ("Type", wintypes.DWORD),
        ("TargetName", wintypes.LPWSTR),
        ("Comment", wintypes.LPWSTR),
        ("LastWritten", _FILETIME),
        ("CredentialBlobSize", wintypes.DWORD),
        ("CredentialBlob", ctypes.POINTER(ctypes.c_ubyte)),
        ("Persist", wintypes.DWORD),
        ("AttributeCount", wintypes.DWORD),
        ("Attributes", ctypes.c_void_p),
        ("TargetAlias", wintypes.LPWSTR),
        ("UserName", wintypes.LPWSTR),
    ]


def available():
    return sys.platform == "win32"


def _api():
    if not available():
        raise OSError("Windows Credential Manager exists only on Windows")
    api = ctypes.WinDLL("advapi32", use_last_error=True)
    api.CredWriteW.argtypes = [ctypes.POINTER(_CREDENTIAL), wintypes.DWORD]
    api.CredWriteW.restype = wintypes.BOOL
    api.CredReadW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                              ctypes.POINTER(ctypes.POINTER(_CREDENTIAL))]
    api.CredReadW.restype = wintypes.BOOL
    api.CredDeleteW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD]
    api.CredDeleteW.restype = wintypes.BOOL
    api.CredFree.argtypes = [ctypes.c_void_p]
    api.CredFree.restype = None
    return api


def write(target, user, secret):
    """Store (or replace) user and secret under target."""
    blob = secret.encode("utf-16-le")
    buf = (ctypes.c_ubyte * len(blob)).from_buffer_copy(blob)
    cred = _CREDENTIAL()
    cred.Type = CRED_TYPE_GENERIC
    cred.TargetName = target
    cred.CredentialBlobSize = len(blob)
    cred.CredentialBlob = ctypes.cast(buf, ctypes.POINTER(ctypes.c_ubyte))
    cred.Persist = CRED_PERSIST_LOCAL_MACHINE
    cred.UserName = user
    if not _api().CredWriteW(ctypes.byref(cred), 0):
        raise OSError(f"CredWrite failed (error {ctypes.get_last_error()})")


def read(target):
    """(user, secret), or None when nothing is stored under target."""
    api = _api()
    out = ctypes.POINTER(_CREDENTIAL)()
    if not api.CredReadW(target, CRED_TYPE_GENERIC, 0, ctypes.byref(out)):
        code = ctypes.get_last_error()
        if code == ERROR_NOT_FOUND:
            return None
        raise OSError(f"CredRead failed (error {code})")
    try:
        cred = out.contents
        raw = ctypes.string_at(cred.CredentialBlob, cred.CredentialBlobSize)
        return cred.UserName or "", raw.decode("utf-16-le")
    finally:
        api.CredFree(out)


def delete(target):
    """True when something was removed, False when nothing was stored."""
    if _api().CredDeleteW(target, CRED_TYPE_GENERIC, 0):
        return True
    code = ctypes.get_last_error()
    if code == ERROR_NOT_FOUND:
        return False
    raise OSError(f"CredDelete failed (error {code})")
