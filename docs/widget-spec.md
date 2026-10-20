---
date: 2026-09-23
tags: [panel, stand-ui, tooling]
status: current
---
# Widget contract and pak build

Related: [stand-keyboard-2026-09-24](stand-keyboard-2026-09-24.md) · [editor-escape-2026-09-23](editor-escape-2026-09-23.md) · [panel-cursor-2026-09-23](panel-cursor-2026-09-23.md)

The current contract of the mod's own cooked widgets, how the stand roster is
found in the game's own widgets, and the toolchain that builds the pak.
`docs/asset-contract.json` names this file as its contract reference
(WorkRules `PWP_InputContract` 3, StandInput `PWP_Contract` 2), and
`tools/release.py` checks the shipped pak against that JSON.

## Current widget contract (WorkRules contract 3, StandInput contract 2)

The current generator and `Scripts/overlay.lua` require 21 named widgets:

- Root (CanvasPanel), Backdrop (Border), Body (VerticalBox).
- TabsRow, TitleRow, SubRow, NoticeRow, SearchRow, CaptionRow, HeadRow: SizeBox containers holding same-prefix CanvasPanels (Tabs, Title, Sub, Notice, Search, Caption, Head).
- RuleList and ItemList: ScrollBoxes with automatic sizing.
- FootRow (SizeBox) holding Foot (CanvasPanel).

The row heights are 34, 34, 26, 22, 40, 24, 28, and 76 respectively. Backdrop defaults to centre anchors/alignment, a 1086 × 700 placeholder, RGBA (0.03, 0.05, 0.08, 0.92); Body padding is 18. Lua supplies the final preferred position, size and controls. Search is a container, not the editable control itself. All 21 widgets are exposed as generated-class properties; `GetWidgetFromName` is not the runtime lookup contract.

The action-router candidate uses the shipped PalUserWidget parent, PWP_InputContract=3, PWP_CancelRequested=false and bIsFocusable=true. Blueprint registers the consuming RadialMenuCancel action with an engine-bound callback; no delegate is passed by value through Lua. The callback only sets the request. Lua verifies registration was attempted and the widget is active, acknowledges/cancels through the current callback's widget, and deactivates before detachment. Contract 3 adds the engine-owned PWP_AmountEditor reference and PWP_EditorEscapeHeld boolean for focused-editor Escape preview/release handling. Normal edit cancellation returns focus only when that editor owns it; teardown never requests refocus. The native Pal widget's GameMouseCaptureMode is set and verified as NoCapture before activation ([panel-cursor-2026-09-23](panel-cursor-2026-09-23.md)). See [editor Escape evidence](editor-escape-2026-09-23.md). Generic Slate-only handling (the rejected contract 1, an OnPreviewKeyDown handler) did not isolate ordinary panel Escape; contract 3 retains CommonUI for that path.

Why the Blueprint owns the binding: BreedingHelper's earlier attempt to pass the action delegate by value from Lua crashed natively, and a raw UE4SS key observer that deactivates a widget before the game's router consumes the key leaks Escape to the menu underneath. The local Pal kit has stub implementations of these functions, so an editor run cannot prove Palworld's input consumption; only a native test can.

StandInput (`WBP_StandInput_C`, `PWP_Contract` 2) is the per-cell receiver on the Monitoring Stand. It handles number keys in its own native OnKeyDown event and leaves Escape unhandled for the game's parent route. Details and acceptance: [stand-keyboard-2026-09-24](stand-keyboard-2026-09-24.md), [stand-pointer-2026-09-24](stand-pointer-2026-09-24.md).

Back up editor assets and installed packages before rebuilding. Verify all 21 names/types, graph connections, compilation, defaults and compiled-event tests, followed by a fresh-process `-VerifyInputOnly` readback. Package only the intended widgets plus the existing verified ModActor; exclude experimental assets. The editor module is a build tool, not a runtime dependency. Native acceptance (editing, closing, vanilla focus and text input after a restart) is recorded in [editor-escape-2026-09-23](editor-escape-2026-09-23.md) and, for the release candidate, [g3-escape-photo-death-2026-10-17](g3-escape-photo-death-2026-10-17.md) and [g3-panel-2026-10-17](g3-panel-2026-10-17.md); repeat it after every new cook.

## Stand roster scope (the game's own widgets)

The Monitoring Stand grid lives in the game's menu, not in our pak, so Lua has
to find it. Two rules came out of the September 11-12 native failures:

