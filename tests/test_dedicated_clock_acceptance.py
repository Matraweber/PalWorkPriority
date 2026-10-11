import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('clock_accept', ROOT/'tools/accept_dedicated_clock_probe.py')
M = importlib.util.module_from_spec(spec)
spec.loader.exec_module(M)
NONCE = 'a'*32


def evidence():
    base = dict(nonce=NONCE, clock='GameplayStatics_GetAccurateRealTime', measurement='clock_under_test',
                elapsed_validated='false', total_callback_ms='unknown', resolver_ms='unknown',
                verified='false', active='false', storage_grant='false', authority_grant='false', coverage_grant='false')
    rows = []
    for n in range(1, 9):
        rows.append(dict(base, status='observed', reason='sample', samples=str(n), callbacks=str(n),
                         reads='34', read_intervals='32', work_steps='4096', checksum=str(sum(range(1,4097))%65521),
                         between_sample_ms='unknown' if n==1 else '1000',
                         between_sample_advanced='false' if n==1 else 'true',
                         read_burst_ms='0.32', mean_read_interval_ms='0.01', work_and_final_read_ms='0.08',
                         first_to_last_read_ms='0.4', within_sample_advanced='true'))
    rows.append(dict(base, status='finished', reason='sample_limit', samples='8', callbacks='8',
                     observed_samples='8', forward_intervals='7', within_sample_advances='8',
                     advancement_observed='true', cancellation_attempted='true', timer_cancelled='true'))
    return rows


def render(rows):
    return ''.join('PWP_DEDICATED_CLOCK | '+' | '.join(k+'='+v for k,v in row.items())+'\n' for row in rows)


class ClockAcceptanceTests(unittest.TestCase):
    def test_valid_observation_is_not_native_elapsed_or_ownership_proof(self):
        result=M.accept(render(evidence()), NONCE)
        self.assertTrue(result['advancement_observed'])
        for key in ('elapsed_validated','native_identity_verified','restoration_verified','storage_grant','authority_grant'):
            self.assertFalse(result[key])

    def test_fault_matrix(self):
        cases=[(0,'nonce','b'*32),(0,'samples','2'),(0,'reads','33'),(0,'elapsed_validated','true'),
               (0,'storage_grant','true'),(0,'checksum','1'),(1,'between_sample_ms','0'),
               (1,'between_sample_ms','nan'),(1,'mean_read_interval_ms','100'),
               (1,'first_to_last_read_ms','101'),(8,'timer_cancelled','false'),
               (8,'forward_intervals','6'),(8,'within_sample_advances','7'),(8,'reason','clock_unavailable')]
        for index,key,value in cases:
            with self.subTest(key=key,value=value):
                rows=evidence();rows[index][key]=value
                with self.assertRaises(ValueError):M.accept(render(rows),NONCE)

    def test_truncation_extra_rows_and_duplicate_keys(self):
        text=render(evidence())
        for bad in (text[:-1],render(evidence()[:-1]),text+text.splitlines()[0]+'\n',
                    text.replace('nonce='+NONCE,'nonce='+NONCE+' | nonce='+NONCE,1)):
            with self.assertRaises(ValueError):M.accept(bad,NONCE)

    def test_cumulative_elapsed_limit(self):
        rows=evidence()
        for row in rows[1:8]:row['between_sample_ms']='10000'
        with self.assertRaises(ValueError):M.accept(render(rows),NONCE)
        for row in rows[1:7]:row['between_sample_ms']='9000'
        rows[7]['between_sample_ms']='6000'
        with self.assertRaises(ValueError):M.accept(render(rows),NONCE)

    def test_inert_module_does_not_pass(self):
        with self.assertRaises(ValueError):M.accept('',NONCE)
        rows=evidence()
        for row in rows[:8]:
            for key in ('read_burst_ms','mean_read_interval_ms','work_and_final_read_ms','first_to_last_read_ms'):
                row[key]='0'
            row['within_sample_advanced']='false'
        rows[8]['within_sample_advances']='0'
        with self.assertRaises(ValueError):M.accept(render(rows),NONCE)


if __name__=='__main__':unittest.main()
