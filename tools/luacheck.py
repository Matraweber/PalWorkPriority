"""Structural sanity check for the mod's Lua sources.

There is no Lua interpreter on the dev machine, and every edit to these files
is a text patch. The failure that actually happens is a patch that damages a
string literal or drops an "end", and Lua only reports it at load time, by
which point the whole mod is silently absent from the game.

This is not a parser. It strips comments and strings properly, then checks
that block keywords and brackets balance, which is what a bad patch breaks.

    python tools/luacheck.py Scripts/*.lua
"""

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


def check(path):
    src = open(path, encoding="utf-8").read()
    problems = []

    try:
        clean = strip(src, path)
    except SyntaxError as exc:
        return [str(exc)]

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
