#include "BuildWorkRulesWidgetCommandlet.h"

#include "AssetToolsModule.h"
#include "IAssetTools.h"
#include "FileHelpers.h"

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
#include "Components/HorizontalBox.h"
#include "Components/HorizontalBoxSlot.h"
#include "Components/ScrollBox.h"
#include "Components/TextBlock.h"
#include "Components/EditableTextBox.h"
#include "Components/Button.h"

#include "Factories/BlueprintFactory.h"
#include "Engine/Blueprint.h"
#include "GameFramework/Actor.h"
#include "Kismet2/BlueprintEditorUtils.h"
#include "Kismet2/KismetEditorUtilities.h"
#include "UObject/SavePackage.h"

DEFINE_LOG_CATEGORY_STATIC(LogWorkRulesWidget, Log, All);

namespace
{
	const TCHAR* ModFolder = TEXT("/Game/Mods/PalWorkPriority");
	const TCHAR* UiFolder = TEXT("/Game/Mods/PalWorkPriority/UI");
	const TCHAR* WidgetName = TEXT("WBP_WorkRules");
	const TCHAR* ActorName = TEXT("ModActor");

	void Say(const FString& Line)
	{
		UE_LOG(LogWorkRulesWidget, Display, TEXT("%s"), *Line);
	}

