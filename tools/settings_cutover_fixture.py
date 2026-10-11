"""Disposable two-stream cutover experiment; NEVER operates on a game directory.

Only input is a verified review bundle. Every changed file lives in a fresh
temporary directory owned by this object. Resume re-reads disk state, and the
startup marker is removed last. This is not a live installer or an authority grant.
"""
from pathlib import Path
import base64
import hashlib
import json
import os
import shutil
import tempfile
import settings_migration_backup as B
import settings_export_bundle as Bundle
from settings_cutover_lock import TransactionLock

MARKER='.settings-cutover'
STREAMS={'priorities':'priorities.txt','limits':'caps.txt'}
TRIAL=('async-trial/launch.lua','async-trial/receipt.lua')
ROLLBACK_INTENT='rollback-intent.json'


def envelope(body, generation):
    B.require(type(generation) is int and 0<generation<2147483647,'bounded generation required')
    h=2166136261
    for byte in body:h=((h^byte)*16777619)&0xffffffff
    raw=f'# PWP-DATA 1 {generation} {len(body)} {h:08x}\n'.encode()+body
    B.require(len(raw)<=B.MAX_BYTES,'candidate too large')
    return raw


def encoded(raw):return None if raw is None else base64.b64encode(raw).decode('ascii')
def decoded(raw):return None if raw is None else base64.b64decode(raw,validate=True)


