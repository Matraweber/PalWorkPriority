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
