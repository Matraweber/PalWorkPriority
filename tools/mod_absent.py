"""Remove or restore PalWorkPriority for mod-absent frame captures (G5).

Usage (game must be closed):
  python -B tools/mod_absent.py remove   -> prints the quarantine folder
  python -B tools/mod_absent.py restore <quarantine folder>
remove moves the mod folder and LogicMods/PalWorkPriority.pak to
D:/PalWorkPriority-backups/g5-absent-<time>/ with a SHA-256 manifest and sets
the mods.txt entry to 0 byte-exactly (the file is CRLF; sed would rewrite it).
restore checks the quarantine folder against its manifest first (nothing is
moved when it does not match), moves both back, restores mods.txt and
verifies every hash again.
Procedure: docs/testing.md "Mod-absent baseline"; first used 2026-10-19.

Every guard is an explicit check that exits with a message, so python -O
cannot switch one off.
"""
import hashlib, shutil, subprocess, sys, time
from pathlib import Path

GAME = Path('D:/Steam/steamapps/common/Palworld')
MODS = GAME / 'Mods/NativeMods/UE4SS/Mods'
MOD = MODS / 'PalWorkPriority'
PAK = GAME / 'Pal/Content/Paks/LogicMods/PalWorkPriority.pak'
BACKUPS = Path('D:/PalWorkPriority-backups')
GAME_EXE = 'Palworld-Win64-Shipping'
LINE_ON, LINE_OFF = b'PalWorkPriority : 1\r\n', b'PalWorkPriority : 0\r\n'


def die(message):
    """Stop with a message and exit code 1 (instead of assert, which python -O
    removes)."""
    raise SystemExit('mod_absent: ' + message)


def sha(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def closed():
    """Refuse every step while the game runs, or when that cannot be told."""
    r = subprocess.run(['tasklist', '/FI', 'IMAGENAME eq %s.exe' % GAME_EXE], capture_output=True, text=True)
    if r.returncode != 0:
        die('tasklist failed, so the game cannot be confirmed closed: %s' % (r.stderr or '').strip())
    if GAME_EXE in (r.stdout or ''):  # tasklist truncates the name, so match the stem
        die('close the game first (%s is running)' % GAME_EXE)


def manifest(root):
    return {str(p.relative_to(root)).replace('\\', '/'): sha(p) for p in root.rglob('*') if p.is_file()}


def remove():
    mods_txt = (MODS / 'mods.txt').read_bytes()
    if mods_txt.count(LINE_ON) != 1:
        die('mods.txt has no single enabled PalWorkPriority line; nothing was moved')
    if not MOD.is_dir() or not PAK.is_file():
        die('the mod folder or the pak is missing (%s, %s); nothing was moved' % (MOD, PAK))
    q = BACKUPS / time.strftime('g5-absent-%Y%m%d-%H%M%S')
    q.mkdir(parents=True)
    (q / 'mods.txt.orig').write_bytes(mods_txt)
    files = manifest(MOD)
    lines = ['%s  PalWorkPriority/%s' % (h, n) for n, h in sorted(files.items())]
    lines.append('%s  LogicMods/PalWorkPriority.pak' % sha(PAK))
    lines.append('%s  mods.txt' % hashlib.sha256(mods_txt).hexdigest())
    (q / 'manifest.sha256').write_text('\n'.join(lines) + '\n')
    shutil.move(str(MOD), str(q / 'PalWorkPriority'))
    (q / 'LogicMods').mkdir()
    shutil.move(str(PAK), str(q / 'LogicMods' / 'PalWorkPriority.pak'))
    (MODS / 'mods.txt').write_bytes(mods_txt.replace(LINE_ON, LINE_OFF))
    print(q)
    print('moved %d mod files and the pak; mods.txt entry set to 0' % len(files))


def recorded(q):
    """{name: sha256} from the quarantine folder's manifest."""
    path = q / 'manifest.sha256'
    if not path.is_file():
        die('no manifest.sha256 in %s; not a mod_absent quarantine folder' % q)
    out = {}
    for line in path.read_text().splitlines():
        h, sep, name = line.partition('  ')
        if not sep or len(h) != 64:
            die('%s has an unreadable line: %r' % (path, line))
        out[name] = h
    return out


def check_quarantine(q, want):
    """The quarantine folder holds exactly what remove recorded."""
    have = {'PalWorkPriority/' + n: h for n, h in manifest(q / 'PalWorkPriority').items()} \
        if (q / 'PalWorkPriority').is_dir() else {}
    pak = q / 'LogicMods' / 'PalWorkPriority.pak'
    if pak.is_file():
        have['LogicMods/PalWorkPriority.pak'] = sha(pak)
    if (q / 'mods.txt.orig').is_file():
        have['mods.txt'] = sha(q / 'mods.txt.orig')
    bad = sorted(n for n in set(want) | set(have) if want.get(n) != have.get(n))
    if bad:
        die('the quarantine folder %s does not match its manifest, nothing was moved: %s'
            % (q, ', '.join(bad[:10])))


def restore(q):
    q = Path(q)
    if MOD.exists() or PAK.exists():
        die('the mod is already present (%s or %s); nothing was moved' % (MOD, PAK))
    want = recorded(q)
    check_quarantine(q, want)
    shutil.move(str(q / 'PalWorkPriority'), str(MOD))
    shutil.move(str(q / 'LogicMods' / 'PalWorkPriority.pak'), str(PAK))
    (MODS / 'mods.txt').write_bytes((q / 'mods.txt.orig').read_bytes())
    bad = 0
    for name, h in sorted(want.items()):
        path = (MODS / name) if name.startswith('PalWorkPriority/') else (PAK if name.startswith('LogicMods/') else MODS / 'mods.txt')
        if not path.is_file() or sha(path) != h:
            bad += 1
            print('MISMATCH', name)
    print('restored; %d hash mismatches' % bad)
    sys.exit(1 if bad else 0)


def main(argv):
    closed()
    if argv[:1] == ['remove']:
        remove()
    elif argv[:1] == ['restore'] and len(argv) == 2:
        restore(argv[1])
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main(sys.argv[1:])
