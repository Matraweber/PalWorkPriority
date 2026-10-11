"""Compile and run isolated regressions using the same Lua major/minor as UE4SS.

Install the test dependency with:
  python -m pip install --no-user --target .test-deps lupa==2.6
Tests use Lua 5.4 explicitly; LuaJIT or Lua 5.3 is not an acceptable fallback.
"""
from pathlib import Path
import argparse
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / '.test-deps'))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--compile-only', action='store_true')
    parser.add_argument('tests', nargs='*')
    args = parser.parse_args()
    try:
        from lupa.lua54 import LuaRuntime
    except ImportError:
        print('FAIL: Lua 5.4 test runtime missing. See tools/test_lua.py.', file=sys.stderr)
        return 1
    failed = 0
    files = sorted((ROOT / 'Scripts').glob('*.lua'))
    compiler = LuaRuntime(unpack_returned_tuples=True)
    assert compiler.eval('_VERSION') == 'Lua 5.4'
    compile_chunk = compiler.eval('function(s, n) local f,e=load(s,n,"t",{}); return f~=nil,e end')
    for file in files:
        ok, error = compile_chunk(file.read_text(encoding='utf-8-sig'), '@' + file.as_posix())
        if not ok:
            print('FAIL compile:', error)
            failed += 1
    print(f'Lua 5.4: compiled {len(files)} modules, {failed} failures')
    if args.compile_only or failed:
        return min(failed, 1)
    tests = [Path(p).resolve() for p in args.tests] if args.tests else sorted((ROOT / 'tests').glob('test_*.lua'))
    if not tests:
        print('FAIL: no behavioral tests found')
        return 1
    for file in tests:
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().TEST_ROOT = ROOT.as_posix()
        lua.execute('package.path = TEST_ROOT .. "/Scripts/?.lua;" .. TEST_ROOT .. "/tests/?.lua;" .. package.path')
        try:
            lua.execute(file.read_text(encoding='utf-8-sig'), name='@' + file.as_posix())
            print('PASS', file.name)
        except Exception as exc:
            failed += 1
            print('FAIL', file.name, exc)
    print(f'{len(tests)} regression scripts, {failed} failures')
    return min(failed, 1)


if __name__ == '__main__':
    raise SystemExit(main())
