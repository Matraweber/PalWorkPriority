"""Check and arm one read-only identity observation, without deploying production."""
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = Path('D:/Steam/steamapps/common/Palworld/Mods/NativeMods/UE4SS')
PROBE = RUNTIME / 'Mods/PWPLocalAuthorityRead'
EVIDENCE = ROOT / 'test-results/local-authority-live-20261004'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    if PROBE.exists() or EVIDENCE.exists():
        raise RuntimeError('one-shot destination exists; preserve it')
    if digest(RUNTIME / 'UE4SS.dll') != '21b691a69a20c0801f465369d4fcbca7d7444764022fac2a7e8edc7709ef92b8':
        raise RuntimeError('runtime changed')
    names = ('save_local_authority', 'save_context_pair_probe', 'save_headless_identity_probe',
             'save_world_identity_probe', 'save_identity_probe')
    files = {'main.lua': ROOT / 'experiments/local-authority-live/main.lua'}
    files.update({'experiments/' + n + '.lua': ROOT / ('experiments/' + n + '.lua') for n in names})
    snapshots = {n: p.read_bytes() for n, p in files.items()}
    sys.path.insert(0, str(ROOT / '.test-deps'))
    from lupa.lua54 import LuaRuntime
    lua = LuaRuntime(unpack_returned_tuples=True)
    compile_chunk = lua.eval('function(s,n) local f,e=load(s,n,"t",{}); return f~=nil,e end')
    for n, data in snapshots.items():
        ok, why = compile_chunk(data.decode('utf-8'), '@' + n)
        if not ok:
            raise RuntimeError(why)
    checked = subprocess.run([sys.executable, str(ROOT / 'tools/test_lua.py'),
        'tests/test_save_local_authority.lua', 'tests/test_save_context_pair_probe.lua'],
        cwd=ROOT, capture_output=True, timeout=60)
    if checked.returncode or any(p.read_bytes() != snapshots[n] for n, p in files.items()):
        raise RuntimeError('checks failed/source changed: ' + checked.stdout.decode(errors='replace'))
    production = RUNTIME / 'Mods/PalWorkPriority'
    def fingerprint():
        return {str(p.relative_to(production)): digest(p) for p in production.rglob('*')
                if p.is_file() and (p.suffix == '.lua' or (p.parent == production and p.suffix == '.txt'))}
    before = fingerprint()
    if not before:
        raise RuntimeError('missing production snapshot')
    nonce = datetime.now(timezone.utc).strftime('authority-%Y%m%dT%H%M%SZ')
    EVIDENCE.mkdir()
    (EVIDENCE / 'checks.log').write_bytes(checked.stdout + checked.stderr)
    installed = {}
    for n, data in snapshots.items():
        target = PROBE / 'Scripts' / n
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        installed[n] = digest(target)
        if installed[n] != hashlib.sha256(data).hexdigest():
            raise RuntimeError('copy mismatch')
    if fingerprint() != before:
        raise RuntimeError('production changed during install')
    (EVIDENCE / 'install.json').write_text(json.dumps(dict(nonce=nonce, installed=installed,
        production_before=before, read_only=True), indent=2))
    (PROBE / 'Scripts/run.txt').write_text('PWP_AUTHORITY_READ ' + nonce + '\n')
    (PROBE / 'enabled.txt').write_text('')  # arm last
    print(json.dumps(dict(nonce=nonce, probe=str(PROBE), evidence=str(EVIDENCE))))


if __name__ == '__main__':
    main()
