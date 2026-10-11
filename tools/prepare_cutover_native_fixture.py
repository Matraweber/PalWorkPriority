"""Prepare/restore the fixed disposable native cutover server; never launches.

Reuses the clock fixture's checked archival/restoration machinery with NEW
evidence/backup paths. No live client settings, journals or async DLL are used.
"""
import json
import sys
import prepare_dedicated_clock_fixture as Base

Base.FIXTURE = Base.ROOT / 'test-results/cutover-native-20261011'
Base.BACKUP = Base.SERVER / 'PWPTestBackups/cutover-native-20261011'


if __name__ == '__main__':
    if sys.argv[1:] == ['--prepare']:
        result = Base.prepare()
    elif sys.argv[1:] == ['--restore']:
        result = Base.restore()
    elif not sys.argv[1:]:
        result = {'preflight': Base.preflight(), 'launched': False}
    else:
        raise SystemExit('use --prepare, --restore, or no arguments for preflight')
    print(json.dumps(result))
