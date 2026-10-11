"""Explicit disposable staged-transaction recovery; never removes startup fence.

Only identity-bound original, empty reservation, or complete candidate bytes are
admitted. Unknown/partial payloads, replacement objects and incomplete receipts
are preserved and refused. Complete receipts can also bind empty unpublished stages.
"""
from contextlib import ExitStack
import hashlib
import json
import re
import uuid
import settings_destination_fixture as F
from settings_staged_reservation import StagedReservation,RecoveredReservation,CONTRACT

B=F.B;C=F.C


def _json(entry):
    def unique(pairs):
        result={}
        for k,v in pairs:
            B.require(k not in result,'duplicate receipt field');result[k]=v
        return result
    B.require(entry['state']=='present','missing recovery metadata')
    return json.loads(C.decoded(entry['bytes']),object_pairs_hook=unique)


def _id(value):return {k:value[k] for k in ('device','inode')}


def publication(record,f,name):
    B.require(type(record) is dict and set(record)=={'contract','plan_sha256','root_name',
        'root_identity','name','nonce','stage_basename','identity','initial_sha256',
        'marker_sha256','activation_allowed','ownership_granted'},'publication receipt fields')
    nonce=record['nonce'];ident=record['identity']
    B.require(record['contract']==CONTRACT and record['plan_sha256']==f.plan_hash
        and record['root_name']==f.root.name and record['root_identity']==_id(f.root_id)
        and record['name']==name and type(nonce) is str and re.fullmatch('[0-9a-f]{32}',nonce)
        and record['stage_basename']=='.settings-reservation-'+nonce+'.stage'
        and record['initial_sha256']==hashlib.sha256(b'').hexdigest()
        and record['marker_sha256']==hashlib.sha256(f.marker).hexdigest()
        and record['activation_allowed'] is False and record['ownership_granted'] is False,
        'publication receipt binding differs')
    B.require(type(ident) is dict and set(ident)=={'device','inode','size'}
        and all(type(ident[k]) is int and ident[k]>0 for k in ('device','inode'))
        and type(ident['size']) is int and ident['size']==0,'publication identity invalid')
    return ident


def resume(f,hook=lambda _:None):
    B.require(type(f) is C.Fixture,'owned disposable Fixture required');p=f._plan()
    with F.TransactionLock(f.root,f.root_id):
        hook('recovery-before-metadata')
        intent_entry=B.read_exact(f.root/F.INTENT,B.MAX_MANIFEST_BYTES)
        intent=_json(intent_entry)
        B.require(set(intent)=={'contract','plan_sha256','original','desired','expected',
                                'live_cutover_allowed','root','target'} and
            intent['contract']=='PWP-DESTINATION-EXPERIMENT-2' and intent['plan_sha256']==f.plan_hash
            and intent['original']==p['original'] and intent['desired']==p['desired']
            and intent['root']==_id(f.root_id) and intent['target']==_id(B.identity(f.target.stat()))
            and intent['live_cutover_allowed'] is False and set(intent['expected'])==set(B.NAMES),
            'staged recovery intent differs')
        protected={f.root/'plan.json':B.read_exact(f.root/'plan.json',B.MAX_MANIFEST_BYTES),
                   f.root/F.INTENT:intent_entry,f.target/C.MARKER:B.read_exact(f.target/C.MARKER)}
        B.require(C.decoded(protected[f.target/C.MARKER].get('bytes'))==f.marker,'recovery fence differs')
        receipts={}
        for name in B.NAMES:
            path=f.root/('staged-'+name+'.json');entry=B.read_exact(path,65536)
            if entry['state']=='present':protected[path]=entry;receipts[name]=_json(entry)
        for name in C.TRIAL:
            entry=B.read_exact(f.target/name)
            B.require((None if entry['state']=='missing' else C.decoded(entry['bytes']))==C.decoded(p['original'][name]),
                      'trial changed before recovery')
            if entry['state']=='present':protected[f.target/name]=entry
        directories={d:B.identity(d.stat()) for d in (f.root,f.target,f.target/'async-trial')}
        B.require(_id(directories[f.target])==intent['target'],'target changed during recovery admission')
        with F.InventoryPins(protected,directories):
            B.require(f._plan()==p,'recovery plan changed')
            def check_trial():
                for name in C.TRIAL:
                    B.require(f.read(name)==C.decoded(p['original'][name]),'trial changed during recovery')
            # Validate every destination before creating any new reservation or
            # overwriting any file; metadata paths are fixed, never followed.
            snapshots={};prepared=set()
            for name in B.NAMES:
                original=C.decoded(p['original'][name]);prior=intent['expected'][name]
                B.require(type(prior) is dict and
                          (prior=={'state':'missing'} if original is None else prior.get('state')=='present'),
                          'intent original presence differs')
                B.require((None if prior['state']=='missing' else C.decoded(prior['bytes']))==original,
                          'intent snapshot differs from original')
                now=B.read_exact(f.target/name);snapshots[name]=now
                if original is None:
                    if name not in receipts:
                        B.require(now['state']=='missing','unrecorded destination; preserve it')
                        continue
                    owned=publication(receipts[name],f,name)
                    # Reconstruct only the exact validated scratch basename.
                    # Identity AND empty contents must match its prior receipt.
                    stage=f.root/receipts[name]['stage_basename'];B.checked_path(stage)
                    if stage.exists():
                        scratch=B.read_exact(stage)
                        B.require(now['state']=='missing' and _id(scratch['identity'])==_id(owned)
                                  and C.decoded(scratch['bytes'])==b'','unpublished scratch changed or destination occupied')
                        prepared.add(name)
                        continue
                    B.require(now['state']=='present' and _id(now['identity'])==_id(owned),
                              'published destination identity changed')
                    allowed=(b'',C.decoded(p['desired'][name]))
                else:
                    B.require(name not in receipts and now['state']=='present'
                              and _id(now['identity'])==_id(prior['identity']),'original destination identity changed')
                    allowed=(original,C.decoded(p['desired'][name]))
                B.require(C.decoded(now['bytes']) in allowed,'unknown or partial payload; preserve it')
            hook('recovery-validated')
            with ExitStack() as stack:
                held={}
                for name,expected in snapshots.items():
                    if expected['state']=='missing':
                        cls=RecoveredReservation if name in prepared else StagedReservation
                        lease=stack.enter_context(cls(f.root,f.root_id,name,f.plan_hash,f.marker))
                        if name not in prepared:lease.prepare_receipt()
                        hook('recovery-before-publish:'+name)
                        lease.publish();hook('recovery-after-publish:'+name)
                    else:
                        lease=stack.enter_context(F.DestinationLease(f.root,f.root_id,name,expected,f.marker))
                    held[name]=lease
                hook('recovery-all-held')
                for name,lease in held.items():
                    hook('before-recovery-write:'+name)
                    check_trial()
                    lease.overwrite(C.decoded(p['desired'][name]))
                    hook('after-recovery-write:'+name)
                B.require(all(held[n].read()==C.decoded(p['desired'][n]) for n in B.NAMES),'recovery readback differs')
                check_trial()
            result={'candidate_copies_verified':True,'fence_retained':True,'trial_retired':False,
                    'live_cutover_allowed':False,'unknown_payload_recovery':False,
                    'power_loss_durability_proven':False}
            B.write_new(f.root/('recovered-'+uuid.uuid4().hex+'.json'),F.wire(result))
    return result
