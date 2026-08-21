"""One place for every path the tools touch, client and server.

The dedicated server mirrors the client's mod layout exactly, so the only
difference is the root, the process name, and where crash dumps land. Tools
accept --server (or env PWP_TARGET=server) and everything else follows.
"""

import os

CLIENT_ROOT = r"C:\Program Files (x86)\Steam\steamapps\common\Palworld"
SERVER_ROOT = r"C:\Program Files (x86)\Steam\steamapps\common\PalServer"


def resolve(argv=None):
    """Returns (paths dict, argv with --server removed)."""
    argv = list(argv or [])
    server = "--server" in argv or os.environ.get("PWP_TARGET") == "server"
    argv = [a for a in argv if a != "--server"]

    root = SERVER_ROOT if server else CLIENT_ROOT
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
