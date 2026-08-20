"""Report every keybind every installed UE4SS mod registers.

Picking a free hotkey by grepping for a key name is not enough, and getting it
wrong once already cost a collision: FreeCam looked like a plain F8 binding
because the key and the modifier are set up on different lines, several lines
apart, both from config with literal defaults.

So resolve the arguments instead of reading them. For each RegisterKeyBind
call this follows the key and modifier expressions back through local
assignments in the same file, including the `x or DEFAULT` shape config-driven
mods use, and prints what the binding actually resolves to.

    python tools/keybind_audit.py
    python tools/keybind_audit.py --key F8
"""

import os
import re
import sys
import glob

MODS = (r"C:\Program Files (x86)\Steam\steamapps\common\Palworld"
        r"\Mods\NativeMods\UE4SS\Mods")

CALL = re.compile(r"RegisterKeyBind\s*\(", re.S)
KEY_LITERAL = re.compile(r"Key\.([A-Z0-9_]+)")
MOD_LITERAL = re.compile(r"ModifierKey\.([A-Z]+)")
ASSIGN = re.compile(r"^\s*local\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$", re.M)


def split_args(text, start):
    """The argument list of a call whose '(' is at `start`, split at depth 1."""
    depth, i, args, cur = 0, start, [], []
    while i < len(text):
        ch = text[i]
        if ch in "([{":
            depth += 1
            if depth == 1:
                i += 1
                continue
        elif ch in ")]}":
            depth -= 1
            if depth == 0:
                args.append("".join(cur).strip())
                return args, i
        elif ch == "," and depth == 1:
            args.append("".join(cur).strip())
            cur = []
            i += 1
            continue
        if depth >= 1:
            cur.append(ch)
        i += 1
    return args, i


def resolve(expr, locals_map, depth=0):
    """Follow an expression back to the Key./ModifierKey. literals it can yield."""
    if depth > 4 or not expr:
        return expr

    keys = KEY_LITERAL.findall(expr)
    mods = MOD_LITERAL.findall(expr)
    if keys or mods:
        return expr

    for name in re.findall(r"[A-Za-z_][A-Za-z0-9_]*", expr):
        if name in locals_map:
            return resolve(locals_map[name], locals_map, depth + 1)
    return expr


def describe(key_expr, mod_expr, locals_map, file_has_mods):
    key_r = resolve(key_expr, locals_map)
    keys = KEY_LITERAL.findall(key_r)

    mods, unresolved = [], False
    if mod_expr is not None:
        mod_r = resolve(mod_expr, locals_map)
        mods = MOD_LITERAL.findall(mod_r)
        # An empty table is a mod saying "no modifiers" out loud, which is an
        # answer rather than a gap. FreeCam's speed keys use it.
        if not mods and mod_r.replace(" ", "") in ("{}", "nil"):
            pass
        elif not mods:
            # A modifier argument that resolves to nothing recognisable is the
            # dangerous case, not the harmless one. FreeCam decides its
            # modifier inside a function, so following locals finds nothing and
            # the binding reads as unmodified F8 when it is really Alt+F8.
            # Say so rather than guessing at none.
            unresolved = True

    if not keys:
        return None, "key unresolved: " + key_expr[:44]

    key = keys[-1] if len(keys) > 1 else keys[0]

    if unresolved:
        hint = "+".join(sorted(set(file_has_mods))) or "?"
        return hint + "?+" + key, "modifier decided at runtime, check by hand"

    label = "+".join([m.title() for m in dict.fromkeys(mods)] + [key])
    note = "default, config may override" if len(keys) > 1 else ""
    return label, note


def scan_file(path):
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return []

    locals_map = {}
    for name, value in ASSIGN.findall(text):
        locals_map.setdefault(name, value.strip())

    # Every modifier this file mentions anywhere, as the fallback hint for a
    # binding whose modifier cannot be followed.
    file_has_mods = MOD_LITERAL.findall(text)

    out = []
    for m in CALL.finditer(text):
        args, _ = split_args(text, m.end() - 1)
        if not args:
            continue

        key_expr = args[0]
        mod_expr = None
        if len(args) >= 3 and "function" not in args[1]:
            mod_expr = args[1]

        label, note = describe(key_expr, mod_expr, locals_map, file_has_mods)
        if label:
            line = text.count("\n", 0, m.start()) + 1
            out.append((label, note, os.path.basename(path), line))
    return out


def main(argv):
    want = None
    if "--key" in argv:
        want = argv[argv.index("--key") + 1].upper()

    if not os.path.isdir(MODS):
        print("mods folder not found: " + MODS)
        return 2

    rows = []
    for mod in sorted(os.listdir(MODS)):
        mod_dir = os.path.join(MODS, mod)
        if not os.path.isdir(mod_dir):
            continue
        for path in sorted(glob.glob(os.path.join(mod_dir, "**", "*.lua"),
                                     recursive=True)):
            for label, note, fname, line in scan_file(path):
                rows.append((label, mod, note, fname, line))

    # Kept whole, because the listing at the end asks which mods have no
    # direct call at all. Computing that from a filtered set claims every
    # mod is missing a binding it simply did not match on.
    all_rows = rows
    if want:
        rows = [r for r in rows if want in r[0].upper().split("+")]
        print("bindings using %s\n" % want)

    rows.sort(key=lambda r: (r[0].count("+"), r[0], r[1]))

    seen = set()
    for label, mod, note, fname, line in rows:
        tag = (label, mod)
        if tag in seen:
            continue
        seen.add(tag)
        print("  %-22s %-26s %s%s"
              % (label, mod, "%s:%d" % (fname, line),
                 "   (" + note + ")" if note else ""))

    print("\n%d resolved binding(s) across %d mod(s)"
          % (len(seen), len({r[1] for r in rows})))

    # Anything holding a Key. literal in a mod that never calls
    # RegisterKeyBind directly is wrapping it in a helper, and the sweep above
    # cannot see those at all. Listing them keeps a miss visible instead of
    # letting silence read as "nothing there".
    print("\nmods with key literals but no direct RegisterKeyBind call:")
    quiet = 0
    for mod in sorted(os.listdir(MODS)):
        mod_dir = os.path.join(MODS, mod)
        if not os.path.isdir(mod_dir):
            continue
        if mod in {r[1] for r in all_rows}:
            continue

        found = set()
        for path in glob.glob(os.path.join(mod_dir, "**", "*.lua"),
                              recursive=True):
            try:
                text = open(path, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            for k in KEY_LITERAL.findall(text):
                found.add(k)

        if found:
            quiet += 1
            listed = sorted(found)
            print("  %-26s %s" % (mod, ", ".join(listed[:12])
                                  + (" ..." if len(listed) > 12 else "")))
    if quiet == 0:
        print("  none")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
