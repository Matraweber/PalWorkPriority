# Testing without restarting the game

Most of this mod was built by editing Lua, restarting Palworld, walking to a
base and opening a menu. That is roughly a two minute round trip for a one
line change, and it is why several wrong guesses survived as long as they did:
each one cost enough to check that checking got skipped.

UE4SS ships the tools to avoid nearly all of it. They are off by default.

## What is enabled

In `Mods/NativeMods/UE4SS/UE4SS-settings.ini`:

    EnableHotReloadSystem = 1     ; Ctrl+R reloads every Lua mod in place
    ConsoleEnabled       = 1      ; a console window with live output
    GuiConsoleEnabled    = 1      ; the in game debug window
    GuiConsoleVisible    = 1      ; ...shown at startup

The original file is kept beside it as `UE4SS-settings.ini.backup-before-devtools`.

## The loop

1. Edit a file under `Scripts/`.
2. `tools/deploy.ps1` to copy it into the game.
3. **Ctrl+R** in the game.

The mod is torn down and loaded again from disk. No restart, no reloading a
save, no walking anywhere. `log.say` output appears in the console window as
it happens rather than having to be read out of `priority.log` afterwards.

Hot reload runs every mod's `reset` path, so anything held across a reload
has to be rebuilt. That is already true here: a world switch drops every
widget and wrapper for the same reason.

## The console

The GUI console has a Lua box. That is the part worth having, because it
answers questions about the engine directly instead of through another edit
and another restart. The questions that cost the most time in this project
were all of this shape and all answerable in one line:

    LoadAsset("/Game/Others/InventoryItemIcon/Texture/T_itemicon_Material_Stone")
    StaticFindObject("/Game/Others/InventoryItemIcon/Texture/T_itemicon_Material_Stone.T_itemicon_Material_Stone")

If the window does not appear, `GraphicsAPI` in the same file is the thing to
change: it is set to `opengl`, and `dx11` is the other option that works.

## What still needs the game

Anything about how it looks, and anything about a dedicated server. Hot reload
covers behaviour, not rendering decisions, and not two machines.
