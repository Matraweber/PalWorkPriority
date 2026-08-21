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

## Reloading without restarting

UE4SS has two of these and only one is worth using.

**Ctrl+R reloads every Lua mod installed.** Twenty seven of them here, most
belonging to other people. It was tried twice and crashed the game both times,
including with the list cut to three, so it stays off.

**Auto reloading watches one mod's Scripts directory**, which is the one that
matches how anyone would actually want to work:

    EnableAutoReloadingLuaMods = 1

    ; The reload triggers when any file is edited or a new file is added
    ; to the 'Scripts' directory.

Deploy a file and the mod reloads itself. No keypress, nothing else torn down.
This setting was sitting at 0 in the shipped configuration and went unnoticed
for a long time while restarts were being spent instead, which is worth
remembering the next time something feels harder than it should be: read the
settings file before building a way around it.

It uses the same machinery underneath as Ctrl+R, so it is not risk free. What
it does not do is take twenty six other mods with it.

## Driving the panel from outside

`tools/remote.py` writes instructions to a file the mod reads once a second:

    python tools/remote.py open
    python tools/remote.py "mode item,snap"
    python tools/remote.py close

The file matters rather than being an implementation detail: while the panel
holds the input mode UE4SS never sees a key press, which is exactly when the
panel is the thing being worked on.

`snap` runs `shot showui`, so the game photographs itself and the png can be
read straight off disk. That removes the last step that needed a person, since
alt tabbing to take a screenshot is itself what stops the game ticking.

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
