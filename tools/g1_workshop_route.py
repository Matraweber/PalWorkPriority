"""G1 Workshop route: 0.4.1 installed by the game's own mod loader, then updated.

Phases (game closed for every phase):
  prepare            back up PalModSettings.ini, mods.txt, the Workshop item and
                     ManagedMods; move the dev install aside; activate the
                     Workshop item (ActiveModList=PalWorkPriority)
  seed <041-dir>     after the loader installed 0.4.1: put 0.4.1-written
                     priorities.txt/caps.txt in place and mark Scripts/config.lua
                     (interval_seconds = 11) like a user edit
  update <zip>       replace the Workshop item's files with the 0.5.0 Workshop
                     archive, as a Steam update would (.workshop.json kept)
  check              compare rows and config after the 0.5.0 launch
  restore            undo everything and verify the dev install's hashes
State lives in D:/PalWorkPriority-backups/g1-workshop-<time>/ (path printed by
prepare, passed back with --state).
"""
import hashlib, json, shutil, subprocess, sys, time, zipfile
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
    assert 'Palworld-Win64-Shipping.exe' not in out, 'close the game first'


def rows(path):
    if not Path(path).exists():
        return None
    return sorted(l for l in Path(path).read_text(encoding='utf-8', errors='replace').splitlines()
                  if l.strip() and not l.startswith('#'))


def prepare():
    b = Path('D:/PalWorkPriority-backups') / time.strftime('g1-workshop-%Y%m%d-%H%M%S')
    b.mkdir(parents=True)
    for src, name in [(SETTINGS, 'PalModSettings.ini'), (MODS / 'mods.txt', 'mods.txt')]:
        shutil.copy2(src, b / name)
    shutil.copytree(WS, b / 'workshop-3786408856')
    shutil.copytree(MANAGED, b / 'ManagedMods')
    state = {'dev_tree': tree(MOD), 'pak': sha(PAK), 'workshop_tree': tree(WS)}
    shutil.move(str(MOD), str(b / 'dev-PalWorkPriority'))
    (b / 'dev-LogicMods').mkdir()
    shutil.move(str(PAK), str(b / 'dev-LogicMods/PalWorkPriority.pak'))
    text = SETTINGS.read_bytes()
    nl = b'\r\n' if b'\r\n' in text else b'\n'
    assert b'ActiveModList=PalWorkPriority' not in text
    SETTINGS.write_bytes(text.rstrip(b'\r\n') + nl + b'ActiveModList=PalWorkPriority' + nl)
    (b / 'state.json').write_text(json.dumps(state))
    print(b)


def seed(b, src):
    src = Path(src)
    assert MOD.is_dir(), 'the loader has not installed the Workshop item yet'
    for name in ('priorities.txt', 'caps.txt'):
        shutil.copy2(src / name, MOD / name)
    cfg = MOD / 'Scripts/config.lua'
    text = cfg.read_text(encoding='utf-8')
    assert 'interval_seconds = 10' in text, 'unexpected 0.4.1 config'
    cfg.write_text(text.replace('interval_seconds = 10', 'interval_seconds = 11', 1), encoding='utf-8')
    state = json.loads((b / 'state.json').read_text())
    state['seeded'] = {n: rows(MOD / n) for n in ('priorities.txt', 'caps.txt')}
    state['installed_041'] = tree(MOD)
    (b / 'state.json').write_text(json.dumps(state))
    print('seeded %d priority rows, %d limit rows; config marker interval_seconds = 11'
          % (len(state['seeded']['priorities.txt']), len(state['seeded']['caps.txt'])))


def update(b, archive):
    keep = (WS / '.workshop.json').read_bytes()
    shutil.rmtree(WS)
    WS.mkdir()
    zipfile.ZipFile(archive).extractall(WS)
    (WS / '.workshop.json').write_bytes(keep)
    print('Workshop item now holds', json.loads((WS / 'Info.json').read_text())['Version'])


def check(b):
    state = json.loads((b / 'state.json').read_text())
    out = {}
    for n in ('priorities.txt', 'caps.txt'):
        now = rows(MOD / n)
        out[n] = 'identical' if now == state['seeded'][n] else ('MISSING' if now is None else 'DIFFERS (%d vs %d rows)' % (len(now), len(state['seeded'][n])))
    root_cfg = MOD / 'config.lua'
    out['root config.lua'] = ('interval_seconds = 11' in root_cfg.read_text(encoding='utf-8')) if root_cfg.exists() else 'MISSING'
    out['Scripts/config.lua still present'] = (MOD / 'Scripts/config.lua').exists()
    out['config.migration.bak'] = (MOD / 'config.migration.bak').exists()
    info = json.loads((MANAGED / 'PalWorkPriority/Info.json').read_text()) if (MANAGED / 'PalWorkPriority/Info.json').exists() else {}
    out['loader installed version'] = info.get('Version')
    print(json.dumps(out, indent=1))


def restore(b):
    state = json.loads((b / 'state.json').read_text())
    after = b / 'after'
    after.mkdir(exist_ok=True)
    if MOD.exists():
        shutil.move(str(MOD), str(after / 'PalWorkPriority'))
    if PAK.exists():
        shutil.move(str(PAK), str(after / 'PalWorkPriority.pak'))
    if (MANAGED / 'PalWorkPriority').exists():
        shutil.move(str(MANAGED / 'PalWorkPriority'), str(after / 'ManagedMods-PalWorkPriority'))
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
    elif cmd == 'seed':
        seed(st, sys.argv[2])
    elif cmd == 'update':
        update(st, sys.argv[2])
    elif cmd == 'check':
        check(st)
    elif cmd == 'restore':
        restore(st)
    else:
        sys.exit(__doc__)
