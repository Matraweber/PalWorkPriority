"""G7 install checks: clean manual install, clean Workshop install, and a manual
install while the Workshop item is active. Reversible; game closed for every step.

  prepare                      back up and move the dev install aside
  manual <manual.zip> [--sha256 H]
                               extract the manual archive into the game root.
                               The archive must match the manual sha256 in the
                               release manifest next to it
                               (PalWorkPriority-<V>-release.json); an archive
                               without one (the 0.4.1 Nexus zip) needs --sha256.
  workshop-content <zip>       put an archive's files into the Workshop item
  workshop on|off              add/remove ActiveModList=PalWorkPriority
  wipe                         remove whatever PalWorkPriority install exists
  status                       report what is installed and from where
  restore --state <folder>     undo everything, verify hashes. The backup is
                               checked against its state.json first; nothing
                               is wiped or replaced when it does not match.
State: D:/PalWorkPriority-backups/g7-install-<time>/ (printed by prepare,
passed back with --state).

Every guard is an explicit check that exits with a message, so python -O
cannot switch one off.
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
BACKUPS = Path('D:/PalWorkPriority-backups')
GAME_EXE = 'Palworld-Win64-Shipping'


def die(message):
    """Stop with a message and exit code 1 (instead of assert, which python -O
    removes)."""
    raise SystemExit('g7_install_matrix: ' + message)


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def tree(root):
    root = Path(root)
    return {str(p.relative_to(root)).replace('\\', '/'): sha(p) for p in root.rglob('*') if p.is_file()}


def closed():
    """Refuse every step while the game runs."""
    r = subprocess.run(['tasklist', '/FI', 'IMAGENAME eq %s.exe' % GAME_EXE], capture_output=True, text=True)
    if r.returncode != 0:
        die('tasklist failed, so the game cannot be confirmed closed: %s' % (r.stderr or '').strip())
    if GAME_EXE in r.stdout:  # tasklist truncates the name, so match the stem
        die('close the game first (%s is running)' % GAME_EXE)


def prepare():
    b = BACKUPS / time.strftime('g7-install-%Y%m%d-%H%M%S')
    b.mkdir(parents=True)
    shutil.copy2(SETTINGS, b / 'PalModSettings.ini')
    shutil.copy2(MODS / 'mods.txt', b / 'mods.txt')
    shutil.copytree(WS, b / 'workshop-3786408856')
    shutil.copytree(MANAGED, b / 'ManagedMods')
    state = {'dev_tree': tree(MOD), 'pak': sha(PAK), 'workshop_tree': tree(WS),
             'settings': sha(SETTINGS), 'mods_txt': sha(MODS / 'mods.txt')}
    shutil.move(str(MOD), str(b / 'dev-PalWorkPriority'))
    (b / 'dev-LogicMods').mkdir()
    shutil.move(str(PAK), str(b / 'dev-LogicMods/PalWorkPriority.pak'))
    (b / 'state.json').write_text(json.dumps(state))
    print(b)


def release_sha256(archive, kind):
    """The sha256 the release manifest next to the archive lists for it, or
    None when there is no manifest."""
    m = re.fullmatch(r'PalWorkPriority-(.+)-%s\.zip' % kind, archive.name)
    if not m:
        return None
    manifest = archive.parent / ('PalWorkPriority-%s-release.json' % m.group(1))
    if not manifest.is_file():
        return None
    try:
        entry = json.loads(manifest.read_text(encoding='utf-8'))['archives'][kind]
    except (ValueError, KeyError, TypeError) as err:
        die('the release manifest %s has no readable %s entry (%s)' % (manifest, kind, err))
    if entry.get('file') != archive.name:
        die('the release manifest %s lists %r, not %s' % (manifest, entry.get('file'), archive.name))
    return entry.get('sha256')


def manual(archive, expected=None):
    archive = Path(archive)
    if not archive.is_file():
        die('archive not found: %s' % archive)
    listed = release_sha256(archive, 'manual')
    if listed is None and expected is None:
        die('no release manifest next to %s; pass --sha256 <hash> for an archive without one' % archive.name)
    if listed is not None and expected is not None and expected.lower() != listed:
        die('--sha256 differs from the release manifest for %s' % archive.name)
    want = (expected or listed).lower()
    actual = sha(archive)
    if actual != want:
        die('%s has sha256 %s, expected %s (%s): not the archive that was built'
            % (archive.name, actual[:12], want[:12], 'release manifest' if listed else '--sha256'))
    z = zipfile.ZipFile(archive)
    names = [n for n in z.namelist() if not n.endswith('/')]
    z.extractall(GAME)
    print('extracted %d files of %s (sha256 %s) into the game root' % (len(names), archive.name, actual[:12]))


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


def verify_backup(b):
    """The backup folder holds exactly what prepare recorded. Runs before
    restore wipes or replaces anything; returns the state."""
    if b is None:
        die('restore needs --state <the folder prepare printed>')
    b = Path(b)
    if not (b / 'state.json').is_file():
        die('no state.json in %s; not a prepare backup' % b)
    try:
        state = json.loads((b / 'state.json').read_text())
        dev_tree, pak, workshop_tree = state['dev_tree'], state['pak'], state['workshop_tree']
    except (ValueError, KeyError, TypeError) as err:
        die('state.json in %s is unreadable (%s)' % (b, err))
    problems = []
    dev = b / 'dev-PalWorkPriority'
    if not dev.is_dir():
        problems.append('dev-PalWorkPriority is missing')
    elif tree(dev) != dev_tree:
        problems.append('dev-PalWorkPriority differs from the recorded tree')
    backup_pak = b / 'dev-LogicMods/PalWorkPriority.pak'
    if not backup_pak.is_file():
        problems.append('dev-LogicMods/PalWorkPriority.pak is missing')
    elif sha(backup_pak) != pak:
        problems.append('dev-LogicMods/PalWorkPriority.pak differs from the recorded hash')
    ws = b / 'workshop-3786408856'
    if not ws.is_dir():
        problems.append('workshop-3786408856 is missing')
    elif tree(ws) != workshop_tree:
        problems.append('workshop-3786408856 differs from the recorded tree')
    for name, key in (('PalModSettings.ini', 'settings'), ('mods.txt', 'mods_txt')):
        if not (b / name).is_file():
            problems.append('%s is missing' % name)
        elif key in state and sha(b / name) != state[key]:  # states before 2026-10-29 lack these
            problems.append('%s differs from the recorded hash' % name)
    if problems:
        die('the backup in %s does not match its state.json, nothing was changed: %s' % (b, '; '.join(problems)))
    return state


def restore(b):
    state = verify_backup(b)
    b = Path(b)
    wipe()
    # The loader renames a pak it did not install to <name>-<time>.pak.bak
    # before writing its own (scenario B, 2026-10-20); keep those with the state.
    for stray in PAK.parent.glob('PalWorkPriority-*.pak.bak'):
        shutil.move(str(stray), str(b / stray.name))
        print('moved loader backup', stray.name, 'into the state folder')
    shutil.move(str(b / 'dev-PalWorkPriority'), str(MOD))
    shutil.move(str(b / 'dev-LogicMods/PalWorkPriority.pak'), str(PAK))
    shutil.copy2(b / 'PalModSettings.ini', SETTINGS)
    shutil.copy2(b / 'mods.txt', MODS / 'mods.txt')
    if WS.exists():
        shutil.rmtree(WS)
    shutil.copytree(b / 'workshop-3786408856', WS)
    ok = tree(MOD) == state['dev_tree'] and sha(PAK) == state['pak'] and tree(WS) == state['workshop_tree']
    print('restored; dev install, pak and Workshop item identical:', ok)
    sys.exit(0 if ok else 1)


def option(argv, name):
    if name not in argv:
        return None
    i = argv.index(name)
    if i + 1 >= len(argv):
        die('%s needs a value' % name)
    return argv[i + 1]


def main(argv):
    if not argv:
        sys.exit(__doc__)
    closed()
    cmd = argv[0]
    st = option(argv, '--state')
    st = Path(st) if st else None
    if cmd in ('manual', 'workshop-content', 'workshop') and len(argv) < 2:
        die('%s needs an argument' % cmd)
    if cmd == 'prepare':
        prepare()
    elif cmd == 'wipe':
        wipe()
    elif cmd == 'status':
        status()
    elif cmd == 'manual':
        manual(argv[1], option(argv, '--sha256'))
    elif cmd == 'workshop-content':
        workshop_content(argv[1])
    elif cmd == 'workshop':
        if argv[1] not in ('on', 'off'):
            die('workshop takes on or off')
        workshop(argv[1] == 'on')
    elif cmd == 'restore':
        restore(st)
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main(sys.argv[1:])
