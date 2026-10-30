"""G1 Workshop route: 0.4.1 installed by the game's own mod loader, then updated.

Phases (game closed for every phase):
  prepare            back up PalModSettings.ini, mods.txt, the Workshop item and
                     ManagedMods; move the dev install aside; activate the
                     Workshop item (ActiveModList=PalWorkPriority)
  seed <041-dir>     after the loader installed 0.4.1: put 0.4.1-written
                     priorities.txt/caps.txt in place and mark Scripts/config.lua
                     (interval_seconds = 11) like a user edit
  update <zip> [--sha256 H]
                     replace the Workshop item's files with the 0.5.0 Workshop
                     archive, as a Steam update would (.workshop.json kept).
                     The archive is checked first like g7_install_matrix.py
                     does: its release manifest's hash and tag v<V>, or
                     --sha256 for an archive without a manifest.
  check              compare rows and config after the 0.5.0 launch
  restore            undo everything (dev install, pak, PalModSettings.ini,
                     mods.txt, the Workshop item and ManagedMods) and verify
                     the hashes. The backup is checked first; nothing moves
                     when it does not match. A second restore only reports:
                     the dev install is back in the game already.
State lives in D:/PalWorkPriority-backups/g1-workshop-<time>/ (path printed by
prepare, passed back with --state).

Every guard is an explicit check that exits with a message, so python -O
cannot switch one off.
"""
import hashlib, json, shutil, subprocess, sys, time, zipfile
from pathlib import Path

import g7_install_matrix

GAME = Path('D:/Steam/steamapps/common/Palworld')
MODS = GAME / 'Mods/NativeMods/UE4SS/Mods'
MOD = MODS / 'PalWorkPriority'
PAK = GAME / 'Pal/Content/Paks/LogicMods/PalWorkPriority.pak'
SETTINGS = GAME / 'Mods/PalModSettings.ini'
MANAGED = GAME / 'Mods/ManagedMods'
WS = Path('D:/Steam/steamapps/workshop/content/1623730/3786408856')
BACKUPS = Path('D:/PalWorkPriority-backups')
GAME_EXE = 'Palworld-Win64-Shipping'


def die(message):
    """Stop with a message and exit code 1 (instead of assert, which python -O
    removes)."""
    raise SystemExit('g1_workshop_route: ' + message)


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def tree(root):
    root = Path(root)
    return {str(p.relative_to(root)).replace('\\', '/'): sha(p) for p in root.rglob('*') if p.is_file()}


def closed():
    """Refuse every phase while the game runs."""
    r = subprocess.run(['tasklist', '/FI', 'IMAGENAME eq %s.exe' % GAME_EXE], capture_output=True, text=True)
    if r.returncode != 0:
        die('tasklist failed, so the game cannot be confirmed closed: %s' % (r.stderr or '').strip())
    if GAME_EXE in r.stdout:  # tasklist truncates the name, so match the stem
        die('close the game first (%s is running)' % GAME_EXE)


def rows(path):
    if not Path(path).exists():
        return None
    return sorted(l for l in Path(path).read_text(encoding='utf-8', errors='replace').splitlines()
                  if l.strip() and not l.startswith('#'))


def prepare():
    # Checked before anything is copied or moved.
    if b'ActiveModList=PalWorkPriority' in SETTINGS.read_bytes():
        die('PalModSettings.ini already activates the Workshop item; restore an earlier run first')
    b = BACKUPS / time.strftime('g1-workshop-%Y%m%d-%H%M%S')
    b.mkdir(parents=True)
    for src, name in [(SETTINGS, 'PalModSettings.ini'), (MODS / 'mods.txt', 'mods.txt')]:
        shutil.copy2(src, b / name)
    shutil.copytree(WS, b / 'workshop-3786408856')
    shutil.copytree(MANAGED, b / 'ManagedMods')
    state = {'dev_tree': tree(MOD), 'pak': sha(PAK), 'workshop_tree': tree(WS), 'managed_tree': tree(MANAGED)}
    shutil.move(str(MOD), str(b / 'dev-PalWorkPriority'))
    (b / 'dev-LogicMods').mkdir()
    shutil.move(str(PAK), str(b / 'dev-LogicMods/PalWorkPriority.pak'))
    text = SETTINGS.read_bytes()
    nl = b'\r\n' if b'\r\n' in text else b'\n'
    SETTINGS.write_bytes(text.rstrip(b'\r\n') + nl + b'ActiveModList=PalWorkPriority' + nl)
    (b / 'state.json').write_text(json.dumps(state))
    print(b)


def seed(b, src):
    src = Path(src)
    if not MOD.is_dir():
        die('the loader has not installed the Workshop item yet')
    for name in ('priorities.txt', 'caps.txt'):
        shutil.copy2(src / name, MOD / name)
    cfg = MOD / 'Scripts/config.lua'
    text = cfg.read_text(encoding='utf-8')
    if 'interval_seconds = 10' not in text:
        die('unexpected 0.4.1 config (no interval_seconds = 10)')
    cfg.write_text(text.replace('interval_seconds = 10', 'interval_seconds = 11', 1), encoding='utf-8')
    state = json.loads((b / 'state.json').read_text())
    state['seeded'] = {n: rows(MOD / n) for n in ('priorities.txt', 'caps.txt')}
    state['installed_041'] = tree(MOD)
    (b / 'state.json').write_text(json.dumps(state))
    print('seeded %d priority rows, %d limit rows; config marker interval_seconds = 11'
          % (len(state['seeded']['priorities.txt']), len(state['seeded']['caps.txt'])))


