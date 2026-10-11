"""Build/test an isolated DEV ONLY existing-journal pending-update gate.
No install, DLL load, game, watcher, or writes to the compiled journal root.
Run: python experiments/native-draining-bridge/build_live_pending.py
"""
from pathlib import Path
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
import uuid

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
spec = importlib.util.spec_from_file_location('toolchain', HERE.parent/'native-settings-bridge/check_link.py')
tc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tc)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    out = HERE/'build'/('live-pending-'+uuid.uuid4().hex[:12])
    out.mkdir(parents=True)
    evidence = out/'live-evidence.tsv'
    artifact = out/'pwp_draining_bridge_DEV_PENDING_ONLY.dll'
    receipt = dict(test_only=True, bounded_hold_ms=60000, tests_passed=False, source_stable=False,
                   artifact=str(artifact), evidence_path=str(evidence), installed=False,
                   runtime_abi_verified=False, macro='PWP_LIVE_PENDING_GATE_DEV_ONLY')
    def run(args, label, timeout=120):
        p = subprocess.run(list(map(str,args)), capture_output=True, timeout=timeout, env=env)
        (out/(label+'.log')).write_bytes(p.stdout+p.stderr)
        if p.returncode:
            raise RuntimeError(label+' failed: '+(p.stdout+p.stderr).decode(errors='replace')[-1000:])
        return p.stdout.decode(errors='replace')
    try:
        paths = list((ROOT/'native/save_core').glob('*.cpp'))+list((ROOT/'native/save_core').glob('*.hpp'))
        paths += [p for p in HERE.iterdir() if p.suffix in {'.cpp','.hpp','.py','.ps1'}]
        paths += list((HERE/'test-stubs').rglob('*.hpp'))
        paths += list((ROOT/'Scripts').glob('*.lua'))
        paths += [ROOT/p for p in ('Scripts/store.lua','Scripts/caps.lua','experiments/save_scope.lua',
                                   'experiments/save_settings_codec.lua','experiments/native-settings-bridge/check_link.py')]
        before = {p.relative_to(ROOT).as_posix():digest(p) for p in sorted(set(paths))}
        receipt['sources'] = before
        if digest(tc.DLL) != tc.EXPECTED:
            raise RuntimeError('pinned runtime changed')
        receipt['staged_runtime_sha256'] = digest(tc.DLL)
        header_receipt = json.loads((tc.PRE/'receipt.json').read_text())
        for name in ('source/deps/first/LuaMadeSimple/include/LuaMadeSimple/LuaMadeSimple.hpp',
                     'source/deps/first/LuaRaw/include/lua.h'):
            if digest(tc.PRE/name) != header_receipt['hashes'][name]:
                raise RuntimeError('pinned header changed')
        dispatch = (HERE/'dispatch.hpp').read_text()
        roots = re.findall(r'#else\s*L("(?:[^"\\]|\\.)*"),\s*#endif',dispatch)
        if len(roots) != 1:
            raise RuntimeError('compiled root declaration changed')
        journal_root = Path(json.loads(roots[0]))
        if not journal_root.is_absolute():
            raise RuntimeError('absolute compiled root required')
        receipt['compiled_root'] = str(journal_root)
        leaves = sorted(journal_root.glob('*.record'))
        parsed = [re.fullmatch(r'pwp-record-v1-([a-f0-9]{32})-([a-f0-9]{32})-(limits|priorities)-([AB])\.record',p.name)
                  for p in leaves]
        if len(leaves)!=4 or not all(parsed) or len({m.group(1,2) for m in parsed})!=1:
            raise RuntimeError('exact existing four-journal target required')
        if {m.group(3,4) for m in parsed}!={('limits','A'),('limits','B'),('priorities','A'),('priorities','B')}:
            raise RuntimeError('both journal pairs required')
        storage,guild = parsed[0].group(1,2)
        receipt.update(storage=storage,guild=guild,protected_journals={p.name:digest(p) for p in leaves})
        sdk_include = tc.SDK.parents[1]/'Include'/tc.SDK.name
        env={**os.environ,'CL':'','_CL_':'','LINK':'','_LINK_':'',
             'INCLUDE':';'.join(map(str,[tc.VC/'include',sdk_include/'ucrt',sdk_include/'um',sdk_include/'shared'])),
             'LIB':';'.join(map(str,[tc.VC/'lib/x64',tc.SDK/'ucrt/x64',tc.SDK/'um/x64']))}
        def compile_unit(source,name,extra=()):
            run([tc.BIN/'cl.exe','/nologo','/c','/std:c++latest','/utf-8','/EHsc','/MD','/O2','/DNDEBUG','/W4','/WX',
                 '/Fo'+str(out/(name+'.obj')), *extra,source],name+'-compile')
        common=[]
        for name in ('owner','record','record_reader','root_capability','backend','journal'):
            compile_unit(ROOT/'native/save_core'/f'{name}.cpp',name);common.append(out/(name+'.obj'))
        compile_unit(ROOT/'native/save_core/draining_writer.cpp','writer-normal')
        normal_symbols=run([tc.BIN/'dumpbin.exe','/symbols',out/'writer-normal.obj'],'normal-symbols')
        if 'live_pending' in normal_symbols:
            raise RuntimeError('dev gate leaked into normal compilation')
        def config(name, world, group, logfile, timeout=None):
            path=out/(name+'.hpp')
            text='#pragma once\n#define PWP_LIVE_PENDING_GATE_DEV_ONLY 1\n'
            text+='#define PWP_LIVE_PENDING_EVIDENCE L'+json.dumps(str(logfile))+'\n'
            for stream in ('limits','priorities'):
                text+='#define PWP_LIVE_PENDING_'+stream.upper()+'_SCOPE '+json.dumps('PWP-SCOPE-1:'+world+':'+group+':'+stream)+'\n'
            if timeout is not None:
                text+='#define PWP_LIVE_PENDING_GATE_TESTING 1\n#define PWP_LIVE_PENDING_TEST_TIMEOUT_MS '+str(timeout)+'\n'
            path.write_text(text)
            return path
        live_config=config('live-config',storage,guild,evidence)
        compile_unit(ROOT/'native/save_core/draining_writer.cpp','writer-live',['/FI'+str(live_config)])
        # Generate a test-only copy of entry/dispatch with an isolated fixed root.
        # Production entry/dispatch and the normal build directory are untouched.
        test_root=out/'fixture-store';test_root.mkdir()
        root_header=out/'test-root.hpp'
        root_header.write_text('#pragma once\ninline constexpr wchar_t pwp_draining_test_root[]=L'+json.dumps(str(test_root))+';\n')
        test_dispatch=dispatch.replace('"build/real_test_root.hpp"',json.dumps(root_header.as_posix()))
        for inc in ('../../native/save_core/draining_writer.hpp','wire.hpp','terminal.hpp'):
            test_dispatch=test_dispatch.replace('"'+inc+'"',json.dumps((HERE/inc).resolve().as_posix()))
        (out/'test-dispatch.hpp').write_text(test_dispatch)
        (out/'test-entry.cpp').write_text((HERE/'entry.cpp').read_text().replace('"dispatch.hpp"','"test-dispatch.hpp"'))
        sys.path.insert(0,str(ROOT/'.test-deps'))
        from lupa.lua54 import LuaRuntime
        lua=LuaRuntime(unpack_returned_tuples=True);lua.globals().ROOT=ROOT.as_posix()
        payloads=lua.execute('''
            package.path=ROOT..'/Scripts/?.lua;'..package.path
            package.loaded.log={warn=function()end,error=function()end}
            local Store,Caps=require('store'),require('caps')
            local Codec=dofile(ROOT..'/experiments/save_settings_codec.lua')
            local function enc(s,b)return assert(Codec.new{storage=string.rep('1',32),guild=string.rep('2',32),stream=s}.encode(b))end
            local p=enc('priorities',assert(Store.serialize_snapshot({pal={[1]=2,[2]=false}},false)))
            local l=enc('limits',assert(Caps.serialize_snapshot({[string.rep('2',32)]={Mining={Stone=100}}})))
            local p2=enc('priorities',assert(Store.serialize_snapshot({pal={[1]=4,[2]=false}},false)))
            local l2=enc('limits',assert(Caps.serialize_snapshot({[string.rep('2',32)]={Mining={Stone=200}}})))
            return p,l,p2,l2
        ''')
        generated='#pragma once\n#include <string>\n'
        for name,payload in [('pwp_typed_payload_1',payloads[0]),('pwp_typed_payload_2',payloads[2]),
                             ('pwp_combined_priority_payload',payloads[2]),('pwp_limits_payload_1',payloads[1]),('pwp_limits_payload_2',payloads[3])]:
            generated+='inline const std::string '+name+'="'+''.join('\\x%02x'%b for b in payload.encode())+'";\n'
        (out/'payload.hpp').write_text(generated)
        baseline=(HERE/'entry_test.cpp').read_text()
        baseline=baseline[baseline.index('#include "build/real_test_payload.hpp"'):]
        baseline=baseline.replace('"build/real_test_payload.hpp"','"payload.hpp"')
        (out/'test-baseline.hpp').write_text('#include "test-entry.cpp"\n#define main baseline_main\n'+baseline+'\n#undef main\n')
        harness=r'''
#include "test-baseline.hpp"
#include "GATE_HEADER"
namespace lp=pwp::experimental::live_pending;
int main(int argc,char** argv){try{
    const bool timeout=argc>1&&std::string(argv[1])=="timeout";
    check(call(0).status==1,"configure");int handles[2];
    const std::string names[2]={"limits","priorities"};
    const std::string payloads[2]={pwp_limits_payload_1,pwp_combined_priority_payload};
    const std::string latest[2]={pwp_limits_payload_2,pwp_typed_payload_1};
    for(unsigned i=0;i<2;++i){
        for(unsigned gen=0;gen<2;++gen){
            int h=owner(guild,names[i]);check(call(2,h,1).status==1,"seed start");recovery(h);
            check(call(4,h,2,{gen?"existing":"initialize_missing"}).status==1,"seed approve");
            check(call(5,h,3,{payloads[i]}).status==1,"seed submit");drain(h,4);cleanup(h);
        }
        check(lp::test_parks==0,"seeding or partial pair must not park");
        handles[i]=owner(guild,names[i]);check(call(2,handles[i],1).status==1,"existing start");
        auto r=recovery(handles[i]);check(r[10]=="valid"&&r[13]=="valid","existing pair");
        check(call(4,handles[i],2,{"existing"}).status==1,"existing approval");
    }
    check(lp::test_parks==0,"readiness must not start hold");
    for(unsigned i=0;i<2;++i){
        check(call(5,handles[i],3,{payloads[i]}).status==1,"update submit");
        {std::unique_lock<std::mutex> lock(lp::test_mutex);
        check(lp::test_changed.wait_for(lock,std::chrono::seconds(10),[&]{return lp::test_parks==i+1;}),"parked update");}
        check(call(5,handles[i],4,{latest[i]}).status==1,"latest tail while first update held");
    }
    if(timeout){std::unique_lock<std::mutex> lock(lp::test_mutex);
        check(lp::test_changed.wait_for(lock,std::chrono::seconds(10),[]{return lp::test_timeouts==2;}),"bounded timeout releases");
    }else for(int h:handles){auto s=status(h);check(std::stoull(s[3])>std::stoull(s[4]),"both pending before travel");}
    for(int h:handles)check(call(7,h,5).status==1,"retire BOTH");
    for(int h:handles){drain(h,6);cleanup(h);}
    check(timeout||lp::test_timeouts==0,"join must beat timeout");
    for(unsigned i=0;i<2;++i){int h=owner(guild,names[i]);check(call(2,h,1).status==1,"reopen");auto r=recovery(h);
        check((r[11]=="4"&&r[12]==latest[i])||(r[14]=="4"&&r[15]==latest[i]),"exact latest tail recovered");drain(h,2);cleanup(h);}
    check(lua_State::worker_calls==0,"no worker Lua");std::cout<<"PASS actual entry live gate "<<(timeout?"timeout":"join")<<'\n';return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
'''.replace('GATE_HEADER',(HERE/'live_pending_gate.hpp').as_posix())
        (out/'gate-test.cpp').write_text(harness)
        for mode,ms in [('join',60000),('timeout',100)]:
            test_log=out/(mode+'-evidence.tsv')
            cfg=config(mode+'-config','1'*32,'2'*32,test_log,ms)
            compile_unit(ROOT/'native/save_core/draining_writer.cpp','writer-'+mode,
                         ['/FI'+str(cfg),'/DPWP_DRAINING_WRITER_TESTING'])
            compile_unit(out/'gate-test.cpp','test-'+mode,['/FI'+str(cfg),'/DPWP_DRAINING_BRIDGE_TEST',
                         '/I'+str(HERE/'test-stubs')])
            run([tc.LINK_BIN/'link.exe','/nologo','/machine:x64','/subsystem:console','/out:'+str(out/(mode+'.exe')),
                 out/('test-'+mode+'.obj'),out/('writer-'+mode+'.obj'),*common,'bcrypt.lib'],mode+'-link')
            run([out/(mode+'.exe'),mode],mode+'-run',90)
            rows=[line.split('\t') for line in test_log.read_text().splitlines()]
            if any(len(r)!=10 for r in rows):raise RuntimeError('malformed durable evidence')
            if mode=='join' and max(int(r[1]) for r in rows if r[2]=='park')>=min(int(r[1]) for r in rows if r[2]=='join'):
                raise RuntimeError('both holds must precede first original join')
            for stream in ('limits','priorities'):
                lane=[r for r in rows if r[3].endswith(':'+stream)]
                if sum(r[2]=='park' for r in lane)!=1:raise RuntimeError('gate not one-shot')
                joins=[r for r in lane if r[2]=='join' and r[6]!='accepted=0']
                if len(joins)!=1:raise RuntimeError('missing original join')
                j=joins[0]
                if mode=='join' and not (int(j[6].split('=')[1])>int(j[7].split('=')[1]) and j[8]=='parked=1' and j[9]=='timeout=0'):
                    raise RuntimeError('not parked/pending at original join')
                if mode=='timeout' and sum(r[2]=='timeout' for r in lane)!=1:raise RuntimeError('timeout missing')
            archive=out/(mode+'-records');archive.mkdir()
            for leaf in test_root.iterdir():leaf.rename(archive/leaf.name)
        compile_unit(HERE/'entry.cpp','entry',['/external:W0',
            '/external:I'+str(tc.PRE/'source/deps/first/LuaMadeSimple/include'),
            '/external:I'+str(tc.PRE/'source/deps/first/LuaRaw/include'),'/external:I'+str(tc.PRE/'thirdparty/fmt/include')])
        (out/'UE4SS.def').write_text('LIBRARY UE4SS.dll\nEXPORTS\n'+'\n'.join(sorted(tc.ALLOWED))+'\n')
        run([tc.LINK_BIN/'lib.exe','/nologo','/machine:x64','/def:'+str(out/'UE4SS.def'),'/out:'+str(out/'UE4SS.lib')],'import-lib')
        run([tc.LINK_BIN/'link.exe','/nologo','/dll','/machine:x64','/out:'+str(artifact),out/'entry.obj',out/'writer-live.obj',
             *common,out/'UE4SS.lib','bcrypt.lib'],'live-link')
        imports=run([tc.BIN/'dumpbin.exe','/imports',artifact],'imports')
        if set(re.findall(r'^\s+[0-9A-F]+\s+(\S*LuaMadeSimple\S*)',imports,re.M))!=tc.ALLOWED:
            raise RuntimeError('public imports changed')
        if re.search(r'\b(lua_\w+|luaL_\w+|lua54\.dll)\b',imports):raise RuntimeError('raw Lua import')
        exports=run([tc.BIN/'dumpbin.exe','/exports',artifact],'exports')
        if set(re.findall(r'^\s*\d+\s+[0-9A-F]+\s+[0-9A-F]+\s+(\S+)',exports,re.M))!={'luaopen_pwp_draining_bridge'}:
            raise RuntimeError('new public export')
        binary=artifact.read_bytes()
        for literal in (str(journal_root),str(evidence)):
            if (literal+'\0').encode('utf-16le')not in binary:raise RuntimeError('fixed path absent')
        if before!={name:digest(ROOT/name) for name in before}:raise RuntimeError('source changed during build')
        if receipt['protected_journals']!={p.name:digest(p) for p in leaves}:raise RuntimeError('target journals changed')
        receipt.update(tests_passed=True,source_stable=True,probe_sha256=digest(artifact),
                       compiled=True,linked=True,normal_macro_absent=True,timeout_test_ms=100,
                       evidence_schema='PWP_DEV_PENDING_1 TSV: UTC_FILETIME,event,scope,worker,caller,accepted,committed,parked,timeout',
                       evidence_events=['park','join','release_join','timeout','release_timeout','join_before_park'],
                       evidence_requires='both target scopes parked before external load_pre; original joins pending and parked; no timeout',
                       scope_handle_mapping='canonical scope plus worker; correlate stream with Lua native_exit handle',
                       test_scope='actual entry/filesystem; existing pairs; first update; per-owner join; accelerated timeout',
                       generated={p.name:digest(p) for p in out.iterdir() if p.suffix in {'.hpp','.cpp'}})
    except Exception as exc:
        receipt['error']=str(exc)
    (out/'receipt.json').write_text(json.dumps(receipt,indent=2))
    print(json.dumps({k:v for k,v in receipt.items() if k not in {'sources','generated','protected_journals'}},indent=2))
    print('RECEIPT='+str(out/'receipt.json'))
    return 0 if receipt['tests_passed'] and receipt['source_stable'] else 1


if __name__=='__main__':
    raise SystemExit(main())
