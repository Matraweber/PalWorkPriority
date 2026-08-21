# The widget, exactly

What to build in the editor. Names are load-bearing: Lua finds every one of
these with `GetWidgetFromName`, so a typo is a silent nil rather than an
error.

## Why this is a shell and not a finished panel

Unreal 5.1 does not expose `WidgetBlueprint`'s editor properties to Python.
Not `WidgetTree`, and not `ParentClass` or `GeneratedClass` either, so a
script can create the asset and nothing more. Probed rather than assumed, in
`tools/ue_probe2.py`.

That settles the division of labour, and in our favour:

**The blueprint is a shell.** A backdrop, a title, a search box, and three
empty containers. No blueprint graph at all, no variables, no functions, no
events. It is a layout and nothing else, which is the one thing the editor is
better at than code.

**Lua fills it.** Rows are constructed and added at runtime, exactly as the
current panel already does successfully. That code works and is keeping the
mod usable today; it just needs a host it owns rather than one the game
rebuilds underneath it.

This also drops the earlier contract of `AddRule`, `OnItemChosen` and the
rest. Those needed blueprint functions and custom events, which is graph work,
and none of it is necessary if Lua owns the widgets directly.

## What it fixes

Both of the current panel's real problems, and only these two:

- **Lifetime.** We create the widget and add it to the viewport, so nothing
  destroys it under us. Two crashes came from injecting into the HUD, which
  is rebuilt as its own state changes.
- **Focus.** An `EditableTextBox` inside a widget we own can take keyboard
  focus, so search can be typed. An injected one never could, which is why
  the picker pages instead of filtering.

## Assets

    Content/Mods/PalWorkPriority/
      ModActor                  Blueprint Actor, empty graph
      UI/WBP_WorkRules          the shell below

`ModActor` exists only so UE4SS recognises the pak as a LogicMod. It does
nothing and needs nothing in it.

## WBP_WorkRules

Parent class `UserWidget`. Plain, not one of the Pal types: nothing here
needs the game's HUD behaviour, and a plain widget is one less thing to be
surprised by.

    [CanvasPanel]  Root
      [Border]  Backdrop
          anchors: centre, size 900 x 700, alignment 0.5 / 0.5
          Brush Color: 0.03, 0.05, 0.08, alpha 0.92
        [VerticalBox]  Body
            padding 18 on all sides
          [TextBlock]      Title          "WORK RULES", size 24
          [EditableTextBox] Search        hint "search items"
          [ScrollBox]      RuleList       fill vertically
          [ScrollBox]      ItemList       fill vertically, Visibility Collapsed
          [HorizontalBox]  Actions
            [Button] NewRuleButton    with a [TextBlock] "new rule" inside
            [Button] CloseButton      with a [TextBlock] "close" inside

Nine named widgets. `RuleList` and `ItemList` are separate so switching
between the rules and the picker is a visibility flip rather than a rebuild,
and `ItemList` starts collapsed because the panel opens on the rules.

Set `Is Variable` on every named widget. Without it the name is not kept in
the compiled class and `GetWidgetFromName` returns nothing.

## Getting the class, which is not LoadAsset

Proven, and worth writing down exactly, because four wrong answers came first.

    2026-08-21  WBP_WorkRules_C  WidgetBlueprintGeneratedClass
                /Game/Mods/PalWorkPriority/UI/WBP_WorkRules.WBP_WorkRules_C

`LoadAsset` does not reach anything in a mod pak, in any spelling. The route
is the asset registry, which is what BPModLoaderMod uses on the ModActor in
this very pak:

    local data = {
        PackageName = UEHelpers.FindOrAddFName(
            "/Game/Mods/PalWorkPriority/UI/WBP_WorkRules"),
        AssetName = UEHelpers.FindOrAddFName("WBP_WorkRules_C"),
    }
    local class = AssetRegistryHelpers:GetAsset(data)

Three things about that call, each of which cost a session to learn:

**On the game thread.** GetAsset on a package that is not loaded does a
synchronous load, and a synchronous load off the game thread deadlocks. The
mod hung outright, ticking stopped, and the game carried on around it.

**Through a callback.** Which follows from the above: the answer is not
available when the call returns, and writing it as though it were is what
caused the hang.

**FindOrAddFName, not FName.** A name merely looked up is None when the game
has never seen it, and a name out of a mod's own pak is exactly that.

`ModActor_C` resolving instantly is not evidence any of this is unnecessary.
It resolves instantly because BPModLoaderMod loaded it seconds earlier, which
is why it makes such a good control and such a misleading example.

## What Lua does with it

Constructs one, adds it to the viewport, and from then on treats it as the
current panel treats its own overlay.

    -- overlay.mod_class(package, asset, function(class) ... end)
    -- construct, AddToViewport
    local list = panel:GetWidgetFromName(FName("RuleList"))
    -- construct TextBlocks into `list`, exactly as panel.lua already does

Clicks keep working the way they already do, through `IsHovered` and the
mouse binding in `ui.bind_mouse`. That path is proven and does not depend on
the input mode switch that has never succeeded.

Search is the one genuinely new thing, and the only part that needs the
widget to exist: read `Search`'s text each tick and filter, which is what
`items.search` has been waiting for.

## Cooking

1. Primary Asset Label in `Content/Mods/PalWorkPriority/`, unique nonzero
   Chunk ID. Zero is the base game's chunk and produces no separate pak.
2. Cook, confirm the chunk holds these two assets and nothing else.
3. Rename the pak to `PalWorkPriority.pak`.
4. `Pal/Content/Paks/LogicMods/`, alongside the five already there.

## Building it, which is all in code

No UMG designer at any point. Unreal 5.1 does not expose WidgetTree to Python,
but C++ has no such restriction, so a commandlet builds the tree instead:

    unreal/PalWidgetGen                       the module, see its README
    Build.bat PalEditor Win64 Development     four seconds
    UnrealEditor-Cmd.exe -run=BuildWorkRulesWidget
    UnrealEditor-Cmd.exe -run=Cook -TargetPlatform=Windows -CookDir=...
    python tools/pak_mod.py                   pak and install

## Build it empty first

Put the shell together, give it a coloured backdrop and a title, and cook it
before anything else exists. If that pak loads and the panel appears on
screen, the whole route is proven and everything after is ordinary work in
Lua, which is where the mod already lives.
