"""Upload a release to the Steam Workshop item with Pocketpair's Palworld Mod
Uploader (Steam app 4212470), the tool 0.4.1 was published with.

  prepare [--version V]      stage the Workshop archive and the change note
  upload [--dry-run|--submit]  drive the uploader (UI Automation)
  check [--version V]        after the upload: Steam's copy equals the stage

prepare checks the archive against build/release-V/PalWorkPriority-V-release.json,
extracts it into D:/PalWorkPriority-workshop/stage/PalWorkPriority (an older
stage is moved aside, never deleted), writes the uploader's .workshop.json
(item 3786408856, last published version from the subscribed copy) and the
change note (CHANGELOG section as Steam BBCode, at most 8000 characters) next
to the folder, not inside it: everything inside the folder is uploaded.

upload starts the uploader with the stage as its Workshop directory, selects
PalWorkPriority, checks name and version, presses "Upload To Steam" and fills
in the change note. By default it stops there: the Change Notes window stays
open and pressing OK publishes. --submit presses OK and waits for Steam's
answer; --dry-run presses Cancel and closes the uploader (nothing is sent).
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


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def tree(root):
    root = Path(root)
    return {str(p.relative_to(root)).replace('\\', '/'): sha(p) for p in root.rglob('*') if p.is_file()}


def code_version():
    return re.search(r'VERSION = "([^"]+)"', (REPO / 'Scripts/main.lua').read_text(encoding='utf-8')).group(1)


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


def change_note(version):
    text = (REPO / 'CHANGELOG.md').read_text(encoding='utf-8')
    m = re.search(r'^## %s\b.*?(?=^## |\Z)' % re.escape(version), text, re.S | re.M)
    assert m, 'CHANGELOG.md has no "## %s" section' % version
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
    assert len(note.encode('utf-8')) <= NOTE_MAX, len(note.encode('utf-8'))
    return note, left_out


def prepare(version):
    manifest = json.loads((REPO / ('build/release-%s/PalWorkPriority-%s-release.json' % (version, version))).read_text())
    entry = manifest['archives']['workshop']
    archive = REPO / ('build/release-%s' % version) / entry['file']
    assert sha(archive) == entry['sha256'], 'archive hash does not match the release manifest'
    tag = subprocess.run(['git', '-C', str(REPO), 'rev-parse', 'v%s^{commit}' % version],
                         capture_output=True, text=True).stdout.strip()
    assert tag == manifest['source_commit'], 'tag v%s is not the commit the archive was built from' % version

    if MOD.exists():
        aside = ROOT / time.strftime('stage-before-%Y%m%d-%H%M%S')
        shutil.move(str(STAGE), str(aside))
        print('older stage moved to', aside)
    MOD.mkdir(parents=True)
    with zipfile.ZipFile(archive) as z:
        z.extractall(MOD)

    info = json.loads((MOD / 'Info.json').read_text(encoding='utf-8'))
    assert info['Version'] == version, info['Version']
    assert info['PackageName'] == 'PalWorkPriority' and info.get('DebugMode') is False
    assert (MOD / info['Thumbnail']).is_file()
    assert not list(MOD.rglob('*.dll')), 'the Workshop archive must not hold a DLL'

    published = json.loads((SUBSCRIBED / '.workshop.json').read_text(encoding='utf-8'))
    assert published['publishedfileid'] == ITEM
    assert published['last_published_version'] != version, 'version %s is already published' % version
    (MOD / '.workshop.json').write_text(json.dumps(published, indent=2), encoding='utf-8')

    note, left_out = change_note(version)
    (STAGE / ('changenote-%s.txt' % version)).write_text(note, encoding='utf-8', newline='\n')
    (STAGE / 'stage.json').write_text(json.dumps({
        'version': version, 'archive': entry['file'], 'sha256': entry['sha256'],
        'source_commit': manifest['source_commit'], 'files': tree(MOD)}, indent=2))
    print('staged %d files of %s in %s' % (len(tree(MOD)) - 1, entry['file'], MOD))
    print('last published version: %s; item %s' % (published['last_published_version'], ITEM))
    print('change note: %d of %d characters%s' % (len(note), NOTE_MAX,
          '; left out (linked instead): ' + ', '.join(left_out) if left_out else ''))


def upload(mode):
    state = json.loads((STAGE / 'stage.json').read_text())
    assert tree(MOD) == state['files'], 'the stage changed since prepare; run prepare again'
    tasks = subprocess.run(['tasklist'], capture_output=True, text=True).stdout.lower()
    assert 'steam.exe' in tasks, 'start Steam and log in first'
    (UPLOADER.parent / 'workshop_path.txt').write_text(str(STAGE), encoding='utf-8')
    args = ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
            str(REPO / 'tools/workshop-upload.ps1'), '-Exe', str(UPLOADER),
            '-Version', state['version'], '-NotesFile', str(STAGE / ('changenote-%s.txt' % state['version']))]
    if mode:
        args.append('-' + mode)
    sys.exit(subprocess.run(args).returncode)


def check(version):
    state = json.loads((STAGE / 'stage.json').read_text())
    staged = {k: v for k, v in tree(MOD).items() if k != '.workshop.json'}
    steam = {k: v for k, v in tree(SUBSCRIBED).items() if k != '.workshop.json'}
    meta = json.loads((MOD / '.workshop.json').read_text(encoding='utf-8'))
    print('uploader recorded last published version:', meta.get('last_published_version'))
    print('Steam copy Info.json version:', json.loads((SUBSCRIBED / 'Info.json').read_text(encoding='utf-8'))['Version'])
    missing = sorted(set(staged) - set(steam))
    extra = sorted(set(steam) - set(staged))
    differ = sorted(k for k in set(staged) & set(steam) if staged[k] != steam[k])
    for name, files in (('missing in the Steam copy', missing), ('only in the Steam copy', extra), ('different', differ)):
        if files:
            print('%s (%d): %s' % (name, len(files), ', '.join(files[:10])))
    ok = not (missing or extra or differ) and meta.get('last_published_version') == version
    print('PASS: the Steam copy equals the staged %s' % state['archive'] if ok else
          'NOT YET: Steam has not downloaded the update (subscribe, or restart Steam) or the upload failed')
    sys.exit(0 if ok else 1)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)
    for name in ('prepare', 'check'):
        sub.add_parser(name).add_argument('--version', default=code_version())
    up = sub.add_parser('upload').add_mutually_exclusive_group()
    up.add_argument('--dry-run', dest='mode', action='store_const', const='DryRun')
    up.add_argument('--submit', dest='mode', action='store_const', const='Submit')
    a = p.parse_args()
    if a.cmd == 'prepare':
        prepare(a.version)
    elif a.cmd == 'upload':
        upload(a.mode)
    else:
        check(a.version)


if __name__ == '__main__':
    main()
