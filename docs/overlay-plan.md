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
| Wwise | 2021.1.11, SDK (C++) and the VS 2022 integration | Audiokinetic Launcher, free account |
| Modding kit | github.com/localcc/PalworldModdingKit | clone it |

Palworld reports engine version 5.1 in UE4SS's own boot log, so this is not
inferred from a wiki.

Wwise is not optional even though we ship no audio. Confirmed against the kit
rather than taken on trust: `Wwise` is one of the 46 plugins in
`Pal.uproject`, and `Source/Pal/Pal.Build.cs` lists `AkAudio` as a module
dependency, with the Ak headers used across the C++. No `Plugins/Wwise`
folder ships with the kit, so it will not compile until you supply one.

## Wwise, which is the awkward part

Audiokinetic has delisted old patch versions from their launcher, so
2021.1.11 may simply not be offered. Two things make that less fatal than it
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

Outstanding, both because they need an account login: Unreal Engine 5.1
through the Epic launcher, and Wwise through the Audiokinetic launcher.

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
