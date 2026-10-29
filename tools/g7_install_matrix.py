"""G7 install checks: clean manual install, clean Workshop install, and a manual
install while the Workshop item is active. Reversible; game closed for every step.

  prepare                      back up and move the dev install aside
  manual <manual.zip> [--sha256 H]
                               extract the manual archive into the game root
  workshop-content <workshop.zip> [--sha256 H]
                               replace the Workshop item's files with the
                               archive's (.workshop.json kept)
  workshop on|off              add/remove ActiveModList=PalWorkPriority
  wipe --state <folder>        remove whatever PalWorkPriority install exists;
                               refused unless the prepare backup in <folder>
                               matches its state.json (it holds the dev install)
  status                       report what is installed and from where
  restore --state <folder>     put back the dev install, pak, settings,
                               mods.txt, ManagedMods and the Workshop item,
                               and verify their hashes. The backup is checked
                               against its state.json first; nothing is wiped
                               or replaced when it does not match. An
                               INSTALL.txt a manual archive left in the game
                               root is moved into the state folder.
State: D:/PalWorkPriority-backups/g7-install-<time>/ (printed by prepare,
passed back with --state).

Both archive commands run the same check before anything is changed. With a
release manifest next to the archive (PalWorkPriority-<V>-release.json, as
tools/release.py writes it), the archive's sha256 must be the one listed and
the manifest's source_commit must be the commit tag v<V> points at in this
repository: a moved-aside older build is refused. An archive without a
manifest (the 0.4.1 Nexus zip) needs --sha256. The zip is then read in full
(every member's CRC) before the game or Workshop folder is touched.

Every guard is an explicit check that exits with a message, so python -O
cannot switch one off.
"""
import hashlib, json, re, shutil, subprocess, sys, time, zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
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
    install_txt = GAME / 'INSTALL.txt'
    state = {'dev_tree': tree(MOD), 'pak': sha(PAK), 'workshop_tree': tree(WS),
             'settings': sha(SETTINGS), 'mods_txt': sha(MODS / 'mods.txt'), 'managed_tree': tree(MANAGED),
             'install_txt': sha(install_txt) if install_txt.is_file() else None}
    shutil.move(str(MOD), str(b / 'dev-PalWorkPriority'))
    (b / 'dev-LogicMods').mkdir()
    shutil.move(str(PAK), str(b / 'dev-LogicMods/PalWorkPriority.pak'))
    (b / 'state.json').write_text(json.dumps(state))
    print(b)


def release_entry(archive, kind):
    """(version, manifest, entry) from the release manifest next to the
    archive, or None when there is no manifest."""
    m = re.fullmatch(r'PalWorkPriority-(.+)-%s\.zip' % kind, archive.name)
    if not m:
        return None
    manifest_path = archive.parent / ('PalWorkPriority-%s-release.json' % m.group(1))
    if not manifest_path.is_file():
        return None
    try:
        manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
        entry = manifest['archives'][kind]
        entry.get('file')
    except (ValueError, KeyError, TypeError, AttributeError) as err:
        die('the release manifest %s has no readable %s entry (%s)' % (manifest_path, kind, err))
    if entry.get('file') != archive.name:
        die('the release manifest %s lists %r, not %s' % (manifest_path, entry.get('file'), archive.name))
    if manifest.get('version', m.group(1)) != m.group(1):
        die('the release manifest %s is for version %r, not %s' % (manifest_path, manifest.get('version'), m.group(1)))
    return m.group(1), manifest, entry


def tag_commit(version):
    """The commit tag v<version> points at in this repository."""
    r = subprocess.run(['git', '-C', str(REPO), 'rev-parse', '--verify', '--quiet', 'v%s^{commit}' % version],
                       capture_output=True, text=True)
    commit = (r.stdout or '').strip()
    if r.returncode != 0 or not commit:
        die('tag v%s does not exist in %s, so the archive cannot be tied to it' % (version, REPO))
    return commit


def checked_archive(archive, kind, expected=None):
    """The archive check both install routes share; it runs before anything
    is changed (module docstring). Returns the member file names."""
    archive = Path(archive)
    if not archive.is_file():
        die('archive not found: %s' % archive)
    release = release_entry(archive, kind)
    if release is None and expected is None:
        die('no release manifest next to %s; pass --sha256 <hash> for an archive without one' % archive.name)
    listed = str(release[2].get('sha256', '')).lower() if release else None
    if listed is not None and expected is not None and expected.lower() != listed:
        die('--sha256 differs from the release manifest for %s' % archive.name)
    want = listed if listed is not None else expected.lower()
    actual = sha(archive)
    if actual != want:
        die('%s has sha256 %s, expected %s (%s): not the archive that was built'
            % (archive.name, actual[:12], want[:12], 'release manifest' if release else '--sha256'))
    if release:
        version, manifest, _ = release
        built, tag = manifest.get('source_commit'), tag_commit(version)
        if built != tag:
            die('%s was built from %s, but tag v%s is %s: an older or moved-aside build. '
                'Use the build of the tag (tools/release.py writes build/release-%s)'
                % (archive, str(built)[:12], version, tag[:12], version))
        print('%s: sha256 %s, built from %s = tag v%s' % (archive.name, actual[:12], tag, version))
    else:
        print('%s: sha256 %s as given (no release manifest, not tied to a tag)' % (archive.name, actual[:12]))
    try:
        with zipfile.ZipFile(archive) as z:
            damaged = z.testzip()
            names = [n for n in z.namelist() if not n.endswith('/')]
    except (zipfile.BadZipFile, OSError) as err:
        die('%s cannot be read as a zip (%s); nothing was changed' % (archive, err))
    if damaged:
        die('%s: member %s is damaged; nothing was changed' % (archive, damaged))
    return names


