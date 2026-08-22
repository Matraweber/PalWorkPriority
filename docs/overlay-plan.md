# The proper overlay

Replacing the injected text panel with a real blueprint widget in our own pak.

Every problem the current panel has comes from one cause: it injects into
widgets the game owns. Two crashes, a duplicate that drew itself twice, arrow
keys that never fire, an input mode that will not switch. We control neither
the lifetime of those widgets nor where input goes. A widget we own fixes the
whole category at once, and gets icons and a working search box on the way.

## Versions, exactly

These are pinned. The kit will not compile against anything else, and letting
Unreal "helpfully" upgrade the project breaks plugins and serialization.

| | Version | Where |
| --- | --- | --- |
| Unreal Engine | 5.1, any 5.1.x | Epic Games Launcher |
| Visual Studio | 2022 Community or higher | visualstudio.microsoft.com |
| VS workload | Desktop development with C++ | in the VS installer |
| VS component | MSVC v143, VS 2022 C++ x64/x86 Build Tools (v14.38-17.8) | Individual Components |
| .NET | 6 runtime, x64 | dotnet.microsoft.com |
| .NET Framework | 4.8.1 Developer Pack | winget, `Microsoft.DotNet.Framework.DeveloperPack_4` |
| Wwise | 2021.1.11, SDK (C++) and the VS 2022 integration | Audiokinetic Launcher, free account |
| Modding kit | github.com/localcc/PalworldModdingKit | clone it |

Palworld reports engine version 5.1 in UE4SS's own boot log, so this is not
inferred from a wiki.

Wwise is not optional even though we ship no audio. Confirmed against the kit
rather than taken on trust: `Wwise` is one of the 46 plugins in
`Pal.uproject`, and `Source/Pal/Pal.Build.cs` lists `AkAudio` as a module
dependency, with the Ak headers used across the C++. No `Plugins/Wwise`
folder ships with the kit, so it will not compile until you supply one.

## Resolved: the widget is built from Lua, not cooked

The overlay does not need a pak. A UserWidget constructed at runtime, given a
WidgetTree and a CanvasPanel root and added to the viewport, appears on screen
and is ours. Proven in game, not argued: `Scripts/overlay.lua`, Ctrl+F7.

That is the whole of what the blueprint route was for. We own the lifetime, so
nothing rebuilds it underneath us, which is what caused both crashes. And a
widget we own can hold keyboard focus, which is what search needs.

The editor work is therefore not required, and neither is any of what follows
in this file. It is kept because it is all true, it cost a day to establish,
and it is the fallback if the runtime widget turns out to have a limit we have
not hit yet.

### On driving the editor directly

Asked and answered properly rather than assumed. Every Unreal MCP server
requires an engine newer than the one Palworld uses:

    official Unreal MCP        UE 5.8+
    chongdashu/unreal-mcp      UE 5.5+, states 5.1 unsupported
    UEBlueprintMCP             UE 5.7+
    unreal-blueprint-mcp       UE 5.4

Palworld is 5.1 and cannot be moved off it, since the kit's own instructions
are that the project must not be upgraded. Anthropic's connector registry has
nothing for Unreal either.

### On making Python able to fill a widget tree

Also asked, also checked. There is no plugin that does this. The marketplace
UMG Templates plugin is about palette categories, not scripting, and GraphDeck
is a separate authoring tool rather than an API.

There is a documented way, and it is writing one ourselves. `UWidgetTree`
does expose what is needed, to C++ rather than to Python:

    // Build.cs, editor only
    if (Target.bBuildEditor)
    {
        PrivateDependencyModuleNames.AddRange(
            new string[] { "UMGEditor", "UnrealEd" });
    }

    // then, inside #if WITH_EDITOR
    WidgetTree->ConstructWidget<UTextBlock>(...)
    WidgetTree->FindWidget(...)
    FBlueprintEditorUtils::MarkBlueprintAsStructurallyModified(Blueprint)

Wrapping those in a UBlueprintFunctionLibrary marked
`UFUNCTION(BlueprintCallable, meta=(ScriptMethod))` would hand Python exactly
the capability it lacks. Perhaps a hundred and fifty lines, and the toolchain
to build it is already working here.

It is not being done, because it would let us script an asset we no longer
need. The runtime widget removed the requirement for a cooked blueprint
entirely. Written down because it is the answer if that ever changes, and
because "no plugin exists" on its own is a misleading way to leave it.

