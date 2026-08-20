using UnrealBuildTool;

// Editor only. Nothing here ships in the mod: this module exists so a
// commandlet can build a Widget Blueprint's contents in code, which Python
// cannot do. Unreal 5.1 does not expose WidgetBlueprint's WidgetTree to
// Python at all, so a script can create the asset and put nothing inside it.
// C++ has no such restriction.
public class PalWidgetGen : ModuleRules {
    public PalWidgetGen(ReadOnlyTargetRules Target) : base(Target) {
        PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;
        bLegacyPublicIncludePaths = false;

        PublicDependencyModuleNames.AddRange(new string[] {
            "Core",
            "CoreUObject",
            "Engine",
        });

        PrivateDependencyModuleNames.AddRange(new string[] {
            "UnrealEd",         // commandlets, asset creation, package saving
            "UMG",              // the widget classes themselves
            "UMGEditor",        // UWidgetBlueprint and its factory
            "Kismet",           // compiling the blueprint afterwards
            "KismetCompiler",
            "AssetTools",
            "Slate",
            "SlateCore",
            "Projects",
        });
    }
}
