"""Synthetic records are constructed/mutated before calling the pure acceptor."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('accept_cutover_native', ROOT/'tools/accept_cutover_native.py')
M = importlib.util.module_from_spec(spec)
spec.loader.exec_module(M)
NONCE = 'a' * 32


def record(phase='fenced', priorities=M.EMPTY_PRIORITIES, limits=M.EMPTY_LIMITS):
    fenced = phase == 'fenced'
    return dict(nonce=NONCE, phase=phase, loaded='true',
                gate='restart_required' if fenced else 'ready',
                gate_blocked='true' if fenced else 'false',
                priority_state='unavailable' if fenced else 'saved',
                limit_state='unavailable' if fenced else 'saved',
                settings_opens='0' if fenced else '8', trial_opens='0' if fenced else '2',
                priority_hex=priorities.hex(), limit_hex=limits.hex(), error='none')


def render(row):
    return 'PWP_CUTOVER_NATIVE\t' + '\t'.join(k+'='+v for k, v in row.items()) + '\n'


class Acceptance(unittest.TestCase):
    def accept(self, row, phase='fenced', p=M.EMPTY_PRIORITIES, c=M.EMPTY_LIMITS):
        return M.accept(render(row), NONCE, phase, p, c)

    def test_two_phases_and_no_grants(self):
        for phase in ('fenced', 'recovered'):
            p = M.EMPTY_PRIORITIES if phase == 'fenced' else M.EMPTY_PRIORITIES+b'mine|1|X\n'
            c = M.EMPTY_LIMITS if phase == 'fenced' else M.EMPTY_LIMITS+b'*|Mining|Stone|OFF\n'
            result = self.accept(record(phase, p, c), phase, p, c)
            self.assertTrue(result['observation_accepted'])
            self.assertTrue(result['bodies_match'])
            for key, value in result.items():
                if key.endswith(('_verified', '_allowed', '_grant')):
                    self.assertIs(value, False, key)

    def test_exact_schema_missing_extra_duplicate(self):
        self.assertEqual(len(record()), 12)
        for key in record():
            row = record(); del row[key]
            with self.subTest(missing=key), self.assertRaises(ValueError): self.accept(row)
        text = render(record())
        for bad in (text[:-1]+'\textra=true\n', text[:-1]+'\tnonce='+NONCE+'\n',
                    text.replace('phase=fenced', 'nonce='+NONCE)):
            with self.assertRaises(ValueError): M.accept(bad, NONCE, 'fenced', M.EMPTY_PRIORITIES, M.EMPTY_LIMITS)

    def test_missing_multiline_prefix_and_bounds(self):
        text = render(record())
        for bad in ('', text[:-1], text+'\n', text+'\r', text+text, '[UE4SS] '+text,
                    text[:-1]+'[engine] next record\n', text+'[engine] next record\n',
                    text+'\x00', text+'é', 'x'*(M.MAX_LINE+1), None, b'bytes'):
            with self.assertRaises(ValueError): M.accept(bad, NONCE, 'fenced', M.EMPTY_PRIORITIES, M.EMPTY_LIMITS)
        self.assertTrue(M.accept(text[:-1]+'\r\n', NONCE, 'fenced', M.EMPTY_PRIORITIES, M.EMPTY_LIMITS)['observation_accepted'])

    def test_identity_and_failure_controls(self):
        for key, value in (('nonce', 'b'*32), ('phase', 'recovered'), ('loaded', 'false'),
                           ('loaded', '1'), ('error', 'entry_failed'), ('error', 'observation_failed')):
            row=record();row[key]=value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError): self.accept(row)
        for nonce in ('0'*32, 'A'*32, 'a'*31, 'a'*33, '１'*32, None):
            with self.assertRaises(ValueError): M.accept(render(record()), nonce, 'fenced', M.EMPTY_PRIORITIES, M.EMPTY_LIMITS)
        with self.assertRaises(ValueError): M.accept(render(record()), NONCE, 'other', M.EMPTY_PRIORITIES, M.EMPTY_LIMITS)

    def test_phase_states_counts_and_zero_read_recovery(self):
        for phase in ('fenced', 'recovered'):
            changes=[('gate','unknown'), ('gate_blocked','unknown'), ('priority_state','saving'),
                     ('limit_state','error'), ('settings_opens','-1'), ('settings_opens','01'),
                     ('settings_opens','1.0'), ('settings_opens','65'), ('settings_opens','9'*100),
                     ('trial_opens','1'), ('trial_opens','02')]
            changes += [('settings_opens','1' if phase=='fenced' else '0'),
                        ('trial_opens','2' if phase=='fenced' else '0')]
            for key,value in changes:
                row=record(phase);row[key]=value
                with self.subTest(phase=phase,key=key,value=value), self.assertRaises(ValueError): self.accept(row,phase)
        row=record('recovered');row['settings_opens']='64'
        self.assertTrue(self.accept(row,'recovered')['observation_accepted'])

    def test_hex_and_body_mismatch(self):
        for key in ('priority_hex', 'limit_hex'):
            for value in ('', '0', 'gg', 'AA', '20 20', '00', '00'*(M.MAX_BODY+1)):
                row=record();row[key]=value
                with self.subTest(key=key,value=value[:10]), self.assertRaises(ValueError): self.accept(row)
        row=record();row['priority_hex']=row['priority_hex'].upper()
        with self.assertRaises(ValueError): self.accept(row)

    def test_fenced_cannot_accept_nonempty_matching_snapshots(self):
        for p,c in ((M.EMPTY_PRIORITIES+b'mine|1|X\n',M.EMPTY_LIMITS),
                    (M.EMPTY_PRIORITIES,M.EMPTY_LIMITS+b'*|Mining|Stone|OFF\n'),
                    (M.EMPTY_PRIORITIES+b'# baseline=vanilla\n',M.EMPTY_LIMITS)):
            with self.assertRaises(ValueError): self.accept(record('fenced',p,c),'fenced',p,c)

    def test_expected_bytes_types_and_capacity(self):
        for body in ('text', bytearray(b'x'), None, b'', b'x'*(M.MAX_BODY+1)):
            with self.assertRaises(ValueError): self.accept(record('recovered'),'recovered',body,M.EMPTY_LIMITS)
        body=b'x'*M.MAX_BODY
        self.assertTrue(self.accept(record('recovered',body,body),'recovered',body,body)['bodies_match'])


if __name__ == '__main__': unittest.main()
