"""Remove or restore PalWorkPriority for mod-absent frame captures (G5).

Usage (game must be closed):
  python -B tools/mod_absent.py remove   -> prints the quarantine folder
  python -B tools/mod_absent.py restore <quarantine folder>
remove moves the mod folder and LogicMods/PalWorkPriority.pak to
D:/PalWorkPriority-backups/g5-absent-<time>/ with a SHA-256 manifest and sets
the mods.txt entry to 0 byte-exactly (the file is CRLF; sed would rewrite it).
restore moves both back, restores mods.txt and verifies every hash.
Procedure: docs/testing.md "Mod-absent baseline"; first used 2026-10-19.
"""
import hashlib, os, shutil, subprocess, sys, time
from pathlib import Path

GAME = Path('D:/Steam/steamapps/common/Palworld')
MODS = GAME / 'Mods/NativeMods/UE4SS/Mods'
MOD = MODS / 'PalWorkPriority'
PAK = GAME / 'Pal/Content/Paks/LogicMods/PalWorkPriority.pak'
LINE_ON, LINE_OFF = b'PalWorkPriority : 1\r\n', b'PalWorkPriority : 0\r\n'


def sha(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def game_running():
    out = subprocess.run(['tasklist', '/FI', 'IMAGENAME eq Palworld-Win64-Shipping.exe'],
                         capture_output=True, text=True).stdout
    return 'Palworld-Win64-Shipping.exe' in out


def manifest(root):
    return {str(p.relative_to(root)).replace('\\', '/'): sha(p) for p in root.rglob('*') if p.is_file()}


def remove():
    q = Path('D:/PalWorkPriority-backups') / time.strftime('g5-absent-%Y%m%d-%H%M%S')
    q.mkdir(parents=True)
    mods_txt = (MODS / 'mods.txt').read_bytes()
    assert mods_txt.count(LINE_ON) == 1, 'mods.txt has no single enabled PalWorkPriority line'
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


def restore(q):
    q = Path(q)
    assert not MOD.exists() and not PAK.exists(), 'mod is already present'
    shutil.move(str(q / 'PalWorkPriority'), str(MOD))
    shutil.move(str(q / 'LogicMods' / 'PalWorkPriority.pak'), str(PAK))
    (MODS / 'mods.txt').write_bytes((q / 'mods.txt.orig').read_bytes())
    bad = 0
    for line in (q / 'manifest.sha256').read_text().splitlines():
        h, name = line.split('  ', 1)
        path = (MODS / name) if name.startswith('PalWorkPriority/') else (PAK if name.startswith('LogicMods/') else MODS / 'mods.txt')
        if sha(path) != h:
            bad += 1
            print('MISMATCH', name)
    print('restored; %d hash mismatches' % bad)
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    assert not game_running(), 'close the game first'
    if sys.argv[1] == 'remove':
        remove()
    elif sys.argv[1] == 'restore':
        restore(sys.argv[2])
    else:
        sys.exit(__doc__)
