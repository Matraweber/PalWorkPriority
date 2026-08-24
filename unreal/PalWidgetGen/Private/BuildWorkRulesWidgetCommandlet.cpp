#include "BuildWorkRulesWidgetCommandlet.h"

#include "AssetToolsModule.h"
#include "IAssetTools.h"

#include "WidgetBlueprint.h"
#include "WidgetBlueprintFactory.h"
#include "Blueprint/WidgetTree.h"
#include "Blueprint/UserWidget.h"

#include "Components/CanvasPanel.h"
#include "Components/CanvasPanelSlot.h"
#include "Components/Border.h"
#include "Components/BorderSlot.h"
#include "Components/VerticalBox.h"
#include "Components/VerticalBoxSlot.h"
#include "Components/ScrollBox.h"
#include "Components/SizeBox.h"

#include "Kismet2/BlueprintEditorUtils.h"
#include "Kismet2/KismetEditorUtilities.h"
#include "UObject/SavePackage.h"

DEFINE_LOG_CATEGORY_STATIC(LogWorkRulesWidget, Log, All);

namespace
{
	const TCHAR* UiFolder = TEXT("/Game/Mods/PalWorkPriority/UI");
	const TCHAR* WidgetName = TEXT("WBP_WorkRules");

	void Say(const FString& Line)
	{
		UE_LOG(LogWorkRulesWidget, Display, TEXT("%s"), *Line);
	}

	/**
	 * Named, and named on the GENERATED CLASS.
	 *
	 * bIsVariable is what promotes a widget to a property of the compiled
	 * class, and a property read is the only way the Lua side can pick these
	 * up: GetWidgetFromName looks like the obvious API and is not a UFUNCTION,
	 * so UE4SS cannot call it at all. A widget that loses its name here fails
	 * silently there, at the point a row does not appear.
	 */
	template <typename T>
	T* Make(UWidgetTree* Tree, const TCHAR* Name)
	{
		T* Widget = Tree->ConstructWidget<T>(T::StaticClass(), FName(Name));
		if (Widget)
		{
			Widget->bIsVariable = true;
		}
		return Widget;
	}

	bool SaveAsset(UObject* Asset)
	{
		UPackage* Package = Asset->GetOutermost();
		Package->MarkPackageDirty();

		const FString FileName = FPackageName::LongPackageNameToFilename(
			Package->GetName(), FPackageName::GetAssetPackageExtension());

		FSavePackageArgs Args;
		Args.TopLevelFlags = RF_Public | RF_Standalone;
		Args.SaveFlags = SAVE_NoError;
		return UPackage::SavePackage(Package, nullptr, *FileName, Args);
	}

	/** One row of the stack: a fixed height box wrapping a canvas. */
	struct FRow
	{
		const TCHAR* Name;
		float Height;
	};

	/**
	 * The shell is a STACK OF ROWS, and that is the whole design.
	 *
	 * The first shell held a title, a search box, two lists and a button row,
	 * and the panel could use exactly one of them. Everything else it draws -
	 * tabs, a subtitle, a caption, column headings, an add bar - had nowhere
	 * to go, so it kept drawing those at absolute canvas coordinates. Half the
	 * panel in a Slate flow and half in fixed coordinates only holds together
	 * while the flow contains one thing: the moment a second container joined
	 * it, every sibling below shifted and the rows scattered across the panel.
	 *
	 * So every line the panel draws gets its own fixed height SizeBox wrapping
	 * its own CanvasPanel. Slate owns the vertical order; the panel keeps the
	 * X positions it already has, inside a row that is only as tall as it
	 * needs to be. That is the arrangement that already worked for the list
	 * rows, applied to the rest of the panel.
	 *
	 * A row the current screen does not want is collapsed and costs no height,
	 * which is how one shell serves the rules screen and the picker both.
	 *
	 * Heights come from the panel's own constants: LINE is 34, and the rows
	 * carrying smaller text are sized to that text.
	 */
	const FRow HeadRows[] = {
		{ TEXT("Tabs"),    34.0f },   // RULES  ADD ............... CLOSE
		{ TEXT("Title"),   34.0f },   // Production Limits
		{ TEXT("Sub"),     26.0f },   // the sentence under the title
		{ TEXT("Notice"),  22.0f },   // editing caption and transient notices
		{ TEXT("Search"),  40.0f },   // the picker's search field
		{ TEXT("Caption"), 24.0f },   // "What your storage holds, 13 items"
		{ TEXT("Head"),    28.0f },   // JOB ITEM IN STORAGE LIMIT STATUS
	};

	/** After the two lists: the add bar, or the pager and Back. */
	const FRow TailRows[] = {
		{ TEXT("Foot"),    76.0f },
	};
}

UBuildWorkRulesWidgetCommandlet::UBuildWorkRulesWidgetCommandlet()
{
	IsClient = false;
	IsServer = false;
	IsEditor = true;
	LogToConsole = true;
}

