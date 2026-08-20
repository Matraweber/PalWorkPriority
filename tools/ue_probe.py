"""What the Unreal Python API can actually do here, run inside the editor.

Authoring a Widget Blueprint from Python is the plan, but Unreal's Python
surface for UMG is partly editor-only and varies by version. Rather than write
the whole widget against an assumed API and watch it fail somewhere in the
middle, this asks first and reports.

Run it from the editor's Output Log:

    py "C:/Users/user/Desktop/palworld-priority-mod/tools/ue_probe.py"

or headless with the editor closed:

    UnrealEditor-Cmd.exe <Pal.uproject> -run=pythonscript
        -script="C:/.../ue_probe.py"
"""

import unreal

OUT = []


def say(line=""):
    OUT.append(str(line))
    unreal.log(str(line))


def has(obj, name):
    try:
        return hasattr(obj, name)
    except Exception:
        return False


say("=" * 64)
say("Unreal Python probe")
say("=" * 64)

say("engine version: %s" % unreal.SystemLibrary.get_engine_version())
say("project dir:    %s" % unreal.Paths.project_dir())
say("")

# --- can we create a Widget Blueprint at all -----------------------------
say("--- asset creation ---")
for name in ("WidgetBlueprintFactory", "AssetToolsHelpers", "EditorAssetLibrary"):
    say("  unreal.%-26s %s" % (name, has(unreal, name)))

# --- the classes a panel is made of --------------------------------------
say("")
say("--- UMG widget classes ---")
wanted = ["CanvasPanel", "ScrollBox", "VerticalBox", "HorizontalBox",
          "EditableTextBox", "TextBlock", "Image", "Button", "Border",
          "SizeBox", "Overlay", "UniformGridPanel", "WidgetSwitcher",
          "WrapBox", "UserWidget", "WidgetTree"]
for name in wanted:
    say("  unreal.%-20s %s" % (name, has(unreal, name)))

# --- the part most likely to be missing ----------------------------------
#
# Creating the asset is easy. Putting widgets INSIDE it needs the widget tree,
# and that is the API Unreal exposes least consistently. If this section comes
# back empty the widget has to be assembled by hand in the editor and Python
# is only good for the boring parts.
say("")
say("--- widget tree manipulation ---")
tree = getattr(unreal, "WidgetTree", None)
if tree is None:
    say("  unreal.WidgetTree is not exposed at all")
else:
    members = [m for m in dir(tree) if not m.startswith("_")]
    say("  WidgetTree members: %d" % len(members))
    for m in members:
        say("    " + m)

say("")
say("--- editor utility subsystems ---")
for name in ("EditorUtilityLibrary", "EditorUtilitySubsystem",
             "WidgetBlueprintLibrary", "EditorLevelLibrary"):
    say("  unreal.%-26s %s" % (name, has(unreal, name)))

# --- anything with Widget in the name, for the things not guessed above --
say("")
say("--- every exposed name containing 'WidgetBlueprint' ---")
for name in sorted(n for n in dir(unreal) if "WidgetBlueprint" in n):
    say("  " + name)

# Written to disk as well as the log, because the Output Log is awkward to
# copy out of and the whole point is to read the answer somewhere else.
path = unreal.Paths.project_dir() + "ue_probe_result.txt"
try:
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(OUT))
    unreal.log("probe written to %s" % path)
except Exception as exc:
    unreal.log_error("could not write probe result: %s" % exc)
