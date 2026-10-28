---
date: 2026-10-28
tags: [records, testing]
status: current
---
# Lessons: mistakes this project already paid for

Related: [DECISIONS](DECISIONS.md) · [testing](testing.md) · [RELEASE-0.5.0](RELEASE-0.5.0.md)

Read this before changing code or claiming a result. Every rule below cost a
crash, a wrong release note or days of work. Add to it in the same change that
discovers a new one, with the date and a link to the evidence.

## Engine and UE4SS: the rules that prevent crashes

- **A property you write may end up in the player's save.** A stone pit's
  work state set to NotWorkable came back NotWorkable after a reload, while a
  rock's did not (2026-10-28, [per-item-limits-2026-10-27](per-item-limits-2026-10-27.md)). Before a mod writes a game value,
  reload once and check whether it survived; restore it by hand right after
  the test.
- **A stored engine object is a use-after-free.** An object obtained in the
  current call is safe. One kept for a later frame is not, and calling
  `:IsValid()` on it IS the crash. `pcall` cannot catch an access violation.
  Strings, booleans, numbers and timestamps may cross calls. Wrappers may not.
  (Aug 2026, several crash dumps; PalPriority caches widgets and we still refuse to.)
- **A boolean memo is exempt** from the rule above. Nothing engine-side is kept,
  only an answer that cannot change without a world change (`latch_authority`).
