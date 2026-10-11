"""Prepare an immutable OFFLINE reconciliation bundle, never a live cutover.

Caller-supplied membership is syntax-checked evidence to REVIEW, not proof.
No launcher removal, legacy replacement, journal deletion or rollback is provided.
Incomplete destinations remain on disk and are never overwritten or reused.
"""
from pathlib import Path
import argparse
import base64
import hashlib
import json
import sys
import settings_migration_backup as B
import settings_journal_export as J
ROOT=Path(__file__).resolve().parents[1]


def reconcile(snapshot, records, storage, guild, legacy_guild, membership):
    originals=B.frozen(snapshot)
    selected=J.propose(records,storage,guild)
    B.require(type(membership) is list and len(membership)<=4096,'bounded membership list required')
    for claim in membership:
        B.require(type(claim) is dict and set(claim)=={'pal','storage','guild'}
                  and all(type(v) is str for v in claim.values()),'invalid membership claim')
    sys.path.insert(0,str(ROOT/'.test-deps'))
    from lupa.lua54 import LuaRuntime
    lua=LuaRuntime(unpack_returned_tuples=True,encoding=None)
    def table(value):
        if type(value) is dict:return lua.table_from({k.encode():table(v) for k,v in value.items()})
        if type(value) is list:return lua.table_from([table(v) for v in value])
        return value.encode() if type(value) is str else value
    for k,v in {'ROOT':ROOT.as_posix(),'files':originals,'STORAGE':storage,'GUILD':guild,
                'ALIAS':legacy_guild,'CLAIMS':membership}.items():lua.globals()[k.encode()]=table(v)
    for name in ('priorities','limits'):
        lua.globals()[('J_'+name).encode()]=base64.b64decode(selected['streams'][name]['canonical_body_base64'],validate=True)
    result=lua.execute(b"""
        package.path=ROOT..'/Scripts/?.lua;'
        local function forbidden()error('export forbids runtime IO')end
        io.open=forbidden;io.popen=forbidden;io.output=forbidden
        os.rename=forbidden;os.remove=forbidden;os.execute=forbidden
        local Data=require('datafile')
        Data.fs={open=function(path,mode)
            assert(mode=='rb');local raw=files[path]
            if raw==nil then return nil,'missing',2 end
            return {read=function(_,n)assert(n>=#raw);return raw end,close=function()return true end}
        end,rename=forbidden,remove=forbidden}
        local Store,Caps=require('store'),require('caps')
        local p,pm=Data.read('priorities.txt',Store.decode_snapshot)
        local c,cm=Data.read('caps.txt',Caps.decode_snapshot)
        assert(p and c,'valid legacy recovery required for both streams')
        local Plan=dofile(ROOT..'/experiments/settings_export_reconcile.lua')
        local r,why=Plan.plan{enabled=true,storage=STORAGE,guild=GUILD,legacy_guild=ALIAS,membership=CLAIMS,
            legacy_priorities=assert(Store.serialize_snapshot(p.data,p.baseline)),
            legacy_limits=assert(Caps.serialize_snapshot(c.data)),
            journal_priorities=J_priorities,journal_limits=J_limits}
        assert(r,why)
        r.selected_legacy={priorities={source=pm.source,generation=pm.generation},limits={source=cm.source,generation=cm.generation}}
        return r
    """)
    def convert(v):
        if isinstance(v,bytes):return v.decode('utf-8')
        if hasattr(v,'items'):return {convert(k):convert(x) for k,x in v.items()}
        return v
    result=convert(result)
    result['journal_selection']=selected['streams']
    return result


def prepare(source, journals, destination, storage, guild, legacy_guild, membership, quiescent):
    B.require(callable(quiescent) and quiescent() is True,'offline prerequisite')
    membership=json.loads(json.dumps(membership))  # detach caller-owned evidence
    source=B.checked_path(source,directory=True);journals=B.checked_path(journals,directory=True)
    destination=B.checked_path(destination,directory=True)
    for protected in (source,journals):
        B.require(not destination.is_relative_to(protected),'bundle must be outside live roots')
        identity=protected.stat()
        for ancestor in destination.parents:
            if ancestor.exists():
                other=ancestor.stat()
                B.require((identity.st_dev,identity.st_ino)!=(other.st_dev,other.st_ino),'bundle aliases live root')
    B.require(not destination.exists(),'destination exists; preserve previous bundle')
    legacy=B.capture(source);journal=J.capture(journals,storage,guild)
    trial={name:B.read_exact(source/name) for name in ('async-trial/launch.lua','async-trial/receipt.lua')}
    records={key:None if entry['state']=='missing' else base64.b64decode(entry['bytes'],validate=True)
             for key,entry in journal.items()}
    plan=reconcile(legacy,records,storage,guild,legacy_guild,membership)
    def unchanged():
        B.require(quiescent() is True,'writer started')
        B.require(B.stable_equal(legacy,B.capture(source)),'legacy changed')
        B.require(journal==J.capture(journals,storage,guild),'journals changed')
        B.require(trial=={name:B.read_exact(source/name) for name in trial},'trial markers changed')
    unchanged()
    artifacts={}
    for name,raw in B.frozen(legacy).items():artifacts['legacy/'+name]=raw
    for key,raw in records.items():
        if raw is not None:artifacts['journals/'+key+'.record']=raw
    for name,entry in trial.items():
        if entry['state']=='present':artifacts['trial/'+Path(name).name]=base64.b64decode(entry['bytes'],validate=True)
    for stream,body in plan['bodies'].items():artifacts['candidates/'+stream+'.body']=body.encode('utf-8')
    destination.mkdir()
    for name,raw in artifacts.items():
        unchanged()
        target=destination/name;target.parent.mkdir(exist_ok=True)
        B.write_new(target,raw)
    unchanged()
    manifest={'contract':'PWP-EXPORT-BUNDLE-1','replacement_allowed':False,'membership_verified':False,
              'source':legacy,'journal_root':str(journals),'journal_entries':journal,'trial_entries':trial,
              'membership_claims':membership,'plan':plan,
              'files':{name:dict(sha256=hashlib.sha256(raw).hexdigest(),bytes=len(raw)) for name,raw in artifacts.items()}}
    B.write_new(destination/'proposal.json',json.dumps(manifest,sort_keys=True,indent=2).encode('utf-8'))
    verify(destination)
    unchanged()
    return manifest


