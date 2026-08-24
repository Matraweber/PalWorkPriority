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

    # Brace depth entering each line, so a `name =` inside a table constructor
    # can be told from a real assignment. Lua blocks close with `end`, not `}`,
    # so depth is zero everywhere except inside a table literal - which is
    # exactly the case that must not be reported.
    depth_at, depth = [], 0
    for text in lines:
        depth_at.append(depth)
        depth += text.count("{") - text.count("}")

    problems = []
    for name, decl_line in sorted(declared.items(), key=lambda kv: kv[1]):
        if name in inner:
            continue
        # A read. Not preceded by . or : - a field access is not a read of the
        # local - and not followed by a lone =, which is a write, handled next.
        use = re.compile(r"(?<![\w.:])" + re.escape(name) + r"(?![\w])(?!\s*=[^=])")

        # A write, and the more dangerous of the two. A read above the
        # declaration yields nil and usually errors loudly at the call; a write
        # silently creates a global in UE4SS's shared _G AND leaves the real
        # local permanently unset, so the cache it meant to clear never
        # clears. That is how `knows_icon` hid: M.reset assigned it 128 lines
        # above its own `local`, and the first version of this check exempted
        # every `name =` to avoid tripping over table keys like { X = 0.5 }.
        # Requiring the name to open the line, at brace depth zero, separates
        # the two without giving the case up.
        write = re.compile(r"^\s*" + re.escape(name) + r"\s*=[^=]")

        for n in range(1, decl_line):
            text = lines[n - 1]
            is_write = depth_at[n - 1] == 0 and write.match(text)
            if not (use.search(text) or is_write):
                continue
            problems.append(
                "%s:%d '%s' is %s here but not declared until line %d, so it "
                "%s. Add 'local %s' above the first use."
                % (path, n, name,
                   "assigned" if is_write else "used",
                   decl_line,
                   "writes a global and leaves the local unset" if is_write
                   else "reads as a nil global",
                   name))
            break

    return problems


# Lua allows 200 locals per function, and the main chunk of a module is a
# function. Going over is not a runtime error and not a syntax error: loadfile
# simply refuses the chunk. On 24 August panel.lua crossed it, every hot
# reload after that failed with one WARN line, reload.now kept the previous
# module, and the game ran code from before the edit while three separate
# changes looked as though they had done nothing at all.
#
# Counted rather than parsed, so the number is approximate on the safe side:
# every `local` at column zero, which is what a module's own state is, plus
# top level `local function`. Warns from 190 so there is room to land.
LOCAL_LIMIT = 200
LOCAL_WARN_AT = 190


ASSIGN = re.compile(r"^\s*([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s*=(?!=)")

# Everything that binds a name, matched one line at a time so that `$` means
# end of line and a declaration with no initialiser - `local rooted` - counts.
DECL_ON_LINE = (
    re.compile(r"\blocal\s+function\s+([A-Za-z_]\w*)"),
    re.compile(r"\blocal\s+([A-Za-z_][\w\s,]*?)\s*(?:=|$)"),
    re.compile(r"\bfunction\s*[\w.:]*\s*\(([^)]*)\)"),
    re.compile(r"\bfor\s+([A-Za-z_][\w\s,]*?)\s+(?:=|in)\b"),
)


def undeclared_writes(clean, path):
    """Assignments to a name this file never declares as a local.

    In Lua that silently creates a global. It costs nothing until something
    reads the name before the first write, when it is nil - and nil in an
    arithmetic or comparison throws from wherever it happens to be reached,
    with no mention of the missing declaration.

    Written after `owner_cached, owner_at = n, now` outlived its own `local`
    line: a block inserted above the declarations was later removed by cutting
    from its first line to the function below, which took the three
    declarations sitting between them. `owner_at >= 0` then compared nil to a
    number on the first host() call, the panel stopped drawing entirely, and
    the log said nothing at all. use_before_local could not see it - there was
    no longer a declaration to be used before.

    Narrow on purpose, and it earned that the hard way: the general form of
    this check - every name READ but never bound - reported 40 names on a
    clean tree, nearly all of them table-constructor keys like {R=1,G=2}, and
    a checker that cries wolf gets switched off. Writes at brace depth zero
    are the case that can be told apart from a table key with certainty, and
    they are the case that creates the global.
    """
    # Scanned line by line rather than with INNER_BIND, whose patterns end in
    # `$` and are run against the whole file at once - so `$` means end of
    # FILE, and a bare `local rooted` with nothing after it never matched.
    # That is harmless for use_before_local, which only needs to know a name
    # is bound somewhere else, but here it would report every such name as a
    # global. It reported eleven on the first run, all of them declared.
    declared = set()
    for line in clean.splitlines():
        for pat in DECL_ON_LINE:
            for m in pat.finditer(line):
                declared.update(n.strip() for n in m.group(1).split(","))
    declared.discard("")

    problems, depth = [], 0
    for n, line in enumerate(clean.splitlines(), 1):
        # Depth is measured BEFORE the line is judged, so a line that opens a
        # table is still at the depth it started on and its keys are not.
        at_depth = depth
        depth += line.count("{") - line.count("}")
        if at_depth != 0:
            continue
        m = ASSIGN.match(line)
        if not m:
            continue
        for name in (x.strip() for x in m.group(1).split(",")):
            if name and name not in declared:
                problems.append(
                    "%s:%d: assigns `%s`, which this file never declares "
                    "local - that is a global, and nil until it is written"
                    % (path, n, name))
    return problems


def toplevel_locals(clean, path):
    n = 0
    for line in clean.split(chr(10)):
        if not line.startswith("local"):
            continue
        rest = line[5:]
        if not rest[:1].isspace():
            continue
        rest = rest.strip()
        if rest.startswith("function"):
            n += 1
            continue
        # `local a, b, c = ...` declares three.
        names = rest.split("=")[0]
        n += max(1, names.count(",") + 1)

    if n >= LOCAL_LIMIT:
        return ["%s: %d top level local(s), at or over Lua's limit of %d - "
                "the file will load but every hot reload will refuse it. "
                "Collapse some into one table." % (path, n, LOCAL_LIMIT)]
    if n >= LOCAL_WARN_AT:
        print("warn %s: %d top level local(s), Lua's ceiling is %d"
              % (path, n, LOCAL_LIMIT))
    return []


def check(path):
    src = open(path, encoding="utf-8").read()
    problems = []

    try:
        clean = strip(src, path)
    except SyntaxError as exc:
        return [str(exc)]

    problems.extend(use_before_local(clean, path))
    problems.extend(undeclared_writes(clean, path))
    problems.extend(toplevel_locals(clean, path))

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
