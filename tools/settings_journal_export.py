"""Read-only, offline journal export proposal. Never replaces settings or disables trials.

Strict export policy: reject any present invalid A/B record (no older fallback).
Canonical bodies are scoped candidates, NOT complete legacy replacement files:
foreign/unassigned legacy rows and runtime guild aliases still require reconciliation.
"""
from pathlib import Path
import argparse
import base64
import hashlib
import json
import re
import struct
import sys
import settings_migration_backup as Backup

ROOT = Path(__file__).resolve().parents[1]
MAX_RECORD = 18 + 256 + 262144 + 32


def guid(value):
    Backup.require(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{32}", value)
                   and value != "0" * 32, "canonical nonzero GUID required")
    return value


def decode(raw, scope):
    Backup.require(type(raw) is bytes and 50 <= len(raw) <= MAX_RECORD, "record size")
    Backup.require(raw[:8] == b"PWPJNL1\n", "unsupported journal format")
    width, generation, size = struct.unpack_from("<HII", raw, 8)
    Backup.require(0 < width <= 256 and 0 < generation < 2147483647 and size <= 262144,
                   "record fields")
    Backup.require(len(raw) == 18 + width + size + 32, "record length")
    Backup.require(raw[18:18+width] == scope.encode("ascii"), "foreign journal scope")
    Backup.require(hashlib.sha256(raw[:-32]).digest() == raw[-32:], "record checksum")
    return generation, raw[18+width:-32]


def canonical_body(payload, storage, guild, stream):
    sys.path.insert(0, str(ROOT / ".test-deps"))
    from lupa.lua54 import LuaRuntime
    lua = LuaRuntime(unpack_returned_tuples=True, encoding=None)
    values = {b"ROOT": ROOT.as_posix().encode(), b"PAYLOAD": payload,
              b"STORAGE": storage.encode(), b"GUILD": guild.encode(), b"STREAM": stream.encode()}
    for name, value in values.items(): lua.globals()[name] = value
    return lua.execute(b"""
        package.path=ROOT..'/Scripts/?.lua;'
        local function forbidden() error('journal proposal forbids runtime IO') end
        io.open=forbidden; io.popen=forbidden; io.output=forbidden
        os.rename=forbidden; os.remove=forbidden; os.execute=forbidden
        local Codec=dofile(ROOT..'/experiments/save_settings_codec.lua')
        local codec=Codec.new{storage=STORAGE,guild=GUILD,stream=STREAM,max_payload_bytes=262144}
        local decoded,why=codec.decode(PAYLOAD)
        assert(decoded,why)
        local module=require(STREAM=='limits' and 'caps' or 'store')
        return assert(module.serialize_snapshot(decoded.data,decoded.baseline))
    """)


def propose(records, storage, guild):
    guid(storage); guid(guild)
    expected = {f"{stream}-{slot}" for stream in ("priorities", "limits") for slot in ("A", "B")}
    Backup.require(type(records) is dict and set(records) == expected, "both complete stream pairs required")
    streams = {}
    for stream in ("priorities", "limits"):
        scope = f"PWP-SCOPE-1:{storage}:{guild}:{stream}"
        valid = []
        for slot in ("A", "B"):
            raw = records[f"{stream}-{slot}"]
            if raw is None: continue  # explicit, positively observed absence only
            generation, payload = decode(raw, scope)
            # Validate BOTH present generations; never bypass a future/foreign schema.
            body = canonical_body(payload, storage, guild, stream)
            valid.append((generation, slot, payload, body))
        Backup.require(valid, "no valid journal for " + stream)
        if len(valid) == 2 and valid[0][0] == valid[1][0]:
            Backup.require(valid[0][2] == valid[1][2], "equal-generation conflict")
        generation, slot, payload, body = max(valid, key=lambda row: row[0])
        streams[stream] = dict(generation=generation, slot=slot, bytes=len(body),
                               sha256=hashlib.sha256(body).hexdigest(),
                               canonical_body_base64=base64.b64encode(body).decode("ascii"))
    return dict(schema=1, storage=storage, guild=guild, streams=streams,
                replacement_allowed=False, live_scope_verified=False,
                cross_stream_transaction_verified=False,
                reconciliation_required=["preserve unassigned and foreign legacy rows",
                    "prove runtime guild alias mapping", "compare current legacy recovery set",
                    "back up journals, receipts and legacy files before any cutover"])


def capture(directory, storage, guild):
    guid(storage); guid(guild)
    directory = Backup.checked_path(directory, directory=True)
    Backup.require(directory.is_dir(), "journal directory missing")
    names = {f"{stream}-{slot}": f"pwp-record-v1-{storage}-{guild}-{stream}-{slot}.record"
             for stream in ("priorities", "limits") for slot in ("A", "B")}
    before = Backup.identity(directory.stat())
    entries = {key: Backup.read_exact(directory/name, MAX_RECORD) for key, name in names.items()}
    Backup.require(entries == {key: Backup.read_exact(directory/name, MAX_RECORD) for key, name in names.items()},
                   "journals changed during capture")
    Backup.require(before == Backup.identity(directory.stat()), "journal directory changed during capture")
    return entries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--storage", required=True)
    parser.add_argument("--guild", required=True)
    args = parser.parse_args()
    Backup.require(Backup.game_closed(), "game/server must be closed")
    entries = capture(args.directory, args.storage, args.guild)
    records = {key: None if value['state'] == 'missing' else base64.b64decode(value['bytes'], validate=True)
               for key, value in entries.items()}
    result = propose(records, args.storage, args.guild)
    Backup.require(Backup.game_closed() and entries == capture(args.directory, args.storage, args.guild),
                   "process or journals changed while planning")
    result['source_entries'] = entries
    result['offline_sample_checked'] = True  # not an exclusive writer lock
    print(json.dumps(result, indent=2))


if __name__ == '__main__': main()
