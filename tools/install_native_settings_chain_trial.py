"""Checked one-shot disposable settings-chain trial. Never deploys production."""
from pathlib import Path, PureWindowsPath
from datetime import datetime, timezone
import hashlib
import json
import shutil
import subprocess
import sys
import argparse

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = Path('D:/Steam/steamapps/common/Palworld/Mods/NativeMods/UE4SS')

STORE = ROOT / 'test-results/native-draining-live-20261004/store'


def digest(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def check_native_root(receipt):
    root = receipt.get('compiled_root')
    if (receipt.get('compiled_root_verified') is not True or not isinstance(root, str)
            or not PureWindowsPath(root).is_absolute() or PureWindowsPath(root) != PureWindowsPath(STORE)):
        raise RuntimeError('native root mismatch or unverified; expected ' + str(STORE))


def native_sources():
    directory = ROOT / 'experiments/native-draining-bridge'
    paths = [p for p in directory.rglob('*') if p.is_file()
             and 'build' not in p.relative_to(directory).parts and '__pycache__' not in p.parts]
    paths += [p for p in (ROOT/'native/save_core').glob('*') if p.suffix in {'.cpp', '.hpp'}]
    paths += [ROOT/p for p in ('experiments/native-settings-bridge/check_link.py', 'Scripts/store.lua',
              'Scripts/caps.lua', 'experiments/save_settings_codec.lua', 'experiments/save_scope.lua',
              'experiments/save_native_backend.lua')]
    return {str(p.relative_to(ROOT)): digest(p) for p in sorted(paths)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--recover', action='store_true')
    args = parser.parse_args()
    PROBE = RUNTIME / ('Mods/PWPSettingsChainRecovery' if args.recover else 'Mods/PWPSettingsChainTrial')
    EVIDENCE = ROOT / ('test-results/native-settings-chain-recovery-20261004' if args.recover else 'test-results/native-settings-chain-live-20261004')
    build = ROOT / 'experiments/native-draining-bridge/build'
    receipt = json.loads((build / 'receipt.json').read_text())
    check_native_root(receipt)
    required = ('compiled', 'linked', 'source_stable', 'entry_tests_passed', 'real_filesystem_tests_passed',
                'typed_recovery_validated', 'legacy_parser_mutant_rejected', 'unrooted_input_mutant_rejected',
                'normal_crt_exit_with_live_worker_passed', 'registry_destructor_guard_passed',
                'lost_reply_ticket_tested', 'post_publication_uncertainty_tested')
    if not all(receipt.get(k) is True for k in required) or receipt.get('error'):
        raise RuntimeError('native build not accepted')
    if receipt.get('sources') != native_sources():
        raise RuntimeError('native source manifest incomplete or changed')
    if digest(RUNTIME / 'UE4SS.dll') != '21b691a69a20c0801f465369d4fcbca7d7444764022fac2a7e8edc7709ef92b8':
        raise RuntimeError('runtime fingerprint changed')
    if PROBE.exists() or EVIDENCE.exists():
        raise RuntimeError('one-shot destination exists; preserve evidence')
    files = {'main.lua': ROOT / 'experiments/native-settings-chain-live/main.lua',
             'pwp_draining_bridge.dll': build / 'pwp_draining_bridge.dll'}
    for n in ('native_settings_chain_trial', 'save_native_backend', 'save_journal_queue',
              'save_settings_codec', 'save_scope', 'save_draining_backend', 'save_draining_queue',
              'settings_session', 'save_session', 'save_transport', 'save_scratch', 'save_durability_barrier'):
        files['experiments/' + n + '.lua'] = ROOT / ('experiments/' + n + '.lua')
    for n in ('settings_writer', 'settings_gate', 'store', 'caps', 'datafile', 'log', 'workdefs', 'producers', 'perf', 'frame_trace'):
        files[n + '.lua'] = ROOT / ('Scripts/' + n + '.lua')
    snapshots = {n: p.read_bytes() for n, p in files.items()}
    for n, source in files.items():
        approved = receipt['sources'].get(str(source.relative_to(ROOT)))
        if approved is not None and hashlib.sha256(snapshots[n]).hexdigest() != approved:
            raise RuntimeError('captured approved source changed: ' + n)
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
        'tests/test_native_settings_chain_trial.lua', 'tests/test_native_settings_chain_bootstrap.lua',
        'tests/test_save_draining_backend.lua', 'tests/test_save_draining_queue.lua',
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
    nonce = datetime.now(timezone.utc).strftime(('chainrecover-' if args.recover else 'chainwrite-') + '%Y%m%dT%H%M%SZ')
    prior_records = {p.name: digest(p) for p in STORE.iterdir() if p.is_file() and not p.is_symlink()}
    prior_receipt_path = ROOT / ('test-results/native-settings-chain-live-20261004/receipt.json' if args.recover
                                 else 'test-results/native-exit-drain-live-20261004-v2/receipt.json')
    prior_receipt = json.loads(prior_receipt_path.read_text())
    if prior_receipt.get('passed') is not True:
        raise RuntimeError('previous evidence has not passed')
    prior_expected = {**prior_receipt['prior_records'], **prior_receipt['records']}
    expected_count = 15 if args.recover else 11
    if prior_records != prior_expected or len(prior_records)!=expected_count or len(list(STORE.iterdir())) != expected_count:
        raise RuntimeError('prior evidence changed or target not fresh')
    EVIDENCE.mkdir();(EVIDENCE / 'settings-backup').mkdir()
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
        production_before=before, native_build=receipt, prior_records=prior_records, synthetic=True, recovery_only=args.recover), indent=2))
    if receipt['sources'] != native_sources() or any(p.read_bytes() != snapshots[n] for n,p in files.items()):
        raise RuntimeError('inputs changed before arming; addon remains disabled')
    if digest(RUNTIME/'UE4SS.dll') != receipt['staged_runtime_sha256'] or fingerprint() != before:
        raise RuntimeError('runtime/production changed before arming')
    final_entries=list(STORE.iterdir())
    if (len(final_entries)!=expected_count or any(not p.is_file() or p.is_symlink() for p in final_entries)
            or {p.name:digest(p) for p in final_entries if p.is_file()} != prior_records):
        raise RuntimeError('store changed before arming')
    (PROBE / 'Scripts/run.txt').write_text('PWP_SETTINGS_CHAIN ' + ('RECOVER ' if args.recover else 'WRITE ') + nonce + '\n')
    (PROBE / 'enabled.txt').write_text('')  # arm last
    print(json.dumps(dict(nonce=nonce, probe=str(PROBE), evidence=str(EVIDENCE))))


if __name__ == '__main__':
    main()
