# Pal Work Priority: start here

UE4SS Lua mod for Palworld: per-Pal work priorities (1 highest, 5 lowest, X
off) and production limits, drawn on the Monitoring Stand and a custom panel,
synced between clients and a dedicated server.

## Read before doing anything

1. [docs/LESSONS.md](docs/LESSONS.md): mistakes already paid for. The engine
   rules there prevent process-killing crashes that `pcall` cannot catch.
2. [docs/DECISIONS.md](docs/DECISIONS.md): what was decided, and what was
   rejected with measurements. Do not re-propose a rejected idea without new
   numbers.
3. [docs/RELEASE-0.5.0.md](docs/RELEASE-0.5.0.md): the current ship list with
   a "done when" per gate. The wider backlog is
   [docs/release-gates-2026-10-09.md](docs/release-gates-2026-10-09.md).
4. [docs/testing.md](docs/testing.md): how to test and what counts as evidence.

## Working rules

- **Write it down in the same change.** Every non-trivial decision gets a
  DECISIONS.md entry, every mistake a LESSONS.md entry, every live test a dated
  `docs/<topic>-YYYY-MM-DD.md` with the loaded build fingerprint.
- **Commit at the end of every session**, on the working branch
  (`reliability-0.5` until 0.5.0 ships). Master equals what the stores serve.
  No `Co-Authored-By` trailers in this repository.
- **Testing is automated; do not ask the user to click.** The Desktop AHK
  macros restart into singleplayer or the server and open the stand,
  `tools/remote.py` drives the running game, PresentMon captures frames, and an
  independent agent cross-checks each live run. Lua changes may be staged while
  the game runs; a full restart activates them. Never hot-reload during a
  measurement.
- **Claims need evidence of the right kind.** Unit tests are not in-game
  acceptance. Counters and clean logs are not frame times.
- **Ask before anything outward-facing:** publishing to Steam or Nexus, posting
  replies, or changing the GPortal server beyond the test plan. The user posts
  and uploads.
- **Keep private data out of the public repo:** server address, saves, logs,
  `test-results/`.

## Layout

`Scripts/` the mod (loads in-game) · `tests/` Lua and Python regressions
(`python tools/test_lua.py`, `python tools/test_python.py`) · `tools/` deploy,
release, remote control, capture and AHK rigs · `native/`, `experiments/` the
async saving work (off by default) · `unreal/` widget generators for the pak ·
`LogicMods/` the built pak · `docs/` evidence and the files above.
