# Native stand reconstruction boundary — September 24, 2026

## Current implementation

The live class/function-name probe establishes that this game's Monitoring
Stand inherits directly from UUserWidget and owns Construct/Destruct overrides.
The mod now observes those exact Blueprint events. A native Construct advances
a stand-only input generation and wakes discovery. Mouse, numeric and controller
intents captured before that boundary cannot match their old receiver tokens.
Fresh drawing rearms the surviving current tree without duplicating labels.

Destruct is counted but does not revoke input: deferred cleanup must not cancel
new edits after a subsequent construction. No callback retains an engine wrapper
or treats an instance name as proof of object lifetime. No shared UI epoch or
controller state is cleared by this boundary. Exact class and armed-world checks
reject unrelated callbacks. A newly constructed hidden stand can conservatively
cancel queued stand input; it cannot redirect it to another Pal.

## Rejected implementation route

The local modding kit's PalUserWidgetStackableUI and CommonUI declarations do
not describe this menu's runtime inheritance. Initial native PID34460 and the
bounded diagnostic restart PID27820 showed GetId was unavailable (TrivialObject),
so the GUID-gated guard stayed inactive and registered no hooks. No name-only
fallback was enabled. The inapplicable Pal/CommonUI state machine was removed.
Earlier stand-close test outputs document that experiment, not current acceptance.

The explicit `pwp panel standlife` diagnostic reports bounded class and function
names only, never function parameter/property memory. It stops at the named
CoreUObject.Object class. It is manual, not a recurring scan. The probe uses
loadfile because UE4SS caches require chunks even after package.loaded is cleared.
It causes diagnostic lookup work and must stay outside performance recordings.

## Current offline evidence

All49 Lua modules compile; all66 regression scripts pass, including65 stand
checks. New regressions cover native reconstruction between close/reopen without
row binds or a visibility poll, mouse/number/controller cancellation, preservation
of unrelated queued UI work, fresh-token rearming, no duplicate labels, late
Destruct, waking a polled-closed stand and wrong-class/unreadable/old-session
callbacks. See test-results/stand-reconstruction-all-20260924.txt and
stand-reconstruction-checker-20260924.txt. Source and installed test pak contracts
are unchanged (WorkRules3, StandInput2).

## Acceptance boundary

Native registration alone is insufficient. Same-process close/reopen event counts
and usable restored priorities are required. A pure hide/show that neither
constructs Slate nor rebinds rows remains a separate unverified route. Do not
claim full lifecycle coverage, multiplayer acceptance or stutter-free performance.
Settings backup starts at generation184. No publication or commit performed.

## Same-process native reopen acceptance — 19:40–19:41

Completed two real Escape-close / held-V-open cycles in PID15092 without a
restart. The existing checked AHK helper now has --open-only, reusing its 850ms
V hold; a short Sky key tap was insufficient. The original desktop helper was
backed up before replacement, and --check passed before running it.

| Observation | Construct | Destruct | Stand generation |
| --- | ---: | ---: | ---: |
| Initial | 0 | 0 | 1 |
| First reopen, 19:40:54 | 1 | 1 | 2 |
| Second reopen, 19:41:32 | 2 | 2 | 3 |

Both reopened grids visibly restored priority numbers with no duplicate labels
observed. Hooks remained registered without errors. Saved priorities, caps and
config are byte-identical to the pre-change backup. Native receipts are
test-results/stand-reconstruction-reopen1-20260924.txt and
test-results/stand-reconstruction-reopen2-20260924.txt. This closes the ordinary
Escape/V reconstruction-event acceptance gap. Stale queued mutation rejection
is covered by regression tests, not a native race injection in these cycles;
pure hide/show without reconstruction and other lifecycle routes remain open.

## Initial native check and independent review

The final checked build was installed and restarted through the user's AHK
helper: PID15092, world/stand ready at 18:51:46. At 18:54:51 both exact native
hooks registered successfully with no registration errors; constructs/destructs
were still 0/0. The initial opening predates hook arming, so these zero counters
do not verify a reopen. Priorities were visibly rendered in the stand. Receipt:
test-results/stand-reconstruction-initial-native-20260924.txt.

All49 installed Lua files match source. Priorities, caps and external config
remain byte-identical to the pre-change backup. Mill independently reviewed the
final Construct/Destruct implementation, found no blocking issue in that bounded
scope, and passed stand integration, main integration and session tests. The
initial check alone did not establish native reconstruction acceptance; the two
later cycles above supply that evidence for the normal Escape/V route. Neither
check establishes broader performance claims.
