"""Isolated build, actual entry/real IO regressions and pinned public import audit.
No install, no UE4SS load, no live-root creation. All test artifacts below build/.
"""
from pathlib import Path, PureWindowsPath
import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import uuid

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
OUT = HERE / 'build'
# Reuse read-only toolchain / exact pinned public-import allowlist.
spec = importlib.util.spec_from_file_location('settings_build', HERE.parent / 'native-settings-bridge/check_link.py')
prior = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prior)
ALLOWED, VC, BIN, LINK_BIN, SDK, PRE, DLL = (getattr(prior, k) for k in ('ALLOWED','VC','BIN','LINK_BIN','SDK','PRE','DLL'))

def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()

def sources():
    paths = [p for p in HERE.rglob('*') if p.is_file() and 'build' not in p.relative_to(HERE).parts and '__pycache__' not in p.parts]
    paths += [p for p in (ROOT/'native/save_core').glob('*') if p.suffix in {'.cpp','.hpp'}]
    paths += [HERE.parent/'native-settings-bridge/check_link.py', ROOT/'Scripts/store.lua', ROOT/'Scripts/caps.lua',
              ROOT/'experiments/save_settings_codec.lua', ROOT/'experiments/save_scope.lua', ROOT/'experiments/save_native_backend.lua']
    return {str(p.relative_to(ROOT)):digest(p) for p in sorted(paths)}

def run(args,label,**kw):
    p=subprocess.run(list(map(str,args)),capture_output=True,timeout=120,**kw)
    (OUT/label).write_bytes(p.stdout+p.stderr)
    if p.returncode: raise RuntimeError(label+' failed')
    return p.stdout.decode(errors='replace')

