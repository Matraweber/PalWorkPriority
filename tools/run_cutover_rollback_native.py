"""Explicit isolated rollback acceptance steps; never targets client settings.

Uses the existing archived disposable server world and normal REST shutdown.
No async writer DLL is installed. Each CLI operation is separate and reviewable.
"""
from pathlib import Path
from contextlib import contextmanager
import hashlib
import json
import os
import shutil
import subprocess
import sys
import uuid

import settings_cutover_fixture as C
import settings_migration_backup as B
import prepare_dedicated_clock_fixture as Base
import accept_cutover_native as A

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / 'test-results/rollback-native-20261011'
BACKUP = Base.SERVER / 'PWPTestBackups/rollback-native-20261011'
RUNTIME = Base.SERVER / 'Pal/Binaries/Win64/ue4ss'
MOD = RUNTIME / 'Mods/PalWorkPriority'


def record(name, value):
    B.write_new(EVIDENCE/name, (json.dumps(value, indent=2)+'\n').encode())


@contextmanager
def fixture_configuration():
    previous=Base.FIXTURE,Base.BACKUP
    Base.FIXTURE,Base.BACKUP=EVIDENCE,BACKUP
    try:yield
    finally:Base.FIXTURE,Base.BACKUP=previous


def load_fixture():
    r = json.loads((EVIDENCE/'fixture.json').read_text())
    f = object.__new__(C.Fixture)
    f.root = B.checked_path(Path(r['root']), directory=True)
    B.require(f.root.parent == Path(__import__('tempfile').gettempdir())
              and f.root.name.startswith('pwp-cutover-fixture-'), 'unexpected fixture root')
    f.target = f.root/'mod'; f.root_id = r['root_identity']; f.plan_hash = r['plan_sha256']
    f.marker = ('PWP-CUTOVER-FIXTURE-1\n'+f.plan_hash+'\n').encode()
    f.hook = lambda _: None
    f._plan()
    return f, r


def snapshot(f):
    return {n:C.encoded(f.read(n)) for n in (*B.NAMES, *C.TRIAL, C.MARKER)}


def loopback_config(saved):
    lines=(saved/'Config/WindowsServer/Engine.ini').read_text(encoding='utf-8-sig').splitlines()
    sections=[]; active=None
    for line in lines:
        line=line.strip()
        if not line or line.startswith((';','#')):continue
        if line.startswith('['):
            active=[] if line.casefold()=='[httpserver.listeners]' else None
            if active is not None:sections.append(active)
        elif active is not None:active.append(line)
    B.require(sections==[['DefaultBindAddress=127.0.0.1','DefaultReuseAddressAndPort=False',
                          '!ListenerOverrides=ClearArray']], 'exact loopback fixture configuration required')


def prepare():
    with fixture_configuration():return _prepare()


def _prepare():
    Base.preflight()
    loopback_config(Base.SOURCE/'Saved')
    B.require(not EVIDENCE.exists(), 'new evidence directory required')
    EVIDENCE.mkdir()
    # Independent synthetic encoder/data, with absent original launchers. Native
    # recovered startup must read legacy data, not execute a real trial launcher.
    sys.path.insert(0, str(ROOT))
    from tests import test_settings_export_bundle as T
    source = T.Bundle(); source.setUp()
    try:
        for name in C.TRIAL:(source.source/name).unlink()
        source.prepare()
        shutil.copytree(source.destination, EVIDENCE/'synthetic-bundle')
        f = C.Fixture(EVIDENCE/'synthetic-bundle')
        originals = snapshot(f)
        f.resume()
        def stop(label):
            if label == 'rollback:after-replace:caps.txt':
                raise InterruptedError('controlled rollback interruption')
        f.hook = stop
        try:f.rollback()
        except InterruptedError:pass
        else:raise AssertionError('rollback boundary not reached')
        B.require(f.read(C.MARKER) == f._rollback_marker(), 'rollback fence missing')
        scripts = f.target/'Scripts'; scripts.mkdir()
        hashes = {}
        for src in sorted((ROOT/'Scripts').glob('*.lua')):
            dst = scripts/('production_main.lua' if src.name == 'main.lua' else src.name)
            B.write_new(dst, src.read_bytes()); hashes[dst.name] = hashlib.sha256(dst.read_bytes()).hexdigest()
        B.write_new(scripts/'cutover_native_observer.lua', (ROOT/'experiments/cutover_native_observer.lua').read_bytes())
        hashes['cutover_native_observer.lua']=hashlib.sha256((scripts/'cutover_native_observer.lua').read_bytes()).hexdigest()
        config = (ROOT/'Scripts/config.lua').read_text().replace('enabled = true,','enabled = false,').replace('dry_run = false,','dry_run = true,').replace('run_on_world_load = true,','run_on_world_load = false,')
        B.require('enabled = false,' in config and 'dry_run = true,' in config and 'run_on_world_load = false,' in config, 'inert config required')
        B.write_new(f.target/'config.lua', config.encode())
        record('fixture.json', dict(root=str(f.root),root_identity=f.root_id,plan_sha256=f.plan_hash,
               interruption='rollback:after-replace:caps.txt',originals=originals,source_code=hashes,
               config_sha256=hashlib.sha256(config.encode()).hexdigest(),
               expected_priorities=(T.P+b'mine|1|3\nunrelated|2|X\n').decode(),
               expected_limits=(T.C+b'*|Mining|Wood|200\n'+T.ALIAS.encode()+b'|Mining|Stone|100\n').decode(),
               synthetic_only=True, live_cutover_allowed=False))
        record('mixed-state.json', snapshot(f))
    finally:source.doCleanups()
    return Base.prepare()


