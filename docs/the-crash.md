# The recurring crash

Four unexplained exits in one day, no Unreal dialog on most of them, nothing
in the mod's log, and each time the game simply gone. This records what is
actually known, because every session so far has started by rediscovering it.

## It is one bug, not several

Crash reports carry a `PCallStack` of module offsets. Two crashes far apart in
the day, reached from different places, share their tail exactly:

    ... 25854e 878c99 877ab4 87c8bc 94b75e 94a94a 94a113 957b65 ... 94a129 94aeb3

Different entry frames, identical crash site. That rules out "something random
in a big modded game" and makes it one identifiable fault.

## What the site is

The repeating `0x94xxxx` block is the Lua interpreter looping, and `0x87xxxx`
sits just under it. That shape is Lua calling into UE4SS's UObject access.

The fault addresses agree with each other:

    0x000000000000000a
    0x0000000000000019
    0xffffffffffffffff

Each is null, or garbage, plus a small member offset. Together with the stack
that means one thing: **a property or method read on a UObject wrapper whose
object is no longer there.**

## Why pcall does not save it

An access violation is not a Lua error. `pcall` catches Lua errors. Every call
in this mod is wrapped and it makes no difference at all to this fault, which
is why the crash arrives with no message.

`IsValid` is not a defence either, because `IsValid` is itself a member call
on the same dead pointer. Checking is the crash. The only thing that works is
never holding a wrapper long enough for its object to die, which is why
icons.lua stores names and looks the object up fresh every time.

## What is not the cause

Ruled out by evidence rather than by argument:

- **The module reloading.** It died with no reloading in the session at all.
- **The mod count.** It died with three mods enabled.
- **The panel.** It died at 111 seconds with the panel never opened.
- **The command channel.** It died while that was doing nothing but reading a
  small file once a second.

Each of those was blamed at some point, twice with confidence, and each was
wrong.

## Where to look next

Somewhere a wrapper is kept across frames and read later. The candidates are
anything held in a module level table between ticks: pals, camps, containers,
work objects, widgets. The scheduler holds the most of these and runs on its
own timer, which fits a crash that arrives without anyone touching the UI.

The way to find it is not to guess. Add the object's identity to the log at
the point it is stored and the point it is read, run until it crashes, and
read which one was last touched.

## 21 August, evening: two confirmed sites

The breadcrumb caught it twice, with the mark still in flight and the dump
carrying the same second:

| time     | breadcrumb                      | address              |
|----------|---------------------------------|----------------------|
| 21:04:11 | `camp: camp_pals`               | `0xffffffffffffffff` |
| 21:07:07 | `camp: chest sweep, scope camp` | `0x08`               |

Both crashed on the first pass after a base camp streamed in: 37s after load
in one run, and 88s in the other, seconds after walking into the base. A pass
that finds no camp returns before either site and never crashes, which is why
the mod can idle in the wild indefinitely.

### What this rules out

The panel, the open path, and the item probe are all cleared: the 21:04 crash
happened with the panel never opened, and the 20:53 crash came before the
probe had run at all. `base_camps` hands back objects its own sweep just
produced, the safe wrapper age. `ui.refresh` returns before any engine call
while the stand has never been opened.

### What it does not show

Two different sites means it is not one bad call. Both are the heavy
enumeration loops, and the fault addresses (`0x08`, `0x0c`, `-1`) are pointer
reads rather than wrong Lua values.

`valid()` was the obvious shared suspect, since pcall cannot catch an access
violation and so the check is the crash on a stale pointer. But PalBaseInfoGrid
uses a byte-for-byte identical helper and is stable, so being identical to a
working mod, it is not on its own the difference. Worth keeping in view rather
than acting on.

One real difference from that mod: it reaches the roster by property reads,
`WorkerDirector` then `CharacterContainer` then `SlotArray`, where this mod
calls `GetCharacterHandleSlots()` with an out-table. Not yet tested.

### The question never asked

Three sessions of hunting have all assumed the pass is at fault without ever
checking. UE4SS's own dumps go back to 10 August and there are 29 mods
installed. `!pwp off` makes `run_pass` return before both sites while leaving
everything else running, so one run answers it. Convicts or exonerates, and
either is worth more than a fourth theory.

## The cause, named by UE4SS itself

```
21:12:58.7905 [UE4SS.EngineTick.LuaModImpl] Hook threw exception:
  "[Lua::Registry::get_function_ref] Ref was not function
   No traceback", removing hook!
21:13:01.4499 [FCallbackGarbageCollector] Freed invalid callbacks!
```

One millisecond after a pass completed, UE4SS threw away the engine tick hook
because a Lua registry reference it was holding was no longer a function. The
mod went silent without the game dying, which is why the command channel
stopped answering.

This is one bug with two endings. UE4SS keeps a registry reference to anything
scheduled. When it notices a reference has gone bad it removes the hook and the
mod goes quiet. When it does not notice, it calls through the reference and the
process dies, which is the access violation.

That reading accounts for every fact collected today, including the one that
made no sense: the crash site kept moving between `camp_pals` and the chest
sweep because it was never the site. Those are simply the two places the mod
spends the most time, so they are the most likely to be executing when a
reference is called. The fault addresses were pointer-sized (`0x08`, `0x0c`,
`-1`) and the stack recursed inside UE4SS's own Lua layer rather than in
anything to do with pals or chests.

### The fix

Two callbacks were being minted fresh every cycle: the pass every ten seconds,
and the UI body every single second for the whole session. Both are now named
functions defined once, so there is one reference each that lives as long as
the mod and nothing to collect.

