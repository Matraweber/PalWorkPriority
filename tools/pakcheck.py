"""Is the pak you are about to ship the one that actually works?

Written after shipping a stale one. build/PalWorkPriority.pak was six hours
older than the pak installed in Paks/LogicMods, nobody compared them, and the
Workshop package went out with the older blueprint. The panel then found 7 of
its 21 named widgets and fell through to the blueprint's own defaults -
"WORK RULES", "search items", "new rule" - which reads as a broken layout
rather than as the wrong file, so the hunt starts in the wrong place.

The first version of this tried to verify CONTENT: scan the pak for the 21
widget names, since FNames live in a .uasset name table as plain strings. It
reported 0 of 21 on the known-good pak. The index does not expose so much as a
file name (pakinfo: "entries 4", mount point only), so nothing inside is
readable without real Unreal tooling - and a checker that fails a good pak is
worse than none, because it teaches you to ignore it.

So this asks the narrower question that would have caught the actual mistake:
does the pak you are about to ship match the one the game is running? That is
the only pak anyone has evidence about, because it is the one under the panel
that works.

    python tools/pakcheck.py [candidate.pak]
"""

import hashlib
import io
import os
import sys
import time

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIVE = ("C:/Program Files (x86)/Steam/steamapps/common/Palworld/Pal/Content"
        "/Paks/LogicMods/PalWorkPriority.pak")


def describe(path):
    raw = io.open(path, "rb").read()
    return (len(raw),
            hashlib.sha256(raw).hexdigest()[:16],
            time.strftime("%Y-%m-%d %H:%M", time.localtime(os.path.getmtime(path))))


def main(argv):
    cand = argv[0] if argv else os.path.join(HERE, "build",
                                             "PalWorkPriority.pak")

    if not os.path.isfile(cand):
        print("no pak at " + cand)
        return 2
    if not os.path.isfile(LIVE):
        print("no pak installed at " + LIVE)
        print("Nothing to compare against, so this cannot vouch for anything.")
        return 2

    c_size, c_hash, c_when = describe(cand)
    l_size, l_hash, l_when = describe(LIVE)

    print("shipping  %6d bytes  %s  %s" % (c_size, c_hash, c_when))
    print("installed %6d bytes  %s  %s" % (l_size, l_hash, l_when))
    print("")

    if c_hash == l_hash:
        print("ok, identical to the pak the game is running")
        return 0

    print("DIFFERENT. The pak you are about to ship is not the one under the")
    print("panel you have been testing. If the installed one is the good one,")
    print("copy it over the candidate before packaging:")
    print("")
    print('    cp "%s" "%s"' % (LIVE, cand))
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
