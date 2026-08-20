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

## Hot reload, and how to make it usable

Ctrl+R would replace a two minute restart with about a second. Tried plainly,
it crashed the game, and the log said why: it does not reload the mod being
worked on, it tears down and reloads **every** Lua mod installed. Twenty seven
here, most belonging to other people.

There is no way to scope it to one mod. There is a way to be the only mod:

    python tools/solo.py on      only this mod loads, Ctrl+R works
    python tools/solo.py off     everything back as it was

`on` records mods.txt and the UE4SS settings before touching either, and `off`
restores what was recorded rather than guessing at defaults. In solo mode the
loop is deploy, Ctrl+R, look. Out of it, hot reload stays off, because with a
full mod list that key is a crash.

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
