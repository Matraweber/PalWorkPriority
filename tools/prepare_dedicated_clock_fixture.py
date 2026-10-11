"""Prepare/restore the isolated clock fixture. Default only checks inputs.

Never launches, kills or deletes. Originals are moved to a new backup, the
archived disposable world is copied, and every restoration move is resumable.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import uuid

import install_dedicated_clock_probe as installer

ROOT = Path(__file__).resolve().parents[1]
SERVER = installer.SERVER
FIXTURE = ROOT / 'test-results/dedicated-clock-shared-20261011'
BACKUP = SERVER / 'PWPTestBackups/clock-shared-20261011'
SOURCE = SERVER / 'PWPTestBackups/identity-20261009/tested-fixture-third'
TARGETS = [('Mods', 'Mods'), ('Pal/Saved', 'Saved'), ('Pal/Content/Paks/LogicMods', 'LogicMods'),
           ('Pal/Binaries/Win64/ue4ss', 'manual-ue4ss'), ('Pal/Binaries/Win64/dwmapi.dll', 'manual-dwmapi.dll')]
EXPECTED_PROXY = '4c258e9bef0145c9099244d4a9b0b68602f746d561b195862fb7d27945987d77'
require = installer.require


def within(path):
    path = Path(path)
    require(path.absolute().is_relative_to(SERVER.absolute()) and path.absolute() != SERVER.absolute(),
            'outside server boundary')
    for part in (path, *path.parents):
        if part.exists() or part.is_symlink():
            require(not part.is_symlink() and not (getattr(part.lstat(), 'st_file_attributes', 0) & 1024),
                    'redirect refused')
    return path


def fingerprint(path):
    within(path)
    if path.is_file():return {'.': hashlib.sha256(path.read_bytes()).hexdigest()}
    require(path.is_dir(), 'missing directory')
    result = {}
    for item in sorted(path.rglob('*')):
        within(item)
        if item.is_file():result[item.relative_to(path).as_posix()] = hashlib.sha256(item.read_bytes()).hexdigest()
        elif item.is_dir():result[item.relative_to(path).as_posix() + '/'] = 'directory'
        else:raise RuntimeError('unsupported fixture entry')
    return result


def record(path, value):
    # Persistent plan precedes moves. Replacement is same-directory and checked.
    temporary = path.with_name(path.name + '.pending-' + uuid.uuid4().hex)
    data = (json.dumps(value, indent=2) + '\n').encode()
    with temporary.open('xb') as stream:
        require(stream.write(data) == len(data), 'short receipt write')
        stream.flush();os.fsync(stream.fileno())
    os.replace(temporary, path)


def preflight():
    installer.stopped()
    within(SOURCE);within(BACKUP)
    require(not BACKUP.exists() and not (FIXTURE/'activation.json').exists(), 'fixture already prepared')
    installer.checked(SOURCE/'Saved', directory=True)
    runtime = SOURCE/'manual-ue4ss'
    require(installer.digest(installer.checked(runtime/'UE4SS.dll').read_bytes()) == installer.EXPECTED_RUNTIME,
            'archived runtime differs')
    for name in ('UE4SS-settings.ini', 'MemberVariableLayout.ini'):
        installer.checked(runtime/name)
    require(installer.digest(installer.checked(SOURCE/'manual-dwmapi.dll').read_bytes()) == EXPECTED_PROXY,
            'archived proxy differs')
    for rel, _ in TARGETS:
        within(SERVER/rel)
        require((SERVER/rel).parent.is_dir(), "target parent missing")
    return True


def prepare():
    preflight()
    FIXTURE.mkdir(parents=True, exist_ok=True)
    BACKUP.mkdir()
    stage=BACKUP/'staging';stage.mkdir()
    (stage/'Mods').mkdir();(stage/'LogicMods').mkdir()
    # Check every source path for redirects before recursive copying.
    fingerprint(SOURCE/'Saved')
    shutil.copytree(SOURCE/'Saved',stage/'Saved')
    runtime=stage/'manual-ue4ss';runtime.mkdir();(runtime/'Mods').mkdir()
    for name in ('UE4SS.dll','UE4SS-settings.ini','MemberVariableLayout.ini'):
        shutil.copy2(SOURCE/'manual-ue4ss'/name,runtime/name)
    shutil.copy2(SOURCE/'manual-dwmapi.dll',stage/'manual-dwmapi.dll')
    # Validate normal shutdown configuration via the existing strict parser.
    # Make a root-shaped copy under staging; no mocking or path redirection.
    from server_control import rest_config
    shutdown_root=stage/'shutdown-check'
    config_dir=shutdown_root/'Pal/Saved/Config/WindowsServer'
    config_dir.mkdir(parents=True)
    shutil.copy2(stage/'Saved/Config/WindowsServer/PalWorldSettings.ini',config_dir/'PalWorldSettings.ini')
    rest_config(shutdown_root)
    rows=[]
    for rel,name in TARGETS:
        active=within(SERVER/rel)
        rows.append({'active':str(active),'backup':str(BACKUP/name),'name':name,
                     'present':active.exists(),'original':fingerprint(active) if active.exists() else None})
    plan={'server_root':str(SERVER),'backup':str(BACKUP),'activated':False,'restored':False,
          'moves':rows,'source':str(SOURCE)}
    record(FIXTURE/'activation.json',plan)
    installer.stopped()
    for row in rows:
        active,old=within(row['active']),within(row['backup'])
        if row['present']:
            require(fingerprint(active)==row['original'], 'original changed')
            active.rename(old)
        else:require(not active.exists(),'new target appeared')
        within(stage/row['name']).rename(active)
    plan['activated']=True;record(FIXTURE/'activation.json',plan)
    record(FIXTURE/'manual.json',{'manual_root':str(SERVER/'Pal/Binaries/Win64/ue4ss'),
                                'proxy_path':str(SERVER/'Pal/Binaries/Win64/dwmapi.dll')})
    return {'prepared':True,'launched':False,'writer_loaded':False}


def restore():
    installer.stopped()
    plan=json.loads((FIXTURE/'activation.json').read_text())
    require(plan.get('server_root')==str(SERVER) and plan.get('backup')==str(BACKUP), 'wrong plan')
    expected=[(str(SERVER/rel),str(BACKUP/name),name) for rel,name in TARGETS]
    require([(r['active'],r['backup'],r['name']) for r in plan['moves']]==expected,'wrong targets')
    archive=within(BACKUP/'observed-fixture');archive.mkdir(exist_ok=True)
    for row in plan['moves']:
        active,old=within(row['active']),within(row['backup'])
        staged=within(BACKUP/'staging'/row['name']);saved=within(archive/row['name'])
        if old.exists():
            require(row['present'] and fingerprint(old)==row['original'],'backup changed')
            if active.exists():
                require(not staged.exists() and not saved.exists(),'ambiguous active fixture')
                active.rename(saved)
            old.rename(active)
        elif row['present']:
            require(active.exists() and fingerprint(active)==row['original'],'original unavailable')
        elif active.exists():
            require(not staged.exists() and not saved.exists(),'ambiguous new target')
            active.rename(saved)
        require(fingerprint(active)==row['original'] if row['present'] else not active.exists(),
                'restoration mismatch')
    plan['restored']=True;record(FIXTURE/'activation.json',plan)
    return {'restored':True,'original_hashes_match':True}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    group=parser.add_mutually_exclusive_group()
    group.add_argument('--prepare',action='store_true');group.add_argument('--restore',action='store_true')
    args=parser.parse_args()
    try:
        result=restore() if args.restore else prepare() if args.prepare else {'preflight':preflight(),'launched':False}
        print(json.dumps(result));return 0
    except Exception:
        print('Clock fixture operation refused or incomplete; inspect plan before retry. No launch or deletion.');return 1


if __name__=='__main__':raise SystemExit(main())
