"""Offline-only validation. Refuses an existing scratch root; never deletes saves.

Creates the ONE fixed scratch directory after testing missing-root rejection.
Loads Lua 5.4 for driver logic only; native operations use the standalone CLI.
Does NOT load the helper DLL or UE4SS. Leaves target/stages/evidence for review.
"""
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import subprocess
import sys
sys.dont_write_bytecode = True
from verify_readback import SCRATCH, TARGET, FIRST, SECOND, checksum, verify, read_exact

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
EXE = HERE / 'build/file-probe-cli.exe'

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    out = HERE / 'build' / ('offline-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'))
    out.mkdir(parents=True)
    receipt = {'passed': False, 'loaded_ue4ss': False, 'loaded_helper_dll': False,
               'game_touched': False, 'durable_ack': False, 'tests': []}
    tests = receipt['tests']
    try:
        build = json.loads((HERE / 'build/receipt.json').read_text())
        assert build.get('source_stable') and build.get('linked') and not build.get('error')
        assert digest(EXE) == build['cli_sha256']
        assert all(digest(ROOT / p) == value for p,value in build['sources'].items()), 'stale build'
        before = {p: digest(ROOT / p) for p in build['sources']}
        if SCRATCH.exists() or SCRATCH.is_symlink():
            raise RuntimeError('scratch root already exists; refusing reuse/overwrite; preserve evidence')
        for parent in SCRATCH.parents:
            assert not parent.lstat().st_file_attributes & 0x400, 'reparse ancestor'

        def call(hex_bytes):
            p = subprocess.run([str(EXE)], input=hex_bytes, capture_output=True, timeout=30)
            values = tuple(map(int,p.stdout.split()))
            assert len(values)==7 and p.returncode==values[0], (p.returncode,p.stdout,p.stderr)
            assert values[2]>0 and 0<=values[3]<=values[4] and values[6]>0
            return values

        absent = call(b'00')
        assert absent[0]==3 and absent[1] in (2,3) and not SCRATCH.exists()
        tests.append('missing fixed root rejected without creation')
        SCRATCH.mkdir() # harness fixture creation; native never creates its root
        receipt['baseline'] = {'root':str(SCRATCH),'entries':[], 'target_absent':not TARGET.exists()}
        for value in (b'',b'0',b'GG',b'00\0ff',b'00\xff',b'00'*262145):
            r = call(value)
            assert r[0]==1 and r[1]==87 and list(SCRATCH.iterdir())==[]
            tests.append('invalid hex rejected: '+repr(value[:12])+' length='+str(len(value)))
        p = subprocess.run([str(EXE),str(SCRATCH.parent)],capture_output=True,timeout=30)
        assert p.returncode==20 and list(SCRATCH.iterdir())==[]
        tests.append('arbitrary CLI root argument refused')

        sys.path.insert(0,str(ROOT/'.test-deps'))
        from lupa.lua54 import LuaRuntime
        lua = LuaRuntime(encoding=None,unpack_returned_tuples=True)
        assert lua.eval(b'_VERSION')==b'Lua 5.4'
        driver = lua.execute((HERE/'driver.lua').read_bytes())
        lua.globals()[b'PROBE_DRIVER'] = driver
        receipt['lua_rejection_and_success_cases'] = lua.execute((HERE/'test_driver.lua').read_bytes())
        tests.append('Lua fail-closed validation and stop-before-second-call cases')
        completions=[]
        def native(hex_bytes, length):
            assert length==len(hex_bytes)
            phase='initial' if not completions else 'conflict'
            result=call(hex_bytes)
            (out/(phase+'-completion.json')).write_text(json.dumps({'result':result},indent=2))
            # Independent exact bytes, separate from the returned input checksum.
            checked=verify(result,phase)
            (out/(phase+'-readback.json')).write_text(json.dumps(checked,indent=2))
            completions.append(checked)
            return result
        driver[b'verify_pair'](native,FIRST.hex().encode(),SECOND.hex().encode(),read_exact)
        assert len(completions)==2
        tests += ['Lua driver -> real CLI full 256KiB publication + external whole-byte readback',
                  'different-byte conflict + external original-byte preservation']
        stages=list(SCRATCH.glob('pwp-stage-*.tmp'))
        assert len(stages)==1 and stages[0].read_bytes()==SECOND
        tests.append('failed conflict stage retained with different request bytes')
        assert set(SCRATCH.iterdir())=={TARGET,*stages}
        receipt['root_contents']=[{'name':p.name,'bytes':p.stat().st_size,'sha256':digest(p)}
                                  for p in sorted(SCRATCH.iterdir())]
        receipt['target_disposition']='PRESENT; original FIRST bytes retained. First-publication slot consumed. No archive/reset performed.'
        receipt['completions']=completions
        assert before=={p:digest(ROOT/p) for p in before}, 'source changed during tests'
        receipt['source_fingerprints']=before
        receipt['passed']=True
    except Exception as error:
        receipt['error']=repr(error)
    (out/'receipt.json').write_text(json.dumps(receipt,indent=2))
    print(json.dumps(receipt,indent=2))
    print('EVIDENCE:',out)
    return 0 if receipt['passed'] else 1

if __name__=='__main__':
    raise SystemExit(main())
