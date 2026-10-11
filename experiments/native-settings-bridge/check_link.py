"""Build the isolated bridge, execute actual-entry mocks, audit pinned public imports.
Never loads the production bridge or UE4SS, installs files, or starts the game.
"""
from pathlib import Path
import hashlib
import json
import os
import re
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
OUT = HERE / 'build'
PRE = ROOT / 'test-results/native-helper-prerequisites-2281fa31'
VC = Path('C:/Program Files/Microsoft Visual Studio/18/Community/VC/Tools/MSVC/14.50.35717')
BIN = VC / 'bin/Hostx64/x64'
LINK_BIN = ROOT / 'test-results/native-lua-entry-probe-20261004/toolchain/portable/VC/Tools/MSVC/14.51.36231/bin/Hostx64/x64'
SDK = Path('C:/Program Files (x86)/Windows Kits/10/Lib/10.0.26100.0')
DLL = PRE / 'UE4SS_v3.0.1-1097-g2281fa31/ue4ss/UE4SS.dll'
EXPECTED = '21b691a69a20c0801f465369d4fcbca7d7444764022fac2a7e8edc7709ef92b8'
ALLOWED = {
    '??0Lua@LuaMadeSimple@RC@@QEAA@PEAUlua_State@@@Z',
    '??1Lua@LuaMadeSimple@RC@@QEAA@XZ',
    '?get_stack_size@Lua@LuaMadeSimple@RC@@QEBAHXZ',
    '?insert_value@Lua@LuaMadeSimple@RC@@QEBAXHH@Z',
    '?is_string@Lua@LuaMadeSimple@RC@@QEBA_NH@Z',
    '?get_string@Lua@LuaMadeSimple@RC@@QEBA?AV?$basic_string_view@DU?$char_traits@D@std@@@std@@H@Z',
    '?is_integer@Lua@LuaMadeSimple@RC@@QEBA_NH@Z',
    '?get_integer@Lua@LuaMadeSimple@RC@@QEBA_JH@Z',
    '?set_integer@Lua@LuaMadeSimple@RC@@QEBAX_J@Z',
    '?set_string@Lua@LuaMadeSimple@RC@@QEBAXV?$basic_string_view@DU?$char_traits@D@std@@@std@@@Z',
}


