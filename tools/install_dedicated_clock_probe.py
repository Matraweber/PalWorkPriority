"""Clock-only disposable dedicated fixture installer; read-only preflight by default.

No world/guild/parameter observer, writer DLL, launch, or runtime-hash bypass.
--install requires the exact stopped, active isolated clock fixture below.
"""
from pathlib import Path
import argparse
import configparser
import hashlib
import json
import re
import stat
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
SERVER = Path('C:/Program Files (x86)/Steam/steamapps/common/PalServer')
RUNTIME = SERVER / 'Pal/Binaries/Win64/ue4ss'
FIXTURE = ROOT / 'test-results/dedicated-clock-shared-20261011'
EXPECTED_RUNTIME = '21b691a69a20c0801f465369d4fcbca7d7444764022fac2a7e8edc7709ef92b8'
PROBE_NAME = 'PWPDedicatedClockProbe'
RECEIPT = 'clock-installation.json'
SOURCES = {
    'main.lua': 'experiments/dedicated-clock-probe/main.lua',
    'dedicated_clock_entry.lua': 'experiments/dedicated_clock_entry.lua',
    'dedicated_parameter_clock.lua': 'experiments/dedicated_parameter_clock.lua',
    'dedicated_clock_probe.lua': 'experiments/dedicated_clock_probe.lua',
}


def require(value, reason):
    if not value:
        raise RuntimeError(reason)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def checked(path, directory=False):
    path = Path(path)
    for part in (path, *path.parents):
        if part.exists() or part.is_symlink():
            require(not part.is_symlink() and not (getattr(part.lstat(), 'st_file_attributes', 0)
                    & stat.FILE_ATTRIBUTE_REPARSE_POINT), 'reparse path refused')
    require(path.is_dir() if directory else path.is_file(), 'required fixture path absent')
    return path


def stopped():
    # Names only: never collect command lines or credentials.
    result = subprocess.run(['powershell', '-NoProfile', '-NonInteractive', '-Command',
        "$ErrorActionPreference='Stop'; @(Get-Process | Where-Object {"
        "$_.ProcessName -like 'PalServer*' -or $_.ProcessName -like 'Palworld*'}).Count"],
        capture_output=True, text=True, timeout=15)
    require(result.returncode == 0 and result.stdout.strip() == '0',
            'client/server must be stopped; process check must succeed')


def configured_directory(data):
    try:
        parser = configparser.ConfigParser(interpolation=None, strict=True)
        parser.read_string(data.decode('utf-8-sig'))
        value = parser['/Script/Pal.PalGameLocalSettings']['DedicatedServerName']
    except Exception:
        raise RuntimeError('configured dedicated directory unavailable') from None
    require(re.fullmatch(r'[0-9a-fA-F]{32}', value) and value != '0' * 32,
            'configured dedicated directory invalid')
    return value.lower()


def fixture_inputs(runtime):
    require(Path(runtime).absolute() == RUNTIME.absolute(), 'runtime outside explicit server allowlist')
    stopped()
    checked(RUNTIME, directory=True)
    activation = json.loads(checked(FIXTURE / 'activation.json').read_text())
    manual = json.loads(checked(FIXTURE / 'manual.json').read_text())
    backup = SERVER / 'PWPTestBackups/clock-shared-20261011'
    require(activation.get('activated') is True and activation.get('restored') is False
            and Path(activation.get('server_root', '')) == SERVER
            and Path(activation.get('backup', '')) == backup, 'isolated clock fixture not active')
    require(Path(manual.get('manual_root', '')) == RUNTIME
            and Path(manual.get('proxy_path', '')) == SERVER / 'Pal/Binaries/Win64/dwmapi.dll',
            'manual fixture receipt differs')
    for relative, name in [('Mods', 'Mods'), ('Pal/Saved', 'Saved'), ('Pal/Content/Paks/LogicMods', 'LogicMods')]:
        active, old = SERVER / relative, backup / name
        require(any(Path(x.get('active', '')) == active and Path(x.get('backup', '')) == old
                    for x in activation.get('moves', [])), 'fixture restoration plan differs')
        checked(active, directory=True)
        checked(old, directory=True)
    runtime_hash = digest(checked(RUNTIME / 'UE4SS.dll').read_bytes())
    require(runtime_hash == EXPECTED_RUNTIME, 'runtime hash differs')
    directory = configured_directory(checked(SERVER / 'Pal/Saved/Config/WindowsServer/GameUserSettings.ini').read_bytes())
    # Only check this exact configured path; do not enumerate or read save bytes.
    checked(SERVER / 'Pal/Saved/SaveGames/0' / directory / 'Level.sav')
    payloads = {name: checked(ROOT / relative).read_bytes() for name, relative in SOURCES.items()}
    checked(RUNTIME / 'Mods', directory=True)
    return directory, payloads, runtime_hash


