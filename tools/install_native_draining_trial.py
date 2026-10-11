"""Checked one-shot disposable explicit-drain trial. Never deploys production."""
from pathlib import Path, PureWindowsPath
from datetime import datetime, timezone
import hashlib
import json
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = Path('D:/Steam/steamapps/common/Palworld/Mods/NativeMods/UE4SS')
PROBE = RUNTIME / 'Mods/PWPDrainingTrial'
EVIDENCE = ROOT / 'test-results/native-draining-live-20261004'
STORE = EVIDENCE / 'store'


def digest(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def check_native_root(receipt):
    root = receipt.get('compiled_root')
    if (receipt.get('compiled_root_verified') is not True or not isinstance(root, str)
            or not PureWindowsPath(root).is_absolute() or PureWindowsPath(root) != PureWindowsPath(STORE)):
        raise RuntimeError('native root mismatch or unverified; expected ' + str(STORE))


def main():
    build = ROOT / 'experiments/native-draining-bridge/build'
    receipt = json.loads((build / 'receipt.json').read_text())
    check_native_root(receipt)
    required = ('compiled', 'linked', 'source_stable', 'entry_tests_passed', 'real_filesystem_tests_passed',
                'typed_recovery_validated', 'legacy_parser_mutant_rejected', 'unrooted_input_mutant_rejected',
                'normal_crt_exit_with_live_worker_passed', 'registry_destructor_guard_passed',
                'lost_reply_ticket_tested', 'post_publication_uncertainty_tested')
    if not all(receipt.get(k) is True for k in required) or receipt.get('error'):
        raise RuntimeError('native build not accepted')
    for p, value in receipt['sources'].items():
        if digest(ROOT / p) != value:
            raise RuntimeError('build source changed: ' + p)
    if digest(RUNTIME / 'UE4SS.dll') != '21b691a69a20c0801f465369d4fcbca7d7444764022fac2a7e8edc7709ef92b8':
        raise RuntimeError('runtime fingerprint changed')
    if PROBE.exists() or EVIDENCE.exists():
        raise RuntimeError('one-shot destination exists; preserve evidence')
    files = {'main.lua': ROOT / 'experiments/native-draining-live/main.lua',
             'pwp_draining_bridge.dll': build / 'pwp_draining_bridge.dll'}
    for n in ('native_draining_trial', 'native_settings_trial', 'save_native_backend', 'save_journal_queue',
              'save_settings_codec', 'save_scope', 'save_exit_observer'):
        files['experiments/' + n + '.lua'] = ROOT / ('experiments/' + n + '.lua')
    for n in ('settings_gate', 'store', 'caps', 'datafile', 'log', 'workdefs', 'producers', 'perf', 'frame_trace'):
        files[n + '.lua'] = ROOT / ('Scripts/' + n + '.lua')
    snapshots = {n: p.read_bytes() for n, p in files.items()}
    if hashlib.sha256(snapshots['pwp_draining_bridge.dll']).hexdigest() != receipt['probe_sha256']:
        raise RuntimeError('DLL changed')
    sys.path.insert(0, str(ROOT / '.test-deps'))
    from lupa.lua54 import LuaRuntime
    lua = LuaRuntime(unpack_returned_tuples=True)
    compile_chunk = lua.eval('function(s,n) local f,e=load(s,n,"t",{}); return f~=nil,e end')
    for n, data in snapshots.items():
        if n.endswith('.lua'):
            ok, why = compile_chunk(data.decode('utf-8-sig'), '@' + n)
            if not ok:
                raise RuntimeError(why)
    checks = subprocess.run([sys.executable, str(ROOT / 'tools/test_lua.py'),
        'tests/test_native_draining_trial.lua', 'tests/test_save_exit_observer.lua',
        'tests/test_save_native_backend.lua', 'tests/test_persistence_attachment.lua'],
        cwd=ROOT, capture_output=True, timeout=90)
    if checks.returncode or any(p.read_bytes() != snapshots[n] for n, p in files.items()):
        raise RuntimeError('checks failed/source changed: ' + checks.stdout.decode(errors='replace'))
    production = RUNTIME / 'Mods/PalWorkPriority'
    def fingerprint():
        return {str(p.relative_to(production)): digest(p) for p in production.rglob('*')
                if p.is_file() and (p.suffix == '.lua' or (p.parent == production and p.suffix == '.txt'))}
    before = fingerprint()
    if not before:
        raise RuntimeError('missing production snapshot')
    nonce = datetime.now(timezone.utc).strftime('drain-%Y%m%dT%H%M%SZ')
    EVIDENCE.mkdir();(EVIDENCE / 'store').mkdir();(EVIDENCE / 'settings-backup').mkdir()
    for p in production.glob('*.txt'):
        shutil.copy2(p, EVIDENCE / 'settings-backup' / p.name)
    (EVIDENCE / 'checks.log').write_bytes(checks.stdout + checks.stderr)
    installed = {}
    for n, data in snapshots.items():
        target = PROBE / 'Scripts' / n
        target.parent.mkdir(parents=True, exist_ok=True);target.write_bytes(data)
        installed[n] = digest(target)
        if installed[n] != hashlib.sha256(data).hexdigest():
            raise RuntimeError('copy verification failed')
    if fingerprint() != before:
        raise RuntimeError('production changed during install')
    (EVIDENCE / 'install.json').write_text(json.dumps(dict(nonce=nonce, installed=installed,
        production_before=before, native_build=receipt, synthetic=True), indent=2))
    (PROBE / 'Scripts/run.txt').write_text('PWP_DRAIN_TRIAL ' + nonce + '\n')
    (PROBE / 'enabled.txt').write_text('')  # arm last
    print(json.dumps(dict(nonce=nonce, probe=str(PROBE), evidence=str(EVIDENCE))))


if __name__ == '__main__':
    main()