- **Pass `FName(...)`, never a bare Lua string, where the signature says
  NameProperty.** UE4SS dereferences null and kills the process (upstream #1360).
- **Never call a UFunction on a replicated proxy on a client.** Reading a
  property is safe. `GetWorkSuitabilityRank` on a client pal is an access violation.
- **Never enumerate unknown class members.** Full class or function dumps
  (`!pwp funcs`, supers walks past `/Script/CoreUObject.Object`) killed the
  process twice. Use narrow, reviewed probes on a copied save.
  2026-10-27: the ranch probe walked the properties (not functions) of
  `PalWorkMonsterFarm` and its model, stopping at `PalWorkBase` and
  `PalMapObjectConcreteModelBase`, on the live test world. It did not crash,
  but it broke the copied-save rule; the next one goes on a copy.
- **Never call an unreflected C++ method through UE4SS**
  (`GetWidgetFromName` is not a UFUNCTION). Read the property or walk the tree.
- **Never take `SetInputMode_UIOnly`.** The controller goes deaf to keys and
  pads. Keep game input and suppress the pawn instead, and always
  `pc:EnableInput(pc)` on close.
- **Reload with `loadfile`, never `require`.** Re-requiring hands back the
  startup chunk with no error. Keep a hand-bumped module `VERSION`.
- **A widget instance name is not identity.** Close and reopen of the stand
  rebuilds widgets with the same full names. Key "did I draw this tree" on a
  counter bumped when widgets are dropped.
- **`FindFirstOf` on a class with zero instances walks the whole object
  array** (about 10 ms fresh, 36-45 ms in an aged session). Ask how many
  instances exist on the machine asking before calling it.
- **A dedicated server has player controllers** (one per player). "Has a
  controller" is not a client test. `GameViewport ~= nil` is.
- **Commands sent before the `world key:` line land mid-load and crash.**
  `server.py start` waits for the mod, not the world.
- **Any `RequestX_ToServer` must use the OWNED network component.** The wrong
  one drops the RPC silently while counters still count it. This one mistake
  caused both the August transport bug and the toggle churn.
- **`FindFirstOf` can return a hidden or wrong instance** (stand menu,
  2026-09-13). Query the current tree and verify the target.
- **Image, Spacer and TextBlock are childless; CheckBox has one child and must
  stay traversable** (2026-09-12). A failed child-count read on a CheckBox is
  not "empty".
- **A native checkbox change is not a user's edit.** Adopting one as a priority
  edit overwrote saved numbers with X/1 (the 2026-09-12 rapid-click jumps).
- **On UE4SS 2281fa31, consecutive scalar out-parameters all land in argument 1.**
  LuaUObject.cpp:193 keeps the out-param reference at stack slot 1 without
  consuming the argument, so `GetAccurateRealTime(seconds, partial)` filled only
  the first table and PartialSeconds read nil. Pass one table for all outputs
  and read each named field from it. Proven for numeric outputs on the dedicated
  clock fixture (third boot, 2026-10-11); other output types and the server's
  ba2efd55 build are untested. Bears on the 2026-10-19 GetNickname decision,
  which rejected out-tables as unproven.
- **A world-owned Actor can vanish with its world while IO is in flight.**
  Actor absence or a cancelled timer is not proof the IO stopped (V4 moved to a
  rooted transient UObject, 2026-10-03).
- **Never pass a Blueprint delegate by value from Lua.** BreedingHelper's
  attempt crashed natively; let the Blueprint construct and register it
  (WorkRules contract 2/3, 2026-09-16).
- **ScrollBox orders children by creation, not intended index.** A pager host
  created during partial fill sat between item rows (2026-09-24); reserve row
  containers first.
- **GetItemName aborts the game for an id the item table does not have.**
  It does not return the "en Text" placeholder the 88 unnamed vanilla rows
  give; the process dies with "Abort signal received" (2026-10-20,
  COSM_Ninja01). Check the id against the table's row names first.

## Evidence: how we fooled ourselves

- **The shipping game's cheat manager is a shell.** With UE4SS's cheat-manager
  enabler on, `AddPlayerExp`, `SpawnMonster` and both debug add-item calls
  ran without error and did nothing (2026-10-27). Real gameplay functions
  work (`PalUtility.GiveExpToAroundPlayerCharacter`, `K2_TeleportTo`), and
  the installed Creative Menu mod (F1) spawns Pals and items. Check the
  installed tools before writing your own; the user already had one.
- **`GiveExpToAroundPlayerCharacter` is not linear.** 5000 gave 4 XP, then
  10 000 000 jumped the test character from 28 to 64. Player level cannot be
  lowered: give experience in small steps and look after each one.
- **Check a Pal's row before calling it untouched.** Anubis was picked as an
  untouched test Pal; the snapshot showed it had Handiwork 3, Mining 4,
  Transporting 2. Same mistake as the Lamball grep: look the key up in
  `priorities.txt` first.

- **`priorities.txt` holds keys, not species names.** Grepping it for
  "sheep" found nothing, and Lamball was first written down as having no
  stored priorities; it had Farming 5. Look a Pal up by its key from the
  census (2026-10-27).
- **A keyword fallback can type work confidently and wrongly.** "Harvest" was
  not a label, so the berry plantation's id reached the "farm" keyword and
  every crop harvest counted as ranch work for weeks. Read Discovery's
  per-type counts after any typing change; more works of a type than the
  stations built for it is a mistyping (2026-10-27).

- **"Not known yet" must never be read as a definite answer.** nil guild,
  unpainted menu, empty push, missing property (`AuthorityGameMode` read nil on
  the HOST and idled singleplayer). Refuse and retry, never "none" or "all".
  This shape caused at least five separate bugs.
- **"Stutter-free" in August was wrong.** It was concluded from counters,
  tick cadence and clean logs. None of those are frame times. In September,
  independent frame capture showed 10-11 slow frames per minute with the mod
  and 2 without. Only matched captures (mod absent vs present, profiling off
  vs on) can support a performance claim. See [testing.md](testing.md).
- **A count-only row printed as `0 ms` is unmeasured, not free.**
- **When a symptom is intermittent, instrument before editing.** Three bugs
  in one day were each argued to a confident wrong cause first, then settled
  by one round of timers.
- **Measure the region that is actually slow.** Timers around the send said
  17 ms. The real cost was a repaint on a later beat.
- **Passing tests are not in-game acceptance.** Mocked engine contracts cannot
  prove object lifetime, focus, assignments, output or frame time. The test
  count (500+) says nothing about what was verified in the game.
- **A silent fallback hides a broken primary.** The case-sensitive
  `"GameMode"` match was dead for weeks because the walk quietly covered it.
  Count which route answered, not only that something did.
- **Verify a review before acting on it.** Agents infer danger by association.
  One review's headline fix would have blanked the priority grid in
  multiplayer. Check the claim against the code and a live artifact.
- **Read the checker output, not the word "deployed".** A luacheck-failing
  file was deployed once. A server deploy silently did not take once.
- **GetTickCount64 and Sleep have 10-16 ms resolution; time native work with QPC.**
  A strict 200 ms gate measured with them failed a handoff trial (2026-10-04;
  the log lacked raw timestamps, so this is the likely cause, not a proven one).
  The QPC rerun measured 200,268 us and passed. A printed `os.clock` 0 ms means
  below resolution, not free.
- **An advertised child that resolves nil, or an unreadable or empty name,
  refuses the whole snapshot** (panel_runtime, 2026-09-25); an early return had
  passed a partial tree as complete.
- **The August empty-field test kept two camps loaded,** so the no-camp branch
  was never exercised; one map's streaming is not every map's.
- **Matched captures need the same monitor and an idle desktop.** On
  2026-10-20 the game had moved to the second monitor between runs and the
  mod-absent relaunch opened on the first; a run started while the user played
  Hearthstone was thrown away. Screenshot both monitors before every capture
  set and keep present and absent back to back. Let a fresh session settle
  (10 min or more): the absent run captured 2.7 min after load had a 5 s spike
  chain and more GPU work, too noisy for a with/without figure.

## Process: what slowed the project down

- **Read what users asked before taking a feature away.** 0.5 locked new
  limits on 2026-10-11 because a limit switches its whole work type. None of
  the 8 limit comments asked for that, and all of them came from 0.4.1, where
  adding limits works, so the lock would have shipped as a regression. It was
  undone on 2026-10-27 ([limits-unlock-2026-10-27](limits-unlock-2026-10-27.md)).
  Before removing or locking something users have, check the ledger for what
  they actually reported.
- **Six weeks of work were never committed** (Sep 11 to Oct 11, about 95k
  lines on one disk). Commit at the end of every working session, to a branch
  if it is not release-ready. Untracked docs are not protected either.
- **A gate without a "done when" never closes.** Async saving grew layer by
  layer (journals, locks, install fences) for three weeks after the trigger,
  a 1-2 s flush stall seen only on the rented GPortal server. Singleplayer
  saves measured 4-5 ms. Write the exit condition before starting a gate.
- **Users wait while scope grows.** 0.4.1 shipped known P1 bugs (X lost on
  save) and no update followed for six weeks. Ship proven fixes in small
  releases rather than holding them for the full plan.
- **The user's taste outranks an audit.** The panel position was "fixed" by
  an audit and reverted on request. Keep the preferred position.
- **Re-proposing a measured-and-rejected idea wastes a session.** Check
  [DECISIONS.md](DECISIONS.md) for the rejected list first.
- **Read the rejected list before proposing an optimisation.** On 2026-10-19
  a stand "skip when nothing changed" was recommended and chosen, although
  DECISIONS had rejected it on 2026-08-27 as dirty-flag refresh gating (it
  brought the repaint bug back three times). Grep DECISIONS for the idea first.

## Lua traps

- **A button's release can land on the menu underneath.** The panel closed on
  B's press; the release then reached the Monitoring Stand, which closes on
  release. A short press hid it, a 0.8 s hold showed it (2026-10-22). Close
  an overlay on the release when a game menu sits below it.
- **The game's menu actions run before any widget key handler.** Y on the
  stand (view switch) and A in our panel (UI confirm) never reached
  OnKeyDown/OnPreviewKeyDown or a registered binding; only buttons the menu
  does not bind arrive. Read the game's input mappings first
  (`Default__InputSettings.ActionMappings`, a property read) and pick free
  buttons.
- **Editor commandlets need CommonUI's input data loaded by hand.** A widget
  that registers with CommonUI when shown hits the `bInputDataLoaded` ensure
  in a fresh editor process; load `ICommonInputModule::GetSettings()` (the
  module's own instance, not the CDO) before the fixture window.
- **A controller plugged in after the game started is not the player's.** On
  2026-10-21 a virtual pad connected mid-session moved menus but never reached
  the player, and a whole controller test read "broken". Connect the pad, then
  start the game, and probe in the open world before blaming the mod
  (2026-10-22: the read worked all along; the menus take the D-pad and A).
- **A new label can expose an old mapping bug.** "Group limit applies" put
  Mining on Pal souls because workdefs matches item ids by substring ("stone"
  in PalUpgradeStone). The list had shown them as mining products for months;
  nobody read it that closely until a sentence claimed it (2026-10-22). When a
  UI starts asserting something from heuristic data, check the data.
- **Bottom-anchored text grows upward into whatever sits above it.** The
  two-line stand legend pushed its first line into the game's own bar. Check
  new HUD text on screen, not only by width (2026-10-22).
- **A clamp at one end of a ladder is a jump from the other side.** The limit
  ladder's `step` returned the top rung (50,000) for any value above it, so
  "raise" on a typed 100,000 lowered it, and "lower" under 100 raised it to
  100. Found by reading the code for the 2026-10-21 UX review, not by a test.
  A step function must keep a value that is outside its range and say why.

- **An error inside pcall is not free, and it hides a broken call.**
  GetNickname failed on every call after a game update (wrong parameter
  count); pcall swallowed it, so names quietly became species names and each
  failure cost about 0.5 ms (93% of the roster read). When a timed region is
  slow, time its pieces before optimising the obvious part (2026-10-19).
- **`cond and false or x` never yields false.** The `and false` falls through
  to `or x`. This exact line in 0.4.1's store.lua dropped every X priority on
  save ([restart-persistence-2026-10-11.md](restart-persistence-2026-10-11.md)).
  Use an explicit `if`, or make sure the middle value is truthy.
- **`math.tointeger(non-number)` returns nil** silently in Lua 5.4, which makes
  a bad value quietly vanish instead of failing loudly.
- **A status sent only on change is lost if the receiver resets after it.**
  net reported "incompatible" before the client role was decided, and
  `caps.set_role` then reset the panel to "connecting" for good (2026-10-19,
  rc1 client on a 0.4.1 server). Whoever resets state must re-read the
  sender's current status, and tests must replay the real arrival order.

## Tooling traps

- `luacheck.py` only balances blocks. Lua can still reject what it passes.
  Check the reload's own reply.
- `panel.lua` sat at 198 of Lua's 200 top-level locals (194 on 2026-10-20,
  counted from its top-level `local` statements). Exceeding it breaks
  only the hot-reload path, almost silently. New state goes into an existing
  table.
- A regex rename across Lua rewrites table-literal keys too.
- **One blind Escape after focusing the game can be swallowed.** On
  2026-10-28 `restart-stand.ahk --world` failed three times: the menu never
  opened, the Return to Title click hit the world, and the macro stopped
  with "Normal exit did not finish". `--title` (clicks only) worked. The
  macro now presses Escape until a pixel check sees the menu's blue Options
  tab (at most 4 presses); the next `--world-select` run passed. Check that a
  screen is really showing before clicking into it.
- Steam caps a Workshop change note at 8,000 bytes; the 0.5.0 changelog
  section is about 10,000. `tools/workshop_upload.py` trims by priority
  and links the full changelog (2026-10-28).
- Heredocs eat backslashes. Use `chr(10)` / `chr(92)` in generated code.
- Steam Workshop and a manual install fight: Palworld rewrites `mods.txt`
  and copies its own Scripts on launch. Check for a Workshop subscription
  before debugging "my edits do nothing".

- **Never pipe a deploy or install script into `Select-Object -First N`.**
  It stops the upstream script once it has N objects, so `deploy.ps1` died
  silently after its compile step and replaced nothing (2026-10-11). Check the
  installed hash after every deploy; that is what caught it.
- **Never auto-retry an operation that changes a remote system.** The FTP
  helper retried a whole server install after a dropped connection; the
  retry refused ("backup already exists") and made a finished upload look
  failed (2026-10-11). Changing operations now stop and report what already
  happened. Then verify the actual remote state before acting again: all 55
  files were downloaded back and compared before the result was trusted.
- **Read a command before calling it to "just look".** `!pwp cap` cycles the
  staffing maximum instead of printing it, so a status check silently changed
  the user's setting from 3 to 4 mid-test (2026-10-12). `!pwp reload` restored
  it from config. Status lives in `!pwp status`.
- **Before calling it a priority failure, check the station can take a worker.**
  A Pal "ignoring" Generating Electricity 1 was blamed on the mod for an hour
  (2026-10-14); the generators were unbuilt blueprints and then full. A proposed
  fix would have sent Pals to stand at full generators. Ask the user about the
  station (built? full? powered? inside the base?) before reading the census.
- **A priority test needs the Pal busy with the other job first.** A Pal with
  no current job takes its top priority anyway, so "Penking went to the fridge"
  on the old build proved nothing (2026-10-16). The control only showed the
  gap once he was watering when Cooling became 1. Same for every station test.
- **`sample_assignments.py` appends to its output file.** A loop of single
  samples into one file re-reads every earlier line; delete the file before
  each sample or read only its last line (2026-10-16).
- **If the macro reports "New game window did not appear", look at Steam,
  not the macro.** On 2026-10-16 no Palworld process started at all, whether
  launched directly, by the macro or by `steam://rungameid`; starting it from
  Steam by hand worked. Steam's windows are masked for computer use, so ask
  the user what Steam shows instead of retrying.
- **Read the in-game options before calling a limit a bug.** DarnMenu writes
  `Mods/shared/PalWorkPriority_user.lua`; `storage_scope = "global"` there adds
  up every base, which made both of the user's limits met and stopped all
  mining (2026-10-17). An hour went into reading scheduler code first.
- **A rule restored by copying an old caps.txt is refused.** The loader keeps
  the newer generation and recovers from caps.txt.bak (correct). New legacy
  rules are locked in 0.5; re-add one via a temporary config.lua `work_caps`
  entry plus `!pwp limit`, then restore config.lua.
- **The restart macro's keys stopped arriving on 2026-10-17, its clicks did
  not.** With the Windows input host holding the foreground, the in-world Esc
  never reached the game, and the following menu clicks fired the weapon. Do
  the in-world step (Esc, Return to Title, Yes) with computer use when it is
  allowed, then run the macro with `--title`. A title-bar click gets focus
  back; keep CoordMode Client for every other click.
- **Alt+F1 through computer use works, but is also NVIDIA's screenshot key.**
  On 2026-10-17 it looked as if an overlay swallowed the game: the panel had
  opened, NVIDIA took a screenshot, and the game sat on the other monitor
  while screenshots showed only one. Check `switch_display` before concluding
  a window is gone. Run `pwp-focus` before every computer-use batch; focus
  drifts to the input host between batches.
- **Staging combat or death in singleplayer is harder than it looks**
  (2026-10-17). CheatManager `summon` gives an inert Pal (no AI); the NPC
  manager route from dkoz/AdminCommands gives a working one, but a neutral
  species never attacks; `SetHP(0)` leaves the player at 0 HP without dying.
  Pick a naturally aggressive species, or have the user steer. The UE console
  keys (F10, ~) did nothing in-game even with ConsoleEnablerMod on.
  The game's own `APalPlayerController:SelfKillPlayer()` is the clean way:
  a real death with the DEFEAT screen and respawn. Check for a built-in kill
  before staging fights (an hour went into spawning first).
- **Park the mouse off the panel before handing focus back.** With the panel
  open, keys and pad buttons act on the selected row; one unexplained step
  (30000 to 50000) happened right after a focus click (2026-10-17). Diff the
  rules after every UI test.
- **Check the macro's own calibration before blaming the UI.** A failed join
  was blamed on a new Recent Servers entry above RAM; the macro clicks the
  second row on purpose and RAM was second. The real fault was a missing wait
  for the list to load (2026-10-19). Read the macro before diagnosing it.
- **Long foreground waits drop the remote session.** Run restarts and waits
  over a minute with run_in_background.
- **An AHK exit code does not prove the stand opened.** The fixed-time restart
  macro reached the stand without opening it (2026-09-13); short V presses do
  not open it, the 850 ms held-V helper does. Check a screenshot or the stand
  diagnostic before calling a capture "stand open".
- **The remote "panel is now open/closed" reply is not a rendered frame.**
  Until 2026-09-23 it came before the queued actions ran (2026-09-13, 09-15);
  since then `remote.lua` sends it after `panel.set_open_now` confirms the Lua
  panel and overlay state, but a screenshot in the same command can still
  predate the frame. Confirm with a delayed screenshot or status.
- **There is no global `GetEngine` in our UE4SS;** use
  `require('UEHelpers').GetEngine()`. The one-string `StaticFindObject`
  overload rejects a package-only name such as `/Engine/Transient`; take the
  engine's outer instead (2026-10-03).
- **The equals-form UnrealPak extract overwrote the Workshop CreativeMenu pak
  with an empty package** (2026-09-13; restored, SHA-256 b1507a64...). Use the
  two-argument form on a separate copy.
- **The game's mod loader deletes every file it installed before an update,
  and backs up nothing.** User edits inside the shipped `Scripts/` (0.4.1's
  config.lua) are gone before the new version runs (2026-10-20). Keep user
  state outside the shipped folders; data files the loader did not install
  survive. A file of another install in its way is renamed, not lost:
  the manual pak became `PalWorkPriority-<time>.pak.bak` (2026-10-20, found
  on 10-21), although the manifest says `"Backups": []`.
- **The loader installs an active Workshop copy over a manual install without
  asking.** With the Workshop 0.4.1 switched on but never installed, the next
  start replaced a manual 0.5.0 with 0.4.1 (2026-10-20). The newer version
  never runs, so it cannot warn; only documentation helps there.
- **`tasklist` truncates image names to 25 characters.** A check for
  `Palworld-Win64-Shipping.exe` never matched, so four "game closed" guards
  always passed (2026-10-20, no harm because every earlier run followed a
  verified exit). Match `Palworld-Win64-Shipping` without the extension.
- **A system chat line to the local singleplayer player is not shown.**
  `SendSystemToPlayerChat` returned without error three times and nothing
  appeared (2026-10-20), while the same call from a server to a remote player
  does show (G6). Use the panel or the log for local warnings.
