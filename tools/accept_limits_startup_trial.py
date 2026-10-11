"""Read-only byte/receipt acceptance for the guarded real-limits startup trial.

Process launch/normal-exit observation remains a separate prerequisite. This
checker requires the game closed and checks one exact nonce, complete migration
or existing-journal recovery, normal Quit cleanup, and unchanged legacy bytes.
"""
from pathlib import Path
import argparse
import hashlib
import json
import struct
import sys
import settings_migration_backup as Backup
import install_limits_startup_trial as Trial


def expected_bodies():
    sys.path.insert(0, str(Trial.ROOT/'.test-deps'))
    from lupa.lua54 import LuaRuntime
    lua=LuaRuntime(unpack_returned_tuples=True)
    lua.globals().TEST_ROOT=Trial.ROOT.as_posix()
    lua.globals().RECEIPT=Trial.RECEIPT.as_posix()
    lua.globals().W,lua.globals().G,lua.globals().ALIAS=Trial.W,Trial.G,Trial.ALIAS
    return lua.execute('''
        package.path=TEST_ROOT..'/Scripts/?.lua;'..package.path
        local r=dofile(RECEIPT)
        local guard=assert(dofile(TEST_ROOT..'/experiments/settings_migration_guard.lua').new{
            enabled=true,files=r.files,storage=W,guild=G,runtime_guild=ALIAS,
            read_source=function()error('no IO')end,read_backup=function()error('no IO')end,
            verify_receipt=function()error('no IO')end,fenced=function()return false end})
        local body=guard:body()
        local caps=require('caps')
        local data=assert(caps.decode_snapshot(body)).data
        return body,assert(caps.serialize_snapshot({[ALIAS]=data[G]}))
    ''')


def inspect(log, nonce, store, canonical, runtime, recovery=False, exit_reason='quit', edits=False):
    Backup.require(exit_reason in ('quit','load_pre'),'unsupported exit observation')
    events=[]
    marker='PWP_ASYNC_TRIAL\t'+nonce+'\t'
    for line in log.splitlines():
        if marker not in line: continue
        parts=line.split(marker,1)[1].split('\t')
        fields={}
        for field in parts[1:]:
            k,v=field.split('=',1)
            Backup.require(k not in fields,'duplicate event field')
            fields[k]=v
        events.append((parts[0],fields))
    Backup.require(not any(e=='failed' for e,_ in events),'runtime failure')
    # Fields without chronology can describe an old cleanup followed by a later
    # activation. Require one ordered lifecycle for this exact boot nonce.
    selectors=(lambda e,d:e=='armed',lambda e,d:e=='started',
               lambda e,d:e=='state' and d.get('state')=='active',lambda e,d:e=='active',
               lambda e,d:e=='lifecycle' and d.get('event')=='closing',
               lambda e,d:e=='lifecycle' and d.get('event')=='cleanup_complete',
               lambda e,d:e=='native_exit')
    ordered=[]
    for select in selectors:
        positions=[i for i,(e,d) in enumerate(events) if select(e,d)]
        Backup.require(len(positions)==1,'missing/duplicate lifecycle event')
        ordered.append(positions[0])
    Backup.require(ordered==sorted(ordered),'lifecycle event ordering')
    binding=events[ordered[1]][1]
    Backup.require(binding.get('storage')==Trial.W and binding.get('guild')==Trial.G,
                   'runtime binding differs from expected scope')
    active=[d for e,d in events if e=='active']
    Backup.require(len(active)==1 and bytes.fromhex(active[0]['limits'])==runtime,'active data differs')
    state=[d for e,d in events if e=='state' and d.get('state')=='active']
    Backup.require(len(state)==1 and state[0]['initialization']==str(not recovery and not edits).lower(),'wrong recovery path')
    initial_generation='3' if edits and recovery else '1'
    Backup.require(state[0]['generation']==initial_generation and state[0]['committed']==('0' if recovery or edits else '1'), 'wrong active generation')
    cleanup=[d for e,d in events if e=='lifecycle' and d.get('event')=='cleanup_complete']
    Backup.require(len(cleanup)==1 and cleanup[0]['cleanup_verified']=='true'
                   and cleanup[0]['owner_retained']=='false' and cleanup[0]['uncertain']=='false'
                   and cleanup[0]['reason']==exit_reason,'expected normal-exit cleanup not proven')
    exit_rows=[d for e,d in events if e=='native_exit']
    Backup.require(len(exit_rows)==1 and exit_rows[0]['phase']=='closed'
                   and exit_rows[0]['joined']=='true' and exit_rows[0]['cleaned']=='true','native drain incomplete')
    accepted='0' if recovery else '2' if edits else '1'
    final_generation=3 if edits else 1
    Backup.require(exit_rows[0].get('accepted')==accepted and exit_rows[0].get('committed')==accepted
                   and exit_rows[0].get('generation')==str(final_generation),'exit durable prefix mismatch')
    files=list(Path(store).iterdir())
    expected={'A':(final_generation,canonical)}
    if edits:
        needle=b'|Mining|Stone|35000\n'
        Backup.require(canonical.count(needle)==1,'real edit fixture changed')
        expected['B']=(2,canonical.replace(needle,b'|Mining|Stone|35001\n'))
    names={f'pwp-record-v1-{Trial.W}-{Trial.G}-limits-{s}.record' for s in expected}
    Backup.require({p.name for p in files}==names,'unexpected journal paths')
    hashes={}
    for slot,(wanted_generation,body) in expected.items():
        name=f'pwp-record-v1-{Trial.W}-{Trial.G}-limits-{slot}.record'
        raw=(Path(store)/name).read_bytes()
        magic,sn,generation,pn=struct.unpack_from('<8sHII',raw)
        scope=f'PWP-SCOPE-1:{Trial.W}:{Trial.G}:limits'.encode()
        payload=f'PWP-SETTINGS-1\n{Trial.W}\n{Trial.G}\nlimits\n{len(body)}\n'.encode()+body
        Backup.require(magic==b'PWPJNL1\n' and sn==len(scope) and generation==wanted_generation and pn==len(payload), 'record header')
        envelope=magic+struct.pack('<HII',sn,generation,pn)+scope+payload
        Backup.require(raw==envelope+hashlib.sha256(envelope).digest(),'journal differs from exact expected bytes')
        hashes[slot]=hashlib.sha256(raw).hexdigest()
    return dict(accepted=True,nonce=nonce,recovery=recovery,normal_exit_reason=exit_reason,
                record_sha256=hashes['A'],records=hashes,generation=final_generation,edits=edits)


def main():
    p=argparse.ArgumentParser();p.add_argument('nonce');p.add_argument('--recover',action='store_true')
    p.add_argument('--exit-reason',choices=('quit','load_pre'),default='quit')
    p.add_argument('--edits',action='store_true',help='exact 35000 -> 35001 -> 35000 two-edit fixture')
    args=p.parse_args()
    Backup.require(Backup.game_closed(),'normal exit required first')
    before=Backup.verify(Trial.BACKUP)['capture']
    Backup.require(Backup.stable_equal(before,Backup.capture(Trial.MOD)),'legacy files changed')
    canonical,runtime=expected_bodies()
    result=inspect((Trial.MOD/'priority.log').read_text(errors='replace'),args.nonce,Trial.STORE,
                   canonical.encode(),runtime.encode(),args.recover,args.exit_reason,args.edits)
    print(json.dumps(result,indent=2))


if __name__=='__main__':main()
