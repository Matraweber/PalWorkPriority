"""Actual DrainingWriter process-interruption tests, private roots ONLY.
Run: python tools/test_draining_crash.py
Abrupt own-child termination is not a physical power-loss test.
"""
from pathlib import Path
import hashlib
import importlib.util
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import uuid

ROOT=Path(__file__).resolve().parents[1]
CORE=ROOT/'native/save_core'
POINTS=('before_write','after_write','after_flush','after_backup','before_publish',
        'after_publish','after_disposition','after_close')
POST={'after_publish','after_disposition','after_close'}
WORLD,GUILD='1'*32,'2'*32


def require(yes,why):
    if not yes: raise RuntimeError(why)


def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_record(path,scope):
    """Independent framing + SHA256, no production record decoder."""
    if not path.exists(): return None
    raw=path.read_bytes()
    require(len(raw)>=50 and raw[:8]==b'PWPJNL1\n','bad record magic/size')
    size,generation,length=struct.unpack_from('<HII',raw,8)
    require(len(raw)==18+size+length+32,'record length mismatch')
    require(raw[18:18+size]==scope.encode(),'foreign record scope')
    require(hashlib.sha256(raw[:-32]).digest()==raw[-32:],'record SHA256 mismatch')
    require(generation>0,'invalid generation')
    return generation,raw[18+size:-32]


