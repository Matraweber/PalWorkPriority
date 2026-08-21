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


## Auto reload is off again, and why

`EnableAutoReloadingLuaMods = 1` was turned on earlier today as the answer to
restarting the game for every change. It is not, and the evidence arrived the
same evening.

At 21:17:11 it restarted **five** mods, not one. That is the Ctrl+R behaviour
already documented here as unusable, reached by a different door. The claim
that this setting reloads only the changed mod does not survive contact with
its own log.

It also destroys the evidence. UE4SS.log is recreated on reload, so the
`Ref was not function` line that finally named the crash cause was gone from
the file within five minutes of being written. A diagnostic that erases the
diagnosis is worse than no diagnostic.

And it silently invalidates tests. The run that was meant to prove the callback
fix had the fix swapped in underneath it mid-session, twice, so it tested the
fix plus two mod reloads and could not tell them apart.

So: a full restart for every runtime change, and no deploys while a test run is
in progress. Slower, and the only way a result means anything.

`tools/remote.py` still avoids restarts for anything that is not a code change:
opening the panel, switching screens, running any of the mod's own commands
through `pwp <command>`, and taking screenshots.

## The headless rig (22 August)

The dedicated server mirrors the client's mod layout, boots straight into a
copy of the singleplayer world, and runs the entire mod with authority and
nobody at a keyboard. Two camps and fourteen pals stream in with zero players
connected, the demand hook pulses, and the command channel answers.

    python tools/server.py start        boot, wait for the mod to come up
    python tools/server.py stop
    python tools/server.py status
    python tools/server.py freshworld   re-copy the singleplayer world

Every tool takes --server: remote.py, stress.py, watch.py. The world is a
copy; the real singleplayer save is never written.

The client is only needed for what only it has: the panel, the stand menu,
and the blueprint UI mods that BPModLoader loads client-side. Panel code
hot-reloads over the channel, so client sessions are for looking, not for
restarting.

## What the stress runs established (21-22 August)

| build | environment | result |
|---|---|---|
| old (LoopAsync) | client, 6 mods | dead in 20-25 passes, five times |
| old (LoopAsync) | server, 2 mods | survived 300s, 292 passes |
| old (LoopAsync) | server + PalSchema + BP frameworks | survived 300s, 280 passes |
| new (clock)     | server, 2 mods | survived 300s, **750 of 753 passes ran** |

The server does not reproduce the client crash even with the collision mods
loaded, so the remaining client-only suspects are its UI-side blueprint mods
and widget hooks. The decisive test of the fix is therefore one client
session: the old build died there inside thirty seconds of stress, so the
answer arrives fast either way.

Also worth keeping: the old build only got 292 of 753 forced passes through
its queue; the clock ran essentially all of them. Same machine, same world,
2.5 times the completed work.
