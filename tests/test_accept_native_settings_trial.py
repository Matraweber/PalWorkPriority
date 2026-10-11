import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import accept_native_settings_trial as accept


class Acceptance(unittest.TestCase):
    def test_positive_and_negative_evidence(self):
        events = [{'event': 'armed', 'synthetic': True},
                  {'event': 'configured', 'game': 10, 'frequency': 1000}]
        for handle, (stream, reopen) in enumerate([('priorities', False), ('priorities', True),
                                                    ('limits', False), ('limits', True)], 1):
            events.append({'event': 'bound', 'handle': handle, 'stream': stream, 'reopening': reopen})
            for ticket in ([1] if reopen else [1, 2, 3]):
                events.append({'event': 'worker', 'handle': handle, 'stream': stream, 'ticket': ticket,
                               'game': 10, 'worker': 20, 'start': 100, 'finish': 101, 'frequency': 1000})
            events.append({'event': 'released', 'handle': handle, 'stream': stream})
        events += [{'event': 'passed', 'completed': ['priorities', 'limits'], 'synthetic': True,
                    'storage': accept.W, 'guild': accept.G}, {'event': 'stopped', 'state': 'passed'}]
        def log(rows):
            return '\n'.join(json.dumps({'nonce': 'test', 'data': e}) for e in rows)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for stream in ('priorities', 'limits'):
                scope = f'PWP-SCOPE-1:{accept.W}:{accept.G}:{stream}'.encode()
                for slot, generation, revision in [('A', 1, 1), ('B', 2, 3)]:
                    body = accept.payload(stream, revision)
                    encoded = b'PWPJNL1\n' + struct.pack('<HII', len(scope), generation, len(body)) + scope + body
                    (root / f'pwp-record-v1-{accept.W}-{accept.G}-{stream}-{slot}.record').write_bytes(
                        encoded + hashlib.sha256(encoded).digest())
            self.assertTrue(accept.inspect(log(events), root, 'test')['passed'])
            recovery = [dict(e) for e in events if 'handle' not in e or e['handle'] in (2, 4)]
            recovery[0]['recovery_only'] = True
            self.assertTrue(accept.inspect(log(recovery), root, 'test', True)['recovery_only'])
            with self.assertRaises(ValueError):
                accept.inspect(log(events), root, 'test', True)
            for bad in [events[:-1], [e for e in events if e['event'] != 'worker'],
                        events + [{'event': 'bootstrap-failed'}]]:
                with self.assertRaises(ValueError):
                    accept.inspect(log(bad), root, 'test')
            target = next(root.iterdir())
            target.write_bytes(target.read_bytes()[:-1] + b'x')
            with self.assertRaises(ValueError):
                accept.inspect(log(events), root, 'test')


if __name__ == '__main__':
    unittest.main()