int32 UBuildWorkRulesWidgetCommandlet::Main(const FString& Params)
{
	Say(TEXT("building the work rules shell"));

	FAssetToolsModule& AssetToolsModule =
		FModuleManager::LoadModuleChecked<FAssetToolsModule>(TEXT("AssetTools"));
	IAssetTools& AssetTools = AssetToolsModule.Get();

	UWidgetBlueprintFactory* Factory = NewObject<UWidgetBlueprintFactory>();
	Factory->ParentClass = UUserWidget::StaticClass();

	UWidgetBlueprint* Blueprint = Cast<UWidgetBlueprint>(AssetTools.CreateAsset(
		WidgetName, UiFolder, UWidgetBlueprint::StaticClass(), Factory));

	if (!Blueprint || !Blueprint->WidgetTree)
	{
		Say(TEXT("FAILED: no widget blueprint, or it has no widget tree"));
		return 1;
	}

	UWidgetTree* Tree = Blueprint->WidgetTree;

	// Re-runnable. Dropping the root detaches whatever a previous run built,
	// so this can be edited and run again rather than being a one shot.
	Tree->RootWidget = nullptr;

	UCanvasPanel* Root = Make<UCanvasPanel>(Tree, TEXT("Root"));
	Tree->RootWidget = Root;

	// Centred, with a placeholder size. The panel sets the real one at
	// runtime, because the panel is what knows how wide the panel is and a
	// number baked in here can only be changed by rebuilding this asset.
	UBorder* Backdrop = Make<UBorder>(Tree, TEXT("Backdrop"));
	Backdrop->SetBrushColor(FLinearColor(0.03f, 0.05f, 0.08f, 0.92f));

	if (UCanvasPanelSlot* Slot = Cast<UCanvasPanelSlot>(Root->AddChild(Backdrop)))
	{
		Slot->SetAnchors(FAnchors(0.5f, 0.5f, 0.5f, 0.5f));
		Slot->SetAlignment(FVector2D(0.5f, 0.5f));
		Slot->SetPosition(FVector2D(0.0f, 0.0f));
		Slot->SetSize(FVector2D(1086.0f, 700.0f));
	}

	UVerticalBox* Body = Make<UVerticalBox>(Tree, TEXT("Body"));
	if (UBorderSlot* Slot = Cast<UBorderSlot>(Backdrop->AddChild(Body)))
	{
		Slot->SetPadding(FMargin(18.0f));
	}

	auto AddRow = [&](const FRow& Row)
	{
		const FString BoxName = FString(Row.Name) + TEXT("Row");
		USizeBox* Box = Make<USizeBox>(Tree, *BoxName);
		Box->SetHeightOverride(Row.Height);

		// The canvas is what the panel draws into. A CanvasPanel reports no
		// desired size of its own, which is exactly why the SizeBox is here:
		// without one the row would be laid out at zero height and nothing
		// inside it would ever be seen.
		UCanvasPanel* Canvas = Make<UCanvasPanel>(Tree, Row.Name);
		Box->AddChild(Canvas);
		Body->AddChild(Box);
	};

	for (const FRow& Row : HeadRows)
	{
		AddRow(Row);
	}

	// Automatic, never Fill.
	//
	// Two Fill siblings take half the body each whatever is in them, so an
	// emptied list still held half the panel and started the other one in the
	// middle of it. Automatic sizes each to its own content, which is what
	// makes emptying one actually give the space back.
	const TCHAR* Lists[] = { TEXT("RuleList"), TEXT("ItemList") };
	for (const TCHAR* Name : Lists)
	{
		UScrollBox* List = Make<UScrollBox>(Tree, Name);
		if (UVerticalBoxSlot* Slot = Cast<UVerticalBoxSlot>(Body->AddChild(List)))
		{
			Slot->SetSize(FSlateChildSize(ESlateSizeRule::Automatic));
		}
	}

	for (const FRow& Row : TailRows)
	{
		AddRow(Row);
	}

	FBlueprintEditorUtils::MarkBlueprintAsStructurallyModified(Blueprint);
	FKismetEditorUtilities::CompileBlueprint(Blueprint);

	const bool bSaved = SaveAsset(Blueprint);

	// Read back rather than assume. Every name below is one the Lua side asks
	// for by string, and a widget that failed to be named fails silently
	// there rather than here.
	Say(TEXT("widgets in the saved tree:"));

	int32 Named = 0;
	Tree->ForEachWidget([&Named](UWidget* Widget)
	{
		if (Widget)
		{
			++Named;
			Say(FString::Printf(TEXT("  %-16s %s"),
				*Widget->GetName(), *Widget->GetClass()->GetName()));
		}
	});

	Say(FString::Printf(TEXT("%d widget(s), saved: %s"),
		Named, bSaved ? TEXT("yes") : TEXT("NO")));

	return bSaved ? 0 : 1;
}
