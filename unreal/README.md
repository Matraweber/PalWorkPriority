# The Unreal side

One editor-only module, holding one commandlet, which builds the mod's widget
blueprint in code.

## Why there is C++ here at all

The panel could be laid out by hand in the UMG designer. It is not, because
laying it out by hand cannot be reviewed, cannot be re-run, and puts every
widget name in a details panel where a typo is silent.

Doing it in Python was tried first and is not possible. Unreal 5.1 does not
expose `UWidgetBlueprint`'s `WidgetTree` to Python. That was probed rather
than assumed, in `tools/ue_probe2.py`, and the result is unambiguous:

    WidgetTree       -> unreachable (Exception)
    GeneratedClass   -> unreachable (Exception)
    ParentClass      -> unreachable (Exception)

A Python script can create the asset and put nothing inside it. C++ has no
such restriction: `WidgetTree->ConstructWidget<T>()` is the call that puts a
widget into the tree rather than merely creating an object, and it is
ordinary editor code.

## Installing it

The module lives in the Palworld Modding Kit, not here. This directory is the
copy that is version controlled.

    copy PalWidgetGen -> PalworldModdingKit/Source/PalWidgetGen

Two registrations, both one line:

`Pal.uproject`, in `Modules`:

    { "Name": "PalWidgetGen", "Type": "Editor", "LoadingPhase": "Default" }

`Source/PalEditor.Target.cs`, in `ExtraModuleNames`:

    "PalWidgetGen",

Type `Editor` matters. This must never be compiled into a game target: it
exists to produce an asset, and nothing it does belongs in a shipped mod.

## Building and running

    Engine\Build\BatchFiles\Build.bat PalEditor Win64 Development -Project=<kit>\Pal.uproject
    Engine\Binaries\Win64\UnrealEditor-Cmd.exe <kit>\Pal.uproject -run=BuildWorkRulesWidget

Headless, both of them. The commandlet prints every widget it saved, with its
name and class, read back out of the tree rather than reported from what it
intended to do. Every one of those names is a string Lua will ask for later
with `GetWidgetFromName`, and a widget that failed to be named fails silently
there instead of loudly here.

Re-running is safe. The root is detached first, so the tree is rebuilt rather
than appended to, and the layout can be edited and run again.

## What it produces

    /Game/Mods/PalWorkPriority/ModActor        empty, so UE4SS sees a LogicMod
    /Game/Mods/PalWorkPriority/UI/WBP_WorkRules

Contents are specified in `docs/widget-spec.md`. Cooking them into a pak is
the next step and is not done here.