def update(b, archive, expected=None):
    # The release hash, tag v<V> and every member's CRC are checked before
    # the Workshop folder is deleted (round 4, 2026-10-30: none of that was).
    load_state(b, 'update')
    g7_install_matrix.checked_archive(archive, 'workshop', expected)
    meta = WS / '.workshop.json'
    if not meta.is_file():
        die('the Workshop item has no .workshop.json (%s); nothing was changed' % meta)
    keep = meta.read_bytes()
    shutil.rmtree(WS)
    WS.mkdir()
    with zipfile.ZipFile(archive) as z:
        z.extractall(WS)
    (WS / '.workshop.json').write_bytes(keep)
    print('Workshop item now holds', json.loads((WS / 'Info.json').read_text())['Version'])


def load_state(b, command):
    if b is None:
        die('%s needs --state <the folder prepare printed>' % command)
    b = Path(b)
    try:
        return json.loads((b / 'state.json').read_text())
    except FileNotFoundError:
        die('no state.json in %s; not a prepare backup' % b)
    except ValueError as err:
        die('state.json in %s is unreadable (%s)' % (b, err))


def check(b):
    state = load_state(b, 'check')
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


def restored(state, managed):
    """The game holds what prepare recorded."""
    return (MOD.is_dir() and tree(MOD) == state['dev_tree'] and PAK.is_file() and sha(PAK) == state['pak']
            and WS.is_dir() and tree(WS) == state['workshop_tree'] and MANAGED.is_dir() and tree(MANAGED) == managed)


def restore(b):
    state = load_state(b, 'restore')
    b = Path(b)
    dev = b / 'dev-PalWorkPriority'
    managed = state.get('managed_tree')  # states before 2026-10-30 lack it
    if managed is None and (b / 'ManagedMods').is_dir():
        managed = tree(b / 'ManagedMods')
    if not dev.exists():
        # Restored already: the dev install is the game's again. Moving it
        # into after/ now would take it out of the game.
        ok = restored(state, managed)
        print('already restored (no dev-PalWorkPriority in %s); nothing was moved. '
              'Dev install, pak, Workshop item and ManagedMods identical: %s' % (b, ok))
        sys.exit(0 if ok else 1)
    problems = []
    if tree(dev) != state['dev_tree']:
        problems.append('dev-PalWorkPriority differs from the recorded tree')
    backup_pak = b / 'dev-LogicMods/PalWorkPriority.pak'
    if not backup_pak.is_file() or sha(backup_pak) != state['pak']:
        problems.append('dev-LogicMods/PalWorkPriority.pak is missing or differs')
    ws = b / 'workshop-3786408856'
    if not ws.is_dir() or tree(ws) != state['workshop_tree']:
        problems.append('workshop-3786408856 is missing or differs')
    if not (b / 'ManagedMods').is_dir() or tree(b / 'ManagedMods') != managed:
        problems.append('ManagedMods is missing or differs')
    for name in ('PalModSettings.ini', 'mods.txt'):
        if not (b / name).is_file():
            problems.append('%s is missing' % name)
    if problems:
        die('the backup in %s does not match its state.json, nothing was moved: %s' % (b, '; '.join(problems)))
    # A new folder per run: an earlier after/ is never merged into.
    after = b / time.strftime('after-%Y%m%d-%H%M%S')
    after.mkdir()
    if MOD.exists():
        shutil.move(str(MOD), str(after / 'PalWorkPriority'))
    if PAK.exists():
        shutil.move(str(PAK), str(after / 'PalWorkPriority.pak'))
    # The loader installs its copy into ManagedMods: keep the whole folder as
    # it is now and put the backup back.
    if MANAGED.exists():
        shutil.move(str(MANAGED), str(after / 'ManagedMods'))
    shutil.copytree(b / 'ManagedMods', MANAGED)
    shutil.move(str(dev), str(MOD))
    shutil.move(str(backup_pak), str(PAK))
    shutil.copy2(b / 'PalModSettings.ini', SETTINGS)
    shutil.copy2(b / 'mods.txt', MODS / 'mods.txt')
    if WS.exists():
        shutil.move(str(WS), str(after / 'workshop-3786408856'))
    shutil.copytree(ws, WS)
    ok = restored(state, managed)
    print('restored; dev install, pak, Workshop item and ManagedMods identical: %s (the replaced copies are in %s)'
          % (ok, after))
    sys.exit(0 if ok else 1)


def main(argv):
    if not argv:
        sys.exit(__doc__)
    closed()
    cmd = argv[0]
    st = g7_install_matrix.option(argv, '--state')
    st = Path(st) if st else None
    if cmd in ('seed', 'update') and (len(argv) < 2 or argv[1].startswith('--')):
        die('%s needs an argument' % cmd)
    if cmd == 'prepare':
        prepare()
    elif cmd == 'seed':
        load_state(st, 'seed')
        seed(st, argv[1])
    elif cmd == 'update':
        update(st, argv[1], g7_install_matrix.option(argv, '--sha256'))
    elif cmd == 'check':
        check(st)
    elif cmd == 'restore':
        restore(st)
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main(sys.argv[1:])
