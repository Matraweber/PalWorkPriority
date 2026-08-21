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