The remaining anonymous callbacks are one-shots, scheduled once at load or on
world entry. They are a smaller version of the same risk and are worth hoisting
too if this recurs.

### Two theories to retire

`valid()` was not it, and neither was the container sweep. Both looked strong
and both were argued from reading rather than from evidence. What actually
found it was a log message that had been written into UE4SS.log every time this
happened, in a file already open in front of me.


## The fix that was not enough, and the one that follows from evidence

Hoisting the two recurring callbacks into named functions did not stop it. A
clean session with the fix in, no auto reload, one mod start:

```
21:22:32.18 [UE4SS.EngineTick.LuaModImpl] Hook threw exception:
  "[Lua::Registry::get_function_ref] Ref was not function", removing hook!
```

Naming the function stops a closure being allocated. It does not stop the
reference churn, because `ExecuteWithDelay` registers a new Lua reference on
every call, named callback or not. Rescheduling from inside the callback means
one new reference per iteration forever: one a second for the UI loop, one
every ten seconds for the pass.

`LoopAsync(ms, fn)` registers once and repeats, returning true to stop. One
reference for the life of the loop. Every stable mod in this install uses it
for repeating work, and none of them chains `ExecuteWithDelay`. Both loops now
use it.

The `ExecuteWithDelay` calls that remain are one-shots on world entry, which is
the shape the stable mods use too. The icon pump does chain, but it stops when
its queue empties rather than running forever, and it is dormant while the
panel is shut, which covers the sessions that crashed without it ever opening.

### Method note

Two theories were argued from reading the mod's own code and both were wrong.
Both answers came from reading something else: UE4SS's log for the cause, and
the other mods on disk for the shape. The mod's own source was the least
useful thing to stare at, because the bug was never in what it did, only in how
it asked to be called back.


## LoopAsync fixed the hook removal. Something else is still there.

First clean run with the loops registered once: 21:33:20 to 21:39:07, five
minutes and forty-seven seconds, and **not one** `Ref was not function` in the
whole log. The two runs before it lost the engine tick after 72 and 85 seconds.
That bug is fixed, and the reference churn was the cause.

It still crashed, and the second fault is a different animal:

| time     | breadcrumb                          | address              |
|----------|-------------------------------------|----------------------|
| 21:18:28 | `pals: slot 5 name and species`     | `0x656c676774a5`     |
| 21:39:03 | `pals: slot 5 name and species`     | `0x251eba9a7e9`      |

Both at **slot 5**, which is a consistent pal rather than a race that lands
anywhere. Neither address is a small offset from null the way `0x08` and `0x0c`
were; these are heap-sized pointers, so this reads as a real object being used
after it has gone, not a Lua reference that stopped being a function.

The first address decodes to ASCII, which is worth remembering: something read
a string where a pointer was expected.

### Why that mark was not good enough

It covered four calls: `GetNickname`, `GetCharacterID`, and the two identity
key readers, which take their fields off the id struct rather than calling
anything on the parameter. Naming a line instead of a call is the guessing this
whole apparatus exists to stop. Split into four.


## The pass, proven rather than argued

The first controlled experiment of the investigation, and it should have been
the first thing done rather than the tenth.

`pwp off` makes `run_pass` return before it schedules its callback, and leaves
everything else running. Sent over the command channel at 21:58:34:

| condition                          | result                          |
|------------------------------------|---------------------------------|
| pass enabled                       | tick lost at 72s, 84s, 96s, 192s |
| pass disabled, all else running    | **480s, never lost**            |

Checked that the rest really was running rather than quietly dead, which would
have made the result meaningless: at 22:07:15, ten minutes in, the mod answered
a status request with two camps loaded, the demand hook installed and 328
pulses seen, authority held, and the UI loop clearly alive to have answered at
all. Only the pass was missing.

So the failing callback belongs to the pass. That also retires, on evidence
rather than argument, the idea that the UI loop's once-a-second scheduling was
the churn that mattered.

### What changed as a result

`GetCharacterHandleSlots(raw)` hands a Lua table to the engine as an out
parameter for it to write into. It is the only call of that kind in the pass
and the most unusual thing this mod asks of UE4SS. PalBaseInfoGrid gets the
same roster through `WorkerDirector` then `CharacterContainer` then
`SlotArray`, indexing the array directly, and does not lose its tick.

`camp_pals` now takes the property route, keeping the old call only for a
build where the property is absent, so an empty base is never reported when
the roster is simply reached a different way.

Untested as of writing. It is one change, motivated by the one experiment that
controlled for anything, and the previous four theories were each stated with
more confidence than a single clean run could carry.


## Where it stands, 22:26

Longest clean run of the investigation by a wide margin: ten minutes, sixty
three passes, no crash and no `Ref was not function`, still running when the
watch expired.

| run                                  | lasted            |
|--------------------------------------|-------------------|
| baseline, various                    | 64s to ~6 min     |
| property route only                  | 64s, died in sweep |
| property route + cached chest counts | **600s+, alive**  |

### What cannot be claimed from it

Two changes went in together, so this does not attribute the improvement to
either one. The honest reading of the arithmetic: caching cut the sweeps by
three, so a purely rate-driven fault should have moved 64s out to roughly 190s.
It went past 600. That is better than a rate reduction alone predicts, which
weakly suggests the property route contributed as well, and weakly is the right
word for one sample.

It is also one sample. The claim made at 21:39 rested on one sample and was
wrong within the hour.

### If it comes back in the sweep

The rate is reduced, not the fault. The real fix is to stop reading
`ItemId.StaticId` field by field out of an array the game reallocates while
pals deposit into it, and take each container's slots in one go instead.
