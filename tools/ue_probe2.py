"""Can Python actually put widgets inside a Widget Blueprint?

The first probe found unreal.WidgetTree missing from dir(unreal). That is not
the same as unreachable: Unreal exposes UObject properties generically, so the
tree may still come back from get_editor_property even though its type has no
Python name. Concluding from the name lookup alone is the same mistake as
trusting a UE4SS property read, so this asks the object itself.

It creates a throwaway widget, tries every route to its tree, and reports.
Nothing here is kept; the asset is deleted at the end.

    py "<repo>/tools/ue_probe2.py"
"""

import unreal

OUT = []


def say(line=""):
    OUT.append(str(line))
    unreal.log(str(line))


PKG = "/Game/Mods/PalWorkPriority"
NAME = "WBP_ProbeScratch"
PATH = PKG + "/" + NAME

say("=" * 64)
say("Widget tree probe")
say("=" * 64)

# --- create a throwaway widget blueprint ---------------------------------
tools = unreal.AssetToolsHelpers.get_asset_tools()
if unreal.EditorAssetLibrary.does_asset_exist(PATH):
    unreal.EditorAssetLibrary.delete_asset(PATH)

factory = unreal.WidgetBlueprintFactory()
asset = None
try:
    asset = tools.create_asset(NAME, PKG, unreal.WidgetBlueprint, factory)
except Exception as exc:
    say("create_asset raised: %s" % exc)

say("created: %s" % (asset is not None))
if asset is None:
    say("cannot go further without an asset")
else:
    say("class: %s" % type(asset).__name__)

    # --- what properties does it admit to having ------------------------
    say("")
    say("--- properties reachable on the blueprint ---")
    for prop in ("WidgetTree", "widget_tree", "GeneratedClass",
                 "generated_class", "ParentClass", "parent_class"):
        try:
            val = asset.get_editor_property(prop)
            say("  %-16s -> %s" % (prop, type(val).__name__))
        except Exception as exc:
            say("  %-16s -> unreachable (%s)" % (prop, type(exc).__name__))

    # --- the tree itself, if it came back -------------------------------
    tree = None
    for prop in ("WidgetTree", "widget_tree"):
        try:
            tree = asset.get_editor_property(prop)
            if tree is not None:
                break
        except Exception:
            pass

    say("")
    if tree is None:
        say("--- the tree is not reachable, layout must be built by hand ---")
    else:
        say("--- tree object: %s ---" % type(tree).__name__)
        members = [m for m in dir(tree) if not m.startswith("_")]
        say("  %d member(s)" % len(members))
        for m in members:
            say("    " + m)

        # The one call that decides it. If a widget can be constructed into
        # the tree, the whole panel can be scripted.
        say("")
        say("--- attempting to construct a CanvasPanel into the tree ---")
        for method in ("construct_widget", "ConstructWidget"):
            if hasattr(tree, method):
                try:
                    made = getattr(tree, method)(unreal.CanvasPanel)
                    say("  %s -> %s" % (method, made))
                except Exception as exc:
                    say("  %s raised: %s" % (method, exc))
            else:
                say("  %s not present" % method)

    # --- does the Palworld-specific widget type help --------------------
    say("")
    say("--- Palworld widget blueprint types ---")
    for name in ("PalWidgetBlueprintType", "PalWorldHUDWidgetBlueprintType"):
        cls = getattr(unreal, name, None)
        say("  %-32s %s" % (name, cls))

    unreal.EditorAssetLibrary.delete_asset(PATH)
    say("")
    say("scratch asset deleted")

path = unreal.Paths.project_dir() + "ue_probe2_result.txt"
try:
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(OUT))
    unreal.log("written to %s" % path)
except Exception as exc:
    unreal.log_error("could not write: %s" % exc)
