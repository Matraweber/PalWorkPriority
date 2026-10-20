---
date: 2026-10-17
tags: [panel, input, testing]
status: evidence
---
# G3: Escape, photo mode, death while editing, 2026-10-17

Related: [g3-panel-2026-10-17](g3-panel-2026-10-17.md) · [g3-layout-2026-10-17](g3-layout-2026-10-17.md) · [editor-escape-2026-09-23](editor-escape-2026-09-23.md)

Singleplayer test world, build 34c95ad (0.5.0-rc1), Monitoring Stand +
Production Limits panel, amount editor opened on the Wood rule (30,000). Keys
and clicks through computer use, the game focused with `pwp-focus` before each
batch.

## A. Escape while editing: PASS (12:52)

Editor open ("Set Wood: whole number; confirm saves, Esc cancels") -> Esc
cancelled the draft (30,000 unchanged) -> Esc closed only Production Limits ->
Esc closed the stand -> Esc / Esc opened and closed the pause menu -> Tab opened
the inventory 1.2 s later. No grey box, no stale editor, no lost input.

An earlier attempt (12:51) had not opened the editor (the click landed with no
hover first; a real mouse always hovers) and after the same Esc chain one Tab
1.2 s after closing the pause menu did not open the inventory. Not reproduced:
the vanilla control (pause open/close, Tab after 1.2 s, panel never used) and
the repeat of the full chain with the editor open both opened the inventory.
Recorded as a single unexplained miss.

## B. Photo mode while editing: PASS (12:53-12:55)

- Editor open, key 4 (Command Pal wheel): the digit went into the field
  ("300004"), the wheel stayed closed. Esc discarded it: 30,000 unchanged.
- Panel open without editor, key 4: wheel stays closed (the panel's input
  route blocks it, as on 2026-09-24).
- Panel and stand closed, key 4 -> Photo Mode: photo mode shows no grey box,
  with the HUD shown, hidden (F) and restored (F). Esc returned to play.
- Stand and panel reopened normally afterwards, rules unchanged.

