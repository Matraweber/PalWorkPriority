import hashlib
from pathlib import Path
import struct
import sys
import unittest
import tempfile
from unittest import mock
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
import settings_journal_export as E
W,G='a'*32,'b'*32


def record(stream, body=None, generation=1, guild=G):
    if body is None:
        body=(b'# Pal Work Priority: palkey|worktype|priority (1 highest, 5 lowest, X disabled)\n'
              if stream=='priorities' else
              b'# Legacy work-type groups: may stop unrelated products of the same suitability.\n'
              b'# guild|work|item|ceiling (OFF masks an inherited group rule for this guild)\n')
    scope=f'PWP-SCOPE-1:{W}:{guild}:{stream}'.encode()
    payload=b'PWP-SETTINGS-1\n'+W.encode()+b'\n'+guild.encode()+b'\n'+stream.encode()+b'\n'+str(len(body)).encode()+b'\n'+body
    raw=b'PWPJNL1\n'+struct.pack('<HII',len(scope),generation,len(payload))+scope+payload
    return raw+hashlib.sha256(raw).digest()


def pair():
    return {f'{s}-{k}':record(s,generation=(1 if k=='A' else 2))
            for s in ('priorities','limits') for k in ('A','B')}


class Export(unittest.TestCase):
    def test_selects_latest_both_streams_without_grant(self):
        r=E.propose(pair(),W,G)
        self.assertEqual({x['generation'] for x in r['streams'].values()},{2})
        self.assertFalse(r['replacement_allowed'])
        self.assertFalse(r['live_scope_verified'])
        self.assertFalse(r['cross_stream_transaction_verified'])

    def test_invalid_present_peer_never_falls_back(self):
        for raw in (b'',b'junk',record('limits',guild='c'*32),record('limits')+b'extra',
                    record('limits',body=b'unknown|row\n'),record('limits',generation=2147483647)):
            records=pair();records['limits-B']=raw
            with self.subTest(raw=raw[:20]),self.assertRaises(Exception): E.propose(records,W,G)
        records=pair();raw=bytearray(records['priorities-B']);raw[-1]^=1;records['priorities-B']=bytes(raw)
        with self.assertRaisesRegex(ValueError,'checksum'): E.propose(records,W,G)

    def test_missing_and_incomplete_are_distinct(self):
        r=pair();r['limits-B']=None
        self.assertEqual(E.propose(r,W,G)['streams']['limits']['generation'],1)
        r['limits-A']=None
        with self.assertRaisesRegex(ValueError,'no valid'): E.propose(r,W,G)
        del r['limits-A']
        with self.assertRaisesRegex(ValueError,'complete'): E.propose(r,W,G)

    def test_equal_generation_conflict_and_x_roundtrip(self):
        import base64
        r=pair()
        body=b'# Pal Work Priority: palkey|worktype|priority (1 highest, 5 lowest, X disabled)\n# baseline=vanilla\npal|1|X\npal|2|3\n'
        r['priorities-B']=record('priorities',body=body,generation=2)
        result=E.propose(r,W,G)
        self.assertEqual(base64.b64decode(result['streams']['priorities']['canonical_body_base64']),body)
        r['priorities-A']=record('priorities',generation=2)
        with self.assertRaisesRegex(ValueError,'equal-generation'): E.propose(r,W,G)

    def test_capture_is_read_only_and_rejects_instability(self):
        with tempfile.TemporaryDirectory() as temp:
            directory=Path(temp)
            for key,raw in pair().items():
                stream,slot=key.split('-')
                (directory/f'pwp-record-v1-{W}-{G}-{stream}-{slot}.record').write_bytes(raw)
            before={p.name:p.read_bytes() for p in directory.iterdir()}
            captured=E.capture(directory,W,G)
            self.assertEqual(len(captured),4)
            self.assertEqual(before,{p.name:p.read_bytes() for p in directory.iterdir()})
            read=E.Backup.read_exact
            count=0
            def changed(path,limit):
                nonlocal count
                count+=1
                result=read(path,limit)
                if count==5: result={**result,'sha256':'0'*64}
                return result
            with mock.patch.object(E.Backup,'read_exact',side_effect=changed):
                with self.assertRaisesRegex(ValueError,'changed during capture'): E.capture(directory,W,G)

    def test_capture_refuses_unknown_read_and_missing_directory(self):
        with tempfile.TemporaryDirectory() as temp:
            with mock.patch.object(E.Backup,'read_exact',side_effect=PermissionError('denied')):
                with self.assertRaises(PermissionError): E.capture(Path(temp),W,G)
            with self.assertRaisesRegex(ValueError,'directory missing'):
                E.capture(Path(temp)/'absent',W,G)

    def test_scope_validation(self):
        for w in ('0'*32,'A'*32,'../wrong',None):
            with self.assertRaises(ValueError): E.propose(pair(),w,G)

    def test_checksum_valid_bad_inner_scope_rejected(self):
        records=pair();raw=records['limits-B'];scope_len=struct.unpack_from('<H',raw,8)[0]
        start=18+scope_len
        body=raw[:start]+raw[start:-32].replace(G.encode(),b'c'*32)
        records['limits-B']=body+hashlib.sha256(body).digest()
        with self.assertRaises(Exception): E.propose(records,W,G)

if __name__=='__main__':unittest.main()
