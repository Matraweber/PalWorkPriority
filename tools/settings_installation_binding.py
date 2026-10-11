"""Read-only installed-state binding. No activation, mutation or ownership grant.

Default entry points/CLI use fixed reviewed paths. Explicit Paths/Pins injection
is for offline tests; neither receipt nor bundle source paths are followed.
Process checks bracket reads, not an exclusion lock against arbitrary writers.
"""
from dataclasses import dataclass
from pathlib import Path
import base64
import hashlib
import json
import os
import stat
import settings_migration_backup as B
import settings_export_bundle as Bundle
import settings_export_coverage as Coverage
import settings_journal_export as J
import analyze_export_membership as Analyzer

ROOT=Path(__file__).resolve().parents[1]
RUNTIME=Path('D:/Steam/steamapps/common/Palworld/Mods/NativeMods/UE4SS')
MOD=RUNTIME/'Mods/PalWorkPriority'
JOURNALS=ROOT/'test-results/native-limits-live-20261007/store'
BUNDLE=ROOT/'test-results/export-review-only-20261011-e5a32f93/bundle'
MEMBERSHIP=ROOT/'test-results/export-membership-b27c6af221b74ec6b33b479653db6f61'
MARKER='.settings-cutover'
LOCK='.settings-cutover.lock'
TRIAL=('async-trial/launch.lua','async-trial/receipt.lua')
MAX_FILES=8192
MAX_TOTAL=512*1024*1024
MAX_FILE=64*1024*1024


@dataclass(frozen=True)
class Paths:
    mod:Path=MOD
    runtime:Path=RUNTIME/'UE4SS.dll'
    journals:Path=JOURNALS
    bundle:Path=BUNDLE
    membership:Path=MEMBERSHIP


@dataclass(frozen=True)
class Pins:
    runtime_sha256:str='21b691a69a20c0801f465369d4fcbca7d7444764022fac2a7e8edc7709ef92b8'
    main_sha256:str='2117d62226d9e7f72dc6ab7504565d3dcf18a09852f50358a9c40f06e4d78132'
    manifest_sha256:str='b07ab0cb4a63fabac2734d8fde46b9dc0caff4d7a18e9503c595ab915acc71d4'
    membership_sha256:str='9bf4b36989138ea999a40f3a2a77fc60671b8fe581d56fbe6853172353d5814e'
    nonce:str='b27c6af221b74ec6b33b479653db6f61'
    storage:str='31141b9948fe8b9a8b4cc399974dddf1'
    guild:str='d2c75eae4e5c0c4c4d24b89b2010b5eb'
    alias:str='-758686034-1314655308-1294252187-537966059'
    install_sha256:str='1fb0a9cd1396a1c0766bd6356c8b12e0b13109da9124f9b98632246224944fb9'


def _normalized(path):return os.path.normcase(os.path.abspath(path))


def _directory(path):
    path=B.checked_path(path,directory=True);s=path.stat()
    return {'path':str(path),'device':s.st_dev,'inode':s.st_ino}


def _summary(entry):
    return {k:v for k,v in entry.items() if k!='bytes'}


def _digest(path):
    path=B.checked_path(path);before=path.stat()
    B.require(before.st_size<=MAX_FILE,'binding file exceeds bound')
    h=hashlib.sha256();size=0
    with path.open('rb') as f:
        B.require(B.identity(os.fstat(f.fileno()))==B.identity(before),'binding file replaced')
        while True:
            chunk=f.read(1024*1024)
            if not chunk:break
            size+=len(chunk);B.require(size<=MAX_FILE,'binding file exceeds bound');h.update(chunk)
        B.require(B.identity(os.fstat(f.fileno()))==B.identity(before),'binding file changed')
    B.checked_path(path)
    B.require(B.identity(path.stat())==B.identity(before) and size==before.st_size,'binding file changed')
    return {'state':'present','identity':B.identity(before),'sha256':h.hexdigest()}


