---
date: 2026-10-27
tags: [release, reports]
status: current
---
# 0.5.0 reply drafts (not posted)

Related: [RELEASE-0.5.0](RELEASE-0.5.0.md) · [comment-ledger-2026-09-11](comment-ledger-2026-09-11.md)

**Superseded 2026-10-28.** Replies are not needed (user's decision 2026-10-27), and two claims here are false for the final build: new limits can be added (Mining per item), and the controller was a virtual XInput pad, not an Xbox controller. Do not post these without a rewrite.

Rewritten 2026-10-27 against the candidate at 252c0e3, from the gate evidence
in [RELEASE-0.5.0](RELEASE-0.5.0.md). They replace the rc1 drafts of
2026-09-15, which promised nothing because nothing had been tested in the game
yet (git keeps them). Row numbers are the [comment ledger](comment-ledger-2026-09-11.md)'s.

Each draft claims only what a gate measured. Untested areas are named as
untested. **Posting is the user's action.**

**Before posting:**

- Recheck every draft against the tagged final build.
- Read the ledger for comments that arrived since 2026-10-21.
- Post only after 0.5.0 is published, and put the release link in place of
  `[link]`.
- Two drafts depend on open items:
  - **Saber57Draxus** depends on the Vortex result.
  - **TheJoe, Erbse, tigerpow100** depend on the real-controller run.

## Settings lost after a restart (F01-F03)

For Two Bob Games (85), johndujo (B2), like (74), Erbse (73), Gim1i (14),
spleenszuru (20), MaD (25), ThatFawker (32), valdacil (60):

> 0.5.0 is out: [link]. Priorities, including X, now survive restarts. I tested a mix of 1-5 and X on several Pals through two restarts in a row, in singleplayer and on a dedicated server, and the Pals followed the saved values right after loading without touching the stand. The X losses came from the save code: 0.4.1 dropped every X row whenever it saved. X values that 0.4.1 already lost can't be brought back, so if you have an older copy of priorities.txt that still has them, put it back before starting 0.5.0. Back up your mod folder before you update.

Add for valdacil: "Fixed assignments (pinning a Pal to one station by hand) are
still not supported by the mod."

## like's diagnosis (D1)

> Thanks, your diagnosis was right: math.tointeger(false) turned X into nil, so the row was dropped on save. 0.5.0 writes X explicitly and has a test for exactly that case. On your other point: if the settings file can't be read, 0.5.0 logs it and leaves the file alone instead of replacing it with defaults, and the log says when it recovered from a backup copy.

## Ceo of Toes (D2)

> For 0.4.1 the server is the one that saves, so the patch matters on the dedicated server. With 0.5.0 you don't need the patch, but the server and every player need 0.5.0. Mixed versions are refused without writing anything, and the game says which side to update.

## Panel stuck, doubled or overlapping (F04-F06)

For Extramrdo (83, 84), Okami_sama (77), Calas Typhon (18), Drokz077 (19),
Bernie Laplante (16), Hall9002 (54):

> In 0.5.0 Alt+F1 never opens a second panel, and the panel no longer gets stuck in front of the pause menu, inventory or map. I ran 10 open/close cycles plus rapid presses: one panel every time. Escape first cancels an unfinished amount, a second Escape closes only the panel. The list keeps its layout at every size, and the amount editor stays on its row above the page buttons. The Monitoring Stand now has a two-line legend (left and right click, number keys, Alt+F1), and the panel shows its key hints.

Add for Extramrdo (84): "1 is the highest priority, 5 the lowest, X means never."
Add for Gim1i (13): "I couldn't reproduce the Escape crash itself. If it still
happens on 0.5.0, the UE4SS.log from that session would help."

## Grey box after photo mode (F06)

For Zekrom144 (2), Roin (89), Extramrdo (90):

> Found it. In 0.4.1 the panel sat collapsed on the screen from the moment the world loaded, and photo mode made it visible as that grey rectangle, which is also why Extramrdo's Alt+F1 open and close cleared it. 0.5.0 only puts the panel on the screen while it is open. Sleeping in a Pal bed, photo mode and leaving it are clean now, and so is photo mode while editing.

## Item search crash with item mods (F05)

For NoMo (88/B3):

> Reproduced and fixed, thanks for the log, it pointed straight at it. With item mods installed, the search asked the game for the names of item ids that the game's own item table doesn't have, and the game aborts on that. 0.5.0 only asks about items that are in the table. I ran five rounds of Show all, search and Add with Cosmetic Outfits and PalSchema installed, with no crash.

For DarkWyrmReaper (B1): the same text without the thanks for the log; you were
right that Cosmetic Outfits was involved, though the bug was in this mod.

## Mining and chopping stop (F07/F09)

For Okami_sama (76):

> Reproduced: with the mod, no Pal mined or chopped in 42 samples. There were two causes. The game announces rocks and trees only once, when the world loads, so later the mod no longer saw them as work. And limits that were met under the "all bases" storage option kept flickering to "stock unavailable". Both are fixed in 0.5.0 and checked in the game.

## Limits (F07/F19)

For SolidRhoé (3, 4), BIG DADDY (17), Mithandil de Melkin (75), [TLD]Bob77 (38):

> A limit switches a whole work type, which is why a Stone limit also stops ore. Your existing limits keep working in 0.5.0 as group limits, and the panel says so. New limits can't be created in 0.5.0, because a limit per item needs a way to stop one product while another continues, and that isn't ready. Limits per item are planned for 0.6.

Add for BIG DADDY: "Overshoot (ore at about twice its limit) wasn't measured for
0.5.0." Add for Mithandil de Melkin: "Pal-produced materials are on the request
list." Add for [TLD]Bob77: "Guild chests weren't tested for 0.5.0."

## Priority 1 against 5 (F09)

For HelpImStupid0 (87):

> In 0.5.0 priority 1 beats priority 5. On a test base with competing work at 1 and 5, the Pal was on the priority-1 job in at least 8 of 10 checks, and it followed when I swapped the two numbers.

## Generators (F11)

For CosmicWarbear (45), DSFddaaaa (71):

> Found it: the game never announces generator work, so an empty generator didn't pull a Pal with Electricity 1 off other work. 0.5.0 counts built generators that need energy. In the game the Pal was back on the generator 16 seconds after its priority was set back.

Add for DSFddaaaa: "The default for Pals you never ranked has changed too: they
are now left to the game, so transporting no longer gets in the way of their
other work."

## Incineram (F09/F11)

For Glave (50):

> Tested in 0.5.0: Incineram with Handiwork 1 and Kindling 2 was on Handiwork every time there was Handiwork waiting, and went to Kindling only while the workbench had nothing to do.

## Coolers and fishing ponds (F11)

For poiman (67):

> Both are fixed in 0.5.0. Coolers: the game never announces cooling work, so a cooler with food didn't pull a Pal with Cooling 1 off other work (in my test it stayed on watering for about two minutes). Now it goes to the cooler within about 20 seconds. Fishing ponds: the pond's job had no work type the mod understood, so it never counted as work. 0.5.0 treats it as Handiwork, which is what the game's tooltip asks for. In my test an Anubis with Handiwork 1 went from fishing in 2 of 9 checks to 6 of 9. The pond needs bait and a fish target set before any Pal works it.

## Untouched Pals and the default ranking (F03/F18)

For GammaEuviex (27), srvtsonn (55):

> 0.5.0 does what you asked: a fresh install starts every checked job at 1 and every unchecked job at X. A Pal whose jobs all have the same number is now left to the game, so a Pal you never ranked works as in vanilla. The default ranking that put transporting ahead of specialist work no longer applies to Pals you haven't edited. Coolers count as work now as well, so a Pal with Cooling 1 goes to a cooler with food in it. Pals you already ranked keep your numbers.

## KhanKeal (5, 6, 7)

> I retested your three setups on 0.5.0. Pupperai with Logging 1 logged as set. All-1: a Pal whose jobs all have the same number is now left to the game, so all-1 behaves like vanilla. Before that, berry and crop harvests were counted as ranch work, so the mod was acting on the wrong demand. Flambelle with Handiwork 1, Kindling 2, Transporting 3, Ranching 4: I reproduced her staying on the ranch. In my base the cause was that fishing ponds and research labs were invisible to the mod, so as far as it knew there was no Handiwork for her. Both count now. She can still end up grazing while every Handiwork spot is taken by other Pals, because then there is nothing higher left for her. If she keeps grazing on 0.5.0 with Handiwork waiting, what Handiwork stations does that base have?

## Samurai9400 (26)

> I built a research lab and couldn't reproduce the greyed-out research on 0.5.0. The mod types research by its subject (Handiwork research is Handiwork), and a Pal allowed Handiwork researched it. The game itself only asks for lab workers once, when the world loads, so 0.5.0 now counts a running Handiwork research as open work. I've only tested Handiwork research so far. If it's still grey for you on 0.5.0, which research was it and what numbers does the Pal have?

## Rey (34, 35, 10, 12)

> Found the Lamball one, and sorry it took this long. The game never announces ranch work after the world loads, so an empty ranch didn't count as work and the Lamball was kept on other jobs. 0.5.0 counts one Pal per ranch, and in the game the Lamball went to the ranch and stayed there over two game starts. On the early game without a stand: Pals you haven't ranked are now left to the game, so they work as in vanilla until you set numbers.

## Pals refusing allowed work (F11/F13)

For Ruse Spark (41), jeje (1):

> 0.5.0 fixes several reasons Pals refused work they were allowed to do. Rocks, trees, generators, coolers, ranches and fishing ponds weren't counted as work after the world loaded, and met limits could flicker. If a Pal still refuses work on 0.5.0, tell me the Pal, its numbers and what it does instead.

Add for Ruse Spark: "The checkbox you see flash is the game's own, which the mod
hides while it shows its numbers. Tidying that up is planned for later."

For lainverse (31): Sekhmet and the recycler, and "Waiting" while the coal
synthesizer produces, were not tested for 0.5.0. Reply only on what was fixed:
ranch X resets (settings section), command replies and line breaks (logging
section).

## Controller and Steam Deck (F18)

For TheJoe (24), Erbse (68), tigerpow100 (69). **Recheck after the run with a
real controller through Steam Input.**

> 0.5.0 works with a controller on the Monitoring Stand and in the Production Limits panel. On the stand the D-pad moves, LB or A moves toward 1, RB toward X, X sets X, and View opens the panel. In the panel Y opens or raises, X removes, and B closes only the panel. I tested it with an Xbox controller on PC. I haven't tested a Steam Deck yet, so please tell me if something doesn't respond there.

## Multiplayer (F12-F14)

For NoAhQ (33, 36, 37, 42), Drokz077 (19, 28), giorgn (62):

> Tested on my own dedicated server: an edit by a player survives a server restart and reconnect, one guild's rules never apply to another guild's bases, and mixed versions are refused without writing anything. Not tested yet: two real players in two guilds at once, and edits from players without the mod (the reverting edits you saw). Server and every player need 0.5.0.

Drokz077 (28), blank stand grid on GPortal: not reproduced. Ask for the
UE4SS.log of a session where it happens on 0.5.0.

## Performance (F15/F16)

For Plz (49), Ashura (40), luller (39), UltraJohn (8), Siberfox99 (65):

> I measured it properly this time, with the mod present and removed on the same save. My earlier "stutter-free" claim went further than my measurements, sorry about that. In 0.5.0 the mod's scheduling pass takes about 20 ms (it was 35 ms), which is about one slow frame (over 16.7 ms) every 10 seconds. If you have limits that need stock counts, there's one frame over 33 ms every 30 seconds on top. With the Monitoring Stand open, about one extra slow frame per second. The other stutter I measured came from the game itself.

## Installation and commands (F17/F20)

For Toomy141 (53), coolmunch (15), decamhian (59):

> Alt+F1 opens Production Limits, and on the host Alt+F2 recounts now. Both can be rebound in the options menu. The mod needs Experimental UE4SS for Palworld (Workshop item 3625223587). Command replies go to priority.log in the mod folder. Use one copy only: if the Workshop copy is switched on, the game installs it over a manual install on the next start, and 0.5.0 warns about that in the panel.

For Saber57Draxus (57). **Depends on the Vortex gate.** If tested: report the
result. If not: "Vortex isn't supported yet, please install manually or through
the Workshop."

## Logging (F20/F23)

For lainverse (30, 31):

> Command replies are in priority.log in the mod folder, one line each now. Errors such as a failed clear or unavailable storage are named instead of being reported as success.

## Requests not in 0.5.0

- **NoNickNeeded (63):** "Noted for after 0.5.0: restricting editing to
  high-quality stands. It isn't in 0.5.0."
- **wikidnumb (86):** "Separate priority and limit mods are on the request list,
  not in 0.5.0."
- **Material Defender (78-82):** "Running the scheduler once after a menu
  closes is on the list for after 0.5.0. In 0.5.0 many quick edits are saved
  once and followed by one pass."
- **Maritisa (21), Reudo (22), Han Byeol (23):** "1 stays the highest and 5 the
  lowest, so saved values keep their meaning. The stand legend and the panel
  explain the order now."
