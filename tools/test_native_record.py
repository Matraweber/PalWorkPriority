"""Build + exercise native integrity/recovery decisions without game deployment."""
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import os
import subprocess
import unittest

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'test-results/native-record-20261004'
def sources():
    files=[*ROOT.glob('native/save_core/record*'),ROOT/'tools/build_save_record.ps1',
           Path(__file__),ROOT/'tests/test_native_save_record.py']
    return {str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
def main():
    OUT.mkdir(exist_ok=True,parents=True)
    receipt={'passed':False,'production_installed':False,'game_test':False,
             'started_utc':datetime.now(timezone.utc).isoformat(),'sources_before':sources()}
    try:
        build=subprocess.run(['powershell','-NoProfile','-File',str(ROOT/'tools/build_save_record.ps1'),
                              '-OutputDirectory',str(OUT)],capture_output=True,timeout=120,cwd=ROOT)
        (OUT/'build.log').write_bytes(build.stdout+build.stderr)
        if build.returncode:raise RuntimeError('native build failed')
        exe=OUT/'record-test.exe';os.environ['PWP_NATIVE_RECORD_EXE']=str(exe)
        receipt['exe_sha256']=hashlib.sha256(exe.read_bytes()).hexdigest()
        suite=unittest.defaultTestLoader.discover(str(ROOT/'tests'),'test_native_save_record.py')
        with (OUT/'tests.log').open('w') as f:result=unittest.TextTestRunner(stream=f,verbosity=2).run(suite)
        receipt.update(tests=result.testsRun,skipped=len(result.skipped),failures=len(result.failures),errors=len(result.errors))
        receipt['sources_after']=sources()
        receipt['passed']=result.wasSuccessful() and result.testsRun>=7 and not result.skipped and receipt['sources_before']==receipt['sources_after']
    except Exception as error:receipt['error']=str(error)
    receipt['finished_utc']=datetime.now(timezone.utc).isoformat()
    (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2))
    print(json.dumps({k:v for k,v in receipt.items() if not k.startswith('sources')}))
    return 0 if receipt['passed'] else 1
if __name__=='__main__':raise SystemExit(main())