def _exclusions(mod,expected_marker):
    B.require(expected_marker is None or (type(expected_marker) is bytes and 0<len(expected_marker)<=4096),
              'expected marker must be explicit bounded bytes')
    entry=B.read_exact(mod/MARKER,4096)
    raw=None if entry['state']=='missing' else base64.b64decode(entry['bytes'],validate=True)
    B.require(raw==expected_marker,'unexpected cutover marker')
    if raw is not None:B.require((mod/MARKER).stat().st_nlink==1,'linked cutover marker')
    lock=B.checked_path(mod/LOCK)
    try:s=lock.stat()
    except FileNotFoundError:pass
    else:
        # Metadata only: a coordinator may hold this empty file share-zero.
        B.require(stat.S_ISREG(s.st_mode) and s.st_nlink==1 and s.st_size==0,'invalid transaction lock artifact')
    log=B.checked_path(mod/'priority.log')
    if log.exists():B.require(log.stat().st_nlink==1,'linked priority log')


def _tree(mod,expected_marker):
    _exclusions(mod,expected_marker)
    result={};pending=[mod];total=0;count=0
    while pending:
        directory=pending.pop()
        result[directory.relative_to(mod).as_posix()+'/']={'directory':_directory(directory)}
        for path in sorted(directory.iterdir()):
            count+=1;B.require(count<=MAX_FILES,'binding tree exceeds bound')
            info=path.lstat()
            B.require(not stat.S_ISLNK(info.st_mode) and not getattr(info,'st_file_attributes',0)&0x400,
                      'redirected binding entry')
            rel=path.relative_to(mod).as_posix()
            if rel in ('priority.log',MARKER,LOCK):continue
            if stat.S_ISDIR(info.st_mode):pending.append(path)
            else:
                B.require(stat.S_ISREG(info.st_mode),'nonregular binding entry')
                entry=_digest(path);result[rel]=entry
                total+=entry['identity']['size'];B.require(total<=MAX_TOTAL,'binding tree bytes exceed bound')
    _exclusions(mod,expected_marker)
    return result


def _same_content(actual,wanted):
    return (actual['state']==wanted['state'] and
            (actual['state']=='missing' or actual['bytes']==wanted['bytes']))


