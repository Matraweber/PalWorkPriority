"""Upload a release to the Steam Workshop item with Pocketpair's Palworld Mod
Uploader (Steam app 4212470), the tool 0.4.1 was published with.

  prepare [--version V]      stage the Workshop archive and the change note
  upload [--dry-run|--submit]  drive the uploader (UI Automation)
  check [--version V]        after the upload: Steam's copy equals the stage
                             (default: the staged version)

prepare checks the archive against build/release-V/PalWorkPriority-V-release.json,
extracts it into D:/PalWorkPriority-workshop/stage/PalWorkPriority (an older
stage is moved aside, never deleted), writes the uploader's .workshop.json
(item 3786408856, last_published_version = the live version) and the change
note (the CHANGELOG section at tag vV as Steam BBCode, at most 8000
characters) next to the folder, not inside it: everything inside the folder
is uploaded.

The live version is the newest of the subscribed copy's Info.json Version and
the last_published_version the uploader recorded in earlier stages (it writes
that file after a successful upload, before Steam has downloaded anything).
prepare refuses a version that is not newer than the live one: no silent
re-upload, no downgrade.

upload starts the uploader with the stage as its Workshop directory, waits
until the tool shows that directory, selects the row whose Directory cell is
PalWorkPriority, checks name and version, presses "Upload To Steam" and fills
in the change note. By default it stops there: the Change Notes window stays
open and pressing OK publishes. --submit presses OK and waits for Steam's
answer (classify_status: "Workshop item submitted successfully." and
"Submitted, but ..." are published, anything else exits 1); --dry-run presses
Cancel and closes the uploader (nothing is sent).

check compares Steam's copy with the hashes recorded at prepare and refuses
when the stage itself changed since then.

Every guard is an explicit check that exits with a message, so python -O
cannot switch one off.
"""
import argparse, hashlib, json, re, shutil, subprocess, sys, time, zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ITEM = '3786408856'
STEAM = Path('C:/Program Files (x86)/Steam')
UPLOADER = STEAM / 'steamapps/common/PalworldModUploader/PalworldModUploader.exe'
SUBSCRIBED = Path('D:/Steam/steamapps/workshop/content/1623730') / ITEM
ROOT = Path('D:/PalWorkPriority-workshop')
STAGE = ROOT / 'stage'
MOD = STAGE / 'PalWorkPriority'
NOTE_MAX = 8000  # Steam: k_cchPublishedDocumentChangeDescriptionMax
GITHUB = 'https://github.com/Matraweber/PalWorkPriority'
# Changelog parts in the order they are kept when the note is too long
# ("Section/Sub" is a bold sub-heading inside a section; '' is the intro).
KEEP = ['', 'Before you update', 'Limits in', 'Fixed/Settings', 'Fixed/Scheduling', 'Fixed/Multiplayer',
        'Fixed/Installation', 'Fixed/Controller', 'Fixed/Production Limits', 'Not in', 'Vortex', 'Performance']
# The uploader's StatusTextBlock after a successful SubmitItemUpdate
# (PalworldModUploader MainWindow.xaml.cs, OnItemSubmitted).
PUBLISHED = 'Workshop item submitted successfully.'


def die(message):
    """Stop with a message and exit code 1. Used instead of assert, which
    python -O removes."""
    raise SystemExit('workshop_upload: ' + message)


def read_json(path, what):
    try:
        return json.loads(Path(path).read_text(encoding='utf-8'))
    except FileNotFoundError:
        die('%s not found: %s' % (what, path))
    except ValueError as err:
        die('%s is not valid JSON (%s): %s' % (what, err, path))


def version_key(v, what='version'):
    """'0.5.0' -> (0, 5); trailing zeros are dropped, so 0.5 == 0.5.0."""
    if not isinstance(v, str) or not re.fullmatch(r'\d+(\.\d+)*', v.strip()):
        die('%s is not a dotted number: %r' % (what, v))
    key = [int(x) for x in v.strip().split('.')]
    while len(key) > 1 and key[-1] == 0:
        key.pop()
    return tuple(key)


def live_version():
    """The newest version known to be on Steam: the subscribed copy's
    Info.json, and every last_published_version the uploader wrote into an
    earlier stage (the current one and the ones moved aside). The subscribed
    .workshop.json is not used: it was uploaded before the uploader updated
    it, so it is one release behind. Returns (version, {source: version})."""
    info = read_json(SUBSCRIBED / 'Info.json', "the subscribed copy's Info.json (subscribe to item %s first)" % ITEM)
    seen = {'subscribed Info.json': info.get('Version')}
    for folder in [MOD] + sorted(ROOT.glob('stage-before-*/PalWorkPriority')):
        meta = folder / '.workshop.json'
        if meta.is_file():
            recorded = read_json(meta, "an earlier stage's .workshop.json").get('last_published_version')
            if recorded:
                seen[str(meta)] = recorded
    for source, v in seen.items():
        version_key(v, source)
    return max(seen.values(), key=version_key), seen


