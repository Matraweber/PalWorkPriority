"""Independently validate the one-shot read-only observation and unchanged install."""
import json
import re
from install_local_authority_probe import ROOT, RUNTIME, PROBE, EVIDENCE, digest


def main():
    manifest = json.loads((EVIDENCE / 'install.json').read_text())
    raw = (PROBE / 'Scripts/authority.log').read_bytes()
    rows = [line.split('\t') for line in raw.decode('utf-8').splitlines()]
    assert len(rows) == 2 and [r[2] for r in rows] == ['armed', 'observed']
    assert all(r[1] == manifest['nonce'] for r in rows)
    pairs = [part.split('=', 1) for part in rows[1][3:]]
    fields = dict(pairs)
    assert len(fields) == len(pairs)
    assert fields['authority_status'] == 'read' and fields['authority'] == 'true'
    assert fields['guild_status'] == 'format_valid' and fields['activation_allowed'] == 'false'
    assert fields['read_only'] == 'true'
    assert fields['storage'] == '31141b9948fe8b9a8b4cc399974dddf1', 'unexpected world'
    assert re.fullmatch('[0-9a-f]{32}', fields['guild']) and int(fields['guild'], 16) != 0
    match = re.fullmatch(r'(-?\d+)-(-?\d+)-(-?\d+)-(-?\d+)', fields['legacy_guild'])
    assert match is not None
    words = [int(v) for v in match.groups()]
    assert all(-2147483648 <= v <= 4294967295 for v in words)
    assert ''.join(f'{v & 0xffffffff:08x}' for v in words) == fields['guild']
    for key in ('world_address', 'state_address', 'instance_address', 'player_address',
                'controller_address', 'player_state_address', 'guild_address'):
        assert int(fields[key]) > 0
    assert {n: digest(PROBE / 'Scripts' / n) for n in manifest['installed']} == manifest['installed']
    production = RUNTIME / 'Mods/PalWorkPriority'
    after = {str(p.relative_to(production)): digest(p) for p in production.rglob('*')
             if p.is_file() and (p.suffix == '.lua' or (p.parent == production and p.suffix == '.txt'))}
    assert after == manifest['production_before'], 'production/settings changed'
    assert (PROBE / 'Scripts/run.txt').read_text().strip() == 'DISABLED'
    receipt = dict(passed=True, read_only=True, production_unchanged=True,
                   nonce=manifest['nonce'], observation=fields)
    (EVIDENCE / 'authority.log').write_bytes(raw)
    (EVIDENCE / 'receipt.json').write_text(json.dumps(receipt, indent=2))
    (PROBE / 'enabled.txt').rename(PROBE / 'enabled.txt.disabled')
    print(json.dumps(receipt))


if __name__ == '__main__':
    main()
