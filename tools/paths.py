"""One place for every path the tools touch, client and server.

The dedicated server mirrors the client's mod layout exactly, so the only
difference is the root, the process name, and where crash dumps land. Tools
accept --server (or env PWP_TARGET=server) and everything else follows.

Client discovery reads Steam registry entries and libraryfolders.vdf. Set
PWP_CLIENT_ROOT to select an installation explicitly (also useful for portable
Steam installs). A client must contain its executable or PalWorkPriority mod
directory; missing/ambiguous installations raise ValueError, never guess.
"""

import os
import re

CLIENT_ROOT = r"C:\Program Files (x86)\Steam\steamapps\common\Palworld"
SERVER_ROOT = r"C:\Program Files (x86)\Steam\steamapps\common\PalServer"


def _steam_roots():
    """Read registered Steam locations, with conventional locations as probes."""
    roots = []
    try:
        import winreg
    except ImportError:
        pass
    else:
        for hive, key, value in (
            (winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam", "SteamPath"),
            (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Valve\Steam", "InstallPath"),
            (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath"),
        ):
            try:
                with winreg.OpenKey(hive, key) as handle:
                    path, _ = winreg.QueryValueEx(handle, value)
                if isinstance(path, str) and path.strip():
                    roots.append(path)
            except OSError:
                continue
    for variable in ("ProgramFiles(x86)", "ProgramFiles"):
        if os.environ.get(variable):
            roots.append(os.path.join(os.environ[variable], "Steam"))
    roots.append(os.path.dirname(os.path.dirname(os.path.dirname(CLIENT_ROOT))))
    return _unique_paths(roots)


def _unique_paths(paths):
    result = {}
    for path in paths:
        if isinstance(path, str) and path.strip() and os.path.isabs(path):
            path = os.path.normpath(path)
            result.setdefault(os.path.normcase(path), path)
    return list(result.values())


def _vdf_pairs(filename):
    """Read quoted scalar lines from Steam's VDF without interpreting escapes.

    Only VDF's escaped slash/quote are decoded; unicode_escape would corrupt
    non-ASCII library names. Ignore unavailable or oversized metadata.
    """
    try:
        with open(filename, encoding="utf-8-sig") as source:
            text = source.read(1024 * 1024 + 1)
    except (OSError, UnicodeError):
        return []
    if len(text) > 1024 * 1024:
        return []
    pairs = re.findall(r'^\s*"([^"\r\n]+)"\s+"((?:\\.|[^"\\\r\n])*)"\s*(?://[^\r\n]*)?$',
                       text, re.MULTILINE)
    return [(key, re.sub(r'\\([\\"])', r'\1', value)) for key, value in pairs]


def _client_exists(root):
    return (os.path.isfile(os.path.join(root, "Palworld.exe"))
            or os.path.isfile(os.path.join(root, "Pal", "Binaries", "Win64",
                                           "Palworld-Win64-Shipping.exe"))
            or os.path.isdir(os.path.join(root, "Mods", "NativeMods", "UE4SS",
                                          "Mods", "PalWorkPriority")))


def _client_root():
    override = os.environ.get("PWP_CLIENT_ROOT")
    if override is not None:
        roots = _unique_paths([override])
        if len(roots) != 1 or not _client_exists(roots[0]):
            raise ValueError("PWP_CLIENT_ROOT must be an absolute game root containing "
                             "a Palworld executable or the PalWorkPriority mod directory")
        return roots[0]

    libraries = []
    for steam in _steam_roots():
        libraries.append(steam)
        for key, value in _vdf_pairs(os.path.join(steam, "steamapps", "libraryfolders.vdf")):
            # Modern Steam uses path entries; older versions used numeric keys.
            if key.lower() == "path" or key.isdigit():
                libraries.append(value)

    candidates = []
    for library in _unique_paths(libraries):
        common = os.path.join(library, "steamapps", "common")
        candidates.append(os.path.join(common, "Palworld"))
        manifest = os.path.join(library, "steamapps", "appmanifest_1623730.acf")
        for key, value in _vdf_pairs(manifest):
            if (key.lower() == "installdir" and value not in ("", ".", "..")
                    and not any(c in value for c in '/\\:')):
                candidates.append(os.path.join(common, value))
    installed = [root for root in _unique_paths(candidates) if _client_exists(root)]
    if len(installed) == 1:
        return installed[0]
    if installed:
        raise ValueError("Multiple Palworld installations found; set PWP_CLIENT_ROOT: "
                         + ", ".join(installed))
    raise ValueError("No verified Palworld client installation found in Steam libraries; "
                     "set PWP_CLIENT_ROOT to an existing game root")


def resolve(argv=None):
    """Returns (paths dict, argv with --server removed)."""
    argv = list(argv or [])
    server = "--server" in argv or os.environ.get("PWP_TARGET") == "server"
    argv = [a for a in argv if a != "--server"]

    root = SERVER_ROOT if server else _client_root()
    ue4ss = os.path.join(root, "Mods", "NativeMods", "UE4SS")
    mod = os.path.join(ue4ss, "Mods", "PalWorkPriority")

    return {
        "server": server,
        "root": root,
        "ue4ss_log": os.path.join(ue4ss, "UE4SS.log"),
        "mod": mod,
        "log": os.path.join(mod, "priority.log"),
        "trace": os.path.join(mod, "trace.txt"),
        "remote": os.path.join(mod, "remote.txt"),
        # The client's dumps land under LOCALAPPDATA, the server's under its
        # own Saved tree.
        "crashes": (os.path.join(root, "Pal", "Saved", "Crashes") if server
                    else os.path.join(os.environ.get("LOCALAPPDATA", ""),
                                      "Pal", "Saved", "Crashes")),
        "process": "PalServer*" if server else "Palworld*",
        "exe": os.path.join(root, "PalServer.exe") if server else None,
    }, argv


if __name__ == "__main__":
    import argparse
    import sys
    parser = argparse.ArgumentParser(description="Read-only Palworld path discovery")
    parser.add_argument("--client-root", action="store_true", required=True)
    parser.parse_args()
    try:
        print(_client_root())
    except ValueError as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
