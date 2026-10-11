"""Prepare pinned read-only Lua data from a verified offline migration backup.

Does not install, enable, initialize or migrate settings. Process/source checks
are sampled prerequisites, not exclusion locks. Runtime must recheck exact bytes,
fresh authority and path identity while both legacy writers remain fenced.
"""
import base64
from pathlib import Path
import settings_migration_backup as Backup


def lua_bytes(raw):
    return "unhex('" + raw.hex() + "')"


def render(snapshot, backup_root, manifest):
    files = Backup.frozen(snapshot)
    rows = [
        '-- Installer-checked data; not authority, activation or a runtime freshness grant.',
        "local function unhex(s) return (s:gsub('..',function(b)return string.char(tonumber(b,16))end)) end",
        'return {',
        'source_root=' + lua_bytes(str(snapshot['source']).encode('utf-8')) + ',',
        'backup_root=' + lua_bytes(str(backup_root).encode('utf-8')) + ',',
        'manifest=' + lua_bytes(manifest) + ',',
        'files={',
    ]
    for name in Backup.NAMES:
        value = lua_bytes(files[name]) if name in files else 'false'
        rows.append("['" + name + "']=" + value + ',')
    rows.extend(['}}', ''])
    return '\n'.join(rows).encode('ascii')


def prepare(backup_root, destination, quiescent):
    Backup.require(callable(quiescent) and quiescent() is True, 'offline prerequisite failed')
    backup_root = Backup.checked_path(backup_root, directory=True)
    verified = Backup.verify(backup_root)
    captured = verified['capture']
    source = Backup.checked_path(captured['source'], directory=True)
    destination = Backup.checked_path(destination)
    # This pinned Windows Lua build's narrow io.open does not reliably accept
    # UTF-8 filenames. Refuse unsupported roots instead of emitting a receipt
    # that later mistakes an encoding failure for missing settings.
    Backup.require(str(source).isascii() and str(backup_root).isascii(),
                   'runtime readers currently require ASCII source/backup paths')
    # Never add generated scripts to the live settings or immutable backup set.
    Backup.require(not destination.is_relative_to(source) and not destination.is_relative_to(backup_root),
                   'receipt must be outside source and backup')
    Backup.require(not destination.exists(), 'receipt already exists; preserve it')
    protected = {(p.stat().st_dev, p.stat().st_ino) for p in (source, backup_root)}
    for ancestor in destination.parents:
        if ancestor.exists():
            info = ancestor.stat()
            Backup.require((info.st_dev, info.st_ino) not in protected,
                           'receipt aliases source or backup directory')
    current = Backup.capture(source)
    Backup.require(Backup.stable_equal(captured, current), 'source differs from verified backup')
    record = Backup.read_exact(backup_root/'manifest.json', Backup.MAX_MANIFEST_BYTES)
    raw = base64.b64decode(record['bytes'], validate=True)
    # Verify again after capturing bytes so a changed manifest cannot be pinned
    # merely because it was individually parseable/readable in a previous step.
    Backup.verify(backup_root, captured)
    Backup.require(Backup.read_exact(backup_root/'manifest.json', Backup.MAX_MANIFEST_BYTES) == record,
                   'manifest changed during preparation')
    output = render(captured, backup_root, raw)
    Backup.require(quiescent() is True and Backup.stable_equal(captured, Backup.capture(source)),
                   'source/process changed before publication')
    Backup.write_new(destination, output)
    Backup.verify(backup_root, captured)
    Backup.require(Backup.read_exact(backup_root/'manifest.json', Backup.MAX_MANIFEST_BYTES) == record,
                   'manifest changed after publication')
    Backup.require(quiescent() is True and Backup.stable_equal(captured, Backup.capture(source)),
                   'source/process changed after publication; preserve unapproved receipt')
    return {'prepared': True, 'path': str(destination), 'activation_allowed': False}


if __name__ == '__main__':
    import argparse
    import json
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('backup', type=Path)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    print(json.dumps(prepare(args.backup, args.destination, Backup.game_closed)))
