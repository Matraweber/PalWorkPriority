"""Attribute slow frames of one g5_trace_record.py window to recorded mod events.

Usage: python -B tools/g5_trace_analyse.py test-results/g5-trace-<date>/<label>
Offline only. Maps Lua os.clock to QPC with a fixed rate (unit slope): the
offset interval is the intersection of every anchor bracket. An event
"possibly" overlaps a frame if some offset in the interval makes them overlap,
"certainly" if every offset does. Association, not causation; events are
inclusive and nested, so names overlap each other.
"""
import csv, json, sys
from pathlib import Path

root = Path(sys.argv[1])
cap = json.loads((root / 'capture.json').read_text())
raw = next((root / 'capture').glob('*/raw.csv'))
rows = list(csv.DictReader(raw.open()))
freq = None
for key in ('validation',):
    v = cap.get(key, {})
    freq = (v.get('qpc') or {}).get('frequency_hz') or freq
assert freq, 'no QPC frequency in capture.json'
q0 = int(rows[0]['QPCTime'])
frames = [((int(a['QPCTime']) - q0) / freq, (int(b['QPCTime']) - q0) / freq, float(b['msBetweenPresents']))
          for a, b in zip(rows, rows[1:])]

events, anchors = [], {}
for line in (root / 'frame-events.tsv').read_text().splitlines():
    p = line.split('\t')
    if p[0] == 'anchor':
        anchors[p[1]] = (float(p[2]), float(p[3]))
    elif p[0] == 'event':
        events.append((p[1], float(p[2]), float(p[3])))
obs = []
for f in sorted(root.glob('anchor-*.json')):
    a = json.loads(f.read_text())
    assert a['frequency'] == freq and a['read_failures'] == 0
    l, r = anchors[a['nonce']]
    obs.append((l, r, (a['qpc_absent_before'] - q0) / freq, (a['qpc_present_after'] - q0) / freq))
# q = lua + off; publication happened inside [l, r] (Lua) and inside [lo, hi] (QPC)
off_lo = max(lo - r for l, r, lo, hi in obs)
off_hi = min(hi - l for l, r, lo, hi in obs)
print('anchors', len(obs), 'offset interval width ms %.2f' % ((off_hi - off_lo) * 1000), 'feasible', off_lo <= off_hi)
assert off_lo <= off_hi, 'anchors disagree under a fixed rate'
span = frames[-1][1]
mapped = [(n, s + off_lo, s + off_hi, t + off_lo, t + off_hi, (t - s) * 1000) for n, s, t in events
          if t + off_hi >= 0 and s + off_lo <= span]
print('frames', len(frames), 'span %.1f s' % span, 'events in window', len(mapped))

def overlapping(lo, hi):
    out = []
    for n, s_lo, s_hi, t_lo, t_hi, ms in mapped:
        if s_lo <= hi and t_hi >= lo:  # possible
            certain = s_hi < hi and t_lo > lo
            out.append((n, ms, certain))
    return out

for threshold in (33.333333, 16.666667):
    slow = [(lo, hi, ms) for lo, hi, ms in frames if ms > threshold]
    with_mod = sum(1 for lo, hi, ms in slow if overlapping(lo, hi))
    print('\nframes > %.2f ms: %d, with a possible mod event: %d, without: %d'
          % (threshold, len(slow), with_mod, len(slow) - with_mod))
    if threshold > 30:
        prev = None
        for lo, hi, ms in slow:
            ev = overlapping(lo, hi)
            top = sorted(ev, key=lambda e: -e[1])[:3]
            gap = '' if prev is None else ' (+%.1f s)' % (hi - prev)
            print('  t=%7.2f s %6.1f ms%s  %s' % (hi, ms, gap,
                  '; '.join('%s %.0f ms%s' % (n, m, '' if c else '?') for n, m, c in top) or 'NO MOD EVENT'))
            prev = hi

print('\nmod events >= 15 ms (start time in capture, duration):')
big = sorted((s_lo, n, ms) for n, s_lo, s_hi, t_lo, t_hi, ms in mapped if ms >= 15)
last = {}
for s, n, ms in big:
    gap = '' if n not in last else ' (+%.1f s)' % (s - last[n])
    last[n] = s
    print('  t=%7.2f s %-40s %5.0f ms%s' % (s, n[:40], ms, gap))
