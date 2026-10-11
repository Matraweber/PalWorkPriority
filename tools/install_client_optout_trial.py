"""Checked follow-up to the recorded schema-3 install; local experiment only.

Read-only by default. Preserve prior stages, DLL, journals and legacy paths.
Activation is a final launcher replacement, with durable intent and backup.
"""
import hashlib
import json
import os
import subprocess
import sys
import uuid
from pathlib import Path
import install_session_lock_trial as S

BASE = S.ROOT/'test-results/session-lock-install-9b33e1f70608/installed.json'
ALLOWED = {'experiments/settings_live_combined.lua',
           'experiments/settings_startup_gate_group.lua'}


def inspect():
    S.B.require(S.B.game_closed(), 'game must be closed')
    d = S.load(BASE)
    S.B.require(d.get('installed') is True, 'prior install incomplete')
    expected = dict(d['code'])
    expected.update({str(S.MOD/k): v for k,v in d['updates'].items()})
    expected[str(S.MOD/'async-trial/launch.lua')] = d['launcher_sha256']
    for p,h in expected.items():
        S.B.require(S.sha(p) == h, 'installed code changed: '+p)
    stage = S.B.checked_path(d['stage'], directory=True)
    S.B.require(stage.parent == S.MOD/'async-trial', 'unexpected stage')
    S.B.require(S.tree(stage) == d['closure'], 'prior closure changed')
    S.B.require(S.tree(Path(d['original_stage'])) == d['original_tree'], 'original stage changed')
    S.B.require(S.tree(S.STORE) == d['journal'], 'journal changed')
    S.B.verify(S.BACKUP, S.B.capture(S.MOD))
    candidate = S.closure()
    S.B.require(set(candidate) == set(d['closure']), 'closure inventory changed')
    changes = {k for k in candidate if candidate[k] != d['closure'][k]}
    S.B.require(changes == ALLOWED, 'unexpected experiment changes')
    S.B.require(S.tree(S.ROOT/'Scripts') == {
        Path(k).name:v for k,v in d['sources'].items() if k.startswith('Scripts/')
    }, 'production Scripts changed')
    S.compile_lua(candidate)
    return dict(prior_receipt_sha256=S.sha(BASE), candidate=candidate,
                prior_stage=str(stage), journal=d['journal'],
                legacy=S.B.capture(S.MOD), launcher=d['launcher'],
                tool_sha256=S.sha(Path(__file__)))


def main():
    if sys.argv[1:] not in ([], ['--install']):
        raise SystemExit('usage: install_client_optout_trial.py [--install]')
    before = inspect()
    if not sys.argv[1:]:
        print(json.dumps({'checked':True,'changed':sorted(ALLOWED),'installed':False}))
        return
    logs = {}
    for args,name in ((['tools/test_lua.py'],'lua.log'), (['tools/luacheck.py'],'structural.log')):
        p = subprocess.run([sys.executable,*args],cwd=S.ROOT,capture_output=True,timeout=240)
        S.B.require(p.returncode == 0, name+' failed')
        logs[name] = p.stdout+p.stderr
    S.B.require(inspect() == before, 'preflight changed during tests')
    key = uuid.uuid4().hex
    evidence = S.ROOT/'test-results'/('client-optout-install-'+key[:12])
    evidence.mkdir()
    stage = S.MOD/'async-trial'/('client-optout-'+key)
    previous = before['launcher'].encode('ascii')
    old_entry = (Path(before['prior_stage'])/S.ENTRY).as_posix().encode('ascii')
    S.B.require(previous.count(old_entry) == 1, 'entry not unique')
    launcher = previous.replace(old_entry,(stage/S.ENTRY).as_posix().encode('ascii'))
    record = dict(before,new_stage=str(stage),launcher_sha256=hashlib.sha256(launcher).hexdigest(),
                  live_acceptance=False,rollback_to_legacy_allowed=False)
    S.B.write_new(evidence/'launcher-before.lua',previous)
    for name,raw in logs.items():
        S.B.write_new(evidence/name,raw)
    S.B.write_new(evidence/'intent.json',json.dumps(record,indent=2).encode())
    stage.mkdir()
    for rel,h in before['candidate'].items():
        target=stage/S.relative(rel); target.parent.mkdir(parents=True,exist_ok=True)
        raw=(S.ROOT/rel).read_bytes()
        S.B.require(hashlib.sha256(raw).hexdigest()==h,'source changed')
        S.B.write_new(target,raw)
    S.B.require(inspect()==before and S.tree(stage)==before['candidate'],'staging changed')
    pending=S.MOD/'async-trial'/('launch.'+key+'.pending')
    S.B.write_new(pending,launcher)
    S.B.require(inspect()==before and pending.read_bytes()==launcher,'activation precheck failed')
    os.replace(pending,S.MOD/'async-trial/launch.lua')
    S.B.require(S.B.game_closed(),'game started during activation')
    S.B.require((S.MOD/'async-trial/launch.lua').read_bytes()==launcher,'activation differs')
    S.B.require(S.tree(stage)==before['candidate'],'activated closure differs')
    S.B.require(S.tree(Path(before['prior_stage']))==S.load(BASE)['closure'],'prior stage changed')
    S.B.require(S.tree(S.STORE)==before['journal'],'journal changed during activation')
    S.B.require(S.B.capture(S.MOD)==before['legacy'],'legacy changed during activation')
    S.B.write_new(evidence/'installed.json',json.dumps(dict(record,installed=True),indent=2).encode())
    print(json.dumps({'installed':True,'evidence':str(evidence),'live_acceptance':False}))


if __name__ == '__main__':
    main()
