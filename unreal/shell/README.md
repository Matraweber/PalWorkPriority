# Building the shell

The widget blueprint the panel hosts on. Built headless, from code, with
**stock Unreal 5.1.1** - the Palworld modding kit is not involved.

## Why not the modding kit

The kit needs Wwise's Unreal integration to compile at all, even for a mod
that never touches sound, and that download is behind an Audiokinetic
sign-in. It then wants a first build of the whole Palworld source.

None of that is needed here, because nothing in the shell is a Palworld type:
it is CanvasPanel, Border, VerticalBox, SizeBox and ScrollBox, all engine
classes. A throwaway C++ project against the installed engine compiles the
commandlet in under a minute.

## Why not Python

`UWidgetBlueprint::WidgetTree` is protected and unreadable from Python, so a
script can create the asset and put nothing inside it. Probed, not assumed:

    Exception: WidgetBlueprint: Property 'WidgetTree' for attribute
    'WidgetTree' on 'WidgetBlueprint' is protected and cannot be read

C++ has no such restriction, and `WidgetTree->ConstructWidget` is the call
that puts a widget into the tree rather than merely creating an object.

## The steps

Scaffold a project around `unreal/PalWidgetGen` - a `.uproject` naming the
module, and a `ShellGenEditor.Target.cs`. Then:

    Build.bat ShellGenEditor Win64 Development -Project=<ShellGen.uproject>

    UnrealEditor-Cmd.exe <ShellGen.uproject> -run=BuildWorkRulesWidget \
        -unattended -nosplash -nullrhi

    UnrealEditor-Cmd.exe <ShellGen.uproject> -run=Cook \
        -targetplatform=Windows -unattended -nosplash -nullrhi

    UnrealPak.exe PalWorkPriority.pak -Create=<response> -compress

The cook needs the asset pinned or it produces nothing - a widget no map
references is not reachable, and the cooker reports success having done
nothing at all:

    [/Script/UnrealEd.ProjectPackagingSettings]
    +DirectoriesToAlwaysCook=(Path="/Game/Mods")

`ModActor` is reused from the previous pak rather than rebuilt. BPModLoaderMod
needs it to mount the mod, and it is not what any of this is changing.

The response file maps staged files to in-pak paths; `pak.response.example.txt`
is a working one. The mount point has to be
`../../../Pal/Content/Mods/PalWorkPriority/`, which `tools/pakinfo.py` will
confirm on any working mod's pak.

Install into `Pal/Content/Paks/LogicMods/`, not `~WorkshopMods/` - paks there
mount only when the mod manager has that mod switched on.

**The game holds the pak open while it runs.** Installing over it fails with
"Device or resource busy" until Palworld is closed.
