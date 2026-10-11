"""Checked one-shot synthetic probe installation; never copies production Scripts."""
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import shutil

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = Path('D:/Steam/steamapps/common/Palworld/Mods/NativeMods/UE4SS')
PROBE = RUNTIME / 'Mods/PWPJournalProbe'
EVIDENCE = ROOT / 'test-results/native-journal-live-20261004'
EXPECTED = '21b691a69a20c0801f465369d4fcbca7d7444764022fac2a7e8edc7709ef92b8'


def digest(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    build = ROOT / 'experiments/native-journal-probe/build'
    receipt = json.loads((build / 'receipt.json').read_text())
    if not all(receipt.get(k) is True for k in ('compiled', 'linked', 'source_stable', 'dispatch_tests_passed',
                                              'entry_tests_passed', 'legacy_parser_mutant_rejected')) or receipt.get('error'):
        raise RuntimeError('build not accepted')
    approved_sources = {Path(path).as_posix(): value for path, value in receipt['sources'].items()}
    for required in ('entry.cpp', 'dispatch.hpp', 'main.lua', 'compile.ps1', 'check_link.py'):
        if 'experiments/native-journal-probe/' + required not in approved_sources:
            raise RuntimeError('incomplete build manifest: ' + required)
    for path, expected in receipt['sources'].items():
        if digest(ROOT / path) != expected:
            raise RuntimeError('source changed after build: ' + path)
    if digest(RUNTIME / 'UE4SS.dll') != EXPECTED or digest(build / 'pwp_journal_probe.dll') != receipt['probe_sha256']:
        raise RuntimeError('runtime/helper fingerprint mismatch')
    if PROBE.exists() or EVIDENCE.exists():
        raise RuntimeError('one-shot destination already exists; preserve and investigate')
    files = {'main.lua': ROOT / 'experiments/native-journal-probe/main.lua',
             'pwp_journal_probe.dll': build / 'pwp_journal_probe.dll'}
    for name in ('save_context_pair_probe', 'save_headless_identity_probe',
                 'save_world_identity_probe', 'save_identity_probe'):
        files['experiments/' + name + '.lua'] = ROOT / ('experiments/' + name + '.lua')
    # Check the separately audited collector snapshot before any installation.
    approved = {'pwp_journal_probe.dll': receipt['probe_sha256']}
    for line in (ROOT / 'experiments/native-journal-probe/context-dependencies.sha256').read_text().splitlines():
        expected, relative = line.split(None, 1)
        relative = relative.strip()
        if relative not in files or relative in approved:
            raise RuntimeError('unknown/duplicate dependency: ' + relative)
        approved[relative] = expected
        if digest(files[relative]) != expected:
            raise RuntimeError('context dependency changed: ' + relative)
    if set(approved) != set(files) or approved['main.lua'] != approved_sources['experiments/native-journal-probe/main.lua']:
        raise RuntimeError('incomplete/inconsistent installation manifest')
    payloads = {relative: path.read_bytes() for relative, path in files.items()}
    for relative, payload in payloads.items():
        if hashlib.sha256(payload).hexdigest() != approved[relative]:
            raise RuntimeError('source changed while preparing: ' + relative)
    production = RUNTIME / 'Mods/PalWorkPriority'
    before = {str(p.relative_to(production)): digest(p) for p in production.rglob('*')
              if p.is_file() and (p.suffix == '.lua' or (p.parent == production and p.suffix == '.txt'))}
    nonce = datetime.now(timezone.utc).strftime('journal-%Y%m%dT%H%M%SZ')
    EVIDENCE.mkdir(parents=True)
    (EVIDENCE / 'store').mkdir()
    (EVIDENCE / 'settings-backup').mkdir()
    for p in production.glob('*.txt'):
        shutil.copy2(p, EVIDENCE / 'settings-backup' / p.name)
    installed = {}
    for relative, payload in payloads.items():
        target = PROBE / 'Scripts' / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(payload)
        if digest(target) != approved[relative]:
            raise RuntimeError('copy verification failed')
        installed[relative] = digest(target)
    after = {str(p.relative_to(production)): digest(p) for p in production.rglob('*')
             if p.is_file() and (p.suffix == '.lua' or (p.parent == production and p.suffix == '.txt'))}
    if after != before:
        raise RuntimeError('production files changed during installation; probe left disabled')
    record = {'nonce': nonce, 'runtime_sha256': EXPECTED, 'installed': installed,
              'production_before': before, 'production_after': after,
              'production_unchanged': True, 'production_activation_performed': False,
              'destination': str(EVIDENCE / 'store'), 'build': receipt}
    (EVIDENCE / 'installation.json').write_text(json.dumps(record, indent=2))
    # Arm last: partial preparation cannot execute.
    (PROBE / 'Scripts/run.txt').write_text('PWP_JOURNAL_PROBE ' + nonce + '\n')
    (PROBE / 'enabled.txt').write_text('')
    print(json.dumps({'installed': str(PROBE), 'nonce': nonce, 'production_modified': False}))


if __name__ == '__main__':
    main()