def stage(phase):
    B.require(phase in ('fenced','recovered'), 'invalid native phase')
    Base.installer.stopped()
    f,r = load_fixture()
    plan = json.loads((EVIDENCE/'activation.json').read_text())
    B.require(plan['activated'] and not plan['restored'], 'isolated server inactive')
    B.require(Base.installer.digest((RUNTIME/'UE4SS.dll').read_bytes()) == Base.installer.EXPECTED_RUNTIME, 'runtime changed')
    for name,digest in r['source_code'].items():
        B.require(hashlib.sha256((f.target/'Scripts'/name).read_bytes()).hexdigest() == digest, 'source changed')
    if phase == 'fenced':B.require(snapshot(f) == json.loads((EVIDENCE/'mixed-state.json').read_text()), 'interrupted state changed')
    else:B.require(snapshot(f) == r['originals'], 'original settings not restored')
    for path in (MOD, MOD/'Scripts'):path.mkdir(exist_ok=True)
    B.require(not any((RUNTIME/'Mods').glob('*/dlls/*.dll')), 'unexpected native writer')
    nonce = uuid.uuid4().hex; root = f.target.as_posix()+'/'
    wrapper = ('package.path='+json.dumps(root+'Scripts/?.lua;')+'..package.path\n'
               +'assert(dofile('+json.dumps(root+'Scripts/cutover_native_observer.lua')+').run{nonce='+json.dumps(nonce)
               +',phase='+json.dumps(phase)+',root='+json.dumps(root)+',production='+json.dumps(root+'Scripts/production_main.lua')+'})\n')
    sys.path.insert(0, str(ROOT/'.test-deps'))
    from lupa.lua54 import LuaRuntime
    lua = LuaRuntime(unpack_returned_tuples=True)
    compile = lua.eval('function(s) local f,e=load(s,"probe","t",{}); assert(f,e) end')
    for src in (f.target/'Scripts').glob('*.lua'):compile(src.read_text(encoding='utf-8-sig'))
    compile(wrapper)
    active = MOD/'Scripts/main.lua'
    if active.exists():
        B.require(phase == 'recovered' and hashlib.sha256(active.read_bytes()).hexdigest() == json.loads((EVIDENCE/'fenced-install.json').read_text())['wrapper_sha256'], 'unowned wrapper')
        active.rename(EVIDENCE/'fenced-wrapper.lua')
    B.write_new(active, wrapper.encode())
    if not (MOD/'enabled.txt').exists():B.write_new(MOD/'enabled.txt', b'')
    receipt = dict(phase=phase,nonce=nonce,wrapper_sha256=hashlib.sha256(wrapper.encode()).hexdigest(),settings=snapshot(f),writer_loaded=False)
    record(phase+'-install.json', receipt)
    return receipt


def launch(phase):
    B.require(phase in ('fenced','recovered'), 'invalid native phase')
    Base.installer.stopped()
    f,r = load_fixture(); install=json.loads((EVIDENCE/(phase+'-install.json')).read_text())
    B.require(Base.installer.digest((RUNTIME/'UE4SS.dll').read_bytes()) == Base.installer.EXPECTED_RUNTIME, 'runtime changed')
    for name,digest in r['source_code'].items():
        B.require(hashlib.sha256((f.target/'Scripts'/name).read_bytes()).hexdigest()==digest, 'source changed before launch')
    B.require(hashlib.sha256((f.target/'config.lua').read_bytes()).hexdigest()==r['config_sha256'], 'inert configuration changed')
    B.require(snapshot(f) == install['settings'], 'settings changed before launch')
    B.require(hashlib.sha256((MOD/'Scripts/main.lua').read_bytes()).hexdigest() == install['wrapper_sha256'], 'wrapper changed')
    from server_control import rest_config
    rest_config(Base.SERVER)  # Validate normal shutdown before launch; never print secret.
    loopback_config(Base.SERVER/'Pal/Saved')
    import server
    exe = Base.SERVER/'Pal/Binaries/Win64/PalServer-Win64-Shipping-Cmd.exe'
    B.checked_path(exe)
    server.ps('Start-Process -WindowStyle Hidden -FilePath '+server.quoted(exe)+' -WorkingDirectory '+server.quoted(Base.SERVER)+' -ErrorAction Stop')
    return {'launched':True,'phase':phase}


