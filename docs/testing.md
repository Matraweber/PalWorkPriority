# Testing without restarting the game

Most of this mod was built by editing Lua, restarting Palworld, walking to a
base and opening a menu. That is roughly a two minute round trip for a one
line change, and it is why several wrong guesses survived as long as they did:
each one cost enough to check that checking got skipped.

UE4SS ships the tools to avoid nearly all of it. They are off by default.

## What is enabled

In `Mods/NativeMods/UE4SS/UE4SS-settings.ini`:

    ConsoleEnabled       = 1      ; a console window with live output
    GuiConsoleEnabled    = 1      ; the in game debug window
    GuiConsoleVisible    = 1      ; ...shown at startup

The original file is kept beside it as `UE4SS-settings.ini.backup-before-devtools`.

## Hot reload does not work here

Ctrl+R would have replaced a two minute restart with about a second. It was
tried twice and crashed the game both times.

The first crash came with a full mod list, and the log made it look like a
mod count problem: Ctrl+R does not reload the mod being worked on, it tears
down and reloads every Lua mod installed. So the mod list was cut to one with
`tools/solo.py`. It crashed again in the same place, which rules out the
explanation the first crash suggested. The problem is this mod, not its
neighbours.

Which is fair enough. Hot reload destroys the Lua state while a self
rescheduling timer is still pending against it, while hooks are registered,
and while widgets we built are still in the viewport. Surviving that is real
work with an uncertain payoff, and each attempt costs a game session to find
out. It stays off.

`tools/solo.py` is still worth running:

    python tools/solo.py on      only this mod loads
    python tools/solo.py off     everything back as it was

Not for Ctrl+R, but because starting with one mod instead of twenty seven is
a much shorter restart, which was most of the point.

`on` records mods.txt and the UE4SS settings before touching either, and `off`
restores what was recorded rather than guessing at defaults. Run it from a
working setup, and use it rather than switching mods off by hand: a blueprint
mod is a Lua mod plus a pak in `Paks/LogicMods`, and turning off only the Lua
half leaves BPModLoaderMod reaching for mod actors that never come. The script
moves the paks aside along with the mods, and puts them back.

## The console

The GUI console has a Lua box. That is the part worth having, because it
answers questions about the engine directly instead of through another edit
and another restart. The questions that cost the most time in this project
were all of this shape and all answerable in one line:

    LoadAsset("/Game/Others/InventoryItemIcon/Texture/T_itemicon_Material_Stone")
    StaticFindObject("/Game/Others/InventoryItemIcon/Texture/T_itemicon_Material_Stone.T_itemicon_Material_Stone")

If the window does not appear, `GraphicsAPI` in the same file is the thing to
change: it is set to `opengl`, and `dx11` is the other option that works.

## Ask the engine, do not reason about it

The single most useful change was not a tool. It was writing the question as
code that logs its own answer, as `icons.load_test` does: try each candidate,
print what happened, and let one run settle it.

LoadAsset is the example worth keeping. Given a package path it reports
success and loads nothing; given the full object path the asset is there by
the next line. That silent success on the wrong argument was read as a
threading problem, then a timing problem, then a caching problem, and each
wrong reading cost a restart. A test that asked all three at once cost one.

## What still needs a restart

New code, unless in solo mode. The console is worth reaching for first
either way: most of what restarts were being spent on was a question about
the engine rather than a change to the mod.

Rendering and anything involving a dedicated server need the game either way.
