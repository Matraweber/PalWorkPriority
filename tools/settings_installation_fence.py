"""Marker-only installation rehearsal. Never replaces settings or retires a trial.

The lock coordinates these tools. The pinned game's startup marker and a process
check AFTER marker creation cover known game startup races. The fixed-install
factory also denies write/delete access to existing reviewed files; it does not
exclude new children or every unrelated writer. Failures before removal retain the fence. Failures after its
removal can leave incomplete evidence; never automatically recreate the marker.
"""
from pathlib import Path
from contextlib import contextmanager
import base64
import hashlib
import json
import uuid
import settings_migration_backup as B
from settings_cutover_lock import TransactionLock

MOD=Path('D:/Steam/steamapps/common/Palworld/Mods/NativeMods/UE4SS/Mods/PalWorkPriority')
ROOT=Path(__file__).resolve().parents[1]
MARKER='.settings-cutover'


def wire(value):return (json.dumps(value,sort_keys=True,separators=(',',':'))+'\n').encode()


class InstallationLock(TransactionLock):
    """The sole additional root is the explicit client installation, never a CLI path."""
    def _check_root(self):
        B.checked_path(self.root,directory=True)
        B.require(self.root==MOD,'lock outside fixed installation')
        info=self.root.stat()
        B.require((info.st_dev,info.st_ino)==self.identity,'installation root identity changed')


class MarkerCycle:
    """Small testable coordinator; caller supplies independently checked binding."""
    def __init__(self,root,binding,evidence,lock,recheck,closed,hook=lambda _:None):
        self.root=Path(root);self.binding=binding;self.evidence=Path(evidence)
        B.checked_path(self.root,directory=True);B.checked_path(self.evidence,directory=True)
        B.require(not self.evidence.resolve().is_relative_to(self.root.resolve()),
                  'rehearsal evidence must be outside the installation')
        self.lock=lock;self.recheck=recheck;self.closed=closed;self.hook=hook

    def _exact(self,raw):
        entry=B.read_exact(self.root/MARKER)
        B.require(entry['state']=='present' and base64.b64decode(entry['bytes'],validate=True)==raw,
                  'own complete fence not present; do not remove unknown marker')

    def _check(self,marker):
        B.require(self.closed() is True,'game/server process present or unknown')
        self.recheck(self.binding,expected_marker=marker)

    def _finish(self,raw):
        self.hook('before-unfence')
        self._check(raw);self._exact(raw)
        B.checked_path(self.root/MARKER).unlink()
        self.hook('after-unfence')
        # No settings operations after releasing the fence. A later game launch
        # is allowed; the result describes checks completed BEFORE its removal.
        result={'marker_rehearsal_complete':True,'settings_written':False,
                'sources_verified_before_release':True,'live_cutover_allowed':False,
                'async_enabled':False,'arbitrary_writers_excluded':False}
        B.write_new(self.evidence/'complete.json',wire(result))
        return result

    def run(self):
        with self.lock():
            self._check(None)
            B.require(not (self.evidence/'intent.json').exists(),'preserve previous intent')
            nonce=uuid.uuid4().hex
            digest=hashlib.sha256(wire(self.binding)).hexdigest()
            raw=('PWP-INSTALLATION-FENCE-REHEARSAL-1\n'+nonce+'\n'+digest+'\n').encode()
            intent={'contract':'PWP-INSTALLATION-FENCE-REHEARSAL-1','root':str(self.root),
                    'binding':self.binding,'marker':base64.b64encode(raw).decode(),
                    'nonce':nonce,'binding_sha256':digest,'settings_written':False}
            B.write_new(self.evidence/'intent.json',wire(intent))
            self.hook('before-fence')
            B.write_new(self.root/MARKER,raw) # Exclusive creation; never replace.
            self.hook('after-fence')
            self._check(raw);self._exact(raw)
            B.write_new(self.evidence/'fenced.json',wire({'verified':True,'nonce':nonce,
                        'sources_unchanged':True,'settings_written':False}))
            self.hook('after-verified')
            return self._finish(raw)

    def recover(self):
        """Explicit marker-only recovery, never resumes a data migration."""
        with self.lock():
            entry=B.read_exact(self.evidence/'intent.json',B.MAX_MANIFEST_BYTES)
            intent=json.loads(base64.b64decode(entry['bytes'],validate=True))
            B.require(intent.get('contract')=='PWP-INSTALLATION-FENCE-REHEARSAL-1'
                      and intent.get('root')==str(self.root) and intent.get('binding')==self.binding
                      and intent.get('settings_written') is False,'foreign rehearsal intent')
            digest=hashlib.sha256(wire(self.binding)).hexdigest()
            nonce=intent.get('nonce')
            B.require(type(nonce) is str and len(nonce)==32 and all(c in '0123456789abcdef' for c in nonce),'invalid nonce')
            raw=('PWP-INSTALLATION-FENCE-REHEARSAL-1\n'+nonce+'\n'+digest+'\n').encode()
            B.require(intent.get('binding_sha256')==digest and intent.get('marker')==base64.b64encode(raw).decode(),'intent binding differs')
            self._check(raw);self._exact(raw)
            return self._finish(raw)