def preflight(runtime):
    inputs = fixture_inputs(runtime)
    destination = RUNTIME / 'Mods' / PROBE_NAME
    require(not destination.exists() and not destination.is_symlink(), 'clock probe destination already exists')
    receipt = FIXTURE / RECEIPT
    require(not receipt.exists() and not receipt.is_symlink(), 'clock receipt already exists')
    return inputs


def write_exclusive(path, data):
    # Check short writes and read back only after a successful close. Close errors
    # propagate; no failed stage can reach enabled.txt creation.
    with path.open('xb') as stream:
        require(stream.write(data) == len(data), 'diagnostic short write')
    require(checked(path).read_bytes() == data, 'diagnostic copy mismatch')


def prepare(runtime, install=False):
    require(type(install) is bool, 'install must be explicit boolean')
    inputs = preflight(runtime)
    directory, sources, runtime_hash = inputs
    if not install:
        return {'preflight': True, 'installed': False, 'verified': False,
                'storage_grant': False, 'authority_grant': False, 'runtime_sha256': runtime_hash}
    nonce = uuid.uuid4().hex
    payloads = dict(sources)
    payloads['config.lua'] = ('return {nonce="' + nonce + '"}\n').encode('ascii')
    require(preflight(runtime) == inputs, 'preparation inputs changed')
    destination = RUNTIME / 'Mods' / PROBE_NAME
    scripts = destination / 'Scripts'
    destination.mkdir()
    scripts.mkdir()
    arm, enabled = scripts / 'run.txt', destination / 'enabled.txt'
    arm_owned = enabled_owned = False
    try:
        for name, data in payloads.items():
            write_exclusive(scripts / name, data)
        # Third fresh stop/fixture/runtime/source check, immediately before arm.
        require(fixture_inputs(runtime) == inputs, 'fixture changed before arming')
        for name, data in payloads.items():
            require(checked(scripts / name).read_bytes() == data, 'staged diagnostic changed')
        receipt = {'schema': 1, 'probe': PROBE_NAME, 'nonce': nonce,
                   'runtime_sha256': runtime_hash, 'files': {k: digest(v) for k, v in payloads.items()},
                   'verified': False, 'storage_grant': False, 'authority_grant': False,
                   'coverage_grant': False, 'writer_loaded': False, 'clock_only': True,
                   'max_samples': 8, 'interval_ms': 1000, 'elapsed_validated': False}
        write_exclusive(FIXTURE / RECEIPT, (json.dumps(receipt, indent=2) + '\n').encode('utf-8'))
        # Ownership flags are set after exclusive open, before write/close, so an
        # exception there revokes only markers created by this invocation.
        with arm.open('xb') as stream:
            arm_owned = True
            data = ('PWP_DEDICATED_CLOCK ' + nonce + '\n').encode('ascii')
            require(stream.write(data) == len(data), 'clock arm short write')
        require(checked(arm).read_bytes() == data, 'clock arm mismatch')
        with enabled.open('xb'):
            enabled_owned = True  # Empty activation marker is always created last.
    except BaseException:
        try:
            if enabled_owned:
                enabled.unlink()
        finally:
            if arm_owned:
                arm.unlink()
        raise
    return {'installed': True, 'verified': False, 'storage_grant': False,
            'authority_grant': False, 'nonce': nonce}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime-root', required=True)
    parser.add_argument('--install', action='store_true')
    args = parser.parse_args()
    try:
        print(json.dumps(prepare(args.runtime_root, args.install)))
        return 0
    except Exception:
        print('Dedicated clock preparation refused; fixture/checks incomplete. No launch performed.')
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