def observe(phase):
    B.require(phase in ('fenced','recovered'), 'invalid native phase')
    f,r=load_fixture(); receipt=json.loads((EVIDENCE/(phase+'-install.json')).read_text())
    raw=(RUNTIME/'UE4SS.log').read_bytes(); text=raw.decode('utf-8', errors='replace')
    lines=[line[line.index('PWP_CUTOVER_NATIVE'):] for line in text.splitlines(keepends=True) if 'PWP_CUTOVER_NATIVE\t' in line]
    B.require(len(lines)==1,'exactly one native observation required')
    p,c=(A.EMPTY_PRIORITIES,A.EMPTY_LIMITS) if phase=='fenced' else (r['expected_priorities'].encode(),r['expected_limits'].encode())
    accepted=A.accept(lines[0],receipt['nonce'],phase,p,c)
    B.require(snapshot(f)==receipt['settings'],'native startup changed settings')
    import server
    from paths import resolve
    paths,_=resolve(['--server']); processes=server.server_processes(paths)
    B.require(processes,'native process identity unavailable')
    from server_control import rest_config,verify_listener
    port,_=rest_config(Base.SERVER)
    listeners=verify_listener(port,processes,server.ps)
    record(phase+'-acceptance.json',dict(parser=accepted,processes=processes,listeners=listeners,settings_unchanged=True,log_sha256=hashlib.sha256(raw).hexdigest()))
    B.write_new(EVIDENCE/(phase+'-ue4ss.log'),raw)
    B.write_new(EVIDENCE/(phase+'-priority.log'),(f.target/'priority.log').read_bytes())
    return accepted


def recover():
    Base.installer.stopped();f,r=load_fixture()
    stopped=json.loads((EVIDENCE/'fenced-stopped.json').read_text())
    accepted=json.loads((EVIDENCE/'fenced-acceptance.json').read_text())
    install=json.loads((EVIDENCE/'fenced-install.json').read_text())
    B.require(stopped.get('settings_unchanged') is True and stopped.get('normal_exit_observed') is True
              and stopped.get('nonce')==accepted['parser']['nonce']==install['nonce']
              and stopped.get('processes')==accepted['processes'] and bool(stopped.get('processes')),
              'normal fenced shutdown unverified')
    B.require(snapshot(f)==json.loads((EVIDENCE/'mixed-state.json').read_text()),'settings changed since fenced shutdown')
    result=f.resume_rollback()
    B.require(snapshot(f)==r['originals'],'rollback differed from originals')
    record('recovered-state.json',snapshot(f))
    return result


def stop(phase):
    B.require(phase in ('fenced','recovered'), 'invalid native phase')
    import server
    from paths import resolve
    from server_control import graceful_stop,identity
    paths,_=resolve(['--server'])
    accepted=json.loads((EVIDENCE/(phase+'-acceptance.json')).read_text())
    receipt=json.loads((EVIDENCE/(phase+'-install.json')).read_text())
    B.require(accepted['parser']['nonce']==receipt['nonce'] and accepted['parser']['phase']==phase,
              'shutdown observation identity differs')
    targets=server.server_processes(paths)
    B.require(bool(targets) and identity(targets)==identity(accepted['processes']),
              'accepted native process no longer running or changed')
    graceful_stop(paths,targets,processes=lambda:server.server_processes(paths),shell=server.ps)
    Base.installer.stopped()
    f,_=load_fixture()
    B.require(snapshot(f)==receipt['settings'], 'shutdown changed settings')
    record(phase+'-stopped.json',dict(nonce=receipt['nonce'],processes=accepted['processes'],
           settings_unchanged=True,normal_exit_observed=True,settings=snapshot(f)))
    return {'stopped':True,'settings_unchanged':True}


if __name__=='__main__':
    action=sys.argv[1]
    if action=='prepare':result=prepare()
    elif action=='stage':result=stage(sys.argv[2])
    elif action=='launch':result=launch(sys.argv[2])
    elif action=='observe':result=observe(sys.argv[2])
    elif action=='recover':result=recover()
    elif action=='restore':
        with fixture_configuration():result=Base.restore()
    elif action=='stop':result=stop(sys.argv[2])
    else:raise ValueError('unknown explicit action')
    print(json.dumps(result))