@contextmanager
def protected_installation(binding,identity):
    """Deny writes to existing reviewed files during a marker-only operation.

    Exact inventory rechecks remain necessary: read handles do not reserve
    absent names or prevent creation of new children. No payload write grant.
    """
    import settings_installation_binding as I
    from settings_inventory_pins import InventoryPins
    with InstallationLock(MOD,identity):
        marker=B.read_exact(MOD/MARKER,4096)
        observed=None if marker['state']=='missing' else base64.b64decode(marker['bytes'],validate=True)
        # Recovery receipts are untrusted comparisons. Reconstruct from fixed
        # paths before using their inventory; ownership is checked by the cycle.
        checked=I.recheck(binding,expected_marker=observed)
        files={};directories={}
        for name,entry in checked['code_tree'].items():
            path=MOD/name.rstrip('/')
            if 'directory' in entry:directories[path]=entry['directory']
            else:files[path]=entry
        files[I.RUNTIME/'UE4SS.dll']=checked['runtime']
        directories[I.RUNTIME]=checked['roots']['runtime']
        with InventoryPins(files,directories):
            # MarkerCycle performs its first full recheck under every handle,
            # before creating/removing any marker, then repeats before release.
            yield


def installation_cycle(binding,evidence):
    import settings_installation_binding as I
    B.require(binding.get('mod')==str(MOD) and I.MOD==MOD,'binding is not the fixed installation')
    identity=binding['roots']['mod']
    B.require(identity.get('path')==str(MOD) and all(type(identity.get(k)) is int for k in ('device','inode')),
              'invalid bound root identity')
    return MarkerCycle(MOD,binding,evidence,lambda:protected_installation(binding,identity),I.recheck,B.game_closed)


def main():
    import argparse
    import re
    import settings_installation_binding as I
    parser=argparse.ArgumentParser(description=__doc__)
    options=parser.add_mutually_exclusive_group()
    options.add_argument('--rehearse',action='store_true')
    options.add_argument('--recover',type=Path)
    args=parser.parse_args()
    if args.recover:
        evidence=B.checked_path(args.recover,directory=True)
        B.require(evidence.resolve().parent==(ROOT/'test-results').resolve()
                  and re.fullmatch('installation-fence-rehearsal-[0-9a-f]{32}',evidence.name),
                  'recovery evidence outside owned namespace')
        entry=B.read_exact(evidence/'intent.json',B.MAX_MANIFEST_BYTES)
        intent=json.loads(base64.b64decode(entry['bytes'],validate=True))
        result=installation_cycle(intent['binding'],evidence).recover()
    else:
        binding=I.capture()
        if not args.rehearse:
            print(json.dumps({'preflight_passed':True,'binding_sha256':binding['binding_sha256'],
                              'live_cutover_allowed':False}));return
        evidence=ROOT/'test-results'/('installation-fence-rehearsal-'+uuid.uuid4().hex)
        B.checked_path(evidence,directory=True);evidence.mkdir()
        print(json.dumps({'rehearsal_evidence':str(evidence),'settings_written':False}),flush=True)
        result=installation_cycle(binding,evidence).run()
    result['evidence']=str(evidence)
    print(json.dumps(result))


if __name__=='__main__':main()
