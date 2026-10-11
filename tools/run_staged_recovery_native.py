"""Explicit synthetic staged-recovery native acceptance; never targets client settings.

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
import settings_destination_recovery as R
from settings_cutover_lock import TransactionLock
from settings_inventory_pins import InventoryPins
import settings_destination_lease as D
import ctypes
import prepare_dedicated_clock_fixture as Base
import accept_cutover_native as A

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / 'test-results/staged-recovery-native-20261011'
BACKUP = Base.SERVER / 'PWPTestBackups/staged-recovery-native-20261011'
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



CRASH_LABEL='after-publish:priorities.txt.tmp'
CRASH_CODE=73


def crash_after_publish(f):
    """Real child exit; no game process, launcher or installed path involved."""
    args=dict(root=str(f.root),root_identity=f.root_id,plan_sha256=f.plan_hash)
    child=r"""
import json,os,sys
from pathlib import Path
sys.path.insert(0,sys.argv[1])
import settings_cutover_fixture as C
import settings_destination_fixture as F
r=json.loads(sys.argv[2]);f=object.__new__(C.Fixture)
f.root=Path(r['root']);f.target=f.root/'mod';f.root_id=r['root_identity'];f.plan_hash=r['plan_sha256']
f.marker=('PWP-CUTOVER-FIXTURE-1\n'+f.plan_hash+'\n').encode();f.hook=lambda _:None
f._plan()
def hook(label):
    if label=='after-publish:priorities.txt.tmp':os._exit(73)
