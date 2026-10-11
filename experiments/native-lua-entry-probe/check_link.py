"""Compile/link only: never loads the helper or UE4SS into any process."""
from pathlib import Path
import hashlib
import json
import os
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'test-results/native-lua-entry-probe-20261004'
PRE = ROOT / 'test-results/native-helper-prerequisites-2281fa31'
VC = Path('C:/Program Files/Microsoft Visual Studio/18/Community/VC/Tools/MSVC/14.50.35717')
BIN = VC / 'bin/Hostx64/x64'
LINK_BIN = OUT / 'toolchain/portable/VC/Tools/MSVC/14.51.36231/bin/Hostx64/x64'
SDK = Path('C:/Program Files (x86)/Windows Kits/10/Lib/10.0.26100.0')
DLL = Path('D:/Steam/steamapps/common/Palworld/Mods/NativeMods/UE4SS/UE4SS.dll')
EXPECTED = '21b691a69a20c0801f465369d4fcbca7d7444764022fac2a7e8edc7709ef92b8'


def run(args, label, **kw):
    p = subprocess.run([str(a) for a in args], capture_output=True, timeout=120, **kw)
    (OUT / label).write_bytes(p.stdout + p.stderr)
    if p.returncode:
        raise RuntimeError(label + ' failed')
    return p.stdout.decode(errors='replace')


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    record = {'compiled': False, 'linked': False, 'loaded': False, 'game_installed': False,
              'runtime_abi_verified': False, 'private_sdk_used': False, 'second_lua_linked': False}
    try:
        actual = hashlib.sha256(DLL.read_bytes()).hexdigest()
        record['installed_runtime_sha256'] = actual
        if actual != EXPECTED:
            raise RuntimeError('installed runtime differs from pinned evidence')
        run(['powershell', '-NoProfile', '-File', Path(__file__).with_name('compile.ps1')], 'compile-command.log')
        record['compiled'] = True
        symbols = (OUT / 'symbols.txt').read_text()
        needed = sorted(set(re.findall(r'UNDEF.*?\| __imp_(\S*LuaMadeSimple\S*)', symbols)))
        if len(needed) != 3:
            raise RuntimeError('unexpected wrapper import surface')
        exports = run([BIN / 'dumpbin.exe', '/exports', DLL], 'installed-exports.txt')
        exported = set(re.findall(r'^\s*\d+\s+[0-9A-F]+\s+[0-9A-F]+\s+(\S+)', exports, re.M))
        if not set(needed) <= exported:
            raise RuntimeError('compiled imports absent from installed DLL')
        (OUT / 'UE4SS-probe.def').write_text('LIBRARY UE4SS.dll\nEXPORTS\n' + '\n'.join(needed) + '\n')
        run([LINK_BIN / 'lib.exe', '/nologo', '/machine:x64', '/def:' + str(OUT / 'UE4SS-probe.def'),
             '/out:' + str(OUT / 'UE4SS-probe.lib')], 'import-library.log')
        env = {**os.environ, 'LIB': ';'.join(map(str, [VC / 'lib/x64', SDK / 'ucrt/x64', SDK / 'um/x64']))}
        run([LINK_BIN / 'link.exe', '/nologo', '/dll', '/machine:x64', '/out:' + str(OUT / 'pwp_entry_probe.dll'),
             OUT / 'entry.obj', OUT / 'UE4SS-probe.lib'], 'link.log', env=env)
        imports = run([BIN / 'dumpbin.exe', '/imports', OUT / 'pwp_entry_probe.dll'], 'imports.txt')
        if re.search(r'\b(lua_\w+|luaL_\w+|lua54\.dll)\b', imports):
            raise RuntimeError('unexpected plain Lua dependency')
        record.update(linked=True, wrapper_imports=needed,
                      compiler_toolset='14.50.35717', linker_toolset='14.51.36260 (package)',
                      probe_sha256=hashlib.sha256((OUT / 'pwp_entry_probe.dll').read_bytes()).hexdigest())
        record['sources'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in Path(__file__).parent.iterdir() if p.is_file()}
    except Exception as error:
        record['error'] = str(error)
    (OUT / 'receipt.json').write_text(json.dumps(record, indent=2))
    print(json.dumps(record, indent=2))
    return 0 if record['linked'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
