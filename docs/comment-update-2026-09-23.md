# Public report update — September 23, 2026

Read the logged-in Chrome [Steam comments page](https://steamcommunity.com/sharedfiles/filedetails/comments/3786408856). It shows **62 comments**, six more than the September 15 review. All six newer entries and the September 15 boundary were read. Dates below are the page's CEST timestamps. This is a delta review, not a new full census of older comments or Nexus. No replies or moderation performed. The public reports do not identify their loaded package hashes; do not assign them to the unpublished candidate.

| Author / date | Report | Next verification / disposition |
|---|---|---|
| Danodan, Sep 21 04:09 | Clunky behavior causes more frustration than benefit. | General usability corroboration, not a distinct reproducible cause. Prioritize ordinary mouse/keyboard workflows and measured latency. |
| Erbse, Sep 20 19:49 | Work settings do not survive restart; unsure when it began. | Persistence blocker. Values unspecified: do not assume this is only the old X serialization defect. Verify numeric and X changes, durable identity, save receipt and loaded values across a real restart. |
| like, Sep 19 10:10 | Configured priorities reset to defaults every login; otherwise no problems. | Same persistence gate; separate reproduction from X-only reports. Existing candidate tests are not proof that this player's cause is resolved. |
| Mithandil de Melkin, Sep 19 09:44 | Requests Flame Organs, Venom Glands and Pal-specific materials such as Gummos Leaf in limits. | Catalogue request plus producer-control gate. A visible item is not evidence of safe output-specific control. Do not create a misleading rule by merely adding names or disabling a whole suitability. |
| Okami_sama, Sep 18 11:20 | Adding tasks in the panel stopped other work across the base; mine allowed only one Pal. | Reproduce with exact rules, staffing mode, worker cap, candidate suitability and actual assignments. Legacy whole-work limits and staffing allocation are hypotheses, not an established explanation. |
| Okami_sama, Sep 18 10:32 | Open panel cannot be closed except by restarting the game. | Input/lifecycle blocker, corroborates earlier stuck-panel reports. September 23 candidate closure passed a small native sample, but focused-field one-Escape cancellation and automated mouse hit-testing still fail acceptance. |

Local evidence: [monitor retest](monitor-retest-2026-09-23.md). Raw six-entry accessibility excerpt: `test-results/steam-comment-delta-20260923.txt`. The candidate is not release-ready; none of these comments is marked resolved from source inspection alone.
