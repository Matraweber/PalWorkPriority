"""Offline migration backup: exact legacy recovery sets, no source modifications.

A verified backup is NOT migration authorization. Caller must keep writers fenced,
recheck source equality and prove journal absence/current scope before cutover.
Stable offline directories and no other writers are prerequisites; sampled process
checks cannot prevent a restart or exclude every writer. Path checks reject existing
redirects, but are not an atomic filesystem security boundary.
Incomplete destinations are retained and never reused or overwritten automatically.
"""
from pathlib import Path
import base64
import hashlib
import json
import os
import stat
import subprocess

NAMES = tuple(name + suffix for name in ('priorities.txt', 'caps.txt')
              for suffix in ('', '.tmp', '.pending', '.bak'))
MAX_BYTES = 8 * 1024 * 1024
MAX_MANIFEST_BYTES = 96 * 1024 * 1024
CONTRACT = 'PWP-LEGACY-BACKUP-1'
# ProcessName excludes .exe. Conservatively fence the entire client/server name
# families, including launchers, Shipping-Cmd, Test and future build suffixes.
# Names only: no process command lines, environment or credentials are collected.
PROCESS_PREDICATE = "$_.ProcessName -like 'Palworld*' -or $_.ProcessName -like 'PalServer*'"


def require(value, why):
    if not value:
        raise ValueError(why)


def checked_path(path, directory=False):
    path = Path(os.path.abspath(path))
    for part in reversed((path, *path.parents)):
        try:
            info = part.lstat()
        except FileNotFoundError:
            if part != path:
                raise
            return path
        require(not stat.S_ISLNK(info.st_mode) and not (getattr(info, 'st_file_attributes', 0) & 0x400),
                'redirected path: ' + str(part))
        if part != path or directory:
            require(stat.S_ISDIR(info.st_mode), 'not a directory: ' + str(part))
        else:
            require(stat.S_ISREG(info.st_mode), 'not a regular file: ' + str(part))
    return path


def identity(info):
    return dict(device=info.st_dev, inode=info.st_ino, size=info.st_size,
                modified_ns=info.st_mtime_ns, changed_ns=info.st_ctime_ns)


def read_exact(path, max_bytes=None):
    if max_bytes is None:
        max_bytes = MAX_BYTES
    path = checked_path(path)
    try:
        before = path.stat()
    except FileNotFoundError:
        return dict(state='missing')
    require(before.st_size <= max_bytes, 'oversized legacy file')
    with path.open('rb') as stream:
        opened = os.fstat(stream.fileno())
        require(identity(before) == identity(opened), 'source replaced before read')
        raw = stream.read(max_bytes + 1)
        require(len(raw) <= max_bytes and identity(opened) == identity(os.fstat(stream.fileno())),
                'source changed during read')
    checked_path(path)
    require(identity(before) == identity(path.stat()) and len(raw) == before.st_size,
            'source changed after read')
    return dict(state='present', identity=identity(before), sha256=hashlib.sha256(raw).hexdigest(),
                bytes=base64.b64encode(raw).decode('ascii'))


def capture(source):
    source = checked_path(source, directory=True)
    require(source.is_dir(), 'missing settings directory')
    before = identity(source.stat())
    entries = {name: read_exact(source/name) for name in NAMES}
    # A complete second pass catches cross-file edits/replacements and absent->present.
    require(entries == {name: read_exact(source/name) for name in NAMES}, 'unstable recovery set')
    require(before == identity(source.stat()), 'settings directory changed during capture')
    return dict(contract=CONTRACT, source=str(source), source_identity=before, entries=entries)


def stable_equal(a, b):
    # Backup creation below source can legitimately change directory mtime. Its
    # object identity must still match, as must EVERY legacy file/missing marker.
    return (a['source'] == b['source'] and a['entries'] == b['entries']
            and all(a['source_identity'][k] == b['source_identity'][k] for k in ('device', 'inode')))


def frozen(capture_data):
    require(type(capture_data) is dict and capture_data.get('contract') == CONTRACT, 'backup contract')
    require(set(capture_data) == {'contract', 'source', 'source_identity', 'entries'}, 'capture fields')
    require(set(capture_data['entries']) == set(NAMES), 'complete recovery set required')
    result = {}
    for name in NAMES:
        entry = capture_data['entries'][name]
        require(type(entry) is dict, 'entry')
        if entry.get('state') == 'missing':
            require(entry == {'state': 'missing'}, 'missing entry')
            continue
        require(set(entry) == {'state', 'identity', 'sha256', 'bytes'} and entry['state'] == 'present', 'present entry')
        raw = base64.b64decode(entry['bytes'], validate=True)
        require(len(raw) <= MAX_BYTES and base64.b64encode(raw).decode() == entry['bytes'], 'bounded canonical bytes')
        require(hashlib.sha256(raw).hexdigest() == entry['sha256'] and entry['identity']['size'] == len(raw), 'entry checksum/size')
        result[name] = raw
    return result


