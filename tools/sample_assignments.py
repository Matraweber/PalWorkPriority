"""Sample every Pal's current job from the running game, N times.

    python tools/sample_assignments.py <samples> <seconds between> <out file>

Each sample sends '!pwp assignments' through tools/remote.py, then reads the
census lines it wrote to priority.log: one header per Pal
('  Name [KEY] camp=... current=...') followed by
'    direct: state=... fixed=... suitability=N'. Prints one line per sample:
time | Name:state/work for every occupied Pal | the latest demand line.
Work numbers follow Scripts/workdefs.lua (1 Kindling, 4 Generating
Electricity, 5 Handiwork, 12 Transporting, ...). Read-only.
"""
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOG = Path(r"D:\Steam\steamapps\common\Palworld\Mods\NativeMods\UE4SS\Mods\PalWorkPriority\priority.log")
HEADER = re.compile(r"^\s+(\S+) \[([0-9A-F]+)\] camp=(\S+)")
DIRECT = re.compile(r"direct: state=(\w+) fixed=(\w+) suitability=(\w+)")
WANTED = re.compile(r"INFO (?:tick|priority change|world load).*wanted: (.*)$")
SHORT = {"1": "Kindling", "2": "Watering", "3": "Planting", "4": "Electricity", "5": "Handiwork",
         "6": "Gathering", "7": "Lumbering", "8": "Mining", "11": "Cooling", "12": "Transport",
         "13": "Farming"}


def sample():
    start = LOG.stat().st_size
    subprocess.run([sys.executable, str(ROOT / "tools" / "remote.py"), "--no-deploy", "pwp assignments"],
                   capture_output=True, timeout=60)
    with LOG.open("rb") as f:
        f.seek(start)
        lines = f.read().decode("utf-8", "replace").splitlines()
    jobs, name = [], None
    for line in lines:
        h = HEADER.match(line)
        if h:
            name = h.group(1)
            continue
        d = DIRECT.search(line)
        if d and name:
            state, fixed, suit = d.groups()
            if state == "occupied":
                jobs.append(f"{name}:{SHORT.get(suit, suit)}{'(fixed)' if fixed == 'true' else ''}")
            name = None
    wanted = ""
    with LOG.open("rb") as f:
        f.seek(max(0, LOG.stat().st_size - 20000))
        for line in f.read().decode("utf-8", "replace").splitlines():
            m = WANTED.search(line)
            if m:
                wanted = m.group(1)
    return jobs, wanted


def main():
    count, gap, out = int(sys.argv[1]), float(sys.argv[2]), Path(sys.argv[3])
    with out.open("a", encoding="utf-8") as fh:
        for _ in range(count):
            jobs, wanted = sample()
            row = f"{time.strftime('%H:%M:%S')} | {' '.join(sorted(jobs))} | wanted: {wanted[:100]}"
            print(row, flush=True)
            fh.write(row + "\n")
            time.sleep(gap)


if __name__ == "__main__":
    main()