class Fixture:
    def __init__(self,bundle):
        m=Bundle.verify(bundle)
        # No finalizer: automatic cleanup would bypass close() identity checks
        # if a replaced root was refused. Failed setup intentionally leaves evidence.
        self.root=Path(tempfile.mkdtemp(prefix='pwp-cutover-fixture-'))
        self.root_id=B.identity(self.root.stat())
        self.target=self.root/'mod';self.target.mkdir();(self.target/'async-trial').mkdir()
        self.hook=lambda label:None
        originals=B.frozen(m['source'])
        original={name:encoded(originals.get(name)) for name in B.NAMES}
        for name,entry in m['trial_entries'].items():
            original[name]=entry.get('bytes') if entry['state']=='present' else None
        desired={}
        for stream,base in STREAMS.items():
            generation=m['plan']['selected_legacy'][stream]['generation']+1
            raw=envelope(m['plan']['bodies'][stream].encode('utf-8'),generation)
            for suffix in ('','.tmp','.pending','.bak'):desired[base+suffix]=encoded(raw)
        for name,raw in original.items():
            if raw is not None:B.write_new(self.target/name,decoded(raw))
        self.plan={'contract':'PWP-CUTOVER-FIXTURE-1','original':original,'desired':desired,
                   'live_cutover_allowed':False}
        raw=json.dumps(self.plan,sort_keys=True,separators=(',',':')).encode()
        B.require(len(raw)<=B.MAX_MANIFEST_BYTES,'fixture plan too large')
        self.plan_hash=hashlib.sha256(raw).hexdigest()
        B.write_new(self.root/'plan.json',raw)
        self.marker=('PWP-CUTOVER-FIXTURE-1\n'+self.plan_hash+'\n').encode()

    def close(self):
        # Verify the sole recursively deleted root remains our disposable child.
        B.checked_path(self.root,directory=True)
        B.require(self.root.resolve().parent==Path(tempfile.gettempdir()).resolve()
                  and self.root.name.startswith('pwp-cutover-fixture-'),'cleanup root differs')
        current=B.identity(self.root.stat())
        B.require(all(current[k]==self.root_id[k] for k in ('device','inode')),'fixture root replaced')
        shutil.rmtree(self.root)

    def read(self,name):
        B.require(name in set(B.NAMES)|set(TRIAL)|{MARKER},'unapproved fixture path')
        entry=B.read_exact(self.target/name)
        return None if entry['state']=='missing' else base64.b64decode(entry['bytes'],validate=True)

    def _plan(self):
        B.checked_path(self.root,directory=True)
        B.require(self.target==self.root/'mod','fixture target differs')
        current=B.identity(self.root.stat())
        B.require(all(current[k]==self.root_id[k] for k in ('device','inode')),'fixture root changed')
        entry=B.read_exact(self.root/'plan.json',B.MAX_MANIFEST_BYTES)
        raw=base64.b64decode(entry['bytes'],validate=True)
        B.require(hashlib.sha256(raw).hexdigest()==self.plan_hash,'fixture plan changed')
        p=json.loads(raw)
        B.require(p['contract']=='PWP-CUTOVER-FIXTURE-1' and p['live_cutover_allowed'] is False,'fixture contract')
        return p

    def state(self,*,direction='forward'):
        p=self._plan()
        intent=self._intent()
        if direction=='forward':B.require(intent is None,'rollback direction selected; forward resume refused')
        else:
            B.require(direction=='rollback' and intent==self._intent_bytes(),'rollback intent missing or changed')
        values={name:self.read(name) for name in p['original']}
        for name,raw in values.items():
            allowed=[decoded(p['original'][name])]
            allowed.append(decoded(p['desired'][name]) if name in p['desired'] else None)
            B.require(raw in allowed,'unexpected file bytes: '+name)
        return p,values

    def _intent(self):
        entry=B.read_exact(self.root/ROLLBACK_INTENT)
        return None if entry['state']=='missing' else decoded(entry['bytes'])

    def _intent_bytes(self):
        return json.dumps({'contract':'PWP-CUTOVER-ROLLBACK-1','direction':'rollback',
                           'plan_sha256':self.plan_hash,'live_cutover_allowed':False},
                          sort_keys=True,separators=(',',':')).encode()

    def _rollback_marker(self):
        return ('PWP-CUTOVER-ROLLBACK-1\n'+self.plan_hash+'\n').encode()

    @staticmethod
    def _originals_match(p,values,names=None):
        return all(values[n]==decoded(p['original'][n]) for n in (names or p['original']))

    @staticmethod
    def _completed_match(p,values):
        return (all(values[n]==decoded(raw) for n,raw in p['desired'].items())
                and all(values[n] is None for n in TRIAL))

    def _admit_rollback(self):
        p,values=self.state()
        B.require(self.read(MARKER) is None and self._completed_match(p,values),
                  'rollback requires exact completed cutover')

    def rollback(self):
        self._plan()
        with TransactionLock(self.root,self.root_id):
            return self._rollback_locked()

    def _rollback_locked(self):
        """Explicit direction selection; never a live-path or journal rollback.

        The permanent intent prevents a stale forward driver from applying its
        candidates after restoration. Partial scratch is not durable intent.
        """
        self._plan()
        if self._intent() is None:
            self._admit_rollback()
            raw=self._intent_bytes();stage=self.root/'.rollback-intent-stage'
            self.hook('rollback:before-intent-stage');self._admit_rollback()
            B.checked_path(stage)
            if stage.exists():stage.unlink()
            B.write_new(stage,raw)
            self.hook('rollback:after-intent-stage');self._admit_rollback()
            self.hook('rollback:before-intent-replace');self._admit_rollback()
            B.require(decoded(B.read_exact(stage)['bytes'])==raw,'rollback intent stage changed')
            B.checked_path(self.root/ROLLBACK_INTENT)
            os.replace(stage,self.root/ROLLBACK_INTENT)
            self.hook('rollback:after-intent-replace')
        return self._resume_rollback_locked()

    def _rollback_check(self,name):
        p,values=self.state(direction='rollback')
        if name==MARKER:
            B.require(self.read(MARKER) is None and self._completed_match(p,values),
                      'rollback source changed before fencing')
        else:
            B.require(self.read(MARKER)==self._rollback_marker(),'rollback fence missing or changed')
            if name in TRIAL:
                B.require(self._originals_match(p,values,B.NAMES),'legacy changed before trial restoration')
        return p,values

    def _rollback_write(self,name,raw):
        B.require(name in set(B.NAMES)|set(TRIAL)|{MARKER},'unapproved rollback replacement')
        B.require(raw is not None,'rollback replacement requires bytes')
        self._rollback_check(name)
        self.hook('rollback:before-stage:'+name);self._rollback_check(name)
        stage=self.target/'.rollback-stage';B.checked_path(stage)
        if stage.exists():stage.unlink()
        B.write_new(stage,raw)
        self.hook('rollback:after-stage:'+name);self._rollback_check(name)
        self.hook('rollback:before-replace:'+name);self._rollback_check(name)
        B.require(decoded(B.read_exact(stage)['bytes'])==raw,'rollback stage changed')
        B.checked_path(self.target/name)
        os.replace(stage,self.target/name)
        self.hook('rollback:after-replace:'+name)
        B.require(self.read(name)==raw,'rollback readback differs')

    def resume_rollback(self):
        self._plan()
        with TransactionLock(self.root,self.root_id):
            return self._resume_rollback_locked()

    def _resume_rollback_locked(self):
        """Resume only the persisted rollback direction, deriving progress from disk.

        The caller holds the OS lock shared by participating drivers. Arbitrary
        external writers and power-loss/directory-fsync guarantees are out of scope.
        """
        p,values=self.state(direction='rollback')
        marker=self.read(MARKER)
        if marker is None:
            if self._originals_match(p,values):return self._rollback_result()
            B.require(self._completed_match(p,values),'mixed rollback without fence')
            self._rollback_write(MARKER,self._rollback_marker())
        else:B.require(marker==self._rollback_marker(),'foreign rollback fence')
        # All eight recovery variants must be restored before any trial entry.
        for name in (*sorted(B.NAMES),*TRIAL):
            p,values=self._rollback_check(name)
            raw=decoded(p['original'][name])
            if values[name]==raw:continue
            if raw is None:
                self.hook('rollback:before-delete:'+name);self._rollback_check(name)
                B.checked_path(self.target/name).unlink()
                self.hook('rollback:after-delete:'+name)
                B.require(self.read(name) is None,'rollback deletion readback differs')
            else:self._rollback_write(name,raw)
        p,values=self.state(direction='rollback')
        B.require(self._originals_match(p,values),'rollback verification failed')
        self.hook('rollback:before-unfence')
        p,values=self.state(direction='rollback')
        B.require(self._originals_match(p,values),'rollback changed before unfencing')
        B.require(self.read(MARKER)==self._rollback_marker(),'rollback fence changed')
        B.checked_path(self.target/MARKER).unlink()
        self.hook('rollback:after-unfence')
        return self._rollback_result()

    @staticmethod
    def _rollback_result():
        return {'complete':True,'direction':'rollback','live_cutover_allowed':False,
                'replacement_allowed':False,'ownership_verified':False,'deletion_coverage_verified':False}

    def _atomic(self,name,raw):
        B.require(name in set(B.NAMES)|{MARKER},'unapproved replacement')
        self.hook('before-stage:'+name)
        stage=self.target/'.cutover-stage'
        B.checked_path(stage)
        # Sole scratch file belongs to this isolated fixture. Partial bytes from
        # an interrupted prior write never participate in legacy recovery.
        if stage.exists():stage.unlink()
        B.write_new(stage,raw)
        self.hook('after-stage:'+name)
        self.state()
        B.require(base64.b64decode(B.read_exact(stage)['bytes'],validate=True)==raw,'stage changed')
        B.checked_path(self.target/name)
        self.hook('before-replace:'+name)
        p,values=self.state()
        if name==MARKER:
            B.require(self.read(MARKER) is None and all(values[k]==decoded(v) for k,v in p['original'].items()),
                      'source changed before fencing')
        else:B.require(self.read(MARKER)==self.marker,'cutover marker lost')
        os.replace(stage,self.target/name)
        self.hook('after-replace:'+name)
        B.require(self.read(name)==raw,'replacement readback differs')

    def resume(self):
        self._plan()
        with TransactionLock(self.root,self.root_id):
            return self._resume_locked()

    def _resume_locked(self):
        # Nothing relies on a remembered step counter: every boundary is derived
        # from the fixed plan and current exact bytes after an interrupted call.
        p,values=self.state()
        intended={name:decoded(raw) for name,raw in p['desired'].items()}
        complete=all(values[name]==raw for name,raw in intended.items()) and all(values[name] is None for name in TRIAL)
        marker=self.read(MARKER)
        if marker is None:
            if complete:return {'complete':True,'live_cutover_allowed':False}
            B.require(all(values[name]==decoded(raw) for name,raw in p['original'].items()),
                      'mixed settings without cutover marker')
            self._atomic(MARKER,self.marker)
        else:B.require(marker==self.marker,'foreign/incomplete cutover marker')
        for name,raw in intended.items():
            self.state();B.require(self.read(MARKER)==self.marker,'cutover marker lost')
            if self.read(name)!=raw:self._atomic(name,raw)
        # Retire marker files only after every legacy recovery path is new.
        for name in TRIAL:
            self.state();B.require(self.read(MARKER)==self.marker,'cutover marker lost')
            if self.read(name) is not None:
                self.hook('before-retire:'+name);p,values=self.state()
                B.require(all(values[k]==raw for k,raw in intended.items()),'settings changed before trial retirement')
                B.require(self.read(MARKER)==self.marker,'cutover marker lost')
                (B.checked_path(self.target/name)).unlink()
                self.hook('after-retire:'+name)
        p,values=self.state()
        B.require(all(values[name]==raw for name,raw in intended.items()) and all(values[name] is None for name in TRIAL),
                  'two-stream verification failed')
        self.hook('before-unfence');p,values=self.state()
        B.require(all(values[name]==raw for name,raw in intended.items()) and all(values[name] is None for name in TRIAL),
                  'settings changed before unfencing')
        B.require(self.read(MARKER)==self.marker,'cutover marker changed')
        (B.checked_path(self.target/MARKER)).unlink()
        self.hook('after-unfence')
        return {'complete':True,'live_cutover_allowed':False}


if __name__=='__main__':
    import argparse
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('bundle',type=Path)
    args=p.parse_args();fixture=Fixture(args.bundle)
    try:print(json.dumps(fixture.resume()))
    finally:fixture.close()