- **Search only the menu's own tree, down to its one named roster.** The
  captured path is `CanvasPanel_18 → CanvasPanel_82 → CanvasPanel_PalList →
  WBP_PalCommonScrollList_PalList` (class `WBP_PalCommonScrollList_C`), whose
  tree holds `ScrollBox_0` and the Pal rows. `ui_tree.stand_cells` first finds
  exactly one such roster by name and class in the current menu owner's
  panel-child edges (512 visits), then walks only that roster (its own
  4000-visit limit). Missing, unreadable or
  ambiguous scopes refuse; nothing is guessed.
- **Never walk another widget's private WidgetTree** during owner discovery,
  whatever its class suffix. On 2026-09-12 the whole menu was refused because
  the walk reached an input prompt (`Overlay_Guide_Change →
  WBP_PalKeyGuideIcon_C`, class `PalUIActionWidgetBase`) outside the roster;
  a bigger traversal budget could not have fixed that (1990 of 4000 visits).
- **`BP_PalTextBlock_C` is a terminal leaf.** The reader's generic "`_C` is a
  container" rule rejected it on 2026-09-11 and every stand refresh came back
  unavailable (88 of 88). It is now recognised as a leaf before that rule;
  CheckBox content is still traversed, and unknown classes such as
  `PalUIActionWidgetBase` still refuse. Test fixtures had given every widget a
  child-count method, which is what hid the mismatch.

No engine wrapper survives the call; the roster is resolved fresh each time
(see LESSONS, "A stored engine object is a use-after-free").

## Build toolchain (pak)

Moved from the former overlay plan. These versions are pinned: the Palworld
modding kit will not compile against anything else, and letting Unreal upgrade
the project breaks plugins and serialization.

| | Version | Where |
| --- | --- | --- |
| Unreal Engine | 5.1, any 5.1.x (5.1.1 installed at `D:\Program Files (x86)\Epic Games\UE_5.1`) | Epic Games Launcher |
| Visual Studio | 2022, workload "Desktop development with C++" | visualstudio.microsoft.com |
| MSVC | v143 14.38.33130 (VS 2022 C++ x64/x86 build tools v14.38-17.8) | VS installer, Individual Components |
| .NET | 6 runtime, x64 | dotnet.microsoft.com |
| .NET Framework | 4.8.1 Developer Pack | `winget install Microsoft.DotNet.Framework.DeveloperPack_4` |
| Wwise | 2021.1.x with SDK (C++); 2021.1.11.7933 installed | Audiokinetic Launcher, free account |
| Modding kit | github.com/localcc/PalworldModdingKit, cloned to `Desktop\PalworldModdingKit` | `Pal.uproject` says `EngineAssociation: 5.1` |

Palworld reports engine 5.1 in UE4SS's own boot log. The kit compiled here
(`PalEditor Win64 Development`, 315 of 315 steps, under three minutes once the
two traps below were fixed).

**Pin the compiler.** UnrealBuildTool takes the newest toolchain it finds. With
Visual Studio 2026 also installed it picked 14.50, which UE 5.1 predates, and
failed with `ConcurrentLinearAllocator.h(29): error C4668: '__has_feature' is
not defined as a preprocessor macro`. The pin lives in
`%APPDATA%\Unreal Engine\UnrealBuildTool\BuildConfiguration.xml` (current
content, checked 2026-10-20):

    <?xml version="1.0" encoding="utf-8" ?>
    <Configuration xmlns="https://www.unrealengine.com/BuildConfiguration">
      <VCProjectFileGenerator>
        <Version>VisualStudio2022</Version>
      </VCProjectFileGenerator>
      <WindowsPlatform>
        <Compiler>VisualStudio2022</Compiler>
        <CompilerVersion>14.38.33130</CompilerVersion>
        <ToolchainVersion>14.38.33130</ToolchainVersion>
      </WindowsPlatform>
    </Configuration>

**Install the .NET Framework Developer Pack, not only .NET 6.** Without
`NETFXSDK` UnrealBuildTool stops before compiling anything: `Unable to
instantiate module 'SwarmInterface': Could not find NetFxSDK install dir`.
The standalone winget pack is easier than the VS installer component, which
needs an elevated shell and otherwise refuses with exit 5007.

**Wwise is required although the mod ships no audio.** `Wwise` is one of the
46 plugins in `Pal.uproject` and `Source/Pal/Pal.Build.cs` depends on
`AkAudio`; the kit ships no `Plugins/Wwise`. The launcher no longer lists old
2021 patches; any 2021.1.x works (same major). Do not source a delisted build
from a mirror (licence problem, unverifiable binary); ask Audiokinetic support.
Install it before opening the project, then integrate by hand from offline
files:

1. Install Wwise 2021.1.x with **SDK (C++)** ticked.
2. Launcher, **Unreal Engine** tab, **Download**, **Offline Integration
   Files**. That gives `Unreal.5.0.tar.xz`; unpack it twice (`.xz`, then `.tar`).
3. Copy the `Wwise` folder into `PalworldModdingKit/Plugins/`.
4. Make `Plugins/Wwise/ThirdParty` and copy `Win32_vc170`, `x64_vc170` and
   `include` from the SDK into it.
5. Duplicate both `vc170` folders as `vc160` (the kit builds against the older
   toolset name).
6. In `Wwise.uplugin` change `EngineVersion` from `5.0.0` to `5.1`.

**No Unreal MCP server supports UE 5.1** (checked: official Unreal MCP 5.8+,
chongdashu/unreal-mcp 5.5+ and states 5.1 unsupported, UEBlueprintMCP 5.7+,
unreal-blueprint-mcp 5.4), and the kit must not be upgraded, so the editor is
driven by our own commandlets. UE 5.1 does not expose `WidgetTree` (nor
`ParentClass`/`GeneratedClass`) to Python (probed in `tools/ue_probe2.py`), but
C++ can, so `unreal/PalWidgetGen` builds the trees headless:

    Build.bat PalEditor Win64 Development
    UnrealEditor-Cmd.exe Pal.uproject -run=BuildWorkRulesWidget        (and -run=BuildStandInputWidget)
    UnrealEditor-Cmd.exe Pal.uproject -run=... -VerifyInputOnly        fresh-process readback
    UnrealEditor-Cmd.exe -run=Cook -TargetPlatform=Windows ...
    python tools/pak_mod.py [--stage]                                  pak (and install)

Cooking: assets under `Content/Mods/PalWorkPriority/` with a Blueprint Actor
named `ModActor` (the name UE4SS matches; it exists only so the pak counts as
a LogicMod), a Primary Asset Label with a unique **nonzero** chunk ID (zero is
the base game's chunk and gives no separate pak), check the chunk holds only
our assets, name the pak `PalWorkPriority.pak`, keep any `.ucas`/`.utoc`, and
install it in `Pal/Content/Paks/LogicMods/`. In the in-pak paths
`/Game/Mods/PalWorkPriority` appears as `../../../Pal/Content/Mods/PalWorkPriority`
(see `tools/pak_mod.py`). UE4SS loads Blueprint mods only with
`BPModLoaderMod : 1` and `BPML_GenericFunctions : 1` in `mods.txt`. Then
update `docs/asset-contract.json` (hash, size, member hashes, contract
versions) or `tools/release.py` refuses the pak.

---

# History (superseded design notes)

Not build instructions. The first design was a 9-widget shell, then 12; the
21-widget contract above replaced both, and the overlay plan's Blueprint
functions and events (`AddRule`, `OnItemChosen` and the rest) were never built.
What is kept here is what code still relies on.

## Getting the class, which is not LoadAsset

Proven on 2026-08-21 (`WBP_WorkRules_C`, a WidgetBlueprintGeneratedClass at
`/Game/Mods/PalWorkPriority/UI/WBP_WorkRules.WBP_WorkRules_C`) after four wrong
answers. `LoadAsset` does not reach anything in a mod pak, in any spelling. The
route is the asset registry, which is what BPModLoaderMod uses on the ModActor
in this very pak:

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
(`Scripts/panel.lua` points at this paragraph.)

## Why a widget we own

Every early panel problem came from injecting into widgets the game owns: two
crashes from injecting into the HUD (rebuilt as its own state changes), a
duplicate that drew itself twice, keys that never fired. A widget we create and
add to the viewport is not destroyed under us, and an editable text box inside
it can take keyboard focus, which is what search needs. Set `Is Variable` on
every named widget, or the name is not kept in the compiled class.

For a while the panel drew everything onto a runtime-constructed canvas and
needed no pak (a UserWidget built at runtime with its own WidgetTree and
CanvasPanel root does appear and is ours). That stopped being enough once the
chrome moved into named rows: without the pak `use_row` fails for all seven
rows and the header collapses onto one line. The README now treats a missing
pak as a dependency failure, not a working fallback panel.

Making Python able to fill a widget tree would take a small editor-only
UBlueprintFunctionLibrary over `UWidgetTree::ConstructWidget`/`FindWidget` and
`FBlueprintEditorUtils::MarkBlueprintAsStructurallyModified` (Build.cs:
`UMGEditor`, `UnrealEd`, editor targets only). No plugin offers it (the UMG
Templates plugin is palette categories, GraphDeck a separate tool). It was not
built because the C++ commandlets do the job.