## Wwise, which is the awkward part

Audiokinetic has delisted old patch versions from their launcher, and on this
machine it offers nothing in the 2021 line at all.

Sourcing a delisted build of proprietary licensed software from a third party
mirror is not an option worth taking: it is a licence problem and an
unverifiable binary at the same time. The legitimate route is an Audiokinetic
support ticket, which is slow but real. Which is exactly why the blank project
above is worth trying first. Two things make that less fatal than it
sounds.

The kit pins no version anywhere. It asks for `AkAudio` and nothing more.
Audiokinetic's own position is that a newer minor is compatible with an older
one inside the same major, so any 2021.1.x is the target, and 2021.1.11 is
the number the community happens to have written down.

The integration is done by hand from offline files, not by the launcher's
project integration. The steps are not guessable:

1. In the launcher, install a Wwise 2021.1.x with **SDK (C++)** ticked.
2. Go to the launcher's **Unreal Engine** tab, press **Download**, and choose
   **Offline Integration Files**. That produces `Unreal.5.0.tar.xz`.
3. Unpack it twice. The `.xz` yields a `.tar`, and the `.tar` yields the
   folder.
4. Copy the `Wwise` folder into `PalworldModdingKit/Plugins/`.
5. Make a `ThirdParty` folder inside it and copy `Win32_vc170`, `x64_vc170`
   and `include` from the SDK into it.
6. Duplicate both `vc170` folders as `vc160`. The kit builds against the
   older toolset name.
7. Edit `Wwise.uplugin` and change `EngineVersion` from `5.0.0` to `5.1`.

Step 7 is the tell that the exact patch version matters less than the docs
imply: the integration shipped is for Unreal 5.0 and gets hand-edited to 5.1
regardless.

Install Wwise before opening the project. Opening it first fails on a missing
plugin with an error that does not explain itself.

## Two prerequisites nobody's list mentions

Both stopped the build dead, and neither appears in the kit's docs, the
modding wiki, or PalMods.

**The .NET Framework Developer Pack.** Not the same thing as the .NET 6
runtime, which every guide does list. UnrealBuildTool needs `NETFXSDK` for
its SwarmInterface module and fails before compiling a single file without
it:

    Unable to instantiate module 'SwarmInterface': Could not find NetFxSDK
    install dir. Install a version of .NET Framework SDK at 4.6.0 or higher.

`winget install Microsoft.DotNet.Framework.DeveloperPack_4` fixes it. Adding
the same component through the Visual Studio installer needs an elevated
shell and refuses with exit 5007 otherwise, so the standalone pack is easier.

**Pinning the compiler when a newer Visual Studio is installed.**
UnrealBuildTool picks the newest toolchain it can find. With Visual Studio
2026 also present it chose 14.50, which Unreal 5.1 predates entirely:

    Detected compiler newer than Visual Studio 2022
    ConcurrentLinearAllocator.h(29): error C4668: '__has_feature' is not
    defined as a preprocessor macro

Fixed by pinning it, in
`%APPDATA%\Unreal Engine\UnrealBuildTool\BuildConfiguration.xml`:

    <?xml version="1.0" encoding="utf-8" ?>
    <Configuration xmlns="https://www.unrealengine.com/BuildConfiguration">
      <WindowsPlatform>
        <Compiler>VisualStudio2022</Compiler>
        <CompilerVersion>14.38.33130</CompilerVersion>
      </WindowsPlatform>
    </Configuration>

With both done the build takes under three minutes, not the long haul the
docs imply.

## Already in place here

Checked on this machine, so these are not steps:

- .NET 6.0.36 runtime, installed.
- Visual Studio 2022 Community 17.14 with the C++ workload and MSVC
  **14.38.33130**, the toolset the kit asks for. Visual Studio 2026 is also
  present; harmless, but Unreal 5.1 wants the 2022 one, so that is the first
  thing to check if the build complains about a compiler.
- The modding kit, cloned to `Desktop\PalworldModdingKit`. Its `Pal.uproject`
  reports `EngineAssociation: 5.1`.
- Epic Games Launcher, already installed.
- `BPModLoaderMod : 1` and `BPML_GenericFunctions : 1` are enabled in
  `mods.txt`. That is what makes UE4SS load blueprint mods at all.
