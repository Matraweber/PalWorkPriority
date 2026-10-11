"""Disposable held-handle two-stream write experiment. Never activates a mod.

Success retains the startup fence and trial files. No deletion, live adapter or
power-loss claim. Staged v2 copies have a separate explicit recovery tool;
the original v1 direct-reservation experiment still refuses blind resume.
"""
from contextlib import ExitStack
import json
import settings_cutover_fixture as C
import settings_migration_backup as B
from settings_cutover_lock import TransactionLock
from settings_inventory_pins import InventoryPins
from settings_destination_lease import DestinationLease

INTENT='destination-intent.json'


def wire(value):return (json.dumps(value,sort_keys=True,separators=(',',':'))+'\n').encode()


def run(fixture,hook=lambda _:None,*,staged=False):
    B.require(type(fixture) is C.Fixture,'owned disposable Fixture required')
    B.require(type(staged) is bool,'explicit staged experiment mode required')
    p=fixture._plan()
    with TransactionLock(fixture.root,fixture.root_id):
        # Retain originals/plan and parent identities during the experiment.
        protected={fixture.root/'plan.json':B.read_exact(fixture.root/'plan.json',B.MAX_MANIFEST_BYTES)}
        directories={d:B.identity(d.stat()) for d in
                     (fixture.root,fixture.target,fixture.target/'async-trial')}
        for name in C.TRIAL:
            entry=B.read_exact(fixture.target/name)
            if entry['state']=='present':protected[fixture.target/name]=entry
        with InventoryPins(protected,directories):
            p,values=fixture.state()
            B.require(fixture._originals_match(p,values) and fixture.read(C.MARKER) is None,
                      'experiment requires pristine originals and absent marker')
            B.require(not (fixture.root/INTENT).exists(),'experiment cannot resume; preserve prior intent')
            hook('after-pristine-check')
            expected={n:B.read_exact(fixture.target/n) for n in B.NAMES}
            for name,entry in expected.items():
                original=C.decoded(p['original'][name])
                observed=None if entry['state']=='missing' else C.decoded(entry['bytes'])
                B.require(observed==original,'snapshot differs from immutable original: '+name)
            intent={'contract':'PWP-DESTINATION-EXPERIMENT-1','plan_sha256':fixture.plan_hash,
                    'original':p['original'],'desired':p['desired'],
                    'expected':expected,'live_cutover_allowed':False}
            if staged:
                intent.update(contract='PWP-DESTINATION-EXPERIMENT-2',
                              root={k:fixture.root_id[k] for k in ('device','inode')},
                              target={k:directories[fixture.target][k] for k in ('device','inode')})
            B.write_new(fixture.root/INTENT,wire(intent))
            hook('before-fence')
            B.write_new(fixture.target/C.MARKER,fixture.marker)
            hook('after-fence')
            receipts={}
            with ExitStack() as leases:
                held={}
                for name in B.NAMES:
                    hook('before-reserve:'+name)
                    if staged and expected[name]['state']=='missing':
                        from settings_staged_reservation import StagedReservation
                        lease=leases.enter_context(StagedReservation(fixture.root,fixture.root_id,
                            name,fixture.plan_hash,fixture.marker))
                        hook('after-scratch:'+name)
                        lease.prepare_receipt()
                        hook('before-publish:'+name)
                        lease.publish()
                        hook('after-publish:'+name)
                    else:
                        lease=leases.enter_context(DestinationLease(fixture.root,fixture.root_id,
                                                                   name,expected[name],fixture.marker))
                    held[name]=lease
                    # Creation precedes this receipt. A crash in that gap is
                    # deliberately NOT automatically recoverable by this tool.
                    receipts[name]=lease.receipt()
                    B.write_new(fixture.root/('reserved-'+name+'.json'),wire(receipts[name]))
                    hook('after-reserve:'+name)
                hook('all-reserved')
                for name in B.NAMES:
                    original=C.decoded(p['original'][name])
                    B.require(held[name].read()==(b'' if original is None else original),
                              'held destination differs from immutable original: '+name)
                for name in B.NAMES:
                    hook('before-write:'+name)
                    fixture._plan() # Hash-bound originals must remain available.
                    receipt=held[name].overwrite(C.decoded(p['desired'][name]))
                    B.write_new(fixture.root/('written-'+name+'.json'),wire(receipt))
                    hook('after-write:'+name)
                for name in B.NAMES:
                    B.require(held[name].read()==C.decoded(p['desired'][name]),'held final readback differs')
                for name in C.TRIAL:
                    B.require(fixture.read(name)==C.decoded(p['original'][name]),'trial changed')
                B.require(fixture.read(C.MARKER)==fixture.marker,'fence changed')
                hook('verified-held')
            # A close failure prevents success recording. Fence is never removed.
            result={'candidate_copies_verified':True,'destinations':len(B.NAMES),
                    'reserved_missing':sum(r['created'] for r in receipts.values()),
                    'fence_retained':True,'trial_retired':False,'activation_allowed':False,
                    'live_cutover_allowed':False,'automatic_recovery_supported':False,
                    'atomic_multifile_commit':False,'power_loss_durability_proven':False}
            B.write_new(fixture.root/'destination-result.json',wire(result))
    return result