def digest(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def sources():
    paths = [p for p in HERE.rglob('*') if p.is_file() and 'build' not in p.relative_to(HERE).parts
             and '__pycache__' not in p.parts]
    paths += [p for p in (ROOT / 'native/save_core').glob('*') if p.suffix in {'.cpp', '.hpp'}]
    paths += list((ROOT / 'Scripts').glob('*.lua'))
    paths += [ROOT / 'experiments' / name for name in ('save_settings_codec.lua','save_scope.lua')]
    return {str(p.relative_to(ROOT)): digest(p) for p in sorted(paths)}


def run(args, label, **kw):
    p = subprocess.run([str(a) for a in args], capture_output=True, timeout=120, **kw)
    (OUT / label).write_bytes(p.stdout + p.stderr)
    if p.returncode:
        raise RuntimeError(label + ' failed')
    return p.stdout.decode(errors='replace')


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    record = dict(compiled=False, linked=False, source_stable=False, loaded=False,
                  game_installed=False, runtime_abi_verified=False, private_sdk_used=False,
                  second_lua_linked=False, protocol='fixed5-to6; LEu32 fields; terminal16; max raw600000')
    try:
        before = sources()
        if digest(DLL) != EXPECTED:
            raise RuntimeError('staged runtime differs from pinned evidence')
        record['staged_runtime_sha256'] = EXPECTED
        prior = json.loads((PRE / 'receipt.json').read_text())
        for relative in ['source/deps/first/LuaMadeSimple/include/LuaMadeSimple/LuaMadeSimple.hpp',
                         'source/deps/first/LuaRaw/include/lua.h']:
            if digest(PRE / relative) != prior['hashes'][relative]:
                raise RuntimeError('pinned public header changed: ' + relative)
        cpp = PRE / 'source/deps/first/LuaMadeSimple/src/LuaMadeSimple.cpp'
        wrapper = cpp.read_text()
        expected_setter = 'lua_pushlstring(get_lua_state(), str.data(), str.length());'
        if expected_setter not in wrapper:
            raise RuntimeError('pinned binary setter changed')
        record['wrapper_source_sha256'] = digest(cpp)
        entry = (HERE / 'entry.cpp').read_text()
        correct = 'const auto ticket=lua.get_integer(3);\n        const auto handle=lua.get_integer(2);\n        const auto command=lua.get_integer(1);'
        legacy = 'const auto command=lua.get_integer(1);\n        const auto handle=lua.get_integer(2);\n        const auto ticket=lua.get_integer(3);'
        if entry.count(correct) != 1 or entry.count('lua.insert_value(1,2);') != 1:
            raise RuntimeError('entry parser changed: review mutants')
        (OUT / 'entry_legacy_mutant.inc').write_text(entry.replace(correct, legacy))
        (OUT / 'entry_unrooted_mutant.inc').write_text(entry.replace('lua.insert_value(1,2);', '// removed original-root duplication'))
        # The only test-root override is generated into the standalone executable
        # at compile time. No runtime path argument or production-root creation.
        test_root = ROOT / 'test-results' / ('nsb-offline-' + uuid.uuid4().hex[:12]) / 'store'
        test_root.mkdir(parents=True, exist_ok=False)
        (OUT / 'real_test_root.hpp').write_text('#pragma once\ninline constexpr wchar_t pwp_settings_test_root[]=L' + json.dumps(str(test_root)) + ';\n')
        sys.path.insert(0, str(ROOT / '.test-deps'))
        from lupa.lua54 import LuaRuntime
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().TEST_ROOT = ROOT.as_posix()
        payloads = lua.execute('''
            package.path=TEST_ROOT..'/Scripts/?.lua;'..package.path
            package.loaded.datafile={read=function()error('IO')end,write=function()error('IO')end}
            package.loaded.log={warn=function()error('log')end,error=function()error('log')end}
            local Store=require('store')
            local Codec=dofile(TEST_ROOT..'/experiments/save_settings_codec.lua')
            test_codec=Codec.new{storage=string.rep('a',32),guild=string.rep('b',32),stream='priorities'}
            local a=assert(test_codec.encode(Store.serialize_snapshot({pal={[1]=false,[2]=3}},true)))
            local b=assert(test_codec.encode(Store.serialize_snapshot({pal={[1]=2,[2]=4}},false)))
            return a,b
        ''')
        header = '#pragma once\n#include <string>\n'
        for i, payload in enumerate(payloads, 1):
            encoded = ''.join('\\x%02x' % b for b in payload.encode())
            header += f'inline const std::string pwp_typed_payload_{i}="{encoded}";\n'
        (OUT / 'real_test_payload.hpp').write_text(header)
        generated = {name: digest(OUT / name) for name in ('real_test_root.hpp','real_test_payload.hpp')}
        run(['powershell', '-NoProfile', '-File', HERE / 'compile.ps1'], 'compile-command.log')
        record['compiled'] = True
        needed = set(re.findall(r'UNDEF.*?\| __imp_(\S*LuaMadeSimple\S*)', (OUT / 'symbols.txt').read_text()))
        if needed != ALLOWED:
            raise RuntimeError('unexpected wrapper import surface: ' + repr(needed ^ ALLOWED))
        exports = run([BIN / 'dumpbin.exe', '/exports', DLL], 'staged-exports.txt')
        exported = set(re.findall(r'^\s*\d+\s+[0-9A-F]+\s+[0-9A-F]+\s+(\S+)', exports, re.M))
        if not ALLOWED <= exported:
            raise RuntimeError('compiled public imports absent from staged runtime')
        (OUT / 'UE4SS-bridge.def').write_text('LIBRARY UE4SS.dll\nEXPORTS\n' + '\n'.join(sorted(ALLOWED)) + '\n')
        run([LINK_BIN / 'lib.exe', '/nologo', '/machine:x64', '/def:' + str(OUT / 'UE4SS-bridge.def'),
             '/out:' + str(OUT / 'UE4SS-bridge.lib')], 'import-library.log')
        env = {**os.environ, 'LINK': '', '_LINK_': '',
               'LIB': ';'.join(map(str, [VC / 'lib/x64', SDK / 'ucrt/x64', SDK / 'um/x64']))}
        for unit in ('entry_test', 'entry_legacy_test', 'entry_unrooted_test'):
            run([LINK_BIN / 'link.exe', '/nologo', '/machine:x64', '/subsystem:console',
                 '/out:' + str(OUT / (unit + '.exe')), OUT / (unit + '.obj')], unit + '-link.log', env=env)
        run([OUT / 'entry_test.exe'], 'entry-tests.log')
        for mode in ('configure', 'capacity', 'open', 'recover', 'run', 'run_false', 'uncertain', 'release', 'release_false'):
            run([OUT / 'entry_test.exe', mode], 'entry-test-' + mode + '.log')
        record['entry_tests_passed'] = True
        for unit in ('entry_legacy_test', 'entry_unrooted_test'):
            p = subprocess.run([str(OUT / (unit + '.exe'))], capture_output=True, timeout=30)
            (OUT / (unit + '.log')).write_bytes(p.stdout + p.stderr)
            if p.returncode != 1 or b'REGRESSION: actual entry popped-argument/rooted-input configure failed' not in p.stderr:
                raise RuntimeError(unit + ' did not fail at targeted entry boundary')
        record.update(legacy_parser_mutant_rejected=True, unrooted_input_mutant_rejected=True,
                      terminal_fields=16, consume_lost_return_idempotence_tested=True,
                      test_boundary='actual entry+dispatcher+terminal serializer, fake Lua stack and native facade')
        native_objects = [OUT / (name + '.obj') for name in ('owner','record','journal','record_reader','root_capability','backend')]
        run([LINK_BIN / 'link.exe', '/nologo', '/machine:x64', '/subsystem:console',
             '/out:' + str(OUT / 'entry_real_test.exe'), OUT / 'entry_real_test.obj', *native_objects, 'bcrypt.lib'],
            'entry-real-link.log', env=env)
        actual_log = run([OUT / 'entry_real_test.exe'], 'entry-real-tests.log')
        recovered = re.findall(r'^TYPED_[AB]_HEX=([0-9a-f]+)\r?$', actual_log, re.M)
        if len(recovered) != 2:
            raise RuntimeError('real entry did not return both typed payloads')
        for i, encoded in enumerate(recovered):
            payload = bytes.fromhex(encoded).decode()
            if payload != payloads[i] or not lua.eval('function(p) return test_codec.supported(p) end')(payload):
                raise RuntimeError('real recovered payload rejected by actual Lua settings codec')
        real_imports = run([BIN / 'dumpbin.exe', '/imports', OUT / 'entry_real_test.exe'], 'entry-real-imports.txt')
        if 'LuaMadeSimple' in real_imports or 'UE4SS.dll' in real_imports or re.search(r'\blua\d*\.dll\b', real_imports, re.I):
            raise RuntimeError('standalone integration unexpectedly imports a Lua/runtime DLL')
        if generated != {name: digest(OUT / name) for name in generated}:
            raise RuntimeError('generated compile-time fixture changed')
        record.update(real_entry_backend_tests_passed=True, recovered_typed_payloads_validated=True,
                      real_test_root=str(test_root), real_test_generated=generated,
                      real_test_root_is_compile_time_only=True)
        objects = [OUT / (name + '.obj') for name in ('entry','owner','record','journal','record_reader','root_capability','backend')]
        target = OUT / 'pwp_settings_bridge.dll'
        run([LINK_BIN / 'link.exe', '/nologo', '/dll', '/machine:x64', '/out:' + str(target),
             *objects, OUT / 'UE4SS-bridge.lib', 'bcrypt.lib'], 'link.log', env=env)
        imports = run([BIN / 'dumpbin.exe', '/imports', target], 'imports.txt')
        if re.search(r'\b(lua_\w+|luaL_\w+|lua54\.dll)\b', imports):
            raise RuntimeError('unexpected raw Lua dependency')
        actual = set(re.findall(r'^\s+[0-9A-F]+\s+(\S*LuaMadeSimple\S*)', imports, re.M))
        if actual != ALLOWED:
            raise RuntimeError('linked import surface mismatch')
        exports = run([BIN / 'dumpbin.exe', '/exports', target], 'exports.txt')
        names = set(re.findall(r'^\s*\d+\s+[0-9A-F]+\s+[0-9A-F]+\s+(\S+)', exports, re.M))
        if names != {'luaopen_pwp_settings_bridge'}:
            raise RuntimeError('unexpected export surface')
        record.update(linked=True, wrapper_imports=sorted(ALLOWED), probe_sha256=digest(target),
                      compiler_toolset='14.50.35717', linker_directory='14.51.36231')
        after = sources()
        if before != after:
            raise RuntimeError('source changed during build')
        record.update(source_stable=True, sources=after)
    except Exception as error:
        record['error'] = str(error)
    (OUT / 'receipt.json').write_text(json.dumps(record, indent=2))
    print(json.dumps(record, indent=2))
    return 0 if record.get('source_stable') and not record.get('error') else 1


if __name__ == '__main__':
    raise SystemExit(main())
