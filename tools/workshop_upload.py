"""Upload a release to the Steam Workshop item with Pocketpair's Palworld Mod
Uploader (Steam app 4212470), the tool 0.4.1 was published with.

  prepare [--version V]      stage the Workshop archive and the change note
  upload [--dry-run|--submit]  drive the uploader (UI Automation)
  check [--version V]        after the upload: Steam's copy equals the stage
                             (default: the staged version)

prepare checks the archive against build/release-V/PalWorkPriority-V-release.json,
that tag vV is the commit it was built from, and that the public tag on origin
is the same commit (the change note links to GitHub at vV). It extracts it into D:/PalWorkPriority-workshop/stage/PalWorkPriority (an older
stage is moved aside, never deleted), writes the uploader's .workshop.json
(item 3786408856, last_published_version = the live version) and the change
note (the CHANGELOG section at tag vV as Steam BBCode, at most 8000 bytes
in UTF-8) next to the folder, not inside it: everything inside the folder
is uploaded.

The live version is the newest of the subscribed copy's Info.json Version,
the last_published_version the uploader recorded in earlier stages (it writes
that file after a successful upload, before Steam has downloaded anything)
and the version upload --submit recorded as submitted in a stage's
stage.json (the uploader records nothing when it says "Submitted, but failed
to update metadata").
prepare refuses a version that is not newer than the live one: no silent
re-upload, no downgrade.

upload points the uploader's workshop_path.txt at the stage (an older value
is kept in D:/PalWorkPriority-workshop/workshop_path-before-<time>.txt and
printed), starts the uploader with the stage as its Workshop directory, waits
until the tool shows that directory, selects the row whose Directory cell is
PalWorkPriority, checks name and version, presses "Upload To Steam" and fills
in the change note. By default it stops there: the Change Notes window stays
open and pressing OK publishes. --submit presses OK and waits for Steam's
answer (classify_status: "Workshop item submitted successfully." and
"Submitted, but ..." are published and recorded in stage.json, anything else
exits 1); --dry-run presses Cancel and closes the uploader (nothing is sent).
When the driver fails while the Change Notes window is open, it presses
Cancel there (or ends the uploader) and upload prints "NOT published, do not
press OK". upload refuses while the uploader is already running (before
workshop_path.txt is touched) and when the change note file is not the one
prepare wrote (its sha256 is in stage.json).

upload and check first re-check the stage against the release: tag vV, local
and on origin, must still be the commit recorded at prepare, the release
manifest's Workshop hash must still be the staged one, and no newer version
may be live (upload also needs the staged version to be newer than the live
one). A moved tag or a rebuilt archive therefore needs a new prepare before
anything is uploaded.

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
# Changelog parts in priority order ("Section/Sub" is a bold sub-heading
# inside a section; '' is the intro). change_note adds them in this order
# while the whole note fits. The first part that does not fit whole is
# shortened to its first bullets plus a pointer to the full changelog, and
# every later part is left out, so a smaller, lower part never takes the
# place of a higher one. Production Limits ranks above Installation and
# Controller: the panel is what 0.5.0 adds, so its fixes are the last Fixed
# group to be cut.
KEEP = ['', 'Before you update', 'Limits in', 'Fixed/Settings', 'Fixed/Scheduling', 'Fixed/Multiplayer',
        'Fixed/Production Limits', 'Fixed/Installation', 'Fixed/Controller', 'Not in', 'Vortex', 'Performance']
# The uploader's StatusTextBlock after a successful SubmitItemUpdate
# (PalworldModUploader MainWindow.xaml.cs, OnItemSubmitted).
PUBLISHED = 'Workshop item submitted successfully.'
# The last bullet of a shortened part.
MORE = '- More in the full changelog (link below).'
# workshop-upload.ps1's exit code when it failed after pressing OK: the
# upload may be running, so nothing is cancelled and no retry is suggested.
AFTER_OK = 3


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
    for stage in [STAGE] + sorted(ROOT.glob('stage-before-*')):
        meta = stage / MOD.name / '.workshop.json'
        if meta.is_file():
            recorded = read_json(meta, "an earlier stage's .workshop.json").get('last_published_version')
            if recorded:
                seen[str(meta)] = recorded
        record = stage / 'stage.json'
        if record.is_file():
            submitted = (read_json(record, "a stage's stage.json").get('submitted') or {}).get('version')
            if submitted:
                seen[str(record) + ' (submitted)'] = submitted
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
            print("  The uploader did not record the version in the stage's .workshop.json;"
                  ' stage.json records the submission, so check accepts it and a second upload is refused.')
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


def shortened(md):
    """Shorter versions of a changelog part's markdown, longest first: whole
    top-level bullets are cut from the end and MORE takes their place. The
    first bullet always stays, so a part without a second bullet has none."""
    lines = md.rstrip('\n').split('\n')
    starts = [i for i, line in enumerate(lines) if line.startswith('- ')]
    for cut in reversed(starts[1:]):
        yield '\n'.join(lines[:cut]).rstrip() + '\n' + MORE + '\n'


def change_note(version):
    """(note, left_out, shortened): the CHANGELOG section at v<version> as
    BBCode within NOTE_MAX bytes, with the names of the parts left out and
    of the part shown shortened (KEEP explains the order)."""
    text = changelog_at_tag(version)
    m = re.search(r'^## %s\b.*?(?=^## |\Z)' % re.escape(version), text, re.S | re.M)
    if not m:
        die('CHANGELOG.md at v%s has no "## %s" section' % (version, version))
    units = []  # (key, parent section or None, markdown)
    for part in re.split(r'(?m)^(?=### )', m.group(0).rstrip()):
        title = part.splitlines()[0][4:].strip() if part.startswith('### ') else ''
        chunks = re.split(r'(?m)^(?=\*\*[^*\n]+\*\*$)', part)
        units.append((title, None, chunks[0]))
        for chunk in chunks[1:]:
            units.append((title + '/' + chunk.splitlines()[0].strip('* '), title, chunk))
    rank = lambda key: next((i for i, k in enumerate(KEEP) if key.startswith(k) and (k or not key)), len(KEEP))
    name = lambda u: u[0].split('/', 1)[1] + ' fixes' if u[1] == 'Fixed' else u[0]
    link = 'Full changelog: [url=%s/blob/v%s/CHANGELOG.md]CHANGELOG.md[/url] (also in the mod folder).' % (GITHUB, version)

    def render(kept, short):
        """The whole note for the kept units ({index: markdown}), with the
        footer that names exactly the parts shortened and left out: sizes
        are measured, not estimated."""
        left_out = [name(u) for i, u in enumerate(units) if i not in kept]
        cut = [name(units[i]) for i in sorted(short)]
        body = (bbcode(kept[i], version) for i in sorted(kept))
        note = '\n\n'.join(b for b in body if b.strip())
        footer = (['Shortened here: %s.' % ', '.join(cut)] if cut else []) + \
                 (['Not shown here for length: %s.' % ', '.join(left_out)] if left_out else [])
        return note + '\n\n' + ' '.join(footer + [link]), left_out, cut

    def fits(kept, short):
        return len(render(kept, short)[0].encode('utf-8')) <= NOTE_MAX

    # Every accepted set was measured with its footer, so the note fits.
    kept, short = {}, set()
    for i in sorted(range(len(units)), key=lambda i: rank(units[i][0])):
        parent = units[i][1]
        need = {i} | {j for j, u in enumerate(units) if parent is not None and u[0] == parent}
        if need <= kept.keys():
            continue
        trial = dict(kept)
        trial.update({j: units[j][2] for j in need if j not in kept})
        if fits(trial, short):
            kept = trial
            continue
        for md in shortened(units[i][2]):
            trial[i] = md
            if fits(trial, short | {i}):
                kept, short = trial, short | {i}
                break
        break  # nothing after the first part that did not fit whole
    note, left_out, cut = render(kept, short)
    size = len(note.encode('utf-8'))
    if size > NOTE_MAX:
        die('the change note is %d bytes; Steam allows %d' % (size, NOTE_MAX))
    return note, left_out, cut


def release_manifest(version):
    return read_json(REPO / ('build/release-%s/PalWorkPriority-%s-release.json' % (version, version)),
                     'the release manifest')


def tag_commit(version):
    """The commit the local tag v<version> points at; dies when it is missing."""
    tag = subprocess.run(['git', '-C', str(REPO), 'rev-parse', '--verify', '--quiet', 'v%s^{commit}' % version],
                         capture_output=True, text=True).stdout.strip()
    if not tag:
        die('tag v%s does not exist' % version)
    return tag


def public_tag_commit(version):
    """The commit tag v<version> points at on origin ('' when origin has no
    such tag). An annotated tag is peeled (its ^{} line); a lightweight tag
    names the commit directly."""
    ref = 'refs/tags/v%s' % version
    r = subprocess.run(['git', '-C', str(REPO), 'ls-remote', 'origin', ref, ref + '^{}'],
                       capture_output=True, text=True)
    if r.returncode != 0:
        die('git ls-remote origin failed, so the public tag v%s cannot be checked: %s'
            % (version, (r.stderr or '').strip() or 'exit code %d' % r.returncode))
    refs = {}
    for line in r.stdout.splitlines():
        parts = line.split()
        if len(parts) == 2:
            refs[parts[1]] = parts[0]
    return refs.get(ref + '^{}') or refs.get(ref, '')


def check_public_tag(version, tag):
    """The change note links to GitHub at v<version>: the public tag must be
    the same commit as the local one, or the links show another CHANGELOG."""
    public = public_tag_commit(version)
    if not public:
        die('tag v%s is not on origin; push it first (git push origin v%s), the change note links to it'
            % (version, version))
    if public != tag:
        die('the public tag v%s on origin is %s, the local tag is %s, so the change-note links would show '
            'another CHANGELOG. Push the moved tag first (git push --force origin v%s)'
            % (version, public[:12], tag[:12], version))


def write_state(state):
    """stage.json, written to a temporary file and renamed over the old one."""
    path = STAGE / 'stage.json'
    temp = path.with_name('stage.json.tmp')
    temp.write_text(json.dumps(state, indent=2), encoding='utf-8')
    if json.loads(temp.read_text(encoding='utf-8')) != state:
        die('could not write %s' % temp)
    temp.replace(path)


def check_stage_release(state, uploading):
    """The stage still belongs to the release: tag v<version>, local and on
    origin, is the commit recorded at prepare, the release manifest still
    lists the staged Workshop archive, and nothing newer is live. Uploading
    also needs the staged version to be newer than the live one. After a
    successful upload the live version equals the staged one, so check
    accepts equal."""
    version = state['version']
    tag = tag_commit(version)
    if tag != state['source_commit']:
        die('tag v%s is now %s, but the stage was prepared from %s: the tag moved. '
            'Rebuild with tools/release.py and run prepare again' % (version, tag[:12], state['source_commit'][:12]))
    check_public_tag(version, tag)
    manifest = release_manifest(version)
    entry = manifest['archives']['workshop']
    if entry['sha256'] != state['sha256'] or manifest.get('source_commit') != state['source_commit']:
        die('the release manifest lists another Workshop archive (%s from %s) than the stage (%s from %s); '
            'run prepare again' % (entry['sha256'][:12], str(manifest.get('source_commit'))[:12],
                                   state['sha256'][:12], state['source_commit'][:12]))
    live, seen = live_version()
    sources = ', '.join('%s: %s' % kv for kv in seen.items())
    if uploading and version_key(version) <= version_key(live):
        die('version %s is not newer than the live version %s (%s); no re-upload, no downgrade'
            % (version, live, sources))
    if version_key(live) > version_key(version):
        die('a newer version %s is live (%s); the stage holds %s' % (live, sources, version))


def prepare(version):
    version_key(version)
    manifest = release_manifest(version)
    entry = manifest['archives']['workshop']
    archive = REPO / ('build/release-%s' % version) / entry['file']
    if not archive.is_file():
        die('archive not found: %s' % archive)
    if sha(archive) != entry['sha256']:
        die('archive hash does not match the release manifest')
    tag = tag_commit(version)
    if tag != manifest['source_commit']:
        die('tag v%s is not the commit the archive was built from' % version)
    check_public_tag(version, tag)

    # The version guard runs before the stage is touched: a refusal leaves it as it is.
    published = read_json(SUBSCRIBED / '.workshop.json', "the subscribed copy's .workshop.json")
    if published.get('publishedfileid') != ITEM:
        die('the subscribed .workshop.json is for item %r, not %s' % (published.get('publishedfileid'), ITEM))
    live, seen = live_version()
    sources = ', '.join('%s: %s' % kv for kv in seen.items())
    if version_key(version) <= version_key(live):
        die('version %s is not newer than the live version %s (%s); no re-upload, no downgrade'
            % (version, live, sources))
    note, left_out, cut = change_note(version)

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

    note_file = STAGE / ('changenote-%s.txt' % version)
    note_file.write_text(note, encoding='utf-8', newline='\n')
    write_state({
        'version': version, 'archive': entry['file'], 'sha256': entry['sha256'],
        'source_commit': manifest['source_commit'], 'live_version': live, 'files': tree(MOD),
        'changenote': note_file.name, 'changenote_sha256': sha(note_file)})
    print('staged %d files of %s in %s' % (len(tree(MOD)) - 1, entry['file'], MOD))
    print('live version: %s (%s); item %s' % (live, sources, ITEM))
    print('change note (CHANGELOG.md at v%s): %d of %d bytes%s%s' % (
        version, len(note.encode('utf-8')), NOTE_MAX, '; shortened: ' + ', '.join(cut) if cut else '',
        '; left out (linked instead): ' + ', '.join(left_out) if left_out else ''))


def point_uploader_at_stage():
    """Write the stage into the uploader's workshop_path.txt. An older value
    is kept in ROOT/workshop_path-before-<time>.txt and printed, so it can
    be put back."""
    path = UPLOADER.parent / 'workshop_path.txt'
    old = path.read_bytes() if path.is_file() else None
    if old is not None and old.decode('utf-8', 'replace').strip() != str(STAGE):
        ROOT.mkdir(parents=True, exist_ok=True)
        kept = ROOT / time.strftime('workshop_path-before-%Y%m%d-%H%M%S.txt')
        kept.write_bytes(old)
        if kept.read_bytes() != old:
            die('could not keep the old %s in %s; nothing was changed' % (path, kept))
        print("the uploader's Workshop directory was %r; kept in %s (copy it back to %s to restore it)"
              % (old.decode('utf-8', 'replace').strip(), kept, path))
    path.write_text(str(STAGE), encoding='utf-8')


def check_note(state):
    """The change note file is the one prepare wrote; returns its path."""
    note = STAGE / ('changenote-%s.txt' % state['version'])
    if not state.get('changenote_sha256'):
        die('stage.json records no change-note hash (staged before 2026-10-30); run prepare again')
    if not note.is_file() or sha(note) != state['changenote_sha256']:
        die('%s is not the change note prepare wrote (its sha256 is in stage.json); run prepare again' % note)
    return note


def upload(mode):
    state = read_json(STAGE / 'stage.json', 'stage.json (run prepare first)')
    if tree(MOD) != state['files']:
        die('the stage changed since prepare (or it was already uploaded); run prepare again')
    note = check_note(state)
    check_stage_release(state, uploading=True)
    r = subprocess.run(['tasklist'], capture_output=True, text=True)
    if r.returncode != 0:
        die('tasklist failed, so Steam and the uploader cannot be checked: %s' % (r.stderr or '').strip())
    tasks = (r.stdout or '').lower()
    if 'steam.exe' not in tasks:
        die('start Steam and log in first')
    # Before workshop_path.txt is touched: an open uploader has already read it.
    if 'palworldmoduploader.exe' in tasks:
        die('the uploader is already open. Close it first, so it reads the staged Workshop directory; '
            'nothing was changed')
    point_uploader_at_stage()
    args = ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
            str(REPO / 'tools/workshop-upload.ps1'), '-Exe', str(UPLOADER), '-Stage', str(STAGE),
            '-Version', state['version'], '-NotesFile', str(note)]
    status_file = None
    if mode:
        args.append('-' + mode)
    if mode == 'Submit':
        # Next to the folder, not in it: written after the upload anyway.
        status_file = STAGE / time.strftime('submit-status-%Y%m%d-%H%M%S.txt')
        args += ['-StatusFile', str(status_file)]
    code = subprocess.run(args).returncode
    if code == AFTER_OK:
        die('OK was pressed (or may have been) and the driver stopped before Steam answered. '
            'Do not upload again: look at the uploader, then run check')
    if code != 0:
        print('NOT published, do not press OK in the uploader. The driver stopped (exit code %d) and pressed '
              'Cancel or ended the uploader; if a Change Notes window is still open, press Cancel there.' % code)
        sys.exit(code)
    if status_file is None:
        sys.exit(0)
    if not status_file.is_file():
        die('the driver recorded no final status; look at the uploader and run check before trying again')
    text = status_file.read_text(encoding='utf-8-sig')
    if classify_status(text) != 'error':
        # The uploader records the version only when its metadata update
        # works; this record is what stops a second upload otherwise.
        state['submitted'] = {'version': state['version'], 'status': text.strip(),
                              'at': time.strftime('%Y-%m-%d %H:%M:%S')}
        write_state(state)
    sys.exit(report_submit(text))


def check(version=None):
    state = read_json(STAGE / 'stage.json', 'stage.json (run prepare first)')
    version = version or state['version']
    if version != state['version']:
        die('the stage holds %s, not %s' % (state['version'], version))
    recorded = without_meta(state['files'])
    if without_meta(tree(MOD)) != recorded:
        die('the stage changed since prepare; its files no longer match the hashes recorded then')
    check_stage_release(state, uploading=False)
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
    submitted = (state.get('submitted') or {}).get('version')
    if submitted:
        print('upload --submit recorded the submission:', state['submitted'].get('status'))
    recorded_live = meta.get('last_published_version') == version or submitted == version
    ok = not (missing or extra or differ) and recorded_live and steam_version == version
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