def _read(paths,pins,expected_marker):
    roots={k:_directory(p) for k,p in {'mod':paths.mod,'runtime':paths.runtime.parent,
        'journals':paths.journals,'bundle':paths.bundle,'membership':paths.membership}.items()}
    manifest_entry=B.read_exact(paths.bundle/'proposal.json',B.MAX_MANIFEST_BYTES)
    B.require(manifest_entry.get('sha256')==pins.manifest_sha256,'bundle manifest pin differs')
    manifest=Bundle.verify(paths.bundle)
    B.require(json.loads(base64.b64decode(manifest_entry['bytes']))==manifest,'bundle changed during verification')
    # Compare path strings only. Never open a path obtained from the manifest.
    B.require(_normalized(manifest['source']['source'])==_normalized(paths.mod),'bundle source path differs')
    B.require(_normalized(manifest['journal_root'])==_normalized(paths.journals),'bundle journal path differs')
    B.require(all(manifest['source']['source_identity'][k]==roots['mod'][k] for k in ('device','inode')),
              'bundle source root identity differs')
    plan=manifest['plan']
    B.require((plan['storage'],plan['guild'],plan['legacy_guild'])==(pins.storage,pins.guild,pins.alias),'wrong bundle scope')
    report=Coverage.audit(paths.bundle)
    B.require(report['manifest_sha256']==pins.manifest_sha256,'coverage manifest differs')
    install_entry=B.read_exact(paths.membership/'install.json',B.MAX_MANIFEST_BYTES)
    B.require(install_entry.get('sha256')==pins.install_sha256,'reviewed installation receipt pin differs')
    install=json.loads(base64.b64decode(install_entry['bytes']))
    B.require(set(install)=={'activation_allowed','bundle','config','nonce','probe','production_before',
                            'read_only','replacement_allowed','runtime_sha256','sources'},'installation receipt fields')
    B.require(install['nonce']==pins.nonce and install['runtime_sha256']==pins.runtime_sha256
              and install['read_only'] is True and install['activation_allowed'] is False
              and install['replacement_allowed'] is False,'installation receipt identity/grants differ')
    B.require(_normalized(install['bundle'])==_normalized(paths.bundle)
              and _normalized(install['probe'])==_normalized(paths.runtime.parent/'Mods/PWPExportMembershipRead'),
              'installation receipt paths differ')
    B.require(install['config']=={'manifest_sha256':pins.manifest_sha256,'storage':pins.storage,
              'guild':pins.guild,'alias':pins.alias,'keys':report['lookup_union']},'installation receipt config differs')
    log=B.read_exact(paths.membership/'native.log',Analyzer.MAX_LOG)
    B.require(log.get('sha256')==pins.membership_sha256,'membership log pin differs')
    analysis=Analyzer.analyze(base64.b64decode(log['bytes']).decode('ascii'),nonce=pins.nonce,
        manifest_sha256=pins.manifest_sha256,storage=pins.storage,guild=pins.guild,alias=pins.alias,
        keys=report['lookup_union'])
    B.require(analysis['all_current_confirmed'] is True,'membership union unresolved')
    saved=B.read_exact(paths.membership/'analysis.json',Analyzer.MAX_LOG)
    B.require(json.loads(base64.b64decode(saved['bytes']))==analysis,'saved membership analysis differs')
    runtime=_digest(paths.runtime);B.require(runtime['sha256']==pins.runtime_sha256,'runtime pin differs')
    tree=_tree(paths.mod,expected_marker)
    B.require(tree.get('Scripts/main.lua',{}).get('sha256')==pins.main_sha256,'guard main pin differs')
    protected={name:entry['sha256'] for name,entry in tree.items() if 'sha256' in entry}
    # Hash-pinned review baseline, not a freshly trusted code tree. Exact set
    # equality rejects additions/deletions too; no basename/glob exclusions.
    B.require(protected==install['production_before'],'reviewed protected file tree differs')
    legacy={n:B.read_exact(paths.mod/n) for n in B.NAMES}
    journals=J.capture(paths.journals,pins.storage,pins.guild)
    trial={n:B.read_exact(paths.mod/n) for n in TRIAL}
    for group,wanted in ((legacy,manifest['source']['entries']),
                         (journals,manifest['journal_entries']),(trial,manifest['trial_entries'])):
        B.require(set(group)==set(wanted) and all(_same_content(group[n],wanted[n]) for n in group),
                  'installed legacy/journal/trial differs from bundle')
    B.require(B.read_exact(paths.bundle/'proposal.json',B.MAX_MANIFEST_BYTES)==manifest_entry,'manifest changed')
    return {'contract':'PWP-INSTALLATION-BINDING-1','roots':roots,'mod':str(paths.mod),
        'scope':{'storage':pins.storage,'guild':pins.guild,'alias':pins.alias},
        'manifest':_summary(manifest_entry),'runtime':runtime,'code_tree':tree,
        'membership':{'log':_summary(log),'analysis_file':_summary(saved),'install_file':_summary(install_entry),
                      'analysis':analysis},
        'legacy':{n:_summary(v) for n,v in legacy.items()},
        'journals':{n:_summary(v) for n,v in journals.items()},'trial':{n:_summary(v) for n,v in trial.items()},
        'excluded_root_paths':['priority.log',MARKER,LOCK],
        'activation_allowed':False,'replacement_allowed':False,'deletion_allowed':False,
        'ownership_verified':False,'deletion_coverage_verified':False,'history_coverage_verified':False,
        'storage_grant':False,'authority_grant':False,'coverage_grant':False}


def capture_for(paths,pins,quiescent,expected_marker=None):
    """Explicit test/helper inputs; all returned paths are observations, not authority."""
    B.require(type(paths) is Paths and type(pins) is Pins and callable(quiescent),'invalid binding inputs')
    B.require(quiescent() is True,'game/server must be closed')
    first=_read(paths,pins,expected_marker)
    B.require(quiescent() is True,'process started during binding')
    second=_read(paths,pins,expected_marker)
    B.require(quiescent() is True,'process started during binding')
    B.require(first==second,'installation changed during binding')
    first['binding_sha256']=hashlib.sha256(json.dumps(first,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    return first


def recheck_for(binding,paths,pins,quiescent,expected_marker=None):
    # Treat receipt as comparison data only: do not trust its paths or exclusions.
    original=json.loads(json.dumps(binding))
    fresh=capture_for(paths,pins,quiescent,expected_marker)
    B.require(original==fresh,'installation binding drift')
    return fresh


def capture(expected_marker=None):return capture_for(Paths(),Pins(),B.game_closed,expected_marker)
def recheck(binding,expected_marker=None):return recheck_for(binding,Paths(),Pins(),B.game_closed,expected_marker)


if __name__=='__main__':
    import argparse
    argparse.ArgumentParser(description=__doc__).parse_args() # fixed paths only
    print(json.dumps(capture(),sort_keys=True))
