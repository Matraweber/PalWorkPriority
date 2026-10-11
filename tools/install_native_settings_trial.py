"""Check, snapshot and arm the one-shot disposable typed trial. No production deploy."""
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
PROBE = RUNTIME / 'Mods/PWPSettingsTrial'
EVIDENCE = ROOT / 'test-results/native-settings-live-20261004'
STORE = EVIDENCE / 'store'
EXPECTED = '21b691a69a20c0801f465369d4fcbca7d7444764022fac2a7e8edc7709ef92b8'


def digest(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def check_native_root(receipt):
    root = receipt.get('compiled_root')
    if (receipt.get('compiled_root_verified') is not True or not isinstance(root, str)
            or not PureWindowsPath(root).is_absolute() or PureWindowsPath(root) != PureWindowsPath(STORE)):
        raise RuntimeError('native root mismatch or unverified; expected ' + str(STORE))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--recovery', action='store_true')
    args = parser.parse_args()
    evidence = ROOT / 'test-results/native-settings-recovery-20261004' if args.recovery else EVIDENCE
    probe = RUNTIME / 'Mods/PWPSettingsRecovery' if args.recovery else PROBE
    previous = None
    if args.recovery:
        previous = json.loads((EVIDENCE / 'receipt.json').read_text())
        if previous.get('passed') is not True or not (PROBE / 'enabled.txt.disabled').is_file() or (PROBE / 'enabled.txt').exists():
            raise RuntimeError('initial trial must pass and be disabled')
        if {p.name: digest(p) for p in (EVIDENCE / 'store').iterdir()} != previous['records']:
            raise RuntimeError('original trial records changed')
    build = ROOT / 'experiments/native-settings-bridge/build'
    receipt = json.loads((build / 'receipt.json').read_text())
    check_native_root(receipt)
    required = ('compiled', 'linked', 'source_stable', 'entry_tests_passed',
                'legacy_parser_mutant_rejected', 'unrooted_input_mutant_rejected',
                'consume_lost_return_idempotence_tested', 'real_entry_backend_tests_passed',
                'recovered_typed_payloads_validated')
    if not all(receipt.get(k) is True for k in required) or receipt.get('error'):
        raise RuntimeError('native build not accepted')
    for path, value in receipt['sources'].items():
        if digest(ROOT / path) != value:
            raise RuntimeError('native build source changed: ' + path)
    if digest(RUNTIME / 'UE4SS.dll') != EXPECTED or digest(build / 'pwp_settings_bridge.dll') != receipt['probe_sha256']:
        raise RuntimeError('runtime/helper fingerprint mismatch')
    if probe.exists() or evidence.exists():
        raise RuntimeError('one-shot destination exists; preserve evidence')
    files = {'main.lua': ROOT / 'experiments/native-settings-live/main.lua',
             'pwp_settings_bridge.dll': build / 'pwp_settings_bridge.dll'}
    for name in ('native_settings_trial', 'save_native_backend', 'save_journal_queue', 'save_settings_codec', 'save_scope'):
        files['experiments/' + name + '.lua'] = ROOT / ('experiments/' + name + '.lua')
    for name in ('settings_gate', 'store', 'caps', 'datafile', 'log', 'workdefs', 'producers', 'perf', 'frame_trace'):
        files[name + '.lua'] = ROOT / ('Scripts/' + name + '.lua')
    snapshots = {name: p.read_bytes() for name, p in files.items()}
    if hashlib.sha256(snapshots['pwp_settings_bridge.dll']).hexdigest() != receipt['probe_sha256']:
        raise RuntimeError('helper changed during snapshot')
    checks = ['test_native_settings_bootstrap', 'test_native_settings_trial', 'test_save_native_backend',
              'test_native_settings_composition', 'test_save_journal_queue', 'test_settings_session']
    test = subprocess.run([sys.executable, str(ROOT / 'tools/test_lua.py'),
                           *[str(ROOT / ('tests/' + name + '.lua')) for name in checks]],
                          cwd=ROOT, capture_output=True, timeout=90)
    if test.returncode or any(files[n].read_bytes() != data for n, data in snapshots.items()):
        raise RuntimeError('regressions failed or source changed: ' + test.stdout.decode(errors='replace'))
    production = RUNTIME / 'Mods/PalWorkPriority'
    def fingerprint():
        return {str(p.relative_to(production)): digest(p) for p in production.rglob('*')
                if p.is_file() and (p.suffix == '.lua' or (p.parent == production and p.suffix == '.txt'))}
    before = fingerprint()
    if not before:
        raise RuntimeError('production snapshot unavailable')
    nonce = datetime.now(timezone.utc).strftime('settings-%Y%m%dT%H%M%SZ')
    evidence.mkdir()
    if not args.recovery:
        (evidence / 'store').mkdir()
    (evidence / 'settings-backup').mkdir()
    for p in production.glob('*.txt'):
        shutil.copy2(p, evidence / 'settings-backup' / p.name)
    installed = {}
    for relative, data in snapshots.items():
        target = probe / 'Scripts' / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        value = hashlib.sha256(data).hexdigest()
        if digest(target) != value:
            raise RuntimeError('copy verification failed')
        installed[relative] = value
    after = fingerprint()
    if after != before:
        raise RuntimeError('production changed; trial left disabled')
    (evidence / 'preinstall-tests.log').write_bytes(test.stdout + test.stderr)
    (evidence / 'installation.json').write_text(json.dumps({
        'nonce': nonce, 'runtime_sha256': EXPECTED, 'installed': installed, 'build': receipt,
        'production_before': before, 'production_after': after, 'production_unchanged': True,
        'production_activation_performed': False, 'destination': str(EVIDENCE / 'store'),
        'recovery_only': args.recovery, 'previous_records': previous and previous['records']}, indent=2))
    # Last two writes arm only the fully checked disposable package.
    marker = 'PWP_SETTINGS_RECOVERY' if args.recovery else 'PWP_SETTINGS_TRIAL'
    (probe / 'Scripts/run.txt').write_text(marker + ' ' + nonce + '\n')
    (probe / 'enabled.txt').write_text('')
    print(json.dumps({'installed': str(probe), 'nonce': nonce, 'production_modified': False, 'recovery_only': args.recovery}))


if __name__ == '__main__':
    main()