def classify_status(text):
    """The uploader's final status text after OK -> 'published', 'warning'
    or 'error'.

    "Submitted, but failed to update metadata: ..." and "Submitted, but
    failed to open Steam page: ..." replace the success text when a step
    after a successful upload fails: the item is published. Everything else
    (Error: ..., You must accept ..., Submission failed ..., Upload
    canceled ..., anything unknown) is an error."""
    t = (text or '').strip()
    if t == PUBLISHED:
        return 'published'
    if t.startswith('Submitted, but '):
        return 'warning'
    return 'error'


def report_submit(text):
    """Print what the uploader's final status means; return the exit code."""
    kind = classify_status(text)
    shown = (text or '').strip() or '(no status text)'
    if kind == 'error':
        print('NOT published: %s' % shown)
        return 1
    if kind == 'warning':
        print('Published, with a warning from the uploader: %s' % shown)
        if 'metadata' in shown:
            print("  The uploader did not record the version in the stage's .workshop.json,"
                  ' so check reports NOT YET on that line; compare the files it lists.')
    else:
        print('Published: %s' % shown)
    print('Next: python tools/workshop_upload.py check (after Steam has downloaded the update).')
    return 0


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def tree(root):
    root = Path(root)
    return {str(p.relative_to(root)).replace('\\', '/'): sha(p) for p in root.rglob('*') if p.is_file()}


def without_meta(files):
    """The uploader rewrites .workshop.json after a successful upload."""
    return {k: v for k, v in files.items() if k != '.workshop.json'}


def code_version():
    m = re.search(r'VERSION = "([^"]+)"', (REPO / 'Scripts/main.lua').read_text(encoding='utf-8'))
    if not m:
        die('no VERSION = "..." in Scripts/main.lua; pass --version')
    return m.group(1)


def inline(s, version):
    s = re.sub(r'\[([^\]]+)\]\((docs/[^)]+)\)', r'[url=%s/blob/v%s/\2]\1[/url]' % (GITHUB, version), s)
    s = re.sub(r'\[([^\]]+)\]\((https?://[^)]+)\)', r'[url=\2]\1[/url]', s)
    s = re.sub(r'\*\*(.+?)\*\*', r'[b]\1[/b]', s)
    return re.sub(r'`([^`]+)`', r'\1', s)


def bbcode(md, version):
    """CHANGELOG markdown (headings, bold-only lines, bullets with indented
    continuation lines, paragraphs) to Steam BBCode."""
    out, para, item, in_list = [], [], None, False

    def flush():
        nonlocal para, item
        if item is not None:
            out.append('[*]' + inline(' '.join(item), version))
            item = None
        if para:
            out.append(inline(' '.join(para), version))
            para = []

    def close_list():
        nonlocal in_list
        flush()
        if in_list:
            out.append('[/list]')
            in_list = False

    for line in md.splitlines():
        if not line.strip():
            close_list()
            continue
        h = re.match(r'(#+) (.*)', line)
        if h:
            close_list()
            tag = 'h1' if len(h.group(1)) <= 2 else 'h2'
            out.append('[%s]%s[/%s]' % (tag, inline(h.group(2), version), tag))
        elif re.fullmatch(r'\*\*[^*]+\*\*', line.strip()):
            close_list()
            out.append('[h3]%s[/h3]' % line.strip()[2:-2])
        elif line.startswith('- '):
            flush()
            if not in_list:
                out.append('[list]')
                in_list = True
            item = [line[2:].strip()]
        elif item is not None and line.startswith('  '):
            item.append(line.strip())
        else:
            if in_list:
                close_list()
            para.append(line.strip())
    close_list()
    return '\n'.join(out)


def changelog_at_tag(version):
    """CHANGELOG.md as committed at tag v<version>, so the note matches the
    archive built from that tag, not whatever the working tree holds now."""
    r = subprocess.run(['git', '-C', str(REPO), 'show', 'v%s:CHANGELOG.md' % version], capture_output=True)
    if r.returncode != 0:
        die('git show v%s:CHANGELOG.md failed: %s' % (version, r.stderr.decode('utf-8', 'replace').strip()))
    return r.stdout.decode('utf-8').replace('\r\n', '\n')


