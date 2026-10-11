"""Read-only migration proposal from a verified offline legacy backup.

Uses actual Lua 5.4 datafile recovery selection and existing typed migration planner.
Guild aliases supplied here are candidate claims, NOT live authority evidence.
No initialization, installation, journal writes, or player-memory activation.
"""
from pathlib import Path
import base64
import json
import sys
import settings_migration_backup as Backup
ROOT=Path(__file__).resolve().parents[1]


def proposal(snapshot, storage, guild, legacy_guild):
    files=Backup.frozen(snapshot)
    sys.path.insert(0,str(ROOT/'.test-deps'))
    from lupa.lua54 import LuaRuntime
    lua=LuaRuntime(unpack_returned_tuples=True, encoding=None)
    lua.globals()[b'ROOT']=ROOT.as_posix().encode()
    lua.globals()[b'captured']=lua.table_from({n.encode():raw for n,raw in files.items()})
    lua.globals()[b'STORAGE']=storage.encode('ascii')
    lua.globals()[b'GUILD']=guild.encode('ascii')
    lua.globals()[b'ALIAS']=legacy_guild.encode('ascii')
    result=lua.execute('''
        package.path=ROOT..'/Scripts/?.lua;'..package.path
        package.loaded.log={warn=function()end,error=function()end}
        local Data=require('datafile')
        Data.fs={open=function(path,mode)
            assert(mode=='rb','read only')
            local raw=captured[path]
            if raw==nil then return nil,'missing',2 end
            return {read=function(_,count)assert(count>=#raw);return raw end,close=function()return true end}
        end,rename=function()error('write forbidden')end,remove=function()error('write forbidden')end}
        local Store,Caps=require('store'),require('caps')
        local p,pm=Data.read('priorities.txt',Store.decode_snapshot)
        local c,cm=Data.read('caps.txt',Caps.decode_snapshot)
        assert(p and c,'both streams require a valid selected legacy generation')
        local Plan=dofile(ROOT..'/experiments/settings_migration.lua')
        local plan,why=Plan.plan{enabled=true,storage=STORAGE,guild=GUILD,
            priorities=assert(Store.serialize_snapshot(p.data,p.baseline)),
            limits=assert(Caps.serialize_snapshot(c.data)),
            original_files={priorities=assert(captured[pm.source]),limits=assert(captured[cm.source])},
            source_policy='validated-legacy-v1',membership={},
            limit_membership={{legacy_guild=ALIAS,storage=STORAGE,guild=GUILD}},
            limits_policy='explicit-alias-preserve-v1'}
        assert(plan,why)
        return {plan=plan,selected={priorities={source=pm.source,generation=pm.generation},
            limits={source=cm.source,generation=cm.generation}}}
    ''')
    def convert(v, path=()):
        if path == ('plan','backup','original'):
            return {k.decode('ascii'): {'encoding':'base64','bytes':base64.b64encode(raw).decode('ascii')}
                    for k,raw in v.items()}
        if isinstance(v,bytes):return v.decode('utf-8')
        if hasattr(v,'items'):
            values=dict(v.items())
            if values and all(type(k) is int for k in values):
                return [convert(values[i],path+(i,)) for i in range(1,len(values)+1)]
            return {convert(k):convert(x,path+(convert(k),)) for k,x in values.items()}
        return v
    result=convert(result)
    result['source']=snapshot['source']
    result['backup_verified_here']=False
    result['live_scope_verified']=False
    result['activation_allowed']=False
    for stream in ('priorities','limits'):
        record=result['selected'][stream]
        record['sha256']=snapshot['entries'][record['source']]['sha256']
    return result


def main():
    import argparse
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('backup',type=Path);p.add_argument('--storage',required=True)
    p.add_argument('--guild',required=True);p.add_argument('--legacy-guild',required=True)
    args=p.parse_args()
    manifest=Backup.verify(args.backup)
    Backup.require(Backup.game_closed(),'offline prerequisite failed')
    current=Backup.capture(manifest['capture']['source'])
    Backup.require(Backup.stable_equal(manifest['capture'],current),'legacy files changed since backup')
    result=proposal(current,args.storage,args.guild,args.legacy_guild)
    Backup.require(Backup.game_closed() and Backup.stable_equal(current,Backup.capture(current['source'])),
                   'source changed while planning')
    result['backup_verified_here']=True
    print(json.dumps(result,indent=2))


if __name__=='__main__':main()