- `Pal/Content/Paks/LogicMods/` exists and holds five working paks, so the
  loading path is already proven on this install.
- 203 GB free. The engine plus the kit wants roughly 100.

- Unreal Engine 5.1.1 at `D:\Program Files (x86)\Epic Games\UE_5.1`.
- Wwise 2021.1.11.7933 with the SDK, integrated into the kit and retargeted
  to engine 5.1.
- **The kit compiles.** `PalEditor Win64 Development`, 315 of 315 steps,
  producing `UnrealEditor-Pal.dll`. Full log in
  `PalworldModdingKit/build-log.txt`.

Nothing is outstanding. The editor can be opened.

## What gets built

Two things, and the division between them is the point.

**The blueprint does the presentation.** Layout, scrolling, focus, the search
box, and crucially the item icons, which it can resolve from an item id
through the game's own icon lookup. Doing that from Lua would mean loading
textures and building brushes by hand.

**Lua keeps every decision.** `scheduler.lua`, `caps.lua`, `items.lua` and the
rest do not change at all. They already are the mod; the widget is a face.

### Assets

    Content/Mods/PalWorkPriority/
      ModActor                    the entry point BPModLoaderMod looks for
      UI/WBP_WorkRules            the panel
      UI/WBP_WorkRuleRow          one rule
      UI/WBP_WorkRuleItem         one item tile in the picker

### The contract

Keep it to strings and numbers. Structs across the Lua boundary are a source
of pain for no benefit here.

Blueprint functions Lua calls:

    ClearRules()
    AddRule(int Index, String Job, String Item, int Have, int Target)
    ClearItems()
    AddItem(int Index, String ItemId, int Have)
    SetSearchHint(String Text)
    Show(bool Visible)

Blueprint events Lua hooks, fired by the widget when the player does
something:

    OnRuleJobClicked(int Index)
    OnRuleAmountClicked(int Index, int Direction)
    OnRuleRemoveClicked(int Index)
    OnItemChosen(String ItemId)
    OnSearchChanged(String Text)
    OnClosed()

Lua hooks those the same way it hooks anything else:

    RegisterHook(
        "/Game/Pal/Mods/PalWorkPriority/UI/WBP_WorkRules.WBP_WorkRules_C:OnItemChosen",
        function(Context, ItemId) ... end)

`Index` is our own row number, handed out by `AddRule` and handed back
unchanged. The widget never needs to understand what a rule is, which keeps
the blueprint simple and keeps every rule decision in Lua where the tests and
the crash rules already live.

Search is the one thing that has to live in the widget. An `EditableTextBox`
in a widget we own gets real keyboard focus; an injected one does not, which
is why the current picker pages instead of filtering.

## Cooking

1. `Content/Mods/PalWorkPriority/`, with a Blueprint Actor named `ModActor`.
   The name is what UE4SS matches on.
2. A Primary Asset Label with a unique nonzero Chunk ID. Zero is the base
   game's chunk and will not produce a separate pak.
3. Cook, then check the chunk holds our assets and nothing else.
4. Rename the produced pak to `PalWorkPriority.pak`.
5. Drop it in `Pal/Content/Paks/LogicMods/`, next to the five already there.
6. Keep any `.ucas` and `.utoc` produced alongside it.

For the Workshop release the pak goes in a `LogicMods` folder in the mod
package, which is exactly how Creative Menu ships:

    LogicMods/PalWorkPriority.pak     mount ../../../Pal/Content/Mods/...
    Scripts/                          the Lua, unchanged
    Info.json                         gains the LogicMods install rule

## Order of work

**The widget can be built and tested before any Lua exists.** Fill it with
made up rules in the editor, check it lays out, scrolls, takes focus and
looks right. That is the whole reason for doing this, and it needs nothing
from the mod.

**The Lua binding is small** and can be written against the contract above
while the widget is still being drawn, since the contract is the agreement.

**The current panel stays until the new one works.** It is ugly and it is
awkward, but it sets rules, and there is no sense being without one.

## What this does not change

The multiplayer plan in `multiplayer-plan.md` is unaffected. The transport
passed Phase 0 and is already in `net.lua`. A blueprint widget is presentation
and networking is authority; they do not touch. The overlay goes first only
because networking a UI that is about to be replaced would be work done twice.