def change_note(version):
    text = changelog_at_tag(version)
    m = re.search(r'^## %s\b.*?(?=^## |\Z)' % re.escape(version), text, re.S | re.M)
    if not m:
        die('CHANGELOG.md at v%s has no "## %s" section' % (version, version))
    units = []  # (key, parent section or None, bbcode)
    for part in re.split(r'(?m)^(?=### )', m.group(0).rstrip()):
        title = part.splitlines()[0][4:].strip() if part.startswith('### ') else ''
        chunks = re.split(r'(?m)^(?=\*\*[^*\n]+\*\*$)', part)
        units.append((title, None, bbcode(chunks[0], version)))
        for chunk in chunks[1:]:
            units.append((title + '/' + chunk.splitlines()[0].strip('* '), title, bbcode(chunk, version)))
    rank = lambda key: next((i for i, k in enumerate(KEEP) if key.startswith(k) and (k or not key)), len(KEEP))
    footer = 'Full changelog: [url=%s/blob/v%s/CHANGELOG.md]CHANGELOG.md[/url] (also in the mod folder).' % (GITHUB, version)
    budget = NOTE_MAX - len(footer) - 150  # room for the "not shown" line
    keep, used = set(), 0
    for i in sorted(range(len(units)), key=lambda i: rank(units[i][0])):
        parent = units[i][1]
        need = {i} | {j for j, u in enumerate(units) if parent is not None and u[0] == parent}
        size = sum(len(units[j][2].encode('utf-8')) + 2 for j in need - keep)
        if used + size <= budget:
            keep |= need
            used += size
    left_out = [u[0].split('/', 1)[1] + ' fixes' if u[1] == 'Fixed' else u[0]
                for i, u in enumerate(units) if i not in keep]
    note = '\n\n'.join(u[2] for i, u in enumerate(units) if i in keep and u[2].strip())
    if left_out:
        footer = 'Not shown here for length: %s. %s' % (', '.join(left_out), footer)
    note += '\n\n' + footer
    size = len(note.encode('utf-8'))
    if size > NOTE_MAX:
        die('the change note is %d bytes; Steam allows %d' % (size, NOTE_MAX))
    return note, left_out


def prepare(version):
    version_key(version)
    manifest = read_json(REPO / ('build/release-%s/PalWorkPriority-%s-release.json' % (version, version)),
                         'the release manifest')
    entry = manifest['archives']['workshop']
    archive = REPO / ('build/release-%s' % version) / entry['file']
    if not archive.is_file():
        die('archive not found: %s' % archive)
    if sha(archive) != entry['sha256']:
        die('archive hash does not match the release manifest')
    tag = subprocess.run(['git', '-C', str(REPO), 'rev-parse', '--verify', '--quiet', 'v%s^{commit}' % version],
                         capture_output=True, text=True).stdout.strip()
    if not tag:
        die('tag v%s does not exist' % version)
    if tag != manifest['source_commit']:
        die('tag v%s is not the commit the archive was built from' % version)

    # The version guard runs before the stage is touched: a refusal leaves it as it is.
    published = read_json(SUBSCRIBED / '.workshop.json', "the subscribed copy's .workshop.json")
    if published.get('publishedfileid') != ITEM:
        die('the subscribed .workshop.json is for item %r, not %s' % (published.get('publishedfileid'), ITEM))
    live, seen = live_version()
    sources = ', '.join('%s: %s' % kv for kv in seen.items())
    if version_key(version) <= version_key(live):
        die('version %s is not newer than the live version %s (%s); no re-upload, no downgrade'
            % (version, live, sources))
    note, left_out = change_note(version)

    if MOD.exists():
        aside = ROOT / time.strftime('stage-before-%Y%m%d-%H%M%S')
        shutil.move(str(STAGE), str(aside))
        print('older stage moved to', aside)
    MOD.mkdir(parents=True)
    with zipfile.ZipFile(archive) as z:
        z.extractall(MOD)

    info = read_json(MOD / 'Info.json', 'the staged Info.json')
    if info.get('Version') != version:
        die('the staged Info.json says version %r, not %s' % (info.get('Version'), version))
    if info.get('PackageName') != 'PalWorkPriority':
        die('the staged Info.json PackageName is %r, not PalWorkPriority' % info.get('PackageName'))
    if info.get('DebugMode') is not False:
        die('the staged Info.json must have DebugMode false')
    if not info.get('Thumbnail') or not (MOD / info['Thumbnail']).is_file():
        die('the staged thumbnail %r is missing' % info.get('Thumbnail'))
    if list(MOD.rglob('*.dll')):
        die('the Workshop archive must not hold a DLL')

    # The uploader compares Info.json against this value before it uploads,
    # and it is what it overwrites with the new version after a success.
    published['last_published_version'] = live
    (MOD / '.workshop.json').write_text(json.dumps(published, indent=2), encoding='utf-8')

    (STAGE / ('changenote-%s.txt' % version)).write_text(note, encoding='utf-8', newline='\n')
    (STAGE / 'stage.json').write_text(json.dumps({
        'version': version, 'archive': entry['file'], 'sha256': entry['sha256'],
        'source_commit': manifest['source_commit'], 'live_version': live, 'files': tree(MOD)}, indent=2))
    print('staged %d files of %s in %s' % (len(tree(MOD)) - 1, entry['file'], MOD))
    print('live version: %s (%s); item %s' % (live, sources, ITEM))
    print('change note (CHANGELOG.md at v%s): %d of %d characters%s' % (version, len(note), NOTE_MAX,
          '; left out (linked instead): ' + ', '.join(left_out) if left_out else ''))


