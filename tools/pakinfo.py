"""List what is inside an Unreal .pak, without any Unreal tooling.

Written to answer one question before committing to the blueprint route: what
does a working Palworld UI mod actually ship, and where does it put it. The
answer decides the folder layout, the asset paths and the mount point our own
pak would need, and none of that is guessable from outside.

This reads the footer and the index. It does not decode .uasset contents, so
it says what the assets ARE and where they live, not what is in them.

    python tools/pakinfo.py "path/to/Some.pak"
"""

import io
import os
import struct
import sys

MAGIC = 0x5A6F12E1


def u32(f):
    return struct.unpack("<I", f.read(4))[0]


def u64(f):
    return struct.unpack("<Q", f.read(8))[0]


def fstring(f):
    """An FString: length, then bytes. Negative length means UTF-16."""
    n = struct.unpack("<i", f.read(4))[0]
    if n == 0:
        return ""
    if n < 0:
        raw = f.read(-n * 2)
        return raw.decode("utf-16-le", "replace").rstrip("\0")
    raw = f.read(n)
    return raw.decode("utf-8", "replace").rstrip("\0")


def find_footer(data):
    """The footer sits at the end, but its size varies by version, so the
    magic is searched for rather than assumed to be at a fixed offset."""
    needle = struct.pack("<I", MAGIC)
    at = data.rfind(needle, max(0, len(data) - 1024))
    if at < 0:
        return None
    return at


def read_index(path):
    data = open(path, "rb").read()
    at = find_footer(data)
    if at is None:
        return None, "no pak magic in the last 1024 bytes"

    f = io.BytesIO(data)
    f.seek(at + 4)
    version = u32(f)
    index_offset = u64(f)
    index_size = u64(f)

    info = {"version": version, "size": len(data),
            "index_offset": index_offset, "index_size": index_size}

    if index_offset + index_size > len(data):
        return info, "index runs past the end, so it is encrypted or compressed"

    idx = io.BytesIO(data[index_offset:index_offset + index_size])
    try:
        mount = fstring(idx)
        count = u32(idx)
    except Exception as exc:
        return info, "index unreadable: " + str(exc)

    info["mount"] = mount
    info["count"] = count

    # Version 8 and below store filename then entry inline. From 10 the index
    # became a path-hash plus directory structure and this simple walk stops
    # working, which is itself worth reporting rather than guessing past.
    names = []
    if version <= 8:
        try:
            for _ in range(count):
                names.append(fstring(idx))
                # FPakEntry: offset, size, uncompressed, method, hash, ...
                idx.read(8 + 8 + 8 + 4 + 20)
                method = 0
                idx.read(1)
        except Exception:
            pass
    info["names"] = names
    return info, None


def strings_in(path, minlen=6):
    """Asset paths as they appear verbatim in the file.

    Crude on purpose. Even where the index cannot be walked, the /Game/ paths
    are stored as plain text and are the part worth seeing.
    """
    data = open(path, "rb").read()
    out, cur = [], bytearray()

    for byte in data:
        if 32 <= byte < 127:
            cur.append(byte)
        else:
            if len(cur) >= minlen:
                out.append(cur.decode("ascii"))
            cur = bytearray()
    if len(cur) >= minlen:
        out.append(cur.decode("ascii"))
    return out


def main(argv):
    if not argv:
        print(__doc__)
        return 2

    for path in argv:
        if not os.path.isfile(path):
            print("not found: " + path)
            continue

        print("=" * 70)
        print(os.path.basename(path))
        info, err = read_index(path)

        if info:
            print("  pak version   %s" % info.get("version"))
            print("  size          %d bytes" % info.get("size", 0))
            print("  mount point   %s" % info.get("mount", "?"))
            print("  entries       %s" % info.get("count", "?"))
        if err:
            print("  note: " + err)

        for name in info.get("names", []) if info else []:
            print("    " + name)

        paths = [s for s in strings_in(path)
                 if s.startswith("/Game/") or s.startswith("/Script/")
                 or s.startswith("../")]
        seen, shown = set(), 0
        if paths:
            print("  asset paths found in the file:")
            for s in paths:
                if s in seen:
                    continue
                seen.add(s)
                shown += 1
                if shown <= 40:
                    print("    " + s)
            if shown > 40:
                print("    ... and %d more" % (shown - 40))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