	/**
	 * Construct a widget into the tree and name it.
	 *
	 * The name is the whole point. Lua reaches every one of these with
	 * GetWidgetFromName, so a widget without one is invisible to the mod
	 * however well it renders. bIsVariable is what keeps the name in the
	 * compiled class, and is the code equivalent of ticking "Is Variable" in
	 * the designer.
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
	Say(TEXT("building Content/Mods/PalWorkPriority"));

	IAssetTools& AssetTools =
		FModuleManager::LoadModuleChecked<FAssetToolsModule>("AssetTools").Get();

	// ------------------------------------------------------------------
	// ModActor
	// ------------------------------------------------------------------
	//
	// Empty on purpose. UE4SS recognises a pak as a LogicMod by finding one
	// of these in it, and it does nothing else, so it needs nothing in it.
	{
		const FString Path = FString::Printf(TEXT("%s/%s.%s"),
			ModFolder, ActorName, ActorName);

		UBlueprint* Actor = LoadObject<UBlueprint>(nullptr, *Path);
		if (!Actor)
		{
			UBlueprintFactory* Factory = NewObject<UBlueprintFactory>();
			Factory->ParentClass = AActor::StaticClass();

			Actor = Cast<UBlueprint>(AssetTools.CreateAsset(
				ActorName, ModFolder, UBlueprint::StaticClass(), Factory));
		}

		if (!Actor)
		{
			Say(TEXT("FAILED: could not create ModActor"));
			return 1;
		}

		FKismetEditorUtilities::CompileBlueprint(Actor);
		Say(SaveAsset(Actor)
			? TEXT("  ModActor saved")
			: TEXT("  ModActor could NOT be saved"));
	}

	// ------------------------------------------------------------------
	// WBP_WorkRules
	// ------------------------------------------------------------------
	const FString WidgetPath = FString::Printf(TEXT("%s/%s.%s"),
		UiFolder, WidgetName, WidgetName);

	UWidgetBlueprint* Blueprint = LoadObject<UWidgetBlueprint>(nullptr, *WidgetPath);

	if (!Blueprint)
	{
		UWidgetBlueprintFactory* Factory = NewObject<UWidgetBlueprintFactory>();

		// Plain UserWidget, not one of the Pal types. Nothing here wants the
		// game's HUD behaviour, and a plain widget is one less thing to be
		// surprised by.
		Factory->ParentClass = UUserWidget::StaticClass();

		Blueprint = Cast<UWidgetBlueprint>(AssetTools.CreateAsset(
			WidgetName, UiFolder, UWidgetBlueprint::StaticClass(), Factory));
	}

	if (!Blueprint || !Blueprint->WidgetTree)
	{
		Say(TEXT("FAILED: no widget blueprint, or it has no widget tree"));
		return 1;
	}

	UWidgetTree* Tree = Blueprint->WidgetTree;

	// Re-runnable. Dropping the root detaches whatever a previous run built,
	// so this can be edited and run again rather than being a one shot that
	// has to be right first time.
	Tree->RootWidget = nullptr;

	// ------------------------------------------------------------------
	// The tree
	// ------------------------------------------------------------------
	UCanvasPanel* Root = Make<UCanvasPanel>(Tree, TEXT("Root"));
	Tree->RootWidget = Root;

	UBorder* Backdrop = Make<UBorder>(Tree, TEXT("Backdrop"));
	Backdrop->SetBrushColor(FLinearColor(0.03f, 0.05f, 0.08f, 0.92f));

	if (UCanvasPanelSlot* Slot = Cast<UCanvasPanelSlot>(Root->AddChild(Backdrop)))
	{
		// Anchored to the middle of the screen and aligned about its own
		// centre, so it stays centred at any resolution rather than at the
		// one it was laid out on.
		Slot->SetAnchors(FAnchors(0.5f, 0.5f, 0.5f, 0.5f));
		Slot->SetAlignment(FVector2D(0.5f, 0.5f));
		Slot->SetPosition(FVector2D(0.0f, 0.0f));
		Slot->SetSize(FVector2D(900.0f, 700.0f));
	}

	UVerticalBox* Body = Make<UVerticalBox>(Tree, TEXT("Body"));
	if (UBorderSlot* Slot = Cast<UBorderSlot>(Backdrop->AddChild(Body)))
	{
		Slot->SetPadding(FMargin(18.0f));
	}

	UTextBlock* Title = Make<UTextBlock>(Tree, TEXT("Title"));
	Title->SetText(FText::FromString(TEXT("WORK RULES")));
	{
		// GetFont rather than the Font field, which 5.1 deprecates.
		FSlateFontInfo Font = Title->GetFont();
		Font.Size = 24;
		Title->SetFont(Font);
	}
	Body->AddChild(Title);

	UEditableTextBox* Search = Make<UEditableTextBox>(Tree, TEXT("Search"));
	Search->SetHintText(FText::FromString(TEXT("search items")));
	Body->AddChild(Search);

	// Two lists rather than one, so moving between the rules and the picker
	// is a visibility flip rather than tearing down and rebuilding rows.
	UScrollBox* RuleList = Make<UScrollBox>(Tree, TEXT("RuleList"));
	if (UVerticalBoxSlot* Slot = Cast<UVerticalBoxSlot>(Body->AddChild(RuleList)))
	{
		Slot->SetSize(FSlateChildSize(ESlateSizeRule::Fill));
	}

	UScrollBox* ItemList = Make<UScrollBox>(Tree, TEXT("ItemList"));
	if (UVerticalBoxSlot* Slot = Cast<UVerticalBoxSlot>(Body->AddChild(ItemList)))
	{
		Slot->SetSize(FSlateChildSize(ESlateSizeRule::Fill));
	}
	// The panel opens on the rules, so the picker starts out of the way.
	ItemList->SetVisibility(ESlateVisibility::Collapsed);

	UHorizontalBox* Actions = Make<UHorizontalBox>(Tree, TEXT("Actions"));
	Body->AddChild(Actions);

	auto AddButton = [&](const TCHAR* Name, const TCHAR* LabelName,
		const TCHAR* Label)
	{
		UButton* Button = Make<UButton>(Tree, Name);
		UTextBlock* Text = Make<UTextBlock>(Tree, LabelName);
		Text->SetText(FText::FromString(Label));
		Button->AddChild(Text);
		Actions->AddChild(Button);
	};

	AddButton(TEXT("NewRuleButton"), TEXT("NewRuleLabel"), TEXT("new rule"));
	AddButton(TEXT("CloseButton"), TEXT("CloseLabel"), TEXT("close"));

	// ------------------------------------------------------------------
	// Compile, save, and say what is actually in there
	// ------------------------------------------------------------------
	FBlueprintEditorUtils::MarkBlueprintAsStructurallyModified(Blueprint);
	FKismetEditorUtilities::CompileBlueprint(Blueprint);

	const bool bSaved = SaveAsset(Blueprint);

	// Read back rather than assume. Every name below is one Lua will ask for
	// by string, and a widget that failed to be named fails silently at that
	// point instead of here.
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