def main():
    OUT.mkdir(exist_ok=True)
    # Preserve the prior evidence (and its binary when present) BEFORE any
    # compile/link output can replace it. Failure here must leave receipt intact.
    previous = OUT/'receipt.json'
    archived = None
    if previous.exists():
        archived = OUT/('previous-build-'+uuid.uuid4().hex[:12])
        archived.mkdir()
        for old in [previous, OUT/'pwp_draining_bridge.dll']:
            if old.exists():
                saved = archived/old.name
                shutil.copy2(old, saved)
                if digest(saved) != digest(old): raise RuntimeError('prior build preservation failed')
    receipt=dict(compiled=False,linked=False,source_stable=False,compiled_root_verified=False,game_installed=False,runtime_abi_verified=False,
                 production_bridge_changed=False,protocol='fixed5-to6; recovery16; status16; raw600000; no paths')
    if archived: receipt['previous_build_archive'] = str(archived)
    try:
        before=sources()
        if digest(DLL)!=prior.EXPECTED: raise RuntimeError('pinned runtime changed')
        header_receipt=json.loads((PRE/'receipt.json').read_text())
        for name in ['source/deps/first/LuaMadeSimple/include/LuaMadeSimple/LuaMadeSimple.hpp','source/deps/first/LuaRaw/include/lua.h']:
            if digest(PRE/name)!=header_receipt['hashes'][name]:raise RuntimeError('pinned header changed')
        wrapper=PRE/'source/deps/first/LuaMadeSimple/src/LuaMadeSimple.cpp'
        if 'lua_pushlstring(get_lua_state(), str.data(), str.length());' not in wrapper.read_text():raise RuntimeError('binary setter changed')
        receipt.update(staged_runtime_sha256=digest(DLL),wrapper_source_sha256=digest(wrapper))
        dispatch=(HERE/'dispatch.hpp').read_text()
        # Read the exact non-test compile-time literal, never a runtime path input.
        roots=re.findall(r'root=experimental::RootCapability::open\(\s*'
                         r'#ifdef PWP_DRAINING_BRIDGE_TEST\s*pwp_draining_test_root,\s*'
                         r'#else\s*L("(?:[^"\\]|\\.)*"),\s*#endif',dispatch)
        if len(roots)!=1:raise RuntimeError('fixed compiled root declaration changed')
        compiled_root=json.loads(roots[0])
        if not PureWindowsPath(compiled_root).is_absolute():raise RuntimeError('compiled root must be absolute')
        receipt['compiled_root']=compiled_root
        if 'static Registry* const instance=new Registry' not in dispatch or 'static Registry registry' in dispatch:
            raise RuntimeError('registry must be intentionally process-lifetime')
        if 'if(!slot.joined||slot.writer->status().phase!=DrainPhase::closed)return {};' not in dispatch:
            raise RuntimeError('cleanup join/closed preflight changed')
        if dispatch.count('slot.writer.reset()')!=1:raise RuntimeError('unexpected writer destruction')
        if re.search(r'\bDllMain\s*\(', '\n'.join(p.read_text() for p in HERE.glob('*.cpp'))):raise RuntimeError('DllMain logic forbidden')
        entry=(HERE/'entry.cpp').read_text()
        correct='const auto ticket=lua.get_integer(3);\n        const auto handle=lua.get_integer(2);\n        const auto command=lua.get_integer(1);'
        legacy='const auto command=lua.get_integer(1);\n        const auto handle=lua.get_integer(2);\n        const auto ticket=lua.get_integer(3);'
        if entry.count(correct)!=1 or entry.count('lua.insert_value(1,2);')!=1:raise RuntimeError('update parser mutants')
        (OUT/'entry_legacy_mutant.inc').write_text(entry.replace(correct,legacy))
        (OUT/'entry_unrooted_mutant.inc').write_text(entry.replace('lua.insert_value(1,2);','// unrooted mutant'))
        test_root=OUT/('fs-'+uuid.uuid4().hex[:8])/'store'
        test_root.mkdir(parents=True)
        (OUT/'real_test_root.hpp').write_text('#pragma once\ninline constexpr wchar_t pwp_draining_test_root[]=L'+json.dumps(str(test_root))+';\n')
        sys.path.insert(0,str(ROOT/'.test-deps'))
        from lupa.lua54 import LuaRuntime
        lua=LuaRuntime(unpack_returned_tuples=True)
        lua.globals().TEST_ROOT=ROOT.as_posix()
        payloads=lua.execute('''
            package.path=TEST_ROOT..'/Scripts/?.lua;'..package.path
            package.loaded.datafile={read=function()error('IO')end,write=function()error('IO')end}
            package.loaded.log={warn=function()end,error=function()end}
            local Store=require('store')
            local Caps=require('caps')
            codec=dofile(TEST_ROOT..'/experiments/save_settings_codec.lua').new{
                storage=string.rep('1',32),guild=string.rep('2',32),stream='priorities'}
            limits_codec=dofile(TEST_ROOT..'/experiments/save_settings_codec.lua').new{
                storage=string.rep('1',32),guild=string.rep('2',32),stream='limits'}
            wire=dofile(TEST_ROOT..'/experiments/save_native_backend.lua')
            return assert(codec.encode(Store.serialize_snapshot({pal={[1]=false,[2]=3}},true))),
                assert(codec.encode(Store.serialize_snapshot({pal={[1]=2,[2]=4}},false))),
                assert(limits_codec.encode(Caps.serialize_snapshot({[string.rep('2',32)]={Mining={Stone=100}}}))),
                assert(limits_codec.encode(Caps.serialize_snapshot({[string.rep('2',32)]={Mining={Stone=200}}}))),
                assert(codec.encode(Store.serialize_snapshot({pal={[1]=2,[2]=false}},false)))
        ''')
        generated='#pragma once\n#include <string>\n'
        for name,payload in zip(['pwp_typed_payload_1','pwp_typed_payload_2','pwp_limits_payload_1','pwp_limits_payload_2',
                                 'pwp_combined_priority_payload'],payloads):
            generated+='inline const std::string '+name+'="'+''.join('\\x%02x'%b for b in payload.encode())+'";\n'
        (OUT/'real_test_payload.hpp').write_text(generated)
        run(['powershell','-NoProfile','-File',HERE/'compile.ps1'],'compile.log')
        receipt['compiled']=True
        needed=set(re.findall(r'UNDEF.*?\| __imp_(\S*LuaMadeSimple\S*)',(OUT/'symbols.txt').read_text()))
        if needed!=ALLOWED:raise RuntimeError('unexpected wrapper imports '+repr(needed^ALLOWED))
        exports=run([BIN/'dumpbin.exe','/exports',DLL],'runtime-exports.txt')
        exported=set(re.findall(r'^\s*\d+\s+[0-9A-F]+\s+[0-9A-F]+\s+(\S+)',exports,re.M))
        if not ALLOWED<=exported:raise RuntimeError('public import absent from pinned DLL')
        (OUT/'UE4SS.def').write_text('LIBRARY UE4SS.dll\nEXPORTS\n'+'\n'.join(sorted(ALLOWED))+'\n')
        run([LINK_BIN/'lib.exe','/nologo','/machine:x64','/def:'+str(OUT/'UE4SS.def'),'/out:'+str(OUT/'UE4SS.lib')],'import-library.log')
        env={**os.environ,'LINK':'','_LINK_':'','LIB':';'.join(map(str,[VC/'lib/x64',SDK/'ucrt/x64',SDK/'um/x64']))}
        common=[OUT/(x+'.obj') for x in ['owner','record','record_reader','root_capability','backend']]
        test_objects=common+[OUT/'journal_test.obj',OUT/'draining_writer_test.obj']
        for unit in ['entry_test','entry_legacy_test','entry_unrooted_test']:
            run([LINK_BIN/'link.exe','/nologo','/machine:x64','/subsystem:console','/out:'+str(OUT/(unit+'.exe')),
                 OUT/(unit+'.obj'),*test_objects,'bcrypt.lib'],unit+'-link.log',env=env)
        for unit in ['entry_legacy_test','entry_unrooted_test']:
            p=subprocess.run([str(OUT/(unit+'.exe'))],capture_output=True,timeout=30)
            (OUT/(unit+'.log')).write_bytes(p.stdout+p.stderr)
            if p.returncode!=1 or b'REGRESSION: actual entry popped-argument/rooted-input configure failed' not in p.stderr:
                raise RuntimeError(unit+' failed to reject targeted mutant')
        # Each process shares one compile-time path; archive only its bounded test
        # leaves between scenarios. No live root / production destination touched.
        def archive(mode):
            target=test_root.parent/mode;target.mkdir()
            for p in test_root.iterdir():p.rename(target/p.name)
        for mode in ['teardown','capacity','normal','uncertain','two-stream-pending']:
            log=run([OUT/'entry_test.exe',mode],'entry-'+mode+'.log')
            if mode=='normal':
                recovered=re.findall(r'^TYPED_[AB]_HEX=([0-9a-f]+)\r?$',log,re.M)
                if len(recovered)!=2:raise RuntimeError('missing exact recovered payloads')
                for i,encoded in enumerate(recovered):
                    payload=bytes.fromhex(encoded).decode()
                    if payload!=payloads[i] or not lua.eval('function(p)return codec.supported(p)end')(payload):
                        raise RuntimeError('actual codec rejected recovered bytes')
            if mode=='two-stream-pending':
                if 'BOTH_PENDING limits=3/0 priorities=3/0' not in log:
                    raise RuntimeError('missing simultaneous pending evidence')
                if 'JOIN_PENDING limits=3/0 priorities=3/0' not in log:
                    raise RuntimeError('missing pending evidence inside both real drain/join paths')
                recovered=re.findall(r'^COMBINED_(limits|priorities)_HEX=([0-9a-f]+)\r?$',log,re.M)
                if [stream for stream,_ in recovered]!=['limits','priorities']:
                    raise RuntimeError('missing separate latest stream recoveries')
                for stream,encoded in recovered:
                    payload=bytes.fromhex(encoded).decode()
                    expected=payloads[3] if stream=='limits' else payloads[4]
                    supported=lua.eval('function(p,s)return (s=="limits" and limits_codec or codec).supported(p)end')
                    if payload!=expected or not supported(payload,stream):
                        raise RuntimeError('combined exact typed recovery failed: '+stream)
                    if stream=='priorities' and not lua.eval(
                            'function(p)local s=codec.decode(p);return s and s.data.pal[2]==false end')(payload):
                        raise RuntimeError('combined recovered X did not decode to false')
            archive(mode)
        receipt.update(entry_tests_passed=True,real_filesystem_tests_passed=True,typed_recovery_validated=True,
                       legacy_parser_mutant_rejected=True,unrooted_input_mutant_rejected=True,
                       normal_crt_exit_with_live_worker_passed=True,registry_destructor_guard_passed=True,
                       lost_reply_ticket_tested=True,post_publication_uncertainty_tested=True,real_test_root=str(test_root),
                       two_stream_pending_drain_tested=True,two_stream_latest_typed_recovery_validated=True,
                       two_stream_pending_at_real_join_tested=True,
                       two_stream_existing_update_scope=True,both_retired_before_drain_tested=True,
                       two_stream_priority_x_roundtrip_tested=True)
        target=OUT/'pwp_draining_bridge.dll'
        run([LINK_BIN/'link.exe','/nologo','/dll','/machine:x64','/out:'+str(target),OUT/'entry.obj',*common,
             OUT/'journal.obj',OUT/'draining_writer.obj',OUT/'UE4SS.lib','bcrypt.lib'],'link.log',env=env)
        imports=run([BIN/'dumpbin.exe','/imports',target],'imports.txt')
        actual=set(re.findall(r'^\s+[0-9A-F]+\s+(\S*LuaMadeSimple\S*)',imports,re.M))
        if actual!=ALLOWED or re.search(r'\b(lua_\w+|luaL_\w+|lua54\.dll)\b',imports):raise RuntimeError('linked import mismatch')
        exports=run([BIN/'dumpbin.exe','/exports',target],'exports.txt')
        names=set(re.findall(r'^\s*\d+\s+[0-9A-F]+\s+[0-9A-F]+\s+(\S+)',exports,re.M))
        if names!={'luaopen_pwp_draining_bridge'}:raise RuntimeError('unexpected exports')
        if (compiled_root+'\0').encode('utf-16le') not in target.read_bytes():
            raise RuntimeError('compiled root literal absent from linked DLL')
        if before!=sources():raise RuntimeError('source changed during build')
        receipt.update(linked=True,source_stable=True,compiled_root_verified=True,sources=before,
                       wrapper_imports=sorted(ALLOWED),probe_sha256=digest(target))
    except Exception as e:receipt['error']=str(e)
    (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2))
    print(json.dumps({k:v for k,v in receipt.items() if k not in {'sources','wrapper_imports'}},indent=2))
    return 0 if receipt.get('source_stable') and not receipt.get('error') else 1

if __name__=='__main__':raise SystemExit(main())
