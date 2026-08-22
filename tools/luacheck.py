"""Structural sanity check for the mod's Lua sources.

There is no Lua interpreter on the dev machine, and every edit to these files
is a text patch. The failure that actually happens is a patch that damages a
string literal or drops an "end", and Lua only reports it at load time, by
which point the whole mod is silently absent from the game.

This is not a parser. It strips comments and strings properly, then checks
that block keywords and brackets balance, which is what a bad patch breaks.

    python tools/luacheck.py Scripts/*.lua
"""

import re
import sys
import glob

LONG_OPEN = "["
OPENERS = ("function", "if", "do", "repeat")
CLOSERS = ("end", "until")


def strip(src, path):
    """Remove comments and string literals, preserving newlines and offsets."""
    out = []
    i, n = 0, len(src)
    line = 1

    while i < n:
        ch = src[i]

        if ch == "\n":
            line += 1
            out.append("\n")
            i += 1
            continue

        # long bracket, either a [[string]] or the tail of a --[[comment]]
        if ch == LONG_OPEN:
            j = i + 1
            eq = 0
            while j < n and src[j] == "=":
                eq += 1
                j += 1
            if j < n and src[j] == LONG_OPEN:
                close = "]" + "=" * eq + "]"
                stop = src.find(close, j + 1)
                if stop == -1:
                    raise SyntaxError("%s:%d unterminated long bracket" % (path, line))
                line += src.count("\n", i, stop)
                out.append("\n" * src.count("\n", i, stop))
                i = stop + len(close)
                continue

        if ch == "-" and src.startswith("--", i):
            # a long comment is --[[ ... ]], handled by the branch above once
            # we step past the dashes
            j = i + 2
            if j < n and src[j] == LONG_OPEN:
                k = j + 1
                eq = 0
                while k < n and src[k] == "=":
                    eq += 1
                    k += 1
                if k < n and src[k] == LONG_OPEN:
                    close = "]" + "=" * eq + "]"
                    stop = src.find(close, k + 1)
                    if stop == -1:
                        raise SyntaxError("%s:%d unterminated long comment" % (path, line))
                    line += src.count("\n", i, stop)
                    out.append("\n" * src.count("\n", i, stop))
                    i = stop + len(close)
                    continue
            stop = src.find("\n", i)
            i = n if stop == -1 else stop
            continue

        if ch in "\"'":
            quote = ch
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == "\n":
                    raise SyntaxError(
                        "%s:%d unterminated string literal, a patch probably "
                        "turned an escape into a real newline" % (path, line))
                if src[j] == quote:
                    break
                j += 1
            if j >= n:
                raise SyntaxError("%s:%d unterminated string literal" % (path, line))
            out.append('""')
            i = j + 1
            continue

        out.append(ch)
        i += 1

    return "".join(out)


def words(text):
    token = []
    for ch in text:
        if ch.isalnum() or ch == "_":
            token.append(ch)
        else:
            if token:
                yield "".join(token)
                token = []
    if token:
        yield "".join(token)


# A file-scope declaration is one written hard against the left margin. The
# indent is what separates "this is the module's own name" from a local inside
# some function, and the distinction is the whole reliability of the check.
FILE_DECL = re.compile(r"^local\s+(?:function\s+)?([A-Za-z_][\w\s,]*?)\s*(?:\(|=|$)")

# Anything that binds the same spelling in a nearer scope. If a name is ever
# bound by one of these, a reference to it higher in the file may legitimately
# be that inner binding, and the check cannot tell the two apart - so it says
# nothing rather than guessing.
INNER_BIND = (
    re.compile(r"\s+local\s+(?:function\s+)?([A-Za-z_][\w\s,]*?)\s*(?:\(|=|$)"),
    re.compile(r"function\s*\(([^)]*)\)"),
    re.compile(r"function\s+[\w.:]+\s*\(([^)]*)\)"),
    re.compile(r"\bfor\s+([A-Za-z_][\w\s,]*?)\s+(?:=|in)\b"),
)


def use_before_local(clean, path):
    """Names referenced above the line that declares them.

    Lua binds a name at the position it is written, so a reference sitting
    above its own `local` compiles to a global read, which is nil. Nothing is
    raised at load time: the file parses, the mod starts, and one feature is
    quietly dead until somebody triggers it. This shipped three times in this
    repo - `run_now` (killed `pwp discover` and Ctrl+F11 outright),
    `stock_totals` (threw after a typed limit was already stored, swallowing
    the warning that says the limit stops the job now), and `knows_icon`
    (leaked a global into UE4SS's shared _G and never cleared its own cache).
    All three were invisible to the block-balance check above, and each was
    one line out of place.

    Deliberately conservative. It looks only at names declared at column zero
    and never bound anywhere else in the file, because those are the ones it
    can be certain about, and a checker that cries wolf gets switched off. A
    forward declaration (`local foo` above, `function foo()` below) is the
    supported way to satisfy it.
    """
    lines = clean.split("\n")

    def names_in(blob):
        return [p.strip() for p in blob.split(",") if p.strip().isidentifier()]

    declared = {}       # name -> line of its file-scope `local`
    inner = set()       # names also bound in some nearer scope

    for n, text in enumerate(lines, 1):
        m = FILE_DECL.match(text)
        if m:
            for name in names_in(m.group(1)):
                if name not in declared:
                    declared[name] = n
        for pattern in INNER_BIND:
            for hit in pattern.finditer(text):
                inner.update(names_in(hit.group(1)))

    problems = []
    for name, decl_line in sorted(declared.items(), key=lambda kv: kv[1]):
        if name in inner:
            continue
        # Not preceded by . or : - a field access is not a read of the local.
        # Not followed by a lone = either: that is a table key (`{ X = 0.5 }`)
        # or an assignment, and neither reads the value.
        use = re.compile(r"(?<![\w.:])" + re.escape(name) + r"(?![\w])(?!\s*=[^=])")
        for n in range(1, decl_line):
            if not use.search(lines[n - 1]):
                continue
            problems.append(
                "%s:%d '%s' is used here but not declared until line %d, so it "
                "reads as a nil global. Add 'local %s' above the first use."
                % (path, n, name, decl_line, name))
            break

    return problems


def check(path):
    src = open(path, encoding="utf-8").read()
    problems = []

    try:
        clean = strip(src, path)
    except SyntaxError as exc:
        return [str(exc)]

    problems.extend(use_before_local(clean, path))

    opens = closes = 0
    for word in words(clean):
        if word in OPENERS:
            opens += 1
        elif word in CLOSERS:
            closes += 1

    if opens != closes:
        problems.append(
            "%s: %d block opener(s) against %d closer(s), off by %d"
            % (path, opens, closes, opens - closes))

    for left, right, name in (("(", ")", "paren"), ("{", "}", "brace"),
                              ("[", "]", "bracket")):
        a, b = clean.count(left), clean.count(right)
        if a != b:
            problems.append("%s: %d %s(s) open, %d closed" % (path, a, name, b))

    return problems


def main(argv):
    paths = []
    for arg in argv or ["Scripts/*.lua"]:
        paths.extend(sorted(glob.glob(arg)))

    if not paths:
        print("no files matched")
        return 2

    failed = 0
    for path in paths:
        problems = check(path)
        if problems:
            failed += 1
            for problem in problems:
                print("FAIL " + problem)
        else:
            print("ok   " + path)

    if failed:
        print("\n%d file(s) failed" % failed)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
