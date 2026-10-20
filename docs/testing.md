---
date: 2026-10-20
tags: [testing, tooling]
status: current
---
# Reliability candidate testing

Related: [frame-capture-procedure-2026-10-09](frame-capture-procedure-2026-10-09.md) · [RELEASE-0.5.0](RELEASE-0.5.0.md) · [LESSONS](LESSONS.md)

Target: **0.5.0-rc1, unpublished**. This is the acceptance protocol, not a statement that it passed. Gate status and the evidence for each closed gate are in [RELEASE-0.5.0.md](RELEASE-0.5.0.md); the backlog beyond 0.5.0 is in [release-gates-2026-10-09.md](release-gates-2026-10-09.md); the [comment ledger](comment-ledger-2026-09-11.md) maps public reports and finding IDs F01-F24 to those gates. What counts as evidence is also in [LESSONS.md](LESSONS.md).

## Current evidence

One note per gate run, each with its build, steps and raw receipts:

- G1 settings: [restart-persistence-2026-10-11](restart-persistence-2026-10-11.md) (singleplayer and server restarts, rapid edits), [upgrade-041-2026-10-11](upgrade-041-2026-10-11.md) (0.4.1 upgrade, manual route).
- G3 frontend: [g3-panel-2026-10-17](g3-panel-2026-10-17.md), [g3-layout-2026-10-17](g3-layout-2026-10-17.md), [g3-escape-photo-death-2026-10-17](g3-escape-photo-death-2026-10-17.md); still open: [search-crash-2026-09-15](search-crash-2026-09-15.md).
- G4 scheduling: [g4-scheduling-2026-10-12](g4-scheduling-2026-10-12.md), [-10-14-stations](g4-scheduling-2026-10-14-stations.md), [-10-16-coolers](g4-scheduling-2026-10-16-coolers.md), [-10-17-miners](g4-scheduling-2026-10-17-miners.md).
- G5 performance: [g5-performance-2026-10-19](g5-performance-2026-10-19.md) (matched mod-present vs mod-absent baseline, rounds 1-3), capture method in [frame-capture-procedure-2026-10-09](frame-capture-procedure-2026-10-09.md).
- G6 multiplayer: [g6-guild-isolation-2026-10-19](g6-guild-isolation-2026-10-19.md), [g6-version-mismatch-2026-10-19](g6-version-mismatch-2026-10-19.md); priority edit across a server restart in restart-persistence-2026-10-11.

The full Lua/UI and Python suites are run before every deploy (below). They establish the tested model only.

## Evidence rules

Record a regression failing on the relevant earlier code and passing on the candidate. Isolated Lua/Python tests establish behavior of the tested model and mocked engine contracts only. They cannot prove Unreal object lifetime, focus, native API safety, actual assignment, output or frame-time performance.

The following are insufficient alone: a command sent, echo received, live process, route counter, displayed number, permission-set membership, steady tick cadence or no logged errors. A count-only row printed as `0 ms` in old reports is **unmeasured**. Do not derive speedups from it. For scheduling, judge by the Pal's Current Task and by output (RELEASE G4); `tools/sample_assignments.py` samples the census read-only.

August evidence applies to that saved runtime and observed cases. It does not certify the September dependency or candidate. Earlier “stutter-free”, “zero-cost” and “a crash costs nothing” descriptions are withdrawn as acceptance claims. The August empty-field test kept two camps loaded, so its no-camp branch was never exercised; do not generalise it.

## Read-only identity and frame-analysis tools

A file installed on disk or an old log banner does not establish what is running. Record the loaded build (fingerprint) for every gate run. Ignored test artifacts must not ship.

```powershell
python tools/fingerprint.py --help
python tools/fingerprint.py
python tools/fingerprint.py --server
python tools/analyze_frames.py --help
```

Fingerprint emits JSON to stdout without deployment, launch, remote commands, save access or network actions. It can inspect a candidate archive with `--candidate <archive>`; source/game/workshop roots are configurable as documented by help. Observing a mapped module path later would identify that process/module path; its reported file hash remains **on disk**, not a memory-image hash. A log entry stays historical/unbound unless separate evidence links it to the run.

The frame analyzer reads an **existing independent capture**. It does not record frames and must not accept Lua region timings as frame durations. CSV requires `time_s,frame_ms`: strictly increasing capture-clock timestamps at frame end and positive frame duration.

