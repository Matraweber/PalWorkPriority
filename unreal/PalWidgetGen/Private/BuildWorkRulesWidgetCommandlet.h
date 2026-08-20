#pragma once

#include "CoreMinimal.h"
#include "Commandlets/Commandlet.h"
#include "BuildWorkRulesWidgetCommandlet.generated.h"

/**
 * Builds Content/Mods/PalWorkPriority in code, headless.
 *
 *   UnrealEditor-Cmd.exe Pal.uproject -run=BuildWorkRulesWidget
 *
 * Why this exists rather than a person dragging widgets in the UMG designer:
 * Unreal 5.1 does not expose UWidgetBlueprint's WidgetTree to Python. Probed,
 * not assumed. WidgetTree, GeneratedClass and ParentClass all come back
 * unreachable, so a Python script can create the asset and put nothing at all
 * inside it.
 *
 * C++ has no such restriction. WidgetTree->ConstructWidget is the call that
 * puts a widget into the tree rather than merely creating an object, and it
 * is ordinary editor code.
 *
 * Doing it here rather than by hand also makes the layout a thing that can be
 * re-run, diffed and reviewed, and every widget name a compile time constant
 * rather than something typed into a details panel once and misspelled.
 */
UCLASS()
class UBuildWorkRulesWidgetCommandlet : public UCommandlet
{
	GENERATED_BODY()

public:
	UBuildWorkRulesWidgetCommandlet();

	virtual int32 Main(const FString& Params) override;
};
