# New public reports — September 15, 2026

Read from the logged-in Chrome pages on September 15. Steam now shows **56 comments**, Nexus **15 comments and 1 bug**. Against the September 11 ledger's 52+13 comments, this adds six comment entries (including one author status post) and one bug report: **71 comments plus 1 bug tracked historically**. This is a delta review, not a claim that every old entry was re-read today. No replies, moderation or publication performed.

| Source / ID | Author / visible date | New information | Disposition |
|---|---|---|---|
| [Steam 569297443349502462](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_569297443349502462) | poiman, 7 hours ago at read | Icelyn ignores cooling 1 for priority-5 work; fishing pools ignored despite Handiwork 1. | F11: explicit cooling and fishing reproduction cases. Neither permissions nor UI numbers establish actual job selection. |
| [Steam 569297443349488654](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_569297443349488654) | Erbse, 12 hours ago at read | Deck needed mapped left/right mouse clicks; asks about controller compatibility. | F18: test native focus/navigation/activation on Deck; desktop keyboard success is insufficient. |
| [Steam 569297443349364937](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_569297443349364937) | tigerpow100, Sep 13 20:21 | Cannot change priorities on Steam Deck. | Same input gate; not a separate confirmed cause. |
| [Steam 569297137117173393](https://steamcommunity.com/sharedfiles/filedetails/?id=3786408856#comment_569297137117173393) | Matraweber, Sep 12 22:27 | Author says repairs are underway. | Context, not defect evidence. |
| [Nexus post 175442289](https://www.nexusmods.com/palworld/mods/5376?tab=posts) | DreamFun, Sep 12 10:35 displayed locally | X alone resets after loading; other priorities persist. | F01: strongly matches the confirmed 0.4.1 serialization defect. Candidate has round-trip regression coverage; public build remains 0.4.1. |
| [Nexus post 175615590](https://www.nexusmods.com/palworld/mods/5376?tab=posts) | DSFddaaaa, Sep 15 07:29 displayed locally | Requests Transport default 5; reports interruption of cooking/crafting/generation. | F11/F18: preserve user-approved vanilla checked=1/unchecked=X default; investigate actual scheduling rather than silently changing preferences. |
| [Nexus bug 1133489](https://www.nexusmods.com/palworld/mods/5376?tab=bugs) | DarkWyrmReaper, Sep 14 | Add item/search all items aborts to desktop; suspects recently added cosmetic mod 5049. | New compatibility reproduction under F16/F17/catalogue lifecycle. Suspected interaction is unconfirmed. Preserve crash trace, versions, item IDs and exact operation before attributing it. |

The linked mod is [Cosmetic Outfits](https://www.nexusmods.com/palworld/mods/5049), described as craftable NPC outfits for the Antique Wardrobe. No installation or reproduction with that mod was performed during the comment read. Browser Nexus data was fresher than the web extraction (which showed 14 posts), so the live browser count is used.

Today's game visibly reports **1.0.5.102999**, newer than the September 14 icon test's 1.0.4.102642. Treat this as a new compatibility environment; do not transfer earlier timing or acceptance claims unchanged.
