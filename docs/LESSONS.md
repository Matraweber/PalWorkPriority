# Lessons: mistakes this project already paid for

Read this before changing code or claiming a result. Every rule below cost a
crash, a wrong release note or days of work. Add to it in the same change that
discovers a new one, with the date and a link to the evidence.

## Engine and UE4SS: the rules that prevent crashes

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

## Evidence: how we fooled ourselves

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

## Process: what slowed the project down

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

## Lua traps

- **`cond and false or x` never yields false.** The `and false` falls through
  to `or x`. This exact line in 0.4.1's store.lua dropped every X priority on
  save ([restart-persistence-2026-10-11.md](restart-persistence-2026-10-11.md)).
  Use an explicit `if`, or make sure the middle value is truthy.
- **`math.tointeger(non-number)` returns nil** silently in Lua 5.4, which makes
  a bad value quietly vanish instead of failing loudly.

## Tooling traps

- `luacheck.py` only balances blocks. Lua can still reject what it passes.
  Check the reload's own reply.
- `panel.lua` sat at 198 of Lua's 200 top-level locals. Exceeding it breaks
  only the hot-reload path, almost silently. New state goes into an existing
  table.
- A regex rename across Lua rewrites table-literal keys too.
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
