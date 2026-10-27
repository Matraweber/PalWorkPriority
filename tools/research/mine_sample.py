"""Who mines what: every N seconds, list each Pal whose native assignment is
Mining (suitability 8) and the rock or pit its job id belongs to.
usage: mine_sample.py <label> <seconds> <count> <mining_ids.txt>"""
import re
import subprocess
import sys
import time

label, every, count, ids_path = sys.argv[1], float(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
repo = r'C:\Users\matra\Desktop\palworld-priority-mod'
kind = {}
for line in open(ids_path, encoding='utf-8'):
    m = re.search(r'camp (\d) \| Mining \| (\S+)_0 .*product=(.*?) \| .*id=(\S+)', line)
    if m:
        what = m.group(3).replace('drops ', '')
        kind[m.group(4)] = 'c%s %s (%s)' % (m.group(1), m.group(2), what.split(',')[0])
for i in range(count):
    r = subprocess.run([sys.executable, '-B', 'tools/remote.py', 'pwp assignments'], cwd=repo,
                       capture_output=True, text=True, timeout=60)
    found = []
    name = None
    for line in r.stdout.splitlines():
        m = re.search(r'^\s+(\S+) \[0', line)
        if m:
            name = m.group(1)
            continue
        m = re.search(r'direct: state=(\S+) fixed=\S+ suitability=8 job=(\S+)', line)
        if m and name:
            found.append('%s %s -> %s' % (name, m.group(1), kind.get(m.group(2), 'job ' + m.group(2)[:12])))
    print('%s %s %d: %s' % (label, time.strftime('%H:%M:%S'), i, '; '.join(found) or 'nobody on Mining'), flush=True)
    if i < count - 1:
        time.sleep(every)