Not covered: photo mode from a Pal bed (Zekrom144's report).

## C. Death while editing: RUN 14:13, one finding

The game has a real kill: `APalPlayerController:SelfKillPlayer()` (what
dkoz/AdminCommands' `!slay` calls). With the editor open on Wood ("Set Wood:
whole number; confirm saves, Esc cancels", field 30000), a temporary helper
called it at 14:13:17:

- The DEFEAT screen appeared with the respawn timer and Respawn button. The
  game closed the Monitoring Stand, but **our Production Limits panel and the
  open editor stayed on top of the death screen** (overlay rebuilt at 14:13:25
  and 14:13:30). Finding: the panel does not close itself on death.
- Not stuck: Esc cancelled the edit (30,000 unchanged), a second Esc closed
  the panel, leaving the clean DEFEAT screen. Respawn -> map -> base -> Yes
  worked.
- After respawn: Tab opened and closed the inventory, Alt+F1 opened the panel
  (14:14:38, 21 of 21 widgets, rules Wood 30,000 / Stone 35,000), Esc closed
  it, back to play. Rules and priorities diff equal to the snapshots; 0 ERROR /
  WARN; helper restored (cmp equal).

Verdict: no lost input, no grey box, nothing stuck, but the editor stays open
over the death screen until Esc. Proposed fix: close Production Limits (and
cancel any draft) when the local player dies.

### Fix and retest: PASS (14:18-14:22)

`Scripts/deathwatch.lua`: while the panel is open, the 16 ms UI loop checks
the local player's HP every 0.25 s through properties only (Pawn ->
CharacterParameterComponent -> IndividualParameter -> SaveParameter.HP.Value,
verified live equal to GetHP). A positive 0 cancels any draft and closes the
panel; an unreadable chain changes nothing. Test `tests/test_deathwatch.lua`
(alive, unknown chain, unreadable HP, dead with and without a draft,
throttle, closed panel); negative control: with the 0-HP check broken it
fails. 218 scripts pass. Deployed (hashes equal), restarted, 0.5.0-rc1 loaded
14:19:11.

Retest with a real unsaved draft (the user asked for a number other than the
saved 30000): panel opened without a stand (Alt+F1), editor on Wood, field
cleared and **12345 typed, not confirmed**, then SelfKillPlayer at 14:21:02.
Same second: `Production Limits closed: the player died; the unsaved limit edit
was discarded`. The DEFEAT screen showed no panel and no editor. caps.txt kept
Wood 30000 (12345 nowhere). Respawn at the base, Tab inventory, Alt+F1 shows
Wood 30,000 / Stone 35,000, Esc closes. 0 ERROR / WARN; rules and priorities
equal to the snapshots; helper restored.

**Gate met:** Escape, photo mode and death while editing each leave no grey box,
no lost input and no stale editor.

### Earlier attempts (kept for the record)

With the editor open the character cannot move, so death needs an outside
attacker. Tried the UE4SS console route (user-approved, test world): enabled
`ConsoleEnablerMod` and `CheatManagerEnablerMod` (bundled, normally off) and
restarted. Neither F10 nor ~ opened the console in Palworld (the console object
was created and the keys mapped, per UE4SS.log). Calling
`CheatManager:Summon('/Game/Pal/Blueprint/Character/Monster/PalActorBP/ElecPanda/BP_ElecPanda_BOSS.BP_ElecPanda_BOSS_C')`
from a temporary Lua helper (the lazily re-read `stand_lifecycle_probe.lua`,
restored afterwards) with the editor open did spawn a Grizzbolt model at
13:49:27, but it stood still: no AI, no attack, HP 1250/1250 for 25 s.
Class paths of loaded Pals follow
`/Game/Pal/Blueprint/Character/Monster/PalActorBP/<Name>/BP_<Name>.BP_<Name>_C`.
Cleanup: editor cancelled (30,000), helper file restored (cmp equal), both
console mods back to `: 0`. The inert Grizzbolt stays until the next restart.

Second attempt, after the user pointed at the wiki (13:58-14:01). The modding
wiki has no hostility recipe, but the open-source dkoz/AdminCommands mod
spawns working Pals: `PalUtility:GetNPCManager(pc):SpawnNPCForServer({
ControllerClass = mgr.NPCAIControllerBaseClass, CharacterID, Level, Location,
Yaw, Squad }, nil)`, then activates the AI (`libs/palai.lua`: SetActiveAI,
SetupAI_BP, StartDefaultAIAction, StartCombatMode, sensor and damage-reaction
setup). The same, from the temporary helper with the editor open, spawned a
level 50 `BOSS_ElecPanda` and logged "activated", but it never attacked:
Grizzbolt is neutral in the wild, and an 8-round burst at the large Grizzbolt
in front hit the inert one from the first attempt. HP stayed 1250/1250.

Third attempt: the wiki's Blueprint example "Modifying a Player's HP"
(`CharacterParameterComponent:SetHP(FixedPoint64)` then
`OnRep_IndividualParameter`). Set to 0 with the editor open: HP went 1250000 to
0 and the character crouched, but no death was triggered, not with the panel
open and not after closing editor, panel and stand. The panel and editor stayed
consistent and usable throughout (overlay rebuilt 14:00:44, no errors). HP set
back to 1250000 at 14:01:29; helper file restored (cmp equal); rules unchanged.

So death while editing was still not covered at that point (it was at 14:13,
see section C). A real death needs actual damage:
an aggressive species provoked or naturally hostile near a stand, with the user
steering, or a Summoning Altar boss.

Fourth attempt (14:09-14:12, user suggested many aggressive Pals because the
level 100 base Pals would kill them): six `PREDATOR_` Pals (the always-hostile
variants: Manticore_Dark, Ronin_Dark, 2x Garm, Gorilla, DarkScorpion; IDs from
AdminCommands' enums/paldata.lua) at level 60, spawned and AI-activated in a
ring 2.5-4.5 m around the player with the editor open. All six were at 0 HP
within about 25 s, killed by the base Pals; the player took no damage. Repeat
with the player's HP first set to 1 (SetHP 1000) and the ring at 1.5-2.3 m:
the predators (labels "Lv60 Blazehowl Noct", "Lv60 Bushi Noct", "Direhowl")
fought the base Pals, the player's HP regenerated from 1 upwards without a
hit. HP restored to 1250000 at 14:12; all predators dead; editor cancelled
(30,000); helper restored (cmp equal); rules unchanged; 0 ERROR / WARN.

Conclusion: at a base defended by level 100 Pals, staged hostiles never reach
the player, so death while editing needs a stand outside such a base (a
fresh test base) or the user steering. (Superseded at 14:13: SelfKillPlayer
gave a real death; see the top of section C.)

Cleanup 14:06-14:08 (user asked): a read-only listing found three
`BP_ElecPanda_BOSS_C` actors: level 50 with individual data and no controller
(the NPC spawn), the user's level 24 base Grizzbolt (BaseCamp AI controller),
and one with no individual data and no controller (the `summon` model). Only
that last one was removed (`K2_DestroyActor`, filter: no individual data AND
no controller). A second listing showed only the user's Grizzbolt: the level 50
spawn had already been unloaded by the game. Helper file restored each time.

## Finding: a limit stepped without a deliberate input

At 13:44:22, during an Esc chain that started right after a focus click on the
title bar (the panel had just been rebuilt, "overlay: host ... fresh root" at
13:44:17), the log shows `Lumbering Wood limit requested: 50000`: the Wood rule
went from 30000 to the next ladder rung. Only Enter, the right arrow and the
gamepad A button raise a selected row (main.lua RETURN / RIGHT_ARROW, pad.lua
FaceButton_Bottom); none was sent by the test. Sunshine was running, so a
Moonlight virtual gamepad is a candidate, unproven. Restored with
`!pwp limit Lumbering Wood 30000` at 13:48; rules diff equal to the snapshot.
Open question for 0.5.0: a raise or lower on Enter/A/arrow changes a saved
limit with no confirmation, only an announcement.

0 ERROR / WARN in priority.log 12:48-12:59.

## Dedicated server updated (2026-10-19 17:24-17:28)

GPortal "RAM" through the browser panel, 0 players online: `Scripts` renamed to
`Scripts-before-3daac01` (backup of 34c95ad), `pwp-server-scripts-3daac01.zip`
(git archive of 3daac01, 58 Lua files, sha256 6b04ae61...) uploaded (402.7 KiB)
and unzipped in place. The new `Scripts` holds 58 files; deathwatch.lua,
main.lua, stations.lua and scheduler.lua match the commit's sizes. Panel restart
17:27:54; the server log shows PWP_READY at 17:28:06 (authority, settings
available), no PalWorkPriority error or warning. deathwatch only acts where a
viewport exists, so on the headless server it never runs.
