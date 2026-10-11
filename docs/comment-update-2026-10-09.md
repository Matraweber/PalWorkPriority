# Public report census — October 9, 2026

Read both pages of all **70 Steam comments**, both pages of all **17 Nexus
comments/replies**, and expanded both **Nexus bug reports** in logged-in Chrome.
No messages, replies, moderation or publication performed. Nexus still displays
0.4.1, updated August 28. These public reports are not evidence against a loaded
unpublished candidate unless reproduced with its identity recorded.

Sources: [Steam comments](https://steamcommunity.com/sharedfiles/filedetails/comments/3786408856),
[Nexus posts](https://www.nexusmods.com/palworld/mods/5376?tab=posts),
[Nexus bugs](https://www.nexusmods.com/palworld/mods/5376?tab=bugs).
The browser census, rather than the older web cache, is the current count.

## Delta against the September 23 Steam and September 15 Nexus records

| Source / ID | Author / displayed date | Report and disposition |
|---|---|---|
| Steam 591816835949675692 | Material Defender, Sep29 | Follow-up rationale for running scheduling once after closing a UI. Treat as a performance suggestion, not proof that repeated passes cause native crashes. |
| Steam 591816835949675621 | Material Defender, Sep29 | Apply deferred scheduling to stand edits too. Evaluate against bounded latency, disconnects and unexpected UI teardown; do not depend on a close event to persist edits. |
| Steam 591816596100673992 | Material Defender, Sep28 | Requests 1↔X cycling wraparound. Six-state cycling is now implemented with regression coverage; native mixed-input/controller acceptance remains open. |
| Steam 591816596100673837 | Material Defender, Sep28 | Follow-up: leave chat commands immediate while coalescing UI changes. Same scheduling/latency gate. |
| Steam 591816596100673758 | Material Defender, Sep28 | Suggests a changed flag and a single pass at panel close. Assess existing deferred/coalesced paths before adding another scheduler trigger. |
| Steam 591816596100670438 | Extramrdo, Sep28 | Requests left/right-click reminder. UI discoverability follow-up. |
| Steam 591816596100670402 | Extramrdo, Sep28 | Requests Alt-F1/F2/F3 hints and priority-order explanation; reports stuck panel blocking menus and a second panel after Alt-F1. Existing candidate legend is source evidence only; duplicate/lifecycle reproduction remains a gate. |
| Steam 591816302688012535 | Two Bob Games, Sep23 | Transport X returns to1 after restart; priorities appear ignored until edited again. Separate serialization/recovery from scheduler startup application; numeric/X reload and actual behavior must both pass. |
| Nexus 176018241 | wikidnumb, Sep22 | Requests independent priority/production-limit components. Optional configuration/design work; avoid creating conflicting double installations. |
| Nexus 175824555 | HelpImStupid0, Sep19 local display | Transport5 still dominates primary work1. Add to actual-assignment/output reproduction; fence membership is insufficient. |
| Nexus bug “Priority list not saving” | johndujo, Sep18 expanded local display | Previous selections disappear on reload. Values unspecified; not assumed to be only X. Persistence/startup gate. |

Previously tracked Nexus “Crash To Desktop” (DarkWyrmReaper, Sep14) still has
no replies and reports Search all/Add aborting after adding Cosmetic Outfits
mod5049. The claimed interaction remains a hypothesis, not a proven cause.

## Coverage and next checks

The original [65-comment ledger](comment-ledger-2026-09-11.md),
[September15 delta](comment-update-2026-09-15.md),
[September23 delta](comment-update-2026-09-23.md), and this delta account for
all87current comments plus2bug reports. Earlier substantive reports were reread:
X/numeric reset, actual priority failures, research/ranch/cooling/fishing,
work-type limits, stutter, UI lifecycle/layout, unmodded-client edits,
installation/runtime/Vortex and controller requests remain mapped to the
[current release gates](release-gates-2026-10-09.md).

Refreshing the census closes the reading task only, not the reported defects.
No public issue was marked fixed from this review.