def write_new(path, raw):
    # Exclusive creation; checked flush + fsync + close before any success receipt.
    # fsync maps to the platform's durable file flush; no claim about power-loss
    # survival of directory metadata or storage-device firmware is made.
    checked_path(path)
    with Path(path).open('xb') as stream:
        require(stream.write(raw) == len(raw), 'short backup write')
        stream.flush()
        os.fsync(stream.fileno())
    require(base64.b64decode(read_exact(path, max(MAX_BYTES, len(raw)))['bytes']) == raw, 'backup readback mismatch')


def verify(destination, expected=None):
    """Internal byte consistency only; not authenticated flush/freshness evidence.

    A self-consistent fabricated receipt can pass. Recheck current source separately;
    even an old expected capture does not authorize initialization or activation.
    """
    destination = checked_path(destination, directory=True)
    manifest_path = destination/'manifest.json'
    record = read_exact(manifest_path, MAX_MANIFEST_BYTES)
    require(record['state'] == 'present', 'backup incomplete: no manifest')
    manifest = json.loads(base64.b64decode(record['bytes']))
    require(set(manifest) == {'capture', 'file_flush_requested', 'activation_allowed'}
            and manifest['file_flush_requested'] is True and manifest['activation_allowed'] is False, 'manifest fields')
    snapshot = manifest['capture']
    raw_files = frozen(snapshot)
    require({p.name for p in destination.iterdir()} == set(raw_files) | {'manifest.json'}, 'unexpected/missing backup artifact')
    for name, raw in raw_files.items():
        require(base64.b64decode(read_exact(destination/name)['bytes']) == raw, 'backup bytes changed')
    if expected is not None:
        require(stable_equal(snapshot, expected), 'backup differs from expected recovery set')
    return manifest


def backup(source, destination, quiescent):
    require(callable(quiescent) and quiescent() is True, 'offline prerequisite check failed')
    snapshot = capture(source)
    raw_files = frozen(snapshot)
    destination = checked_path(destination, directory=True)
    require(not destination.exists(), 'destination already exists; preserve it')
    source_id = snapshot['source_identity']
    for ancestor in (destination, *destination.parents):
        if ancestor.exists():
            info = ancestor.stat()
            require((info.st_dev, info.st_ino) != (source_id['device'], source_id['inode']),
                    'backup must be outside the source directory')
    destination.mkdir()  # parent must already exist and pass path checks
    for name, raw in raw_files.items():
        require(quiescent() is True, 'writer started during backup')
        write_new(destination/name, raw)
    require(quiescent() is True and stable_equal(snapshot, capture(source)), 'source changed before backup completion')
    manifest = dict(capture=snapshot, file_flush_requested=True, activation_allowed=False)
    encoded = json.dumps(manifest, sort_keys=True, separators=(',', ':')).encode()
    require(len(encoded) <= MAX_MANIFEST_BYTES, 'manifest size bound')
    write_new(destination/'manifest.json', encoded)
    result = verify(destination, snapshot)
    require(quiescent() is True and stable_equal(snapshot, capture(source)), 'source changed after backup completion')
    return result


def game_closed():
    require(os.name == 'nt', 'live process guard only supports Windows')
    command = ("try { $p = @(Get-Process -ErrorAction Stop | Where-Object { "
               + PROCESS_PREDICATE
               + " }); if ($p.Count -eq 0) { Write-Output 'CLOSED' } else { Write-Output 'RUNNING' } } "
               "catch { Write-Error 'Process enumeration failed'; exit 2 }")
    result = subprocess.run(['powershell', '-NoProfile', '-NonInteractive', '-Command', command],
                            capture_output=True, text=True, timeout=15)
    require(result.returncode == 0, 'process guard failed')
    return result.stdout.strip() == 'CLOSED'


def main():
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    result = backup(args.source, args.destination, game_closed)
    print(json.dumps(dict(verified=True, destination=str(args.destination), activation_allowed=False,
                         files=sum(e['state'] == 'present' for e in result['capture']['entries'].values()))))


if __name__ == '__main__':
    main()