def manual(archive, expected=None):
    names = checked_archive(archive, 'manual', expected)
    with zipfile.ZipFile(archive) as z:
        z.extractall(GAME)
    print('extracted %d files of %s into the game root' % (len(names), Path(archive).name))


def workshop_content(archive, expected=None):
    names = checked_archive(archive, 'workshop', expected)
    meta = WS / '.workshop.json'
    if not meta.is_file():
        die('the Workshop item has no .workshop.json (%s); nothing was changed' % meta)
    keep = meta.read_bytes()
    shutil.rmtree(WS)
    WS.mkdir()
    with zipfile.ZipFile(archive) as z:
        z.extractall(WS)
    (WS / '.workshop.json').write_bytes(keep)
    print('Workshop item holds %d files of %s, version %s'
          % (len(names), Path(archive).name, json.loads((WS / 'Info.json').read_text())['Version']))


def workshop(on):
    text = SETTINGS.read_bytes()
    nl = b'\r\n' if b'\r\n' in text else b'\n'
    line = b'ActiveModList=PalWorkPriority'
    lines = [l for l in text.splitlines() if l.strip() != line]
    if on:
        lines.append(line)
    SETTINGS.write_bytes(nl.join(lines) + nl)
    print('Workshop item', 'active' if on else 'inactive')


def remove_install():
    for p in (MOD, MANAGED / 'PalWorkPriority'):
        if p.exists():
            shutil.rmtree(p)
    if PAK.exists():
        PAK.unlink()
    print('no PalWorkPriority install left')


def wipe(b):
    """remove_install, only while a verified prepare backup holds the dev
    install: before prepare or after restore, MOD is the dev install itself."""
    verify_backup(b, 'wipe')
    remove_install()


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


def verify_backup(b, command='restore'):
    """The backup folder holds exactly what prepare recorded. Runs before
    restore or wipe deletes or replaces anything; returns the state."""
    if b is None:
        die('%s needs --state <the folder prepare printed>' % command)
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
    managed = b / 'ManagedMods'
    if not managed.is_dir():
        problems.append('ManagedMods is missing')
    elif 'managed_tree' in state and tree(managed) != state['managed_tree']:  # states before 2026-10-29 lack it
        problems.append('ManagedMods differs from the recorded tree')
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
    remove_install()
    # The loader renames a pak it did not install to <name>-<time>.pak.bak
    # before writing its own (scenario B, 2026-10-20); keep those with the state.
    for stray in PAK.parent.glob('PalWorkPriority-*.pak.bak'):
        shutil.move(str(stray), str(b / stray.name))
        print('moved loader backup', stray.name, 'into the state folder')
    # A manual archive puts INSTALL.txt into the game root; it is not part of
    # the install. Kept with the state, not deleted.
    install_txt = GAME / 'INSTALL.txt'
    if (install_txt.is_file() and sha(install_txt) != state.get('install_txt')
            and install_txt.read_bytes().startswith(b'Pal Work Priority ')):
        shutil.move(str(install_txt), str(b / 'INSTALL.txt-from-game-root'))
        print('moved the manual archive\'s INSTALL.txt from the game root into the state folder')
    shutil.move(str(b / 'dev-PalWorkPriority'), str(MOD))
    shutil.move(str(b / 'dev-LogicMods/PalWorkPriority.pak'), str(PAK))
    shutil.copy2(b / 'PalModSettings.ini', SETTINGS)
    shutil.copy2(b / 'mods.txt', MODS / 'mods.txt')
    # The loader may have changed ManagedMods during the matrix: keep that
    # copy with the state and put the backup back.
    if MANAGED.exists():
        shutil.move(str(MANAGED), str(b / time.strftime('ManagedMods-after-%Y%m%d-%H%M%S')))
    shutil.copytree(b / 'ManagedMods', MANAGED)
    if WS.exists():
        shutil.rmtree(WS)
    shutil.copytree(b / 'workshop-3786408856', WS)
    managed = state.get('managed_tree', tree(b / 'ManagedMods'))
    ok = (tree(MOD) == state['dev_tree'] and sha(PAK) == state['pak'] and tree(WS) == state['workshop_tree']
          and tree(MANAGED) == managed)
    print('restored; dev install, pak, Workshop item and ManagedMods identical:', ok)
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
        wipe(st)
    elif cmd == 'status':
        status()
    elif cmd == 'manual':
        manual(argv[1], option(argv, '--sha256'))
    elif cmd == 'workshop-content':
        workshop_content(argv[1], option(argv, '--sha256'))
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
