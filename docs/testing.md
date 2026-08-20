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

## Hot reload is off, deliberately

`EnableHotReloadSystem` was tried and turned back off. Ctrl+R does not reload
the mod you are working on. It tears down and reloads **every** Lua mod
installed, which on this machine is twenty nine of them, and that crashed the
game outright.

It is not a per mod tool and there is no way to scope it to one. With a
single mod installed it might be worth the risk. Here it is not, and the risk
falls on a game session rather than on the edit.

## The console

The GUI console has a Lua box. That is the part worth having, because it
answers questions about the engine directly instead of through another edit
and another restart. The questions that cost the most time in this project
were all of this shape and all answerable in one line:

    LoadAsset("/Game/Others/InventoryItemIcon/Texture/T_itemicon_Material_Stone")
    StaticFindObject("/Game/Others/InventoryItemIcon/Texture/T_itemicon_Material_Stone.T_itemicon_Material_Stone")

If the window does not appear, `GraphicsAPI` in the same file is the thing to
change: it is set to `opengl`, and `dx11` is the other option that works.

## What still needs a restart

New code. Without hot reload there is no way around that, so the console is
worth using first: most of what a restart was being spent on was a question
about the engine, not a change to the mod, and a question can be asked
directly.

Rendering and anything involving a dedicated server need the game either way.
