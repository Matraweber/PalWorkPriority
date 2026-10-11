"""Build/test native claim and completion lifecycle. Never installs in game."""
from pathlib import Path
from datetime import datetime,timezone
import hashlib,json,os,subprocess,unittest
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'test-results/native-owner-20261004'
def hashes():
    paths=[*ROOT.glob('native/save_core/owner*'),ROOT/'native/save_core/record.hpp',ROOT/'native/save_core/record.cpp',
           ROOT/'tools/build_save_owner.ps1',Path(__file__),ROOT/'tests/test_native_save_owner.py']
    return {str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
def main():
    OUT.mkdir(exist_ok=True,parents=True)
    r={'passed':False,'production_installed':False,'game_test':False,'sources_before':hashes(),'started_utc':datetime.now(timezone.utc).isoformat()}
    try:
        b=subprocess.run(['powershell','-NoProfile','-File',str(ROOT/'tools/build_save_owner.ps1'),'-OutputDirectory',str(OUT)],capture_output=True,timeout=120,cwd=ROOT)
        (OUT/'build.log').write_bytes(b.stdout+b.stderr)
        if b.returncode:raise RuntimeError('build failed')
        dll=OUT/'owner-test.dll';os.environ['PWP_NATIVE_OWNER_DLL']=str(dll)
        r['dll_sha256']=hashlib.sha256(dll.read_bytes()).hexdigest()
        suite=unittest.defaultTestLoader.discover(str(ROOT/'tests'),'test_native_save_owner.py')
        with (OUT/'tests.log').open('w') as f:result=unittest.TextTestRunner(stream=f,verbosity=2).run(suite)
        r.update(tests=result.testsRun,skipped=len(result.skipped),failures=len(result.failures),errors=len(result.errors),sources_after=hashes())
        r['passed']=result.wasSuccessful() and result.testsRun>=9 and not result.skipped and r['sources_before']==r['sources_after']
    except Exception as e:r['error']=str(e)
    r['finished_utc']=datetime.now(timezone.utc).isoformat();(OUT/'receipt.json').write_text(json.dumps(r,indent=2))
    print(json.dumps({k:v for k,v in r.items() if not k.startswith('sources')}));return 0 if r['passed'] else 1
if __name__=='__main__':raise SystemExit(main())
