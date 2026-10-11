# Current widget contract — September 23, 2026

The historical design notes below describe an obsolete 12-widget shell. They are retained as history, **not build instructions**. The current generator and `Scripts/overlay.lua` require 21 named widgets:

- Root (CanvasPanel), Backdrop (Border), Body (VerticalBox).
- TabsRow, TitleRow, SubRow, NoticeRow, SearchRow, CaptionRow, HeadRow: SizeBox containers holding same-prefix CanvasPanels (Tabs, Title, Sub, Notice, Search, Caption, Head).
- RuleList and ItemList: ScrollBoxes with automatic sizing.
- FootRow (SizeBox) holding Foot (CanvasPanel).

The row heights are 34, 34, 26, 22, 40, 24, 28, and 76 respectively. Backdrop defaults to centre anchors/alignment, a 1086 × 700 placeholder, RGBA (0.03, 0.05, 0.08, 0.92); Body padding is 18. Lua supplies the final preferred position, size and controls. Search is a container, not the editable control itself. All 21 widgets are exposed as generated-class properties; `GetWidgetFromName` is not the runtime lookup contract.

The action-router candidate uses the shipped PalUserWidget parent, PWP_InputContract=3, PWP_CancelRequested=false and bIsFocusable=true. Blueprint registers the consuming RadialMenuCancel action with an engine-bound callback; no delegate is passed by value through Lua. The callback only sets the request. Lua verifies registration was attempted and the widget is active, acknowledges/cancels through the current callback's widget, and deactivates before detachment. Contract 3 adds the engine-owned PWP_AmountEditor reference and PWP_EditorEscapeHeld boolean for focused-editor Escape preview/release handling. Normal edit cancellation returns focus only when that editor owns it; teardown never requests refocus. The native Pal widget's GameMouseCaptureMode is set and verified as NoCapture before activation. See [editor Escape evidence](editor-escape-2026-09-23.md). Generic Slate-only handling (the rejected contract 1) did not isolate ordinary panel Escape; contract 3 retains CommonUI for that path. Physical held-key/controller acceptance remains separate.

Back up editor assets and installed packages before rebuilding. Verify all 21 names/types, graph connections, compilation, defaults and compiled-event tests, followed by a fresh-process `-VerifyInputOnly` readback. Package only the intended widget plus the existing verified ModActor; exclude experimental assets. The editor module is a build tool, not a runtime dependency. Native acceptance (editing, closing, vanilla focus and text input after a restart) is recorded in `native-escape-2026-09-16.md` and remains required after a successful cook.

---

# Historical prototype notes (superseded)

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
