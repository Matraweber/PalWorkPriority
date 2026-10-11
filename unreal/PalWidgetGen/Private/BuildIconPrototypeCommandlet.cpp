#include "BuildIconPrototypeCommandlet.h"
#include "WidgetBlueprint.h"
#include "WidgetBlueprintFactory.h"
#include "Blueprint/WidgetTree.h"
#include "Blueprint/UserWidget.h"
#include "Components/Widget.h"
#include "EdGraphSchema_K2.h"
#include "K2Node_CustomEvent.h"
#include "K2Node_CallFunction.h"
#include "K2Node_VariableGet.h"
#include "K2Node_IfThenElse.h"
#include "Kismet/KismetSystemLibrary.h"
#include "Kismet2/BlueprintEditorUtils.h"
#include "Kismet2/KismetEditorUtilities.h"
#include "UObject/SavePackage.h"

UBuildIconPrototypeCommandlet::UBuildIconPrototypeCommandlet()
{
    IsClient = false; IsServer = false; IsEditor = true; LogToConsole = true;
}

int32 UBuildIconPrototypeCommandlet::Main(const FString& Params)
{
    // Editor-only generator. The resulting asset references shipped classes only.
    UClass* ImageClass = LoadClass<UWidget>(nullptr, TEXT("/Script/CommonUI.CommonLazyImage"));
    UClass* Utility = LoadClass<UObject>(nullptr, TEXT("/Script/Pal.PalUtility"));
    UClass* Manager = LoadClass<UObject>(nullptr, TEXT("/Script/Pal.PalItemIDManager"));
    UClass* Data = LoadClass<UObject>(nullptr, TEXT("/Script/Pal.PalStaticItemDataBase"));
    if (!ImageClass || !Utility || !Manager || !Data) return 1;
    const FString Path = TEXT("/Game/Mods/PalWorkPriorityPrototype/WBP_LazyItemIcon");
    if (LoadObject<UObject>(nullptr, *Path)) return 2; // Never overwrite an experiment silently.
    UPackage* Package = CreatePackage(*Path);
    auto* Factory = NewObject<UWidgetBlueprintFactory>();
    Factory->ParentClass = UUserWidget::StaticClass();
    auto* BP = Cast<UWidgetBlueprint>(Factory->FactoryCreateNew(UWidgetBlueprint::StaticClass(),
        Package, TEXT("WBP_LazyItemIcon"), RF_Public | RF_Standalone, nullptr, GWarn));
    if (!BP) return 3;
    UWidget* Image = BP->WidgetTree->ConstructWidget<UWidget>(ImageClass, TEXT("Icon"));
    Image->bIsVariable = true;
    BP->WidgetTree->RootWidget = Image;
    FBlueprintEditorUtils::MarkBlueprintAsStructurallyModified(BP);
    FKismetEditorUtilities::CompileBlueprint(BP);
    UEdGraph* Graph = BP->UbergraphPages[0];
    const auto* Schema = GetDefault<UEdGraphSchema_K2>();
    auto Link = [Schema](UEdGraphPin* A, UEdGraphPin* B) {
        return A && B && Schema->TryCreateConnection(A, B);
    };
    auto Call = [Graph](UClass* Class, const TCHAR* Name) -> UK2Node_CallFunction* {
        UFunction* Fn = Class->FindFunctionByName(Name);
        if (!Fn) return nullptr;
        auto* N = NewObject<UK2Node_CallFunction>(Graph);
        Graph->AddNode(N); N->CreateNewGuid(); N->SetFromFunction(Fn); N->AllocateDefaultPins();
        return N;
    };
    auto* Event = NewObject<UK2Node_CustomEvent>(Graph);
    Graph->AddNode(Event); Event->CreateNewGuid(); Event->CustomFunctionName = TEXT("SetItem");
    Event->AllocateDefaultPins();
    FEdGraphPinType NameType; NameType.PinCategory = UEdGraphSchema_K2::PC_Name;
    Event->CreateUserDefinedPin(TEXT("ItemId"), NameType, EGPD_Output);
    auto* GetManager = Call(Utility, TEXT("GetItemIDManager"));
    auto* GetData = Call(Manager, TEXT("GetStaticItemData"));
    auto* SetIcon = Call(ImageClass, TEXT("SetBrushFromLazyTexture"));
    auto* ClearIcon = Call(ImageClass, TEXT("SetBrushFromTexture"));
    if (!GetManager || !GetData || !SetIcon || !ClearIcon) return 4;
    auto* Texture = NewObject<UK2Node_VariableGet>(Graph);
    Graph->AddNode(Texture); Texture->CreateNewGuid();
    Texture->VariableReference.SetExternalMember(TEXT("IconTexture"), Data); Texture->AllocateDefaultPins();
    auto* Target = NewObject<UK2Node_VariableGet>(Graph);
    Graph->AddNode(Target); Target->CreateNewGuid();
    Target->VariableReference.SetSelfMember(TEXT("Icon")); Target->AllocateDefaultPins();
    bool Good = Link(Event->FindPin(TEXT("ItemId")), GetData->FindPin(TEXT("StaticItemId")))
        && Link(GetManager->GetReturnValuePin(), GetData->FindPin(UEdGraphSchema_K2::PN_Self))
        && Link(GetData->GetReturnValuePin(), Texture->FindPin(UEdGraphSchema_K2::PN_Self))
        && Link(Texture->GetValuePin(), SetIcon->FindPin(TEXT("LazyTexture")))
        && Link(Target->GetValuePin(), SetIcon->FindPin(UEdGraphSchema_K2::PN_Self));
    Good = Link(Target->GetValuePin(), ClearIcon->FindPin(UEdGraphSchema_K2::PN_Self)) && Good;
    UEdGraphPin* Exec = Event->FindPin(UEdGraphSchema_K2::PN_Then);
    // Clear first, cancelling the preceding request even for an invalid ID.
    for (auto* N : {ClearIcon, GetManager}) {
        if (auto* Input = N->FindPin(UEdGraphSchema_K2::PN_Execute)) {
            Good = Link(Exec, Input) && Good;
            Exec = N->FindPin(UEdGraphSchema_K2::PN_Then);
        }
    }
    // Do not dereference missing manager/data. The false branches leave a blank tile.
    for (auto* Value : {GetManager->GetReturnValuePin(), GetData->GetReturnValuePin()}) {
        auto* Valid = Call(UKismetSystemLibrary::StaticClass(), TEXT("IsValid"));
        if (!Valid) return 4;
        auto* Branch = NewObject<UK2Node_IfThenElse>(Graph);
        Graph->AddNode(Branch); Branch->CreateNewGuid(); Branch->AllocateDefaultPins();
        Good = Link(Value, Valid->FindPin(TEXT("Object"))) && Good;
        Good = Link(Valid->GetReturnValuePin(), Branch->GetConditionPin()) && Good;
        Good = Link(Exec, Branch->GetExecPin()) && Good;
        Exec = Branch->GetThenPin();
    }
    Good = Link(Exec, SetIcon->FindPin(UEdGraphSchema_K2::PN_Execute)) && Good;
    if (!Good) return 5;
    FBlueprintEditorUtils::MarkBlueprintAsStructurallyModified(BP);
    FKismetEditorUtilities::CompileBlueprint(BP);
    if (BP->Status == BS_Error) return 6;
    FSavePackageArgs Args; Args.TopLevelFlags = RF_Public | RF_Standalone;
    return UPackage::SavePackage(Package, BP,
        *FPackageName::LongPackageNameToFilename(Path, FPackageName::GetAssetPackageExtension()), Args) ? 0 : 7;
}