F.run(f,hook,staged=True)
raise AssertionError('crash point not reached')
"""
    result=subprocess.run([sys.executable,'-B','-c',child,str(ROOT/'tools'),json.dumps(args)],
                          capture_output=True,text=True,timeout=90)
    B.require(result.returncode==CRASH_CODE,'staged child did not reach exact crash boundary')
    name='priorities.txt.tmp'
    receipt=json.loads((f.root/('staged-'+name+'.json')).read_bytes())
    ident=R.publication(receipt,f,name)
    entry=B.read_exact(f.target/name)
    B.require(entry['state']=='present' and all(entry['identity'][k]==ident[k] for k in ('device','inode'))
              and C.decoded(entry['bytes'])==b'' and not (f.root/('reserved-'+name+'.json')).exists()
              and not (f.root/receipt['stage_basename']).exists(),'publish-before-progress evidence differs')
    return dict(exit_code=result.returncode,boundary=CRASH_LABEL,publication_identity=ident)


def verify_candidate(f,marker):
    p=f._plan()
    B.require(all(f.read(n)==C.decoded(p['desired'][n]) for n in B.NAMES),'candidate recovery variants differ')
    B.require(all(C.decoded(p['original'][n]) is None and f.read(n) is None for n in C.TRIAL),
              'synthetic trial originals must remain absent')
    B.require(f.read(C.MARKER)==marker,'candidate fence differs')
    return p


def unfence_candidate(f):
    """Explicit disposable-only final gate. Delete the validated marker OBJECT."""
    Base.installer.stopped()
    with TransactionLock(f.root,f.root_id):
        p=verify_candidate(f,f.marker)
        protected={f.root/'plan.json':B.read_exact(f.root/'plan.json',B.MAX_MANIFEST_BYTES),
                   f.root/R.F.INTENT:B.read_exact(f.root/R.F.INTENT,B.MAX_MANIFEST_BYTES)}
        protected.update({f.target/n:B.read_exact(f.target/n) for n in B.NAMES})
        directories={d:B.identity(d.stat()) for d in (f.root,f.target,f.target/'async-trial')}
        with InventoryPins(protected,directories):
            verify_candidate(f,f.marker)
            marker_snapshot=B.read_exact(f.target/C.MARKER)
            # Own ancestor pins survive an uncertain marker-handle close, even
            # when outer context managers unwind. No pathname unlink race.
            guard=D.DestinationLease(f.root,f.root_id,'caps.txt',protected[f.target/'caps.txt'],f.marker)
            try:
                for path in [*reversed(f.target.parents),f.target]:
                    B.checked_path(path,directory=True)
                    h=guard._open(path,0x81,3,3,0x02000000|0x00200000)
                    guard._handles.append(h);guard._info(h,True)
                h=guard._open(f.target/C.MARKER,0x80010000,1,3,0x00200000|0x80)
                guard._handles.append(h);guard._info(h,False)
                info=guard._identity(guard._info(h,False))
                B.require(all(info[k]==marker_snapshot['identity'][k] for k in ('device','inode','size')),'marker identity changed')
                B.require(guard._read(h,65536)==f.marker,'exact marker changed before removal')
                B.require(f._plan()==p and all(f.read(n)==C.decoded(p['desired'][n]) for n in B.NAMES)
                          and all(f.read(n) is None for n in C.TRIAL),'candidate changed before unfencing')
                class Disposition(ctypes.Structure):_fields_=[('DeleteFile',D.L.W.BOOLEAN)]
                value=Disposition(1)
                fn=guard._k.SetFileInformationByHandle
                fn.argtypes=[D.L.W.HANDLE,ctypes.c_int,D.L.W.LPVOID,D.L.W.DWORD];fn.restype=D.L.W.BOOL
                Base.installer.stopped() # Final observed process absence; not a process-start exclusion lock.
                if not fn(h,4,ctypes.byref(value),ctypes.sizeof(value)):raise OSError('fixture marker deletion refused')
            finally:guard.release()
            verify_candidate(f,None)


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
        record('crash.json',crash_after_publish(f))
        B.require(f.read(C.MARKER)==f.marker,'staged fence missing')
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
               interruption='after-publish:priorities.txt.tmp',originals=originals,source_code=hashes,
               config_sha256=hashlib.sha256(config.encode()).hexdigest(),
               expected_priorities=(T.P+b'mine|1|X\nunrelated|2|X\n').decode(),
               expected_limits=(T.C+b'*|Mining|Wood|200\n'+T.ALIAS.encode()+b'|Mining|Stone|OFF\n').decode(),
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
    B.require(hashlib.sha256((f.target/'config.lua').read_bytes()).hexdigest()==r['config_sha256'],'inert configuration changed')
    if phase == 'fenced':B.require(snapshot(f) == json.loads((EVIDENCE/'mixed-state.json').read_text()), 'interrupted state changed')
    else:
        verify_candidate(f,marker=None)
        B.require(snapshot(f)==json.loads((EVIDENCE/'recovered-state.json').read_text()),'recovered settings changed')
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
    activation=json.loads((EVIDENCE/'activation.json').read_text())
    B.require(activation['activated'] and not activation['restored'],'isolated server inactive')
    B.require(not any((RUNTIME/'Mods').glob('*/dlls/*.dll')),'unexpected native writer')
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
              and accepted['parser'].get('phase')=='fenced' and install.get('phase')=='fenced'
              and stopped.get('nonce')==accepted['parser']['nonce']==install['nonce']
              and stopped.get('processes')==accepted['processes'] and bool(stopped.get('processes')),
              'normal fenced shutdown unverified')
    B.require(snapshot(f)==json.loads((EVIDENCE/'mixed-state.json').read_text()),'settings changed since fenced shutdown')
    B.require(snapshot(f)==stopped.get('settings')==install.get('settings'),'shutdown settings chain differs')
    result=R.resume(f)
    verify_candidate(f,marker=f.marker)
    unfence_candidate(f)
    record('recovered-state.json',snapshot(f))
    report=dict(recovery_result=result,fixture_final_state=dict(marker_removed=True,
                candidate_copies_verified=True,trial_absent=True,synthetic_only=True,live_cutover_allowed=False))
    record('recovery-result.json',report)
    return report


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
