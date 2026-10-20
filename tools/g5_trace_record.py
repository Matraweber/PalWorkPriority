"""Record one aligned G5 window: Lua frame events plus a QPC PresentMon capture.

Usage: python -B tools/g5_trace_record.py <label> [--duration 120]
Writes test-results/g5-trace-<date>/<label>/ (private, not in the repo).
Turns profiling ON for the window (the frame-event trace needs it), so this
measures attribution, not the profiling-off frame numbers. Two nonce anchors
before and two after the capture bind Lua os.clock to Windows QPC
(tools/observe_frame_anchor.py); analyse with tools/g5_trace_analyse.py.
Based on test-results/persistence-scope-20261009/record.py (2026-10-09).
"""
import json, shutil, subprocess, sys, time, uuid
from datetime import date
from pathlib import Path

repo = Path(__file__).resolve().parents[1]
mod = Path('D:/Steam/steamapps/common/Palworld/Mods/NativeMods/UE4SS/Mods/PalWorkPriority')
exe = 'D:/Steam/steamapps/common/Palworld/Pal/Binaries/Win64/Palworld-Win64-Shipping.exe'
py = sys.executable
label = sys.argv[1]
duration = int(sys.argv[sys.argv.index('--duration') + 1]) if '--duration' in sys.argv else 120
dest = repo / 'test-results' / ('g5-trace-' + date.today().strftime('%Y%m%d')) / label
dest.mkdir(parents=True)


def remote(words, name):
    result = subprocess.run([py, '-B', str(repo / 'tools/remote.py'), '--no-deploy', words],
                            cwd=repo, capture_output=True, text=True)
    (dest / name).write_text(result.stdout + result.stderr, encoding='utf-8')
    assert result.returncode == 0, result.stdout + result.stderr


pid = subprocess.run(['powershell.exe', '-NoProfile', '-Command', '(Get-Process Palworld-Win64-Shipping).Id'],
                     capture_output=True, text=True).stdout.strip()
pre = subprocess.run([py, '-B', str(repo / 'tools/capture_frames.py'), '--pid', pid, '--game-exe', exe],
                     cwd=repo, capture_output=True, text=True)
ticks = json.loads(pre.stdout)['game']['created_ticks']

remote('pwp perf on,pwp frameevents start', 'start.log')
marker = mod / 'perf-anchor.txt'
if not marker.exists():
    marker.write_bytes(b'initial\n')


def anchor(i):
    nonce = 'g5-' + uuid.uuid4().hex
    observer = subprocess.Popen([py, '-B', str(repo / 'tools/observe_frame_anchor.py'), str(marker), nonce],
                                cwd=repo, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    time.sleep(.1)
    remote('pwp frameanchor ' + nonce, 'anchor-%d.log' % i)
    out, err = observer.communicate(timeout=20)
    assert observer.returncode == 0, err
    (dest / ('anchor-%d.json' % i)).write_text(out)


anchor(1); anchor(2)
cap = subprocess.run([py, '-B', str(repo / 'tools/capture_frames.py'), '--pid', pid, '--game-exe', exe,
                      '--expected-start', ticks, '--duration', str(duration), '--delay', '5',
                      '--qpc-time', '--capture', '--output-root', str(dest / 'capture')],
                     cwd=repo, capture_output=True, text=True)
(dest / 'capture.json').write_text(cap.stdout)
(dest / 'capture.stderr').write_text(cap.stderr)
anchor(3); anchor(4)
remote('pwp frameevents stop,pwp perf,pwp perf off', 'report.log')
shutil.copy2(mod / 'frame-events.tsv', dest / 'frame-events.tsv')
assert cap.returncode == 0, cap.stderr
print('Completed ' + str(dest))
