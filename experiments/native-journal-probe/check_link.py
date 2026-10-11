"""Compile/link plus isolated fake-backend dispatch tests; never loads helper/UE4SS."""
from pathlib import Path
import hashlib
import json
import os
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent / 'build'
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
    '?is_integer@Lua@LuaMadeSimple@RC@@QEBA_NH@Z',
    '?get_integer@Lua@LuaMadeSimple@RC@@QEBA_JH@Z',
    '?set_integer@Lua@LuaMadeSimple@RC@@QEBAX_J@Z',
}


def run(args, label, **kw):
    p = subprocess.run([str(a) for a in args], capture_output=True, timeout=120, **kw)
    (OUT / label).write_bytes(p.stdout + p.stderr)
    if p.returncode:
        raise RuntimeError(label + ' failed')
    return p.stdout.decode(errors='replace')


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    record = {'experiment_version': 2, 'entry_contract': 'two integers: command, immutable expected ticket; (0,0) binds control thread',
              'clock': 'raw QPC ticks; inclusive command', 'compiled': False, 'linked': False, 'loaded': False, 'game_installed': False,
              'runtime_abi_verified': False, 'private_sdk_used': False, 'second_lua_linked': False}
    try:
        tracked = [p for p in (ROOT / 'native/save_core').glob('*') if p.is_file() and p.suffix in {'.cpp','.hpp'}]
        tracked += [p for p in Path(__file__).parent.iterdir() if p.is_file()]
        tracked += list(Path(__file__).with_name('test-stubs').rglob('*.hpp'))
        tracked += [ROOT / 'experiments' / name for name in ('save_context_pair_probe.lua',
                    'save_headless_identity_probe.lua','save_world_identity_probe.lua','save_identity_probe.lua')]
        tracked += [ROOT / 'tests' / name for name in ('test_native_journal_driver.lua','test_save_context_pair_probe.lua')]
        before = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
        actual = hashlib.sha256(DLL.read_bytes()).hexdigest()
        record['staged_runtime_sha256'] = actual
        if actual != EXPECTED:
            raise RuntimeError('staged runtime differs from pinned evidence')
        prior = json.loads((PRE / 'receipt.json').read_text())
        for relative in ['source/deps/first/LuaMadeSimple/include/LuaMadeSimple/LuaMadeSimple.hpp',
                         'source/deps/first/LuaRaw/include/lua.h']:
            if hashlib.sha256((PRE / relative).read_bytes()).hexdigest() != prior['hashes'][relative]:
                raise RuntimeError('pinned public header changed: ' + relative)
        entry = Path(__file__).with_name('entry.cpp').read_text()
        ticket_line = 'const auto ticket=lua.get_integer(2);if(ticket<0 || ticket>3)return 0;'
        command_line = 'const auto command=lua.get_integer(1);if(command<0 || command>6)return 0;'
        correct = ticket_line + '\n        ' + command_line
        if entry.count(correct) != 1:
            raise RuntimeError('entry extraction changed; review legacy mutation')
        mutant = entry.replace(correct, command_line + '\n        ' + ticket_line)
        mutant = mutant.replace('"../../native/save_core/operation.hpp"', '"' + (ROOT / 'native/save_core/operation.hpp').as_posix() + '"')
        mutant = mutant.replace('"dispatch.hpp"', '"' + Path(__file__).with_name('dispatch.hpp').as_posix() + '"')
        (OUT / 'entry_legacy_mutant.inc').write_text(mutant)
        run(['powershell', '-NoProfile', '-File', Path(__file__).with_name('compile.ps1')], 'compile-command.log')
        record['compiled'] = True
        symbols = (OUT / 'symbols.txt').read_text()
        needed = sorted(set(re.findall(r'UNDEF.*?\| __imp_(\S*LuaMadeSimple\S*)', symbols)))
        if set(needed) != ALLOWED:
            raise RuntimeError('unexpected wrapper import surface')
        exports = run([BIN / 'dumpbin.exe', '/exports', DLL], 'staged-exports.txt')
        exported = set(re.findall(r'^\s*\d+\s+[0-9A-F]+\s+[0-9A-F]+\s+(\S+)', exports, re.M))
        if not set(needed) <= exported:
            raise RuntimeError('compiled imports absent from staged DLL')
        (OUT / 'UE4SS-probe.def').write_text('LIBRARY UE4SS.dll\nEXPORTS\n' + '\n'.join(needed) + '\n')
        run([LINK_BIN / 'lib.exe', '/nologo', '/machine:x64', '/def:' + str(OUT / 'UE4SS-probe.def'),
             '/out:' + str(OUT / 'UE4SS-probe.lib')], 'import-library.log')
        env = {**os.environ, 'LINK': '', '_LINK_': '',
               'LIB': ';'.join(map(str, [VC / 'lib/x64', SDK / 'ucrt/x64', SDK / 'um/x64']))}
        run([LINK_BIN / 'link.exe', '/nologo', '/machine:x64', '/subsystem:console',
             '/out:' + str(OUT / 'dispatch-test.exe'), OUT / 'dispatch_test.obj'], 'dispatch-test-link.log', env=env)
        run([OUT / 'dispatch-test.exe'], 'dispatch-tests.log')
        record['dispatch_tests_passed'] = True
        record['dispatch_test_backend'] = 'in-memory only; no journal IO or Lua runtime'
        for unit in ('entry_test', 'entry_legacy_test'):
            run([LINK_BIN / 'link.exe', '/nologo', '/machine:x64', '/subsystem:console',
                 '/out:' + str(OUT / (unit + '.exe')), OUT / (unit + '.obj')], unit + '-link.log', env=env)
        run([OUT / 'entry_test.exe'], 'entry-tests.log')
        legacy = subprocess.run([str(OUT / 'entry_legacy_test.exe')], capture_output=True, timeout=30)
        (OUT / 'entry-legacy-tests.log').write_bytes(legacy.stdout + legacy.stderr)
        if legacy.returncode != 1 or b'REGRESSION: actual entry lost ticket 1 during admission' not in legacy.stderr:
            raise RuntimeError('legacy parser did not fail at targeted admission regression')
        record['entry_tests_passed'] = True
        record['legacy_parser_mutant_rejected'] = True
        record['entry_test_boundary'] = 'actual entry.cpp; stack-removing Lua mock; in-memory owner/operation; no journal IO or runtime ABI claim'
        run([LINK_BIN / 'link.exe', '/nologo', '/dll', '/machine:x64', '/out:' + str(OUT / 'pwp_journal_probe.dll'),
             OUT / 'entry.obj', OUT / 'owner.obj', OUT / 'record.obj', OUT / 'journal.obj', OUT / 'operation.obj', OUT / 'UE4SS-probe.lib', 'bcrypt.lib'], 'link.log', env=env)
        imports = run([BIN / 'dumpbin.exe', '/imports', OUT / 'pwp_journal_probe.dll'], 'imports.txt')
        if re.search(r'\b(lua_\w+|luaL_\w+|lua54\.dll)\b', imports):
            raise RuntimeError('unexpected plain Lua dependency')
        actual_wrappers = set(re.findall(r'^\s+[0-9A-F]+\s+(\S*LuaMadeSimple\S*)', imports, re.M))
        if actual_wrappers != ALLOWED:
            raise RuntimeError('linked wrapper surface differs from audited imports')
        public = run([BIN / 'dumpbin.exe', '/exports', OUT / 'pwp_journal_probe.dll'], 'exports.txt')
        public_names = set(re.findall(r'^\s*\d+\s+[0-9A-F]+\s+[0-9A-F]+\s+(\S+)', public, re.M))
        if public_names != {'luaopen_pwp_journal_probe'}:
            raise RuntimeError('unexpected entry export')
        record.update(linked=True, wrapper_imports=needed,
                      compiler_toolset='14.50.35717', linker_toolset_directory='14.51.36231 (staged package)',
                      probe_sha256=hashlib.sha256((OUT / 'pwp_journal_probe.dll').read_bytes()).hexdigest())
        after = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
        if before != after:
            raise RuntimeError('source changed during build')
        record['sources'] = after
        record['source_stable'] = True
    except Exception as error:
        record['error'] = str(error)
    (OUT / 'receipt.json').write_text(json.dumps(record, indent=2))
    print(json.dumps(record, indent=2))
    return 0 if record.get('source_stable') and not record.get('error') else 1


if __name__ == '__main__':
    raise SystemExit(main())