Metadata JSON requires `schema: 1`, `capture_id`, `source_kind: "independent_frame_capture"`, `capture_tool` including version, `scene`, `machine`, `game_build`, `runtime_build`, `mod_build`, `profiling`, `settings`, and a `clock` object declaring `name`, `unit: "s"`, `timestamp: "frame_end"`. These declarations do not prove the recorded environment.

```powershell
python tools/analyze_frames.py after.csv --metadata after.json
python tools/analyze_frames.py after.csv --metadata after.json --baseline before.csv --baseline-metadata before.json --compare-by mod_build
python tools/analyze_frames.py after.csv --metadata after.json --events events.csv --clock-map alignment.json
```

Compare by `mod_build` or `profiling` while other required metadata matches. Optional event CSV is `time_s,event` and requires explicit clock mapping: schema/capture ID, event and frame clock names, scale, offset_s, uncertainty_ms, valid_frame_interval_s and alignment_method. Mapping is `frame_time = event_time * scale + offset`, within the declared validity interval; Lua os.clock is never assumed equal to the capture clock. Temporal proximity is not causation.

Missing primary capture or required baseline-frame input is refused; the baseline-missing refusal is fixture-tested. No capture input produces an explicit missing-capture result. Exit 2 denotes missing/invalid/unmatched requested input; exit 0 means analyzed, **not stutter-free**. Help/schema fixture tests in [test_fingerprint.py](../tests/test_fingerprint.py) and [test_analyze_frames.py](../tests/test_analyze_frames.py) were exercised. Recording itself is covered under "Frame captures" below.

## Before any game run

- [ ] Record source commit and dirty diff hash, game revision, loaded UE4SS build/binary hash, Lua version, mod/module hashes, pak hash and panel contract.
- [ ] Record OS, resolution/aspect/UI scale, frame cap, renderer, scene/save, Pal count, stations, storage, rules and every enabled mod/version.
- [ ] Back up the test world/settings. Use a disposable copy for failure, migration, stress and producer experiments.
- [ ] Run real Lua compilation, behavioral tests and structural checks; inspect all results before deployment.
- [ ] Inspect exactly which scripts/assets change. Verify installed hashes and newly loaded identities after restart.
- [ ] Compare the active Workshop package's Version/DebugMode against ManagedMods before manual staging. A pending official-loader update can overwrite checked Lua on launch. Preserve user configuration before any such update, and verify the final candidate again after the loader runs; a pre-launch hash alone is insufficient.
- [ ] Keep `EnableAutoReloadingLuaMods = 0`; do not use Ctrl+R. Never deploy or hot reload during a measurement window. Record a deployment as pending restart, not as the running build.
- [ ] Preserve logs/crash artifacts before another launch rotates them. A boot banner is not world readiness.
- [ ] Read the in-game options (`Mods/shared/PalWorkPriority_user.lua`) and save a copy of priorities/caps/config; diff them after every UI test (see LESSONS).

