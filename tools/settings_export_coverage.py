"""Read-only coverage inventory of a verified offline export bundle.

Claims are not ownership evidence. Missing journal rows are differences, not
authorized deletions. This tool neither follows source paths nor installs files.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import sys

import settings_export_bundle as Bundle


def _decode(manifest):
    """Use production recovery selection/typed decoding on captured bytes only."""
    sys.path.insert(0, str(Bundle.ROOT / '.test-deps'))
    from lupa.lua54 import LuaRuntime
    lua = LuaRuntime(unpack_returned_tuples=True, encoding=None)
    lua.globals().ROOT = Bundle.ROOT.as_posix().encode()
    lua.globals().files = lua.table_from({k.encode(): v for k, v in
                                        Bundle.B.frozen(manifest['source']).items()})
    selection = manifest['plan']['journal_selection']['priorities']
    lua.globals().journal = base64.b64decode(selection['canonical_body_base64'], validate=True)
    lua.globals().candidate = manifest['plan']['bodies']['priorities'].encode()
    history, bodies = {}, {}
    plan = manifest['plan']
    for slot in ('A', 'B'):
        entry = manifest['journal_entries']['priorities-' + slot]
        if entry['state'] == 'missing':
            history[slot] = {'state': 'missing', 'keys': []}
            continue
        raw = base64.b64decode(entry['bytes'], validate=True)
        generation, payload = Bundle.J.decode(raw, f"PWP-SCOPE-1:{plan['storage']}:{plan['guild']}:priorities")
        body = Bundle.J.canonical_body(payload, plan['storage'], plan['guild'], 'priorities')
        bodies[slot.encode()] = body
        history[slot] = {'state': 'present', 'generation': generation,
                         'record_sha256': hashlib.sha256(raw).hexdigest(),
                         'canonical_body_sha256': hashlib.sha256(body).hexdigest()}
    lua.globals().history = lua.table_from(bodies)
    result = lua.execute(b"""
        package.path=ROOT..'/Scripts/?.lua;'
        local function forbidden()error('coverage forbids runtime IO')end
        io.open=forbidden;io.popen=forbidden;io.output=forbidden
        os.rename=forbidden;os.remove=forbidden;os.execute=forbidden
        local Data=require('datafile')
        Data.fs={open=function(path,mode)
            assert(mode=='rb');local raw=files[path]
            if raw==nil then return nil,'missing',2 end
            return {read=function(_,n)assert(n>=#raw);return raw end,
                close=function()return true end}
        end,rename=forbidden,remove=forbidden}
        local Store=require('store')
        local legacy,meta=Data.read('priorities.txt',Store.decode_snapshot)
        assert(legacy,'valid selected legacy priorities required')
        local slots={}
        for slot,body in pairs(history)do slots[slot]=assert(Store.decode_snapshot(body)).data end
        return {legacy=legacy.data,journal=assert(Store.decode_snapshot(journal)).data,
            candidate=assert(Store.decode_snapshot(candidate)).data,
            history=slots,
            selected={source=meta.source,generation=meta.generation}}
    """)

    def convert(value):
        if isinstance(value, bytes):
            return value.decode('utf-8')
        if hasattr(value, 'items'):
            return {convert(k): convert(v) for k, v in value.items()}
        return value
    decoded = convert(result)
    for slot, rows in decoded.pop('history').items():
        history[slot]['keys'] = sorted(rows)
        history[slot]['rows'] = sum(len(v) for v in rows.values())
    decoded['history'] = history
    return decoded


def _diff(before, after):
    # Membership, never truthiness: false is the explicit disabled (X) value.
    return {'removed': sum(k not in after for k in before),
            'added': sum(k not in before for k in after),
            'changed': sum(k in after and before[k] != after[k] for k in before)}


def audit(bundle):
    path = Bundle.B.checked_path(bundle, directory=True)
    entry = Bundle.B.read_exact(path / 'proposal.json', Bundle.B.MAX_MANIFEST_BYTES)
    manifest = Bundle.verify(path)
    raw = base64.b64decode(entry['bytes'], validate=True)
    Bundle.B.require(json.loads(raw) == manifest, 'manifest changed before verification')
    decoded = _decode(manifest)
    plan = manifest['plan']
    Bundle.B.require(decoded['selected'] == plan['selected_legacy']['priorities'],
                     'legacy selection differs')
    legacy, journal, candidate = (decoded[k] for k in ('legacy', 'journal', 'candidate'))
    claims = {c['pal']: c for c in manifest['membership_claims']}
    slot_keys = {s: set(v['keys']) for s, v in decoded['history'].items()}
    historical = set().union(*slot_keys.values())
    keys = sorted(set(legacy) | set(journal) | set(claims) | historical)
    coverage = {'legacy_only': [], 'journal_only': [], 'shared': [], 'claim_only': [], 'history_only': []}
    categories = {'target': [], 'foreign': [], 'unclaimed': []}
    ambiguous, rows = [], []
    for pal in keys:
        group = ('shared' if pal in legacy and pal in journal else 'legacy_only'
                 if pal in legacy else 'journal_only' if pal in journal else
                 'claim_only' if pal in claims else 'history_only')
        claim = claims.get(pal)
        category = ('unclaimed' if claim is None else 'target'
                    if claim['storage'] == plan['storage'] and claim['guild'] == plan['guild']
                    else 'foreign')
        coverage[group].append(pal)
        categories[category].append(pal)
        unresolved = group == 'legacy_only' and category == 'unclaimed'
        if unresolved:
            ambiguous.append(pal)
        rows.append({'pal': pal, 'coverage': group, 'claim_category': category,
                     'claim': claim, 'ownership_verified': False,
                     'retained_journal_slots': [s for s in ('A', 'B') if pal in slot_keys[s]],
                     'ambiguous_legacy_only_unclaimed': unresolved,
                     'legacy_rows': len(legacy.get(pal, {})),
                     'journal_rows': len(journal.get(pal, {})),
                     'candidate_rows': len(candidate.get(pal, {})),
                     'legacy_to_journal': _diff(legacy.get(pal, {}), journal.get(pal, {})),
                     'legacy_to_candidate': _diff(legacy.get(pal, {}), candidate.get(pal, {}))})
    Bundle.B.require(Bundle.verify(path) == manifest, 'bundle changed during audit')
    Bundle.B.require(Bundle.B.read_exact(path / 'proposal.json', Bundle.B.MAX_MANIFEST_BYTES) == entry,
                     'manifest changed during audit')
    return {'contract': 'PWP-EXPORT-COVERAGE-1',
            'manifest_sha256': hashlib.sha256(raw).hexdigest(),
            'candidate_hashes': {s: manifest['files']['candidates/' + s + '.body']['sha256']
                                 for s in ('priorities', 'limits')},
            'storage': plan['storage'], 'guild': plan['guild'],
            'selected_legacy': decoded['selected'],
            'journal_selection': plan['journal_selection']['priorities'],
            'retained_priority_records': decoded['history'],
            'older_peer_only_keys': sorted(historical - set(journal)),
            'lookup_union': keys,
            'retained_history_complete': False,
            'coverage': coverage, 'claim_categories': categories, 'pals': rows,
            'ambiguous_legacy_only_unclaimed': ambiguous,
            'interpretation': 'Claims only. Removed counts are row-set differences, not deletion '
                              'proof or permission. Unclaimed legacy-only Pals remain ambiguous. '
                              'Retained A/B records are incomplete history; older-only keys are '
                              'lookup candidates, not ownership or deletion proof.',
            **{k: False for k in ('ownership_verified', 'membership_verified',
                                 'deletion_coverage_verified', 'deletion_allowed',
                                 'activation_allowed', 'replacement_allowed',
                                 'storage_grant', 'authority_grant', 'coverage_grant')}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    args = parser.parse_args()
    try:
        result = audit(args.bundle)
    except Exception:
        print(json.dumps({'audit_completed': False, 'error': 'coverage_audit_failed',
                          'activation_allowed': False, 'replacement_allowed': False}))
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
