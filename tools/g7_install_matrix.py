"""G7 install checks: clean manual install, clean Workshop install, and a manual
install while the Workshop item is active. Reversible; game closed for every step.

  prepare                      back up and move the dev install aside
  manual <manual.zip>          extract the manual archive into the game root
  workshop-content <zip>       put an archive's files into the Workshop item
  workshop on|off              add/remove ActiveModList=PalWorkPriority
  wipe                         remove whatever PalWorkPriority install exists
  status                       report what is installed and from where
  restore                      undo everything, verify hashes
State: D:/PalWorkPriority-backups/g7-install-<time>/ (printed by prepare,
passed back with --state).
"""
import hashlib, json, re, shutil, subprocess, sys, time, zipfile
from pathlib import Path

GAME = Path('D:/Steam/steamapps/common/Palworld')
MODS = GAME / 'Mods/NativeMods/UE4SS/Mods'
MOD = MODS / 'PalWorkPriority'
PAK = GAME / 'Pal/Content/Paks/LogicMods/PalWorkPriority.pak'
SETTINGS = GAME / 'Mods/PalModSettings.ini'
MANAGED = GAME / 'Mods/ManagedMods'
WS = Path('D:/Steam/steamapps/workshop/content/1623730/3786408856')


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def tree(root):
    root = Path(root)
    return {str(p.relative_to(root)).replace('\\', '/'): sha(p) for p in root.rglob('*') if p.is_file()}


def closed():
    out = subprocess.run(['tasklist', '/FI', 'IMAGENAME eq Palworld-Win64-Shipping.exe'], capture_output=True, text=True).stdout
    assert 'Palworld-Win64-Shipping' not in out, 'close the game first'  # tasklist truncates the name


def prepare():
    b = Path('D:/PalWorkPriority-backups') / time.strftime('g7-install-%Y%m%d-%H%M%S')
    b.mkdir(parents=True)
    shutil.copy2(SETTINGS, b / 'PalModSettings.ini')
    shutil.copy2(MODS / 'mods.txt', b / 'mods.txt')
    shutil.copytree(WS, b / 'workshop-3786408856')
    shutil.copytree(MANAGED, b / 'ManagedMods')
    state = {'dev_tree': tree(MOD), 'pak': sha(PAK), 'workshop_tree': tree(WS)}
    shutil.move(str(MOD), str(b / 'dev-PalWorkPriority'))
    (b / 'dev-LogicMods').mkdir()
    shutil.move(str(PAK), str(b / 'dev-LogicMods/PalWorkPriority.pak'))
    (b / 'state.json').write_text(json.dumps(state))
    print(b)


def manual(archive):
    z = zipfile.ZipFile(archive)
    names = [n for n in z.namelist() if not n.endswith('/')]
    z.extractall(GAME)
    print('extracted %d files into the game root' % len(names))


def workshop_content(archive):
    keep = (WS / '.workshop.json').read_bytes()
    shutil.rmtree(WS)
    WS.mkdir()
    zipfile.ZipFile(archive).extractall(WS)
    (WS / '.workshop.json').write_bytes(keep)
    print('Workshop item holds', json.loads((WS / 'Info.json').read_text())['Version'])


def workshop(on):
    text = SETTINGS.read_bytes()
    nl = b'\r\n' if b'\r\n' in text else b'\n'
    line = b'ActiveModList=PalWorkPriority'
    lines = [l for l in text.splitlines() if l.strip() != line]
    if on:
        lines.append(line)
    SETTINGS.write_bytes(nl.join(lines) + nl)
    print('Workshop item', 'active' if on else 'inactive')


def wipe():
    for p in (MOD, MANAGED / 'PalWorkPriority'):
        if p.exists():
            shutil.rmtree(p)
    if PAK.exists():
        PAK.unlink()
    print('no PalWorkPriority install left')


def status():
    out = {}
    main = MOD / 'Scripts/main.lua'
    if main.exists():
        m = re.search(r'VERSION\s*=\s*"([^"]+)"', main.read_text(encoding='utf-8', errors='replace'))
        out['installed Lua version'] = m.group(1) if m else '?'
        out['installed files'] = len(tree(MOD))
    else:
        out['installed Lua version'] = None
    out['pak'] = sha(PAK)[:12] if PAK.exists() else None
    info = MANAGED / 'PalWorkPriority/Info.json'
    out['loader-managed version'] = json.loads(info.read_text())['Version'] if info.exists() else None
    out['Workshop item version'] = json.loads((WS / 'Info.json').read_text())['Version']
    out['Workshop active'] = b'ActiveModList=PalWorkPriority' in SETTINGS.read_bytes()
    out['data files'] = sorted(p.name for p in MOD.glob('*') if p.is_file()) if MOD.exists() else []
    print(json.dumps(out, indent=1))


def restore(b):
    state = json.loads((b / 'state.json').read_text())
    wipe()
    shutil.move(str(b / 'dev-PalWorkPriority'), str(MOD))
    shutil.move(str(b / 'dev-LogicMods/PalWorkPriority.pak'), str(PAK))
    shutil.copy2(b / 'PalModSettings.ini', SETTINGS)
    shutil.copy2(b / 'mods.txt', MODS / 'mods.txt')
    shutil.rmtree(WS)
    shutil.copytree(b / 'workshop-3786408856', WS)
    ok = tree(MOD) == state['dev_tree'] and sha(PAK) == state['pak'] and tree(WS) == state['workshop_tree']
    print('restored; dev install, pak and Workshop item identical:', ok)
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    closed()
    cmd = sys.argv[1]
    st = Path(sys.argv[sys.argv.index('--state') + 1]) if '--state' in sys.argv else None
    if cmd == 'prepare':
        prepare()
    elif cmd == 'wipe':
        wipe()
    elif cmd == 'status':
        status()
    elif cmd == 'manual':
        manual(sys.argv[2])
    elif cmd == 'workshop-content':
        workshop_content(sys.argv[2])
    elif cmd == 'workshop':
        workshop(sys.argv[2] == 'on')
    elif cmd == 'restore':
        restore(st)
    else:
        sys.exit(__doc__)