def main():
    out=ROOT/'test-results'/('draining-crash-'+uuid.uuid4().hex[:12]);out.mkdir(parents=True)
    receipt=dict(passed=False,game_test=False,installed=False,power_loss_test=False,output=str(out),cases=[])
    spec=importlib.util.spec_from_file_location('toolchain',ROOT/'experiments/native-settings-bridge/check_link.py')
    tc=importlib.util.module_from_spec(spec);spec.loader.exec_module(tc)
    include=tc.SDK.parents[1]/'Include'/tc.SDK.name
    env={**os.environ,'CL':'','_CL_':'','LINK':'','_LINK_':'',
         'INCLUDE':';'.join(map(str,[tc.VC/'include',include/'ucrt',include/'um',include/'shared'])),
         'LIB':';'.join(map(str,[tc.VC/'lib/x64',tc.SDK/'ucrt/x64',tc.SDK/'um/x64']))}
    def child(args,log,timeout=30):
        # Timeout terminates ONLY this exact Popen child; never enumerate/kill game processes.
        with subprocess.Popen(list(map(str,args)),stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,
                              creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0)) as p:
            try: stdout,stderr=p.communicate(timeout=timeout)
            except subprocess.TimeoutExpired:
                p.kill();stdout,stderr=p.communicate();(out/log).write_bytes(stdout+stderr)
                raise RuntimeError('own helper timeout: '+log)
            (out/log).write_bytes(stdout+stderr)
            return p.returncode,stdout.decode(errors='strict').replace('\r\n','\n'),p.pid
    def success(args,log,timeout=30):
        code,text,_=child(args,log,timeout);require(code==0,log+' failed');return text
    try:
        paths=list(CORE.glob('*.cpp'))+list(CORE.glob('*.hpp'))+list((ROOT/'Scripts').glob('*.lua'))
        paths += [Path(__file__),ROOT/'experiments/save_scope.lua',ROOT/'experiments/save_settings_codec.lua',
                  ROOT/'experiments/native-settings-bridge/check_link.py']
        before={p.relative_to(ROOT).as_posix():digest(p) for p in sorted(set(paths))};receipt['sources']=before
        sys.path.insert(0,str(ROOT/'.test-deps'))
        from lupa.lua54 import LuaRuntime
        lua=LuaRuntime(unpack_returned_tuples=True);lua.globals().ROOT=ROOT.as_posix()
        values=lua.execute('''
            package.path=ROOT..'/Scripts/?.lua;'..package.path
            package.loaded.log={warn=function()end,error=function()end}
            local Store,Caps=require('store'),require('caps')
            local Codec=dofile(ROOT..'/experiments/save_settings_codec.lua')
            codecs={}
            for _,s in ipairs({'limits','priorities'})do
                codecs[s]=Codec.new{storage=string.rep('1',32),guild=string.rep('2',32),stream=s}
            end
            return assert(codecs.limits.encode(Caps.serialize_snapshot({[string.rep('2',32)]={Mining={Stone=100,Ore=false}}}))),
                assert(codecs.limits.encode(Caps.serialize_snapshot({[string.rep('2',32)]={Mining={Stone=200,Ore=false}}}))),
                assert(codecs.priorities.encode(Store.serialize_snapshot({pal={[1]=2,[2]=false}},true))),
                assert(codecs.priorities.encode(Store.serialize_snapshot({pal={[1]=4,[2]=false}},false)))
        ''')
        payloads={s:{'old':values[i*2].encode(),'new':values[i*2+1].encode()} for i,s in enumerate(('limits','priorities'))}
        supported=lua.eval('''function(s,p)
            local v=codecs[s].decode(p)
            if not v then return false end
            return s=='priorities' and v.data.pal[2]==false
                or s=='limits' and v.data[string.rep('2',32)].Mining.Ore==false
        end''')
        header='#pragma once\n#include <string>\n'
        for stream,choices in payloads.items():
            for label,raw in choices.items():
                header+='inline const std::string crash_'+stream+'_'+label+'="'+''.join('\\x%02x'%b for b in raw)+'";\n'
        (out/'draining_crash_payloads.hpp').write_text(header)
        receipt['payload_header_sha256']=digest(out/'draining_crash_payloads.hpp')
        common=[]
        for name in ('root_capability','owner','record','record_reader','journal','backend','draining_writer'):
            obj=out/(name+'.obj');common.append(obj)
            success([tc.BIN/'cl.exe','/nologo','/c','/std:c++17','/W4','/WX','/EHsc','/MD','/O2','/DNDEBUG',
                     '/DPWP_JOURNAL_TESTING','/DPWP_DRAINING_WRITER_TESTING','/Fo'+str(obj),CORE/(name+'.cpp')],name+'-compile.log',120)
        executables={}
        for variant in ('crash','inert'):
            obj=out/(variant+'.obj');exe=out/(variant+'.exe');executables[variant]=exe
            defines=['/DPWP_CRASH_INERT'] if variant=='inert' else []
            success([tc.BIN/'cl.exe','/nologo','/c','/std:c++17','/W4','/WX','/EHsc','/MD','/O2','/DNDEBUG',
                     *defines,'/I'+str(out),'/Fo'+str(obj),CORE/'draining_crash_test.cpp'],variant+'-compile.log',120)
            success([tc.LINK_BIN/'link.exe','/nologo','/machine:x64','/subsystem:console','/out:'+str(exe),obj,*common,
                     'bcrypt.lib'],variant+'-link.log',120)
        seed=out/'seed';seed.mkdir()
        success([executables['crash'],seed,'seed'],'seed.log')
        require(len(list(seed.iterdir()))==4,'exact four seeded journals')
        def scope(s):return 'PWP-SCOPE-1:'+WORLD+':'+GUILD+':'+s
        def leaf(root,s,slot):return root/('pwp-record-v1-'+WORLD+'-'+GUILD+'-'+s+'-'+slot+'.record')
        for stream in payloads:
            for slot,g in [('A',1),('B',2)]:
                require(parse_record(leaf(seed,stream,slot),scope(stream))==(g,payloads[stream]['old']),'actual seed mismatch')
        def create_case(name):
            folder=out/name;folder.mkdir();root=folder/'store';root.mkdir()
            for p in seed.iterdir():shutil.copy2(p,root/p.name)
            return folder,root
        def verify_crash(result,folder,stream,point,scenario,nonce):
            code,_,pid=result
            require(code==91,'designated self-termination exit91 missing')
            marker=folder/'point-reached.tsv'
            require(marker.exists(),'designated hook marker missing')
            fields=marker.read_text().strip().split('\t')
            require(len(fields)==(10 if scenario=='concurrent' else 6) and fields[:4]==[point,stream,scenario,nonce]
                    and fields[4]==str(pid) and fields[5].isdigit() and int(fields[5])>0,'hook marker mismatch')
            if scenario=='concurrent':require(fields[6:]==['1','0','1','0'],'both actual accepted tails must be unacknowledged at crash')
        def selection_oracle(recovered,stream,point,scenario):
            require(set(recovered)=={'limits','priorities'},'both candidate streams required')
            for s in ('limits','priorities'):
                latest='new' if (s==stream and point in POST)or(s!=stream and scenario=='mixed')else'old'
                require(recovered[s]==(3 if latest=='new'else 2,payloads[s][latest]),'wrong publication-boundary recovery')
        def artifact_oracle(root,stream,point,scenario):
            expected_names=set()
            for s in ('limits','priorities'):
                for slot in ('A','B'):
                    value=(2,payloads[s]['old'])
                    if slot=='A':
                        if s==stream and point in ('after_backup','before_publish'):value=None
                        else:
                            new=(s==stream and point in POST)or(s!=stream and scenario=='mixed')
                            value=(3 if new else 1,payloads[s]['new'if new else'old'])
                    path=leaf(root,s,slot)
                    require(parse_record(path,scope(s))==value,'full canonical pair mismatch: '+s+'-'+slot)
                    if value is not None:expected_names.add(path.name)
            stages=list(root.glob('pwp-journal-stage-*'));backups=list(root.glob('pwp-journal-backup-*'))
            stage_expected=point not in POST
            backup_expected=point in ('after_backup','before_publish','after_publish')
            require(len(stages)==int(stage_expected) and len(backups)==int(backup_expected),'wrong orphan stage/backup count')
            tokens=[]
            for kind,paths in (('stage',stages),('backup',backups)):
                for path in paths:
                    match=re.fullmatch(r'pwp-journal-'+kind+r'-([0-9a-f]{32})\.'+('tmp'if kind=='stage'else'record'),path.name)
                    require(match is not None,'unexpected orphan name');tokens.append(match[1]);expected_names.add(path.name)
                    if kind=='stage' and point=='before_write':require(path.read_bytes()==b'','unwritten stage must be empty')
                    else:
                        value=parse_record(path,scope(stream))
                        require(value==(3,payloads[stream]['new'])if kind=='stage'else value==(1,payloads[stream]['old']),
                                'orphan exact bytes/generation mismatch')
                        require(supported(stream,value[1].decode()),'orphan typed X/OFF validation failed')
            require(len(set(tokens))<=1,'stage and backup nonce mismatch')
            require({p.name for p in root.iterdir()}==expected_names,'unexpected/disappeared crash artifact')
        observations={}
        for scenario in ('single','mixed','concurrent'):
            for stream in ('limits','priorities'):
                for point in (('after_backup','after_publish')if scenario=='concurrent'else POINTS):
                    name=scenario+'-'+stream+'-'+point;folder,root=create_case(name);nonce=uuid.uuid4().hex
                    other='priorities' if stream=='limits' else 'limits'
                    unchanged={p.name:digest(p) for p in root.iterdir() if '-'+other+'-' in p.name}
                    result=child([executables['crash'],root,'crash',stream,point,scenario,nonce],name+'-crash.log')
                    verify_crash(result,folder,stream,point,scenario,nonce)
                    if scenario=='mixed':require('OTHER_COMMITTED\t'+other+'\n' in result[1],'other stream commit not observed')
                    if scenario!='mixed':require(unchanged=={p.name:digest(p) for p in root.iterdir() if '-'+other+'-' in p.name},'untouched stream bytes changed')
                    artifact_oracle(root,stream,point,scenario)
                    disk_before={p.name:digest(p) for p in root.iterdir()}
                    text=success([executables['crash'],root,'recover'],name+'-recover.log')
                    require(disk_before=={p.name:digest(p) for p in root.iterdir()},'fresh recovery modified files')
                    recovered={};slots={}
                    for line in text.splitlines():
                        fields=line.split('\t')
                        if fields[0]=='RECOVER':
                            require(len(fields)==4 and fields[1]not in recovered,'invalid candidate report')
                            recovered[fields[1]]=(int(fields[2]),bytes.fromhex(fields[3]))
                        elif fields[0]=='SLOT':
                            require(len(fields)==6 and (fields[1],fields[2])not in slots,'invalid slot report')
                            require(fields[3]in ('valid','missing'),'unsafe slot')
                            slots[fields[1],fields[2]]=None if fields[3]=='missing' else (int(fields[4]),bytes.fromhex(fields[5]))
                    require(len(recovered)==2 and len(slots)==4,'both streams and BOTH slots required')
                    selection_oracle(recovered,stream,point,scenario)
                    for s in ('limits','priorities'):
                        for slot in ('A','B'):
                            parsed=parse_record(leaf(root,s,slot),scope(s));require(parsed==slots[s,slot],'native/independent slot mismatch')
                            if parsed:
                                require(parsed[1]in payloads[s].values(),'slot payload not exact old/new')
                                require(supported(s,parsed[1].decode()),'Lua codec/X/OFF validation failed')
                        if s==other:
                            # The non-target stream's entire canonical pair is exact.
                            require(slots[s,'B']==(2,payloads[s]['old']),'other old slot changed')
                            require(slots[s,'A']==(3 if scenario=='mixed'else 1,payloads[s]['new' if scenario=='mixed'else'old']),
                                    'other stream pair changed')
                    artifact_oracle(root,stream,point,scenario)
                    observations[name]=(root,recovered)
                    receipt['cases'].append(dict(scenario=scenario,stream=stream,point=point,exit=91,nonce=nonce,passed=True,
                                                artifacts=disk_before))
        negatives=[]
        for variant,point in [('inert','after_write'),('crash','missing_hook')]:
            folder,root=create_case('negative-'+variant);nonce=uuid.uuid4().hex
            result=child([executables[variant],root,'crash','priorities',point,'single',nonce],'negative-'+variant+'.log')
            require(result[0]==0 and 'NO_CRASH' in result[1],'negative helper must complete, not fail unrelatedly')
            try:verify_crash(result,folder,'priorities',point,'single',nonce)
            except RuntimeError as exc:negatives.append({'variant':variant,'rejected':str(exc)})
            else:raise RuntimeError('inert/missing-hook mutant accepted')
        mutations=[]
        def reject(name,fn):
            try:fn()
            except RuntimeError as exc:mutations.append({'mutant':name,'rejected':str(exc)})
            else:raise RuntimeError('oracle accepted mutant: '+name)
        base,observed=observations['concurrent-priorities-after_publish']
        # Selection mutants leave valid disk unchanged: these exercise candidate
        # selection separately from checksum/slot agreement checks.
        older=dict(observed);older['priorities']=(2,payloads['priorities']['old'])
        reject('older-candidate',lambda:selection_oracle(older,'priorities','after_publish','concurrent'))
        swapped={'limits':observed['priorities'],'priorities':observed['limits']}
        reject('stream-swap',lambda:selection_oracle(swapped,'priorities','after_publish','concurrent'))
        def mutant_root(name,source):
            folder=out/('mutant-'+name);folder.mkdir();root=folder/'store';shutil.copytree(source,root);return root
        before_publish,_=observations['concurrent-priorities-after_backup']
        promoted=mutant_root('stage-promotion',before_publish)
        next(promoted.glob('pwp-journal-stage-*')).rename(leaf(promoted,'priorities','A'))
        reject('stage-promotion',lambda:artifact_oracle(promoted,'priorities','after_backup','concurrent'))
        replayed=mutant_root('tail-replay',base)
        s=scope('limits').encode();p=payloads['limits']['new']
        raw=b'PWPJNL1\n'+struct.pack('<HII',len(s),3,len(p))+s+p
        leaf(replayed,'limits','A').write_bytes(raw+hashlib.sha256(raw).digest())
        reject('tail-replay',lambda:artifact_oracle(replayed,'priorities','after_publish','concurrent'))
        missing=mutant_root('nonselected-slot-disappeared',base);leaf(missing,'priorities','B').unlink()
        reject('nonselected-slot-disappeared',lambda:artifact_oracle(missing,'priorities','after_publish','concurrent'))
        corrupt=mutant_root('checksum',base);path=leaf(corrupt,'priorities','A');raw=bytearray(path.read_bytes());raw[-1]^=1;path.write_bytes(raw)
        reject('checksum',lambda:parse_record(path,scope('priorities')))
        after={name:digest(ROOT/name) for name in before}
        require(before==after,'sources changed during test')
        receipt.update(passed=True,source_stable=True,tests=len(receipt['cases']),negative_controls=negatives,
                       binaries={k:digest(v) for k,v in executables.items()},
                       actual_writer=True,independent_sha256=True,both_slots_typed=True,full_artifact_oracle=True,
                       both_pending_cases=4,oracle_mutants=mutations,
                       scope='process interruption only; exact old before publish, exact new after publish; mixed generations permitted')
    except Exception as exc:receipt['error']=str(exc)
    (out/'receipt.json').write_text(json.dumps(receipt,indent=2))
    print(json.dumps({k:v for k,v in receipt.items() if k not in ('sources','cases')},indent=2))
    print('RECEIPT='+str(out/'receipt.json'))
    return 0 if receipt['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