def verify(destination):
    """Recompute from captured bytes only; never follows source paths in a manifest.

    Internal consistency does not authenticate ownership, freshness or durability.
    """
    destination=B.checked_path(destination,directory=True)
    entry=B.read_exact(destination/'proposal.json',B.MAX_MANIFEST_BYTES)
    B.require(entry['state']=='present','incomplete bundle')
    m=json.loads(base64.b64decode(entry['bytes'],validate=True))
    B.require(type(m) is dict and set(m)=={'contract','replacement_allowed','membership_verified',
        'source','journal_root','journal_entries','trial_entries','membership_claims','plan','files'},'bundle fields')
    B.require(m['contract']=='PWP-EXPORT-BUNDLE-1' and m['replacement_allowed'] is False
              and m['membership_verified'] is False,'bundle cannot grant replacement')
    originals=B.frozen(m['source'])
    expected={f'{s}-{slot}' for s in ('priorities','limits') for slot in ('A','B')}
    B.require(type(m['journal_entries']) is dict and set(m['journal_entries'])==expected,'complete journal set')
    B.require(type(m['trial_entries']) is dict and set(m['trial_entries'])==
              {'async-trial/launch.lua','async-trial/receipt.lua'},'complete trial markers')
    def captured_bytes(record,limit):
        B.require(type(record) is dict,'invalid captured entry')
        if record.get('state')=='missing':
            B.require(record=={'state':'missing'},'invalid missing entry');return None
        B.require(set(record)=={'state','identity','sha256','bytes'} and record['state']=='present','invalid present entry')
        raw=base64.b64decode(record['bytes'],validate=True)
        B.require(len(raw)<=limit and base64.b64encode(raw).decode('ascii')==record['bytes']
                  and hashlib.sha256(raw).hexdigest()==record['sha256']
                  and record['identity']['size']==len(raw),'captured bytes mismatch')
        return raw
    records={name:captured_bytes(record,J.MAX_RECORD) for name,record in m['journal_entries'].items()}
    trial={name:captured_bytes(record,B.MAX_BYTES) for name,record in m['trial_entries'].items()}
    p=m['plan']
    rebuilt=reconcile(m['source'],records,p['storage'],p['guild'],p['legacy_guild'],m['membership_claims'])
    B.require(rebuilt==p,'reconciliation plan differs from captured sources')
    artifacts={'legacy/'+name:raw for name,raw in originals.items()}
    artifacts.update({'journals/'+name+'.record':raw for name,raw in records.items() if raw is not None})
    artifacts.update({'trial/'+Path(name).name:raw for name,raw in trial.items() if raw is not None})
    artifacts.update({'candidates/'+stream+'.body':body.encode('utf-8') for stream,body in p['bodies'].items()})
    files={name:dict(sha256=hashlib.sha256(raw).hexdigest(),bytes=len(raw)) for name,raw in artifacts.items()}
    B.require(files==m['files'],'artifact manifest differs')
    seen=set()
    for child in destination.iterdir():
        B.checked_path(child,directory=child.is_dir())
        if child.name=='proposal.json':continue
        B.require(child.name in {'legacy','journals','trial','candidates'} and child.is_dir(),'unexpected bundle member')
        for file in child.iterdir():
            B.checked_path(file)
            name=file.relative_to(destination).as_posix();seen.add(name)
            B.require(name in artifacts,'unexpected artifact')
            B.require(base64.b64decode(B.read_exact(file)['bytes'],validate=True)==artifacts[name],'artifact bytes changed')
    B.require(seen==set(artifacts),'missing bundle artifact')
    B.require(B.read_exact(destination/'proposal.json',B.MAX_MANIFEST_BYTES)==entry,'manifest changed during verification')
    return m


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('source',type=Path);p.add_argument('journals',type=Path);p.add_argument('destination',type=Path)
    p.add_argument('--storage',required=True);p.add_argument('--guild',required=True)
    p.add_argument('--legacy-guild',required=True);p.add_argument('--membership',type=Path,required=True)
    a=p.parse_args()
    raw=B.read_exact(a.membership,1024*1024)
    claims=json.loads(base64.b64decode(raw['bytes'],validate=True))
    result=prepare(a.source,a.journals,a.destination,a.storage,a.guild,a.legacy_guild,claims,B.game_closed)
    print(json.dumps({'prepared':True,'replacement_allowed':False,'files':len(result['files'])}))
