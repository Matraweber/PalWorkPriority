"""Prepare the explicit disposable server observer; default is read-only preflight.

No DLL, writer, save reader, production scripts or game launch. --install stages
only this diagnostic and arms it last. Never run against an ordinary server.
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
FIXTURE = ROOT / 'test-results/server-identity-20261009'
EXPECTED_RUNTIME = '21b691a69a20c0801f465369d4fcbca7d7444764022fac2a7e8edc7709ef92b8'
PROBE_NAME = 'PWPDedicatedIdentityObserver'
SOURCES = {
    'dedicated_parameter_observer.lua': 'experiments/dedicated_parameter_observer.lua',
    'dedicated_parameter_clock.lua': 'experiments/dedicated_parameter_clock.lua',
    'dedicated_parameter_entry.lua': 'experiments/dedicated_parameter_entry.lua',
    'main.lua': 'experiments/dedicated-identity-observer/main.lua',
    'dedicated_identity.lua': 'experiments/dedicated_identity.lua',
    'dedicated_identity_runner.lua': 'experiments/dedicated_identity_runner.lua',
    'dedicated_guild_probe.lua': 'experiments/dedicated_guild_probe.lua',
    'save_headless_identity_probe.lua': 'experiments/save_headless_identity_probe.lua',
}


def require(value, reason):
    if not value:
        raise RuntimeError(reason)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def checked(path, directory=False):
    path = Path(path)
    for part in (path, *path.parents):
        if part.exists():
            require(not part.is_symlink() and not (getattr(part.lstat(), 'st_file_attributes', 0)
                    & stat.FILE_ATTRIBUTE_REPARSE_POINT), 'reparse path refused')
    require(path.is_dir() if directory else path.is_file(), 'required fixture path absent')
    return path


def stopped():
    # Names only: never collect command lines, environment or server credentials.
    result = subprocess.run(['powershell', '-NoProfile', '-NonInteractive', '-Command',
        "$ErrorActionPreference='Stop'; @(Get-Process | Where-Object {"
        "$_.ProcessName -like 'PalServer*' -or $_.ProcessName -like 'Palworld*'}).Count"],
        capture_output=True, text=True, timeout=15)
    require(result.returncode == 0 and result.stdout.strip() == '0',
            'client/server must be stopped; process check must succeed')


def configured_directory(data):
    # Parse strictly but never print the INI, parser errors or other settings.
    try:
        parser = configparser.ConfigParser(interpolation=None, strict=True)
        parser.read_string(data.decode('utf-8-sig'))
        value = parser['/Script/Pal.PalGameLocalSettings']['DedicatedServerName']
    except Exception:
        raise RuntimeError('configured dedicated directory unavailable') from None
    require(re.fullmatch(r'[0-9a-fA-F]{32}', value) and value != '0' * 32,
            'configured dedicated directory invalid')
    return value.lower()


def preflight(runtime):
    require(Path(runtime).absolute() == RUNTIME.absolute(), 'runtime outside explicit server allowlist')
    stopped()
    checked(RUNTIME, directory=True)
    activation = json.loads(checked(FIXTURE / 'activation.json').read_text())
    manual = json.loads(checked(FIXTURE / 'manual.json').read_text())
    require(activation.get('activated') is True and activation.get('restored') is False
            and Path(activation.get('server_root', '')) == SERVER
            and Path(activation.get('backup', '')) == SERVER / 'PWPTestBackups/identity-20261009',
            'isolated identity fixture not active')
    require(Path(manual.get('manual_root', '')) == RUNTIME
            and Path(manual.get('proxy_path', '')) == SERVER / 'Pal/Binaries/Win64/dwmapi.dll',
            'manual fixture receipt differs')
    for relative, name in [('Mods', 'Mods'), ('Pal/Saved', 'Saved'), ('Pal/Content/Paks/LogicMods', 'LogicMods')]:
        row = {'active': str(SERVER / relative), 'backup': str(SERVER / 'PWPTestBackups/identity-20261009' / name)}
        require(any(Path(x.get('active', '')) == Path(row['active']) and Path(x.get('backup', '')) == Path(row['backup'])
                    for x in activation.get('moves', [])), 'fixture restoration plan differs')
        checked(Path(row['active']), directory=True)
        checked(Path(row['backup']), directory=True)
    runtime_hash = digest(checked(RUNTIME / 'UE4SS.dll').read_bytes())
    require(runtime_hash == EXPECTED_RUNTIME, 'runtime hash differs')
    ini = checked(SERVER / 'Pal/Saved/Config/WindowsServer/GameUserSettings.ini').read_bytes()
    directory = configured_directory(ini)
    # Exact configured path only. No enumeration and no inferred fallback world.
    checked(SERVER / 'Pal/Saved/SaveGames/0' / directory / 'Level.sav')
    payloads = {name: checked(ROOT / relative).read_bytes() for name, relative in SOURCES.items()}
    checked(RUNTIME / 'Mods', directory=True)
    destination = RUNTIME / 'Mods' / PROBE_NAME
    require(not destination.exists() and not destination.is_symlink(), 'probe destination already exists')
    require(not (FIXTURE / 'observer-installation.json').exists(), 'observer receipt already exists')
    return directory, payloads, runtime_hash


def prepare(runtime, install=False, guild=None, parameters=False):
    require(guild is None or (isinstance(guild, str) and re.fullmatch(r'[0-9a-f]{32}', guild)
                             and guild != '0' * 32), 'guild query must be exact canonical nonzero hex')
    require(type(parameters) is bool and (not parameters or guild is not None),
            'parameter observation requires explicit guild and boolean opt-in')
    directory, payloads, runtime_hash = preflight(runtime)
    if not install:
        return {'preflight': True, 'installed': False, 'verified': False,
                'storage_grant': False, 'directory': directory, 'runtime_sha256': runtime_hash,
                'query_guild': guild, 'guild_is_query_only': True, 'parameter_observation': parameters}
    nonce = uuid.uuid4().hex
    saved = (SERVER / 'Pal/Saved').as_posix()
    payloads['config.lua'] = ('return {nonce="' + nonce + '",directory="' + directory
                              + '",saved="' + saved + '"'
                              + (',guild="' + guild + '"' if guild is not None else '')
                              + (',parameters=true' if parameters else '') + '}\n').encode()
    # Repeat the full preflight immediately before creating an inactive package.
    again, sources, current_runtime = preflight(runtime)
    require(again == directory and current_runtime == runtime_hash
            and all(payloads[k] == v for k, v in sources.items()), 'preparation inputs changed')
    destination = RUNTIME / 'Mods' / PROBE_NAME
    scripts = destination / 'Scripts'
    destination.mkdir()
    scripts.mkdir()
    for name, data in payloads.items():
        with (scripts / name).open('xb') as stream:
            stream.write(data)
        require((scripts / name).read_bytes() == data, 'diagnostic copy mismatch')
    stopped()
    require(digest(checked(RUNTIME / 'UE4SS.dll').read_bytes()) == runtime_hash, 'runtime changed before arming')
    require(configured_directory(checked(SERVER / 'Pal/Saved/Config/WindowsServer/GameUserSettings.ini').read_bytes())
            == directory, 'configured world changed before arming')
    receipt = {'schema': 1, 'nonce': nonce, 'directory': directory, 'runtime_sha256': runtime_hash,
               'files': {k: digest(v) for k, v in payloads.items()}, 'verified': False,
               'storage_grant': False, 'authority_grant': False, 'writer_loaded': False,
               'query_guild': guild, 'guild_is_query_only': True, 'max_samples': 60, 'interval_ms': 1000,
               'parameter_observation': parameters, 'max_parameter_attempts_per_sample': 1 if parameters else 0,
               'max_callbacks': 60 if parameters else None,
               'parameter_clock': 'GameplayStatics.GetAccurateRealTime' if parameters else None}
    with (FIXTURE / 'observer-installation.json').open('x') as stream:
        json.dump(receipt, stream, indent=2)
    with (scripts / 'run.txt').open('x') as stream:
        stream.write('PWP_DEDICATED_IDENTITY ' + nonce + '\n')
    (destination / 'enabled.txt').open('x').close()  # arm last; no launch
    return {'installed': True, 'verified': False, 'storage_grant': False, 'nonce': nonce}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime-root', required=True)
    parser.add_argument('--install', action='store_true')
    parser.add_argument('--guild', help='Optional exact canonical 32-hex query target; never ownership proof')
    parser.add_argument('--parameters', action='store_true',
                        help='Explicit read-only parameter mode; requires --guild, no writer or grants')
    args = parser.parse_args()
    try:
        print(json.dumps(prepare(args.runtime_root, args.install, args.guild, args.parameters)))
        return 0
    except Exception:
        # No raw configuration, filesystem exception or process output escapes.
        print('Dedicated identity preparation refused; fixture/checks incomplete. No launch performed.')
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
