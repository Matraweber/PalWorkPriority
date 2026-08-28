# Changelog

## 0.4.1

**The mod used to scan the game's entire object list up to four times every
ten seconds. Now it does that once.** That scan is what a hitch on a roughly
ten second rhythm was, and it got worse the longer a session ran, because the
list grows as the game loads things and the scan reads all of it. Measured on
a session several hours old: 36 to 45 milliseconds per scan, three or four of
them per pass, one pass every ten seconds.

Nothing about what the mod does has changed. It answers the same questions,
it just stopped looking them up the expensive way.

### Faster

- **Whether this machine runs the world** is answered from evidence the mod
  already has. The game only asks for base workers on the machine running the
  bases, so a request arriving after this session began is proof, and proof
  that costs nothing. The old scan is still there for the moments nothing has
  been asked yet, which is how a dedicated server answers.
- **The component every change is sent through** is now reached through the
  player controller that owns it, rather than by searching for it. Same
  object, same ownership check, no search. This one also ran on every click
  in the Monitoring Stand grid, so clicks on a server got cheaper too.
- **A pass with no base camp loaded** stops after the first scan instead of
  paying for all of them and then finding nothing to do.
- **The Monitoring Stand grid** finds its cells by walking the menu it is
  drawing into, instead of searching the whole game for them. Halves what an
  open stand costs, and it cannot pick up a stale hidden copy of the menu the
  way the search could.
- **The production limits panel** stops re-sending values that have not
  changed, and only recolours text when the colour is actually different.

### Dedicated servers

- **A server no longer searches for a gamepad.** Checking whether the panel
  hotkey was held made the server look for a local player it does not have,
  and that search reads the whole object list to answer "no". Once a second,
  for the life of the server, for a controller nobody is holding.

### Diagnostics

- **`!pwp perf`** reports how often the mod's hooks fire and what they cost.
  Counting is always on because how OFTEN something happens was the thing
  nobody knew; `!pwp perf on` adds millisecond timing, which costs a little
  to collect and is therefore off by default.
- **`!pwp stand`** writes the Monitoring Stand's widget tree to a file, for
  working out why a grid did not draw.

### Notes

- Three reports on the Workshop describe stutter on a **one second** rhythm.
  The ten second one above is real, measured, and fixed. The one second one I
  could not reproduce or find in the code, and the per-second work the mod
  does measures at a fraction of a millisecond. If you still see it after
  this update, please say so, and say whether disabling other mods changes
  it.
- The multiplayer client path is unchanged in intent but has not been tested
  live since these changes. The server side has.
- `panel.lua` is two top level locals short of Lua's ceiling of 200.
- The item picker's pager is still drawn across rows 7 and 8 when "show all
  craftable items" is on and there is more than one page.

## 0.4.0

**Update your server too.** This release moves the work onto the server, and a
client-only install does nothing: no passes run, the grid stays empty and edits
are sent to a machine that is not listening. There is no protocol version
handshake, so a 0.3.0 server and a 0.4.0 client will not understand each other.
See "Dedicated servers" in the README.

### Multiplayer

- **The Monitoring Stand grid works on a client.** The server sends each pal's
  ranks and priorities, the client draws them, and a click goes back up as a
  request the server validates, applies, saves and pushes to everyone. In 0.3.0
  the grid was blank on a client and a click wrote a local file the server never
  read, so the number changed on screen and the pal carried on as before.
- **Priorities are shared.** Anyone in the guild sees the same numbers, and a
  change made by one player appears for the rest.
- **Priorities and limits are guild-scoped.** Each guild sees and edits only its
  own. The server files a change under whichever guild the message arrived from,
  which a client cannot forge.
- **The mod installs on a dedicated server**, through a server install rule in
  `Info.json`. Subscribing is enough; the pak stays client-side, since a
  headless server draws no UI.

### Fixed

- **A pal is no longer stopped mid-job.** Setting a job to priority 1 while a
  pal worked a priority 2 job switched the priority 1 job OFF, so the pal could
  not take it when it appeared - which kept that job's demand at zero and kept
  the pal where it was. Electric pals showed this worst, because a manned
  generator stops asking for a worker: they would stop generating and could not
  be forced back on. Priority now decides what a pal is permitted to do, and
  demand only decides where it is pulled.
- **Turning the mod off gives the pals back.** Setting `enabled = false` in
  `config.lua` or unticking "Assign Pals to jobs" in DarnMenu used to leave
  every base pal fenced, saved that way, recoverable only by hand. Only the
  `!pwp off` chat command restored them. Every route restores now.
- **A hand-edited data file cannot destroy itself.** A number too large to write
  back loaded cleanly and then failed mid-save, after the file had already been
  truncated - taking every priority, or every guild's ceilings, with it. Both
  files are validated on load and written to a temp file and renamed, so a bad
  row costs that row and a crash costs nothing.
- **The item picker no longer stutters the game.** It was asking the engine to
  confirm every icon it loaded, twelve times a beat, at up to twelve
  milliseconds each. It reads the answer from a sweep it was already paying for.
- **A developer control channel is no longer left on in release builds.** It
  opened a file once a second, all session, on every installation.
- **The panel opens drawn**, instead of appearing as an empty rectangle that
  fills in a fraction of a second later.
- **Remove keeps its warning colour** when armed, instead of turning the same
  colour as everything else the moment the pointer is on it, and it disarms on
  screen after four seconds instead of looking stuck.
- **"Show all craftable items" shows whether it is on**, and a click that cannot
  be carried out says so in the panel instead of only in a log file.

### Security

Two holes that let one guild affect another, both closed:

- A priority change from a player whose guild could not be identified was
  accepted for **any pal on the server**, and that player was sent every guild's
  roster. Unidentifiable now means refused, not permitted.
- **Chat is no longer an admin channel.** Chat reaches every player, and any
  line anyone typed ran on every machine with the mod - including commands that
  cannot be undone. A chat message carries who sent it, so your own commands
  still work from chat anywhere; another player's are refused if they would
  change something. When the sender cannot be identified at all, changing
  commands are refused while anyone else is connected.

Also: the settings file the DarnMenu integration reads is executed in an empty
environment and refuses precompiled bytecode, and a client can no longer be
told to hold an unbounded amount of data.

### Notes

- `panel.lua` is two top-level locals short of Lua's 200 ceiling.
- The item picker's pager is drawn across rows 7 and 8 when "show all craftable
  items" is on and there is more than one page, partly hiding both. Known, see
  `docs/audit-2026-08-26.md`.
- The panel's tab strip shifts between the rules list and the picker. Known and
  deliberate; the alternative was worse to look at.

## 0.3.0

Settings and hotkeys in the game, through the optional DarnMenu integration, so
neither needs a hand edit of `config.lua`. Real in-game item names in the picker
rather than rearranged internal ids. `tools/pakcheck.py`, added after 0.2.0
shipped a stale pak.

## 0.2.0

Shipped with a stale pak: only 7 of 21 named widgets resolved, so several panel
features silently did nothing. Fixed in 0.3.0. `tools/pakcheck.py` exists to
stop it happening again.