The August log identifies UE4SS `c838a8ac`; the September dependency advertised `2281fa31`. The intended distribution is [Experimental UE4SS for Palworld](https://steamcommunity.com/sharedfiles/filedetails/?id=3625223587). On 2026-09-11 the first launch applied a pending official-loader update that recopied 0.4.1 over the candidate and updated UE4SS to 2281fa31 (on-disk SHA-256 `21b691a69a20c0801f465369d4fcbca7d7444764022fac2a7e8edc7709ef92b8`). **Gameplay compatibility is not yet accepted.** Verify the loaded process, not merely the advertised dependency. A frontend PWP_READY/session 0 is not proof of gameplay-world readiness.

**MapCollectablesNative is disabled on the test client.** On 2026-09-11 the client crashed twice before world entry, both faults at `MapCollectablesNative/dlls/main.dll + 0x1232F` (reading `0x1C0`, matching stack hashes), once without the candidate loaded. That names the faulting module, not the bug. It was isolated by renaming only its activation marker `enabled.txt` to `enabled.txt.pwp-test-disabled-20260911`; it had started through that marker although it was not in ActiveModList. On 2026-10-20 the D: install still has the renamed marker (and no `dlls` folder). Restore it only with the game stopped and when deliberately testing that combination.

## Offline regressions

Run from the repository root:

```powershell
python tools/test_lua.py --compile-only
python tools/test_lua.py
python tools/luacheck.py
python tools/test_python.py
```

The Python runner discovers every `test_*.py` under `tests/` with the repository
as the top-level directory, so modules are imported as `tests.test_*`. This avoids
collisions with same-named native developer tools even when tests add `tools/`
to `sys.path`. Do not use repository-wide discovery or unqualified
`discover -s tests`: developer entrypoints under `tools/` are not unit suites.
The equivalent direct command is
`python -m unittest discover -s tests -t . -p "test_*.py" -v`.
The runner also removes native EXE/DLL test opt-ins from its child environment;
those tests are reported as skipped, not native passes. Installer, deployment,
and server unit suites use disposable fixtures or mocks, not live installations.
The runner can be invoked by absolute path from another working directory.

The runner requires **Lua 5.4** (`lupa.lua54`), not LuaJIT/5.3. Follow the pinned instructions in `tools/test_lua.py` if missing; a missing runtime must fail. Compilation cannot be replaced with regex checks. Tests merely existing under `tests/` do not constitute a passing run.

| Gate | Required model assertions |
| --- | --- |
| PERSIST | Round-trip 1–5/X; unrelated edit preserves X; reject malformed data and slotN; open/write/close/rename failures reported; prior generation recoverable; bounded retries; corrupt newer generation does not displace valid older data; live/.tmp/.pending/.bak recovery and repeated-save protection |
| INHERITED LIMIT | Clearing a guild override or inherited shared/config ceiling persists a guild-local OFF mask; survives save/load; other guilds unchanged; removal cannot report success while the same inherited rule silently returns |
| CLI | Four actual-main-code before/after cases: reject fractional limits; queued client is pending; failed clear is failure; unknown/unscoped stock unavailable; legacy labels and current named scope only from verified panel_status, without blind rescans |
| SERVER TOOL | Boot-only/stale readiness fails; new PWP_READY requires authority and available settings; logs/prior test-world backups preserved; server lifecycle assertions require the focused corrected run; attach artifacts |
| CONFIG | Malformed/nonfinite values rejected before migration/main reload/overrides; whole invalid config rejected retaining prior accepted settings; valid 1–5/X unchanged; root precedence; config.migration.bak retained; archive maps source Scripts/config.lua to Scripts/default_config.lua so extraction preserves legacy config before migration; update preserves user files; unreadable/ambiguous data never means fresh install |
| UI | Idempotent close; cancel before teardown; handoff preserves focus; generation invalidates actions/caches; cache commits only after success; reparenting/page boundaries |
| SCHED | Empty versus unavailable roster/stand_rows distinguished; partial off-list unknown; restoration only on confirmed readback; policy changes preserve pending writes; idle X/stale-fence reconciliation; missing scope/type repair; unknown scope quarantined; held/fallback capacity; stable candidate ordering |
| PRODUCER | Nil item ID makes stock unavailable rather than empty; unsupported creation refused; simulated output admission preserves unrelated work and bounded in-flight work; no mocked success promoted to native support |
| SESSION | Current Role 2 overrides stale GameMode evidence; separate remote snapshots/durable stores; writers undecided during transition; reject late callbacks/revisions; do not recover vanilla defaults from managed flags |
| SYNC | Negotiated schema; complete revisions only; duplicate/missing/reordered chunks; pending clicks accumulate; delayed/rejected ack cannot confirm another request/session/guild |
| PERF | Unmeasured counts distinct; timed counts/window/resolution; bounded distributions; inclusive nesting; sink failures; disabled profiler does not fabricate zero timings |
| STRESS | Inert mod fails; wrong run/session/request refused; replay cannot count twice; aborted/rejected work not completed; log truncation breaks evidence |
| PACKAGE | Missing/mismatched pak refused; install rules/version/source consistent; deterministic contents; no save/log/dev trigger; same logical manifest |

A passing script does not close every branch of a gate. Attach exact tests/output and list unmodeled cases.

## Developer channel and restarts

Testing is automated and self-serve (DECISIONS "Testing"): the macros below restart the game and open the stand, `tools/remote.py` drives the running game, and nobody is asked to click. Verify process replacement, gameplay readiness, installed hashes and the visible stand after every restart. Do not classify a closed-stand capture as an open-stand comparison.

User workflow preference (September 12): stage checked Lua changes while the game remains open, then let the user restart to activate them. Before staging, verify automatic reload was disabled for the running session, measurements are finished, and the changed modules are already loaded rather than read dynamically. Preserve previous code/configuration and verify deployed hashes. Do not trigger a reload. Runtime DLL/pak replacement, dynamic file readers, or an active automatic loader require a separate assessment; this preference is not evidence that every file can safely be replaced while running. After restart, verify the actual loaded generation before collecting acceptance evidence.

### Singleplayer macro: `tools/restart-stand.ahk`

Start in gameplay at the Monitoring Stand with its grid open (default `--stand`). The macro closes the stand, takes Return to Title (the normal save path) and Quit, waits up to 60 s for the old PID to exit, launches the game, clicks through Mods Detected / Start Game, picks the **first** world in the list and Start Game (never Delete World), waits up to 150 s for a fresh `PWP_READY ... session=N` (N ≥ 1) after its own log offset, waits 12 s more for the loading fade, then holds V for 850 ms to open the stand.

| Mode | Use |
| --- | --- |
| `--stand` (default) | at the stand, grid open |
| `--world` | in gameplay, stand grid closed |
| `--title` | already on the title menu |
| `--launch` | game closed (refuses if a Palworld process exists) |
| `--open-only` | already facing the stand: only hold V, no restart, no checks |
| `--return-title-only` | stand open: normal Return to Title, then stop (no quit or relaunch) |
| `--check` | config/syntax only: exit 0 when the game exe and priority.log exist, else 2 |
| `-select` suffix (`--stand-select`, `--world-select`, `--title-select`, `--launch-select`) | stop at world selection; pick the intended world by name. Needed for multi-world tests: the list order follows last-played time |
| `-absent` suffix (same four) | PalWorkPriority removed for G5 mod-absent captures: no priority.log, so readiness is a fixed 60 s wait after Start Game |

The two suffixes cannot be combined. Calibration is window-relative (1280x720 reference, `CoordMode Client`): the game must be **one** 16:9 window of at least 800x450, any monitor. The macro never force-kills the game and never edits saves; Pause or Scroll Lock aborts it, and on exit it releases only a key it is holding. Each run appends to `restart-stand-last-run.log` next to the script (ignored by git). Exit codes: 0 finished, 1 stopped (with a message box and a `STOPPED:` line), 2 bad mode or failed `--check`. A first world that is not the intended save, or a character not at the stand, makes it act on the wrong thing.

### Dedicated-server macro: `tools/restart-server-stand.ahk`

Same modes as the singleplayer macro except `--return-title-only`, `-select` and `-absent`; it adds `--self-test` (9 readiness-classification cases). Start at the stand with the grid open. After launch it clicks Join Multiplayer Game, Recent Servers and the calibrated **RAM row, which is the second Recent Servers entry** (recalibrate if that list changes; image matching was tried and did not find the label reliably). Since 2026-10-19 it waits 4 s after Recent Servers (the list loads players and ping before rows exist; clicking at once hit an empty list and the join silently never happened), 3 s after selecting the row and 2.5 s after accepting the game-stored password, then confirms. No password and no GPortal restart are in the macro; the repo copy reads the server address from `PWP_SERVER` only to log it, the real address stays in the Desktop copy (DECISIONS 2026-10-11).

- **The developer channel must be on before launch**: `remote.txt` must exist when the game starts (`--check` also requires it). The macro uses it to send `pwp status` / `pwp net` after a fresh `world key: World` line.
- Readiness needs `synchronization: client; ready`, `authority: client; server owns assignments` and the exact configured guild. The title screen can report authority, so it is not readiness. Unavailable guild data waits; a different confirmed guild stops without sending the stand key. A truncated log is refused.
- After joining it opens and closes the vanilla pause menu once (900 ms each) before holding V. That round trip restores the missing interaction prompts seen after joining; it is a workaround, not a fix (release-gates §3).
- It logs to `restart-server-last-run.log` next to the script. `SERVER_READY` there proves only the connection checks. The accepted run on 2026-09-25 took about two minutes; slow connections take longer. Keep other input idle.

### Both macros

- **The exit code does not prove the stand opened.** The macro only holds V for 850 ms after readiness; the stand, the visible numbers and the saved settings must be checked separately (screenshot, `pwp status`, settings diff).
- Emergency Respawn moves the character to another base (2026-09-24: about 105 m to the five-Pal base). Afterwards the stand-facing macros fail or act on the wrong position; walk back to the stand or use `--title`/`--launch` and re-check the position.
- When keys stop arriving while clicks still work, or a focus click fires the weapon, see LESSONS (2026-10-17): both macros now fall back to a title-bar click for focus and wait 800 ms after a focus change.
- Run restarts and any wait over a minute with `run_in_background` (LESSONS).
- **Use the repo copies.** On 2026-10-20 the Desktop shortcuts `Restart and open monitoring stand.ahk` (2026-09-24) and `Restart server and open monitoring stand.ahk` (2026-09-25) were older than `tools/`: no `-select`, `-absent` or `--return-title-only`, no focus fallback, and the server copy lacks the 2026-10-19 list waits.

### `tools/remote.py`

`tools/remote.py` sends instructions through `<mod>/remote.txt`. The channel is opt-in at startup: that file must exist **before** the game starts. Creating it later does not enable polling in that process. Keep it out of releases (a merge install that retains `remote.txt` keeps the channel enabled).

It no longer deploys by default (`--deploy` opts in; `--no-deploy` is still accepted):

```powershell
python tools/remote.py "pwp status"
python tools/remote.py "pwp perf on"
python tools/remote.py "pwp perf"
python tools/remote.py open
python tools/remote.py "mode item,snap"
python tools/remote.py close
```

Replies go to `priority.log`; the tool tails new output. No output is a failed communication check, not success. One sender owns the channel at a time; concurrent writers can overwrite requests. Other observers read the same artifacts. Read a command before using it to "just look": `!pwp cap` cycles the staffing maximum, status lives in `!pwp status` (LESSONS).

**Control requests are desired states, not toggles** (since 2026-09-23). `open` and `close` set one session-bound desired state, executed on the game-thread drain; requests in the same poll coalesce to the last one, and a world/session change cancels them. Repeated `open` does not close the panel, and repeated `close` retries incomplete native cleanup. Even a matching-state request invalidates older queued UI input. `open,mode item` applies the state and the screen together. A requested line is not completion.

**The "panel is now open/closed" reply is not visual proof.** On 2026-09-11 and -13 it was logged before queued actions had run and reported the old state. Since 2026-09-23 it is logged only after `panel.set_open_now` reports that the Lua panel and overlay reached the state, and failure is logged as failure; it is still Lua state, not a rendered frame. A screenshot in the same command as a queued open or mode change can precede it, so verify with a **delayed screenshot**. `panel screen set` likewise reports Lua state. `cmd submitted` proves only that the reflected console call returned without an ordinary error, not that the console action succeeded.

Opening menus, edits, forced passes and profiling toggles are stateful; record them. Restart after runtime changes. Partial icons/overlay/panel reload (`remote.py reload`) is a developer convenience, not lifecycle acceptance.

Do not run broad `funcs`/class/parameter dumps as smoke tests. Previous dumps crashed in native reflection. Use narrow reviewed probes on a copied save when a specific API fact is missing. `pcall` cannot catch an access violation; do not call into a stale wrapper to validate it.

Roster/off-list/authority/storage/readback changes need fixtures covering empty versus unavailable rosters, current Role 2 against stale GameMode, partial off-list reads, nil item IDs, confirmed restoration and preserving pending writes during policy edits. These cases require native follow-through too.

## Main CLI checks

Exercise real command handlers with mocked boundaries before native testing: fractional limits must be rejected; queued client edits must remain pending; failed clears must report failure; unknown/unscoped stock must remain unavailable. Check that `show_limits` labels legacy semantics and obtains current guild/base names only from verified `panel_status` evidence, without blind rescans. Before/after results belong in the gate note.

Repeat natively with delayed/rejected requests and actual storage/save failures. Successful mocks do not close those gates.

## Native acceptance matrix

This is the full matrix; the 0.5.0 subset and which rows have passed are in [RELEASE-0.5.0.md](RELEASE-0.5.0.md), the rest is the backlog in [release-gates-2026-10-09.md](release-gates-2026-10-09.md). A row not covered by a linked gate note is **PENDING** on the current candidate. Record every listed case; use BLOCKED with a concrete reason when unavailable.

### PERSIST / CONFIG

1. Set distinct 1/2/3/4/5/X, edit an unrelated Pal, close immediately, save/restart. Compare file, displayed values and actual permissions.
2. Upgrade a 0.4.1 copy; separately install in a genuinely fresh copied world. Check numbers, X, mode, ceilings and root config. Preserve migration backups.
3. Reinstall through each accepted route without replacing user settings. Unreadable files report errors rather than empty defaults. Default-file remapping protects manual extraction but not a Workshop updater deleting legacy Scripts before migration: preserve a pre-update backup and test that actual route. If the only edited copy was deleted before migration, it cannot be recovered from the new package.
   Test malformed/nonfinite configuration before migration and reload/override application: reject the whole invalid config, retain prior accepted settings and preserve valid 1–5/X meanings.
4. Inject open/write/close/replacement failures offline first. In a disposable native environment check saving/error state, bounded retries and recovery without losing the previous generation.
5. Compare recovery backups. Do not claim reconstruction of X rows absent from every surviving copy.
6. Clear a guild override covering a shared/config ceiling, and separately a directly inherited rule. Check persisted OFF masks after restart, effective absence for that guild and unchanged rules for another guild.
7. Migration is forward to the candidate schema. Retain separate pre-upgrade backups for downgrade tests; older versions must use compatible backups, not current new-schema files.

### SCHED / PRODUCER / STORAGE

For each case record Pal identity, priority, suitability, fixed assignment, available jobs and states, chosen target, applied permissions, actual activity and output over time.

- Pupperai: logging 1, gathering 2, transporting 3; also the reported all-1 setup.
- Flambella: Handiwork 1, Kindling 2, Transporting 3, Ranching 4 with simultaneous demand.
- Incineram: Handiwork 1 and Kindling 2 both ready; observe bench progress and campfire output.
- Grizzbolt: priority-1 generation while occupied, manually displaced, competing hauling, sleep and wake; observe empty→request→return and power output.
- Cooling, ranching, research, recyclers and synthesizers: fixed assignment, skill eligibility, occupied versus completed station, Palbox roundtrip and restart.
- Four single-skill miners, cap three; held/fallback/widened permissions; balanced/strict mode; stable ties and stronger later roster candidates.
- Idle camp: X edit/clear, last legacy cap removed and stale restriction released without demand.
- Demand arriving before camp/type is readable: repair later; unknown scope never applies everywhere.
- Once an adapter exists: stone capped while ore continues; stone consumption resumes it; multiple producers/rules; fixed workers; measured bounded in-flight output.
- Unsupported producer: refuse new misleading rule; existing legacy groups remain labeled/removable.
- Storage: selected camp/guild, local/broader scope, feed boxes, station inventory, drops, exclusions, unavailable containers and shared guild chest counted once.

**No native producer adapter is accepted.** Existing legacy group caps can be edited; new item-specific creation is refused. Simulated admission does not close PRODUCER. Document the actual control API, runtime and measured behavior before enabling one.

**Assignment evidence comes from `Scripts/assignments.lua`** (`scheduler.assignment_reader`, see [assignment-reader-2026-09-25](assignment-reader-2026-09-25.md); `pwp assignments` prints the census). Until 2026-09-25 the reader was nil and every assignment was unverified. An unknown assignment still means "preserve existing permissions", never "grant" (DECISIONS 2026-09-25), and must not be read as no assignment.

### UI / INPUT

- Repeated opening/closing; Escape during valid/invalid amount edits; confirm/cancel/focus loss; rapid repeated close.
- Pause, inventory, map, Pal bed and photo mode before/during/after panel use; focus remains usable and no dormant grey backdrop appears.
- Respawn, transition, duplicate load, missing pak and reconstructed same-name widgets; no stale action touches a new generation.
- Rules at **0/1/13/14/26/27**, multiple picker pages, both paging directions, add/remove at boundaries and correctly aligned amount editor.
- Stand row recycling/rebind, rapid clicks, direct 1–5/X and controller navigation; skipped cells do not count as painted; unavailable data remains visible.
- Stand input retest: hovered number keys and mouse cycling must use plain glyphs; keyboard/controller navigation retains brackets until pointer-directed editing takes over. Check that the former selected cell loses its brackets immediately. Queue rapid left/right inputs near 1/X boundaries; compare saved/pending results with the exact ordered sequence. The `input: queued actions` profiler row measures inclusive execution, not time waiting for a beat or frame presentation. Queued clicks and keys bind their target cell at press time ([stand-pointer-2026-09-24](stand-pointer-2026-09-24.md), [stand-keyboard-2026-09-24](stand-keyboard-2026-09-24.md)).
- Keep preferred position. Check **16:9, 16:10, 1280×800 Steam Deck, ultrawide and multiple UI scales** with labeled screenshots and input sequences.

### SESSION / SYNC / AUTH

- Solo, listen host, empty and populated dedicated server. A remote player is not a local viewport.
- Two guilds/multiple owners: correct write target, snapshot/rule scope and authorization rejection.
- Modded/unmodded clients: deliberate vanilla edits distinguished from mod writes; no unexplained undo loop.
- Delayed/rejected/coalesced edits; disconnect during snapshot/save; duplicate, reordered or missing records; incomplete snapshot never looks complete.
- Schema/version mismatch; reconnect; **host→client→host on the same map without restarting**. Old remote ceilings and authority evidence cannot cross sessions.
- Session changes with queued actions/edits; late acks cannot confirm new-session requests.

## Server/stress safeguard tests

Before tool acceptance, require these regressions: stop targets only the exact intended server process rather than a wildcard; already-running and still-running paths cannot return unchecked success; stress performs a final liveness/error drain; an actual dry=true marker is honored. Use the current test run for these paths; an earlier run without these assertions cannot establish them.

`tools/server.py stop` now requests graceful shutdown through an already configured
local REST endpoint. It never force-kills the process. It checks listener ownership
against the selected installation/PID/start time, refuses redirects/proxies, and
requires observed exit after HTTP acceptance. Missing or disabled REST, ambiguous
configuration, wrong listener, identity changes and timeout fail without a kill
fallback. The helper does not enable REST or create/change an admin password.
Verify this route on an isolated fixture before relying on it for live automation;
mocked HTTP/process tests do not establish native shutdown behavior. Observed exit
also does not prove settings durability: inspect the independent file generation
and restart recovery separately. See the [official shutdown API](https://docs.palworldgame.com/api/rest-api/shutdown/).

## Completed-pass stress testing

A reply must be emitted **after** a distinct successful, non-aborted pass. Bind run ID, request ID, increasing pass ID, session, mode and positive camp count. Each request matches one completion. Queued commands, generic ticks, echoes and process liveness are insufficient.

After testing the harness against an inert mod and checking the native build:

```powershell
python tools/stress.py 240 --mode normal
python tools/stress.py 240 --mode normal --server
```

Sweep/dry variants belong on disposable worlds after inspecting per-request overrides and restoration. They must not silently persist settings. Fail on timeout, abort/rejection, stale/replayed completion, session change or log discontinuity. Inspect the result artifact as well as the exit code.

The server helper requires a **new PWP_READY authority/settings-available marker**, not the boot banner. It preserves logs and old test-world backups, checks exact executable paths and process start identity, and refuses unchecked lifecycle success. Sixteen server-helper tests pass with process calls mocked. Readiness is not completed-pass evidence: stress still requires a useful request-bound completion and final health checks. Do not automatically refresh a test server from or overwrite the user's live world.

## Performance protocol

Use repeated matched scenes. Compare **mod absent/present** and **profiling off/on** with the same save, settings, runtime, camera, frame cap and workload. Use at least three comparable windows per condition to establish variability before interpreting differences.

Cover base/far-field/dungeon; closed UI, stand, settled rules, cold picker/page changes; fresh and aged sessions; sleeping bases and production bursts. The old observation of two camps staying loaded at distance is specific to that save/runtime, not proof of every world's streaming.

Capture independent frame times alongside complete scheduler/callback spans and timestamped events. Record recorder/version and clock alignment. Preserve raw frames. Report p50/p95/p99, worst events and count/duration of hitches above a threshold declared before testing, separately by scene.

Include camp scans, authority/component resolution, storage, planning/applying, UI/tree rendering, hooks and both logging sinks. Report timed samples, clock resolution and window. Label nested timings **inclusive**; do not add parent/child rows. Count-only is **unmeasured**; sub-resolution is not free. Keep incomplete/error events instead of dropping their cost.

Measure profiler overhead with off/on controls. A pass duration cannot explain an unrelated frame hitch without correlation. Acceptance requires a declared budget, repeated results and review of worst spikes. Do not claim “stutter-free” or percentage speedups with missing root spans/frame capture.

### Frame captures

Independent frames come from PresentMon 2.5.1 through `tools/capture_frames.py` (pinned binary `test-results/capture-tools/PresentMon-2.5.1-x64.exe`, SHA-256 `9bec3083069f58f911e6a512f4806db51a27bd096103087bc1d05ef54c80a191`). By default it is a read-only preflight; `--capture` is opt-in and needs `--pid` and `--game-exe` (`--duration`, `--delay`, `--output-root`). It never elevates, launches the game or force-terminates. The quantity is the interval between application Present calls, not physically displayed frames. Procedure, evidence boundaries and why the September 23 recordings came out empty: [frame-capture-procedure-2026-10-09](frame-capture-procedure-2026-10-09.md). Matched method and the current numbers: [g5-performance-2026-10-19](g5-performance-2026-10-19.md).

- **PresentMon runs unelevated** because this Windows account is in the built-in Performance Log Users group (SID S-1-5-32-559). The user approved adding it on 2026-09-12; it took effect after sign-out/sign-in, and unelevated exact-PID captures have worked since. Its "limited process access" warning is normal and does not stop a capture. Without the group, a trace session exits 6 with access denied. Do not change privileges to work around a failed capture.
- A capture that prints started/stopped can still be empty (the CSV is created lazily and a file-open failure is silent). Check the CSV rows, not the console.
- No input, screenshots or remote commands during a window; profiling off for frame numbers; 60 s windows with a 5 s lead, three per condition.
- Mod-absent baseline (G5): move the PalWorkPriority folder and `LogicMods/PalWorkPriority.pak` out with a SHA-256 manifest, set its `mods.txt` entry to 0, run `pwp off` first so permissions are given back, and restart with `tools/restart-stand.ahk --stand-absent` (or another `-absent` mode). Confirm the UE4SS log has no PalWorkPriority line, and restore against the manifest afterwards.

## Packaging and installation acceptance

- [ ] One clean reviewed source commit/version and matching logical manifest in both archives.
- [ ] Compare the package pak against the hash, size and member hashes in `docs/asset-contract.json` (see [widget-spec](widget-spec.md) for the contract and build).
- [ ] Native mounting/widget contract verified on recorded runtime; reject absent, truncated, mismatched assets.
- [ ] No saves, logs, backups, remote triggers, dumps or loose duplicate scripts.
- [ ] Clean install each archive: one active mod, correct paths, mounted pak and loaded identities.
- [ ] Archive contains `Scripts/default_config.lua` mapped from source `Scripts/config.lua`, leaving legacy editable `Scripts/config.lua` intact until backed-up migration. Update/reinstall preserves root config/data and recovery generations, verified after restart.
- [ ] Authoritative server Lua and compatible client panel/protocol.
- [ ] Vortex remains uncertified until deployment/update/removal passes.
- [ ] Restore permissions and preserve backups before removal; verify game state.

`tools/release.py` validates inputs/builds archives. It does not establish native compatibility or publish. All applicable release blockers still need acceptance.

## Evidence record template

One dated note per gate run (the g3-* to g6-* notes are the pattern), linked from its RELEASE-0.5.0 gate line. For every case record: gate/case ID; earlier failing build/evidence; candidate commit and loaded fingerprints; environment/mod list; exact steps/data; expected and actual behavior; raw artifacts and hashes; completed/timed sample counts; remaining unknowns; reviewer; verdict PASS/FAIL/BLOCKED/PENDING.

The [September 14 Blueprint icon experiment](icon-prototype-2026-09-14.md) records the optional picker prototype, which was reverted (DECISIONS 2026-09-14). Results are limited to the recorded installation, scene and actions; passing isolated tests or a visible grid do not close the remaining native gates. August reports remain historical observations.

## Async interruption tests (October 7)

Run `python tools/test_native_save_journal.py` for isolated journal coverage and
`python tools/test_draining_crash.py` for actual native writer process-interruption
coverage. Both create fresh disposable roots under `test-results`; neither
installs code, changes game settings, nor terminates a game process. The latter
deliberately terminates its own helper at named journal boundaries. Inspect the
receipt and retained artifacts, not just command completion.

Acceptance requires a positively identified interruption, a fresh recovery
process, exact scope/generation/full payload checks, validation through the real
Lua settings codecs (including X/OFF), and unchanged files across read-only
recovery. Both journal slots and expected orphan artifacts matter. An accepted
in-memory edit is not a durable acknowledgement. The two settings streams are
independent: mixed valid generations after interruption are allowed, and a lost
unpublished tail must not be silently replayed. Negative controls must reject
an inert or missing interruption hook and incorrect recovery evidence.

These helper tests do not establish physical power-loss durability, an actual
game-crash integration result, multiplayer lifecycle correctness, or frame-time
performance. Keep those gates separate from orderly live travel/restart evidence
in `docs/async-enablement-2026-10-04.md`.

### Release payload regression (2026-10-11)

Run `python -m unittest discover -s tests -p test_release.py -v`.
This includes both synthetic failure controls and a disposable clean Git snapshot
of the actual candidate source. It builds both archives, compiles final packaged
Lua names, and exercises fresh/default and editable configuration loading from
each extracted package. It does not boot Unreal or certify native widget behavior.
The asset must match schema 2 in `docs/asset-contract.json`, including WorkRules
contract 3 and StandInput contract 2. Supplying a different correct pak hash is
insufficient. Review/update the contract when rebuilding an asset.

A merge install retaining `async-trial/launch.lua` is not a clean public install.
Do not remove that launcher without the settings recovery/migration protocol;
legacy files may be older than journal-backed edits. Retained `remote.txt` also
keeps the developer channel enabled. Both upgrade paths require explicit acceptance.