def upload(mode):
    state = read_json(STAGE / 'stage.json', 'stage.json (run prepare first)')
    if tree(MOD) != state['files']:
        die('the stage changed since prepare (or it was already uploaded); run prepare again')
    tasks = subprocess.run(['tasklist'], capture_output=True, text=True).stdout.lower()
    if 'steam.exe' not in tasks:
        die('start Steam and log in first')
    (UPLOADER.parent / 'workshop_path.txt').write_text(str(STAGE), encoding='utf-8')
    args = ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
            str(REPO / 'tools/workshop-upload.ps1'), '-Exe', str(UPLOADER), '-Stage', str(STAGE),
            '-Version', state['version'], '-NotesFile', str(STAGE / ('changenote-%s.txt' % state['version']))]
    status_file = None
    if mode:
        args.append('-' + mode)
    if mode == 'Submit':
        # Next to the folder, not in it: written after the upload anyway.
        status_file = STAGE / time.strftime('submit-status-%Y%m%d-%H%M%S.txt')
        args += ['-StatusFile', str(status_file)]
    code = subprocess.run(args).returncode
    if code != 0 or status_file is None:
        sys.exit(code)
    if not status_file.is_file():
        die('the driver recorded no final status; look at the uploader and run check before trying again')
    sys.exit(report_submit(status_file.read_text(encoding='utf-8-sig')))


def check(version=None):
    state = read_json(STAGE / 'stage.json', 'stage.json (run prepare first)')
    version = version or state['version']
    if version != state['version']:
        die('the stage holds %s, not %s' % (state['version'], version))
    recorded = without_meta(state['files'])
    if without_meta(tree(MOD)) != recorded:
        die('the stage changed since prepare; its files no longer match the hashes recorded then')
    if not SUBSCRIBED.is_dir():
        die('no subscribed copy at %s (subscribe to item %s)' % (SUBSCRIBED, ITEM))
    steam = without_meta(tree(SUBSCRIBED))
    meta = read_json(MOD / '.workshop.json', 'the staged .workshop.json')
    steam_info = SUBSCRIBED / 'Info.json'
    steam_version = read_json(steam_info, "the subscribed copy's Info.json").get('Version') if steam_info.is_file() else None
    print('uploader recorded last published version:', meta.get('last_published_version'))
    print('Steam copy Info.json version:', steam_version)
    missing = sorted(set(recorded) - set(steam))
    extra = sorted(set(steam) - set(recorded))
    differ = sorted(k for k in set(recorded) & set(steam) if recorded[k] != steam[k])
    for name, files in (('missing in the Steam copy', missing), ('only in the Steam copy', extra), ('different', differ)):
        if files:
            print('%s (%d): %s' % (name, len(files), ', '.join(files[:10])))
    ok = (not (missing or extra or differ) and meta.get('last_published_version') == version
          and steam_version == version)
    print('PASS: the Steam copy equals the staged %s (hashes recorded at prepare)' % state['archive'] if ok else
          'NOT YET: Steam has not downloaded the update (subscribe, or restart Steam) or the upload failed')
    sys.exit(0 if ok else 1)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)
    sub.add_parser('prepare').add_argument('--version', default=None, help='default: VERSION in Scripts/main.lua')
    sub.add_parser('check').add_argument('--version', default=None, help='default: the staged version')
    up = sub.add_parser('upload').add_mutually_exclusive_group()
    up.add_argument('--dry-run', dest='mode', action='store_const', const='DryRun')
    up.add_argument('--submit', dest='mode', action='store_const', const='Submit')
    a = p.parse_args()
    if a.cmd == 'prepare':
        prepare(a.version or code_version())
    elif a.cmd == 'upload':
        upload(a.mode)
    else:
        check(a.version)


if __name__ == '__main__':
    main()
