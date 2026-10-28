"""Pure single-record cutover observation acceptance; no IO or cutover authority.

The caller removes only the UE4SS prefix, retaining one terminating newline.
Expected recovered bodies
must come from independently reviewed evidence. This parser cannot establish
process identity, an actual interruption, restoration, or ownership.
"""
import re

MAX_BODY = 262144
MAX_LINE = 4 * MAX_BODY + 1024
MAX_SETTINGS_OPENS = 64
FIELDS = frozenset(('nonce', 'phase', 'loaded', 'gate', 'gate_blocked',
                    'priority_state', 'limit_state', 'settings_opens',
                    'trial_opens', 'priority_hex', 'limit_hex', 'error'))
EMPTY_PRIORITIES = b'# Pal Work Priority: palkey|worktype|priority (1 highest, 5 lowest, X disabled)\n'
EMPTY_LIMITS = (b'# Production limits. Mining limits stop only the rocks of their item; every other limit switches its whole work type.\n'
                b'# guild|work|item|limit (OFF hides an inherited limit for this guild)\n')


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def accept(line, nonce, phase, expected_priorities: bytes, expected_limits: bytes):
    require(type(nonce) is str and re.fullmatch(r'[0-9a-f]{32}', nonce)
            and nonce != '0' * 32, 'invalid expected nonce')
    require(type(phase) is str and phase in ('fenced', 'recovered'), 'invalid expected phase')
    for body in (expected_priorities, expected_limits):
        require(type(body) is bytes and 0 < len(body) <= MAX_BODY, 'invalid expected body')
    if phase == 'fenced':
        require(expected_priorities == EMPTY_PRIORITIES and expected_limits == EMPTY_LIMITS,
                'fenced expectations must be empty canonical snapshots')
    require(type(line) is str and len(line) <= MAX_LINE + 2 and line.isascii()
            and line.endswith('\n'), 'missing or invalid record framing')
    line = line[:-2] if line.endswith('\r\n') else line[:-1]
    require(len(line) <= MAX_LINE and not any(c in line for c in '\r\n\x00'), 'invalid single record')
    parts = line.split('\t')
    require(len(parts) == len(FIELDS) + 1 and parts[0] == 'PWP_CUTOVER_NATIVE', 'invalid record shape')
    row = {}
    for field in parts[1:]:
        key, separator, value = field.partition('=')
        require(separator and key in FIELDS and key not in row, 'unknown or duplicate field')
        row[key] = value
    require(set(row) == FIELDS, 'incomplete record')
    require(row['nonce'] == nonce and row['phase'] == phase, 'observation identity mismatch')
    require(row['loaded'] == 'true' and row['error'] == 'none', 'entry or observation failed')
    for key, expected in (('priority_hex', expected_priorities), ('limit_hex', expected_limits)):
        text = row[key]
        require(len(text) <= 2 * MAX_BODY and len(text) % 2 == 0
                and re.fullmatch(r'[0-9a-f]*', text) is not None, 'invalid canonical hex')
        require(bytes.fromhex(text) == expected, 'snapshot mismatch')
    require(re.fullmatch(r'0|[1-9][0-9]?', row['settings_opens']) is not None,
            'invalid settings count')
    count = int(row['settings_opens'])
    require(count <= MAX_SETTINGS_OPENS, 'settings count exceeds observation bound')
    if phase == 'fenced':
        require(row['gate'] == 'restart_required' and row['gate_blocked'] == 'true'
                and row['priority_state'] == row['limit_state'] == 'unavailable'
                and count == 0 and row['trial_opens'] == '0', 'fence evidence differs')
    else:
        require(row['gate'] == 'ready' and row['gate_blocked'] == 'false'
                and row['priority_state'] == row['limit_state'] == 'saved'
                and count > 0 and row['trial_opens'] == '2', 'recovery evidence differs')
    return {'observation_accepted': True, 'nonce': nonce, 'phase': phase,
            'settings_opens': count, 'trial_opens': int(row['trial_opens']),
            'bodies_match': True, 'actual_interruption_verified': False,
            'native_identity_verified': False, 'restoration_verified': False,
            'ownership_verified': False, 'deletion_coverage_verified': False,
            'replacement_allowed': False, 'activation_allowed': False,
            'storage_grant': False, 'authority_grant': False, 'coverage_grant': False}
