#include "BuildStandInputWidgetCommandlet.h"

#include "WidgetBlueprint.h"
#include "WidgetBlueprintFactory.h"
#include "Blueprint/UserWidget.h"
#include "Blueprint/WidgetBlueprintLibrary.h"
#include "Blueprint/WidgetTree.h"
#include "Components/Border.h"
#include "Framework/Application/SlateApplication.h"
#include "Widgets/SWindow.h"
#include "Interfaces/ISlateNullRendererModule.h"
#include "Modules/ModuleManager.h"
#include "Misc/ScopeExit.h"
#include "EdGraphSchema_K2.h"
#include "Engine/BlueprintGeneratedClass.h"
#include "Input/Events.h"
#include "InputCoreTypes.h"
#include "K2Node_CallFunction.h"
#include "K2Node_FunctionEntry.h"
#include "K2Node_FunctionResult.h"
#include "K2Node_IfThenElse.h"
#include "K2Node_Self.h"
#include "K2Node_VariableGet.h"
#include "K2Node_VariableSet.h"
#include "Kismet/KismetInputLibrary.h"
#include "Kismet/KismetMathLibrary.h"
#include "Kismet/KismetStringLibrary.h"
#include "Kismet2/BlueprintEditorUtils.h"
#include "Kismet2/CompilerResultsLog.h"
#include "Kismet2/KismetEditorUtilities.h"
#include "Misc/PackageName.h"
#include "Misc/Parse.h"
#include "UObject/SavePackage.h"
#include "UObject/UnrealType.h"

namespace StandInput
{
static const TCHAR* PackagePath = TEXT("/Game/Mods/PalWorkPriority/UI/WBP_StandInput");
static const TCHAR* AssetName = TEXT("WBP_StandInput");
static const FString LegacyOwner(TEXT("PWP generated stand input contract 1"));
static const FString Owner(TEXT("PWP generated stand input contract 2"));
static const FName Target(TEXT("PWP_Target")), Epoch(TEXT("PWP_Epoch")), UiEpoch(TEXT("PWP_UiEpoch"));
static const FName Direction(TEXT("PWP_Direction")), Contract(TEXT("PWP_Contract"));
static const FName Sequence(TEXT("PWP_Sequence")), Dispatch(TEXT("PWP_Dispatch"));
static const FName Down(TEXT("OnMouseButtonDown")), Double(TEXT("OnMouseButtonDoubleClick"));
static const FName Priority(TEXT("PWP_Priority")), KeySequence(TEXT("PWP_KeySequence"));
static const FName KeyDispatch(TEXT("PWP_KeyDispatch")), KeyDown(TEXT("OnKeyDown"));

static bool Check(bool Good, const FString& What)
{
    UE_LOG(LogTemp, Display, TEXT("PWP stand input: %s %s"), *What, Good ? TEXT("PASS") : TEXT("FAILED"));
    return Good;
}
static bool Compile(UWidgetBlueprint* BP)
{
    FBlueprintEditorUtils::MarkBlueprintAsStructurallyModified(BP);
    FCompilerResultsLog Results;
    FKismetEditorUtilities::CompileBlueprint(BP, EBlueprintCompileOptions::None, &Results);
    return Check(Results.NumErrors == 0 && BP->Status != BS_Error && BP->GeneratedClass,
        FString::Printf(TEXT("compile errors=%d warnings=%d"), Results.NumErrors, Results.NumWarnings));
}
static bool Member(UWidgetBlueprint* BP, FName Name, FName Category, const FString& Default)
{
    FEdGraphPinType Type; Type.PinCategory = Category;
    const int32 Index = FBlueprintEditorUtils::FindNewVariableIndex(BP, Name);
    if (Index == INDEX_NONE) return FBlueprintEditorUtils::AddMemberVariable(BP, Name, Type, Default);
    if (!Check(BP->NewVariables[Index].VarType == Type, TEXT("member type ") + Name.ToString())) return false;
    BP->NewVariables[Index].DefaultValue = Default;
    return true;
}
static UEdGraphPin* Exec(UEdGraphNode* N) { return N->FindPin(UEdGraphSchema_K2::PN_Execute); }
static UEdGraphPin* Then(UEdGraphNode* N) { return N->FindPin(UEdGraphSchema_K2::PN_Then); }

// Self-contained version of the proven graph builder. No runtime C++ class,
// delegate binding, mouse-event reflection in Lua, or editor-module reference.
struct FGraph
{
    UEdGraph* Graph;
    const UEdGraphSchema_K2* Schema = GetDefault<UEdGraphSchema_K2>();
    bool Good = true;
    TArray<TPair<UEdGraphPin*, UEdGraphPin*>> Links;
    UK2Node_FunctionEntry* Entry = nullptr;
    UK2Node_FunctionResult* Result = nullptr;

    FGraph(UWidgetBlueprint* BP, FName Name, bool Override)
    {
        Graph = FBlueprintEditorUtils::CreateNewGraph(BP, Name, UEdGraph::StaticClass(), UEdGraphSchema_K2::StaticClass());
        if (Override) FBlueprintEditorUtils::AddFunctionGraph(BP, Graph, false, UUserWidget::StaticClass());
        else FBlueprintEditorUtils::AddFunctionGraph(BP, Graph, true, static_cast<UFunction*>(nullptr));
        for (UEdGraphNode* N : Graph->Nodes)
        {
            N->NodeComment = Owner;
            if (auto* E = Cast<UK2Node_FunctionEntry>(N)) Entry = E;
            if (auto* R = Cast<UK2Node_FunctionResult>(N)) Result = R;
        }
        Good = Entry && (!Override || Result);
        if (Entry) Then(Entry)->BreakAllPinLinks();
    }
    template<class T> T* Node()
    {
        T* N = NewObject<T>(Graph); Graph->AddNode(N); N->CreateNewGuid(); N->NodeComment = Owner;
        N->NodePosX = Graph->Nodes.Num() * 200; return N;
    }
    void Link(UEdGraphPin* A, UEdGraphPin* B)
    {
        const bool Ok = A && B && Schema->TryCreateConnection(A, B) && A->LinkedTo.Contains(B) && B->LinkedTo.Contains(A);
        Good &= Ok;
        if (Ok) Links.Emplace(A, B);
        else Check(false, TEXT("link in ") + Graph->GetName() + TEXT(": ")
            + (A ? A->PinName.ToString() : TEXT("missing")) + TEXT(" -> ") + (B ? B->PinName.ToString() : TEXT("missing")));
    }
    void Default(UEdGraphPin* Pin, const FString& Value)
    {
        if (!Pin) { Good = false; return; }
        Schema->TrySetDefaultValue(*Pin, Value); Good &= Pin->DefaultValue == Value;
    }
    UK2Node_CallFunction* Call(UClass* Class, FName Name, bool Self = false)
    {
        UFunction* Fn = Class ? Class->FindFunctionByName(Name) : nullptr;
        if (!Fn) { Good = false; return nullptr; }
        auto* N = Node<UK2Node_CallFunction>(); N->SetFromFunction(Fn);
        if (Self) N->FunctionReference.SetSelfMember(Name);
        N->AllocateDefaultPins(); return N;
    }
    UK2Node_VariableGet* Get(FName Name)
    {
        auto* N = Node<UK2Node_VariableGet>(); N->VariableReference.SetSelfMember(Name); N->AllocateDefaultPins(); return N;
    }
    UK2Node_VariableSet* Set(FName Name, const TCHAR* Value = nullptr)
    {
        auto* N = Node<UK2Node_VariableSet>(); N->VariableReference.SetSelfMember(Name); N->AllocateDefaultPins();
        if (Value) Default(N->FindPin(Name), Value); return N;
    }
    UK2Node_IfThenElse* Branch()
    {
        auto* N = Node<UK2Node_IfThenElse>(); N->AllocateDefaultPins(); return N;
    }
    bool Finish()
    {
        for (const auto& Pair : Links) Good &= Pair.Key->LinkedTo.Contains(Pair.Value) && Pair.Value->LinkedTo.Contains(Pair.Key);
        return Check(Good, TEXT("graph ") + Graph->GetName());
    }
};

static bool BuildDispatch(UWidgetBlueprint* BP, FName Function, FName Counter)
{
    FGraph G(BP, Function, false);
    if (!G.Good) return false;
    auto* Before = G.Get(Counter);
    auto* Add = G.Call(UKismetMathLibrary::StaticClass(), TEXT("Add_IntInt"));
    auto* After = G.Set(Counter);
    if (!Add) return false;
    G.Link(Before->FindPin(Counter), Add->FindPin(TEXT("A"))); G.Default(Add->FindPin(TEXT("B")), TEXT("1"));
    G.Link(Add->GetReturnValuePin(), After->FindPin(Counter)); G.Link(Then(G.Entry), Exec(After));
    if (G.Result) G.Link(Then(After), Exec(G.Result));
    return G.Finish() && Compile(BP); // Resolve the own callable function before building handlers.
}

static bool BuildMouse(UWidgetBlueprint* BP, FName Name)
{
    FGraph G(BP, Name, true);
    if (!G.Good) return false;
    auto* Yes = G.Node<UK2Node_FunctionResult>();
    Yes->FunctionReference = G.Entry->FunctionReference; Yes->AllocateDefaultPins();
    auto* Handled = G.Call(UWidgetBlueprintLibrary::StaticClass(), TEXT("Handled"));
    auto* Unhandled = G.Call(UWidgetBlueprintLibrary::StaticClass(), TEXT("Unhandled"));
    auto* Empty = G.Call(UKismetStringLibrary::StaticClass(), TEXT("IsEmpty"));
    auto* Key = G.Call(UKismetInputLibrary::StaticClass(), TEXT("PointerEvent_GetEffectingButton"));
    auto* Left = G.Call(UKismetInputLibrary::StaticClass(), TEXT("EqualEqual_KeyKey"));
    auto* Right = G.Call(UKismetInputLibrary::StaticClass(), TEXT("EqualEqual_KeyKey"));
    auto* Send = G.Call(BP->SkeletonGeneratedClass, Dispatch, true);
    auto* Focus = G.Call(UWidgetBlueprintLibrary::StaticClass(), TEXT("SetUserFocus"));
    auto* Self = G.Node<UK2Node_Self>(); Self->AllocateDefaultPins();
    if (!Handled || !Unhandled || !Empty || !Key || !Left || !Right || !Send || !Focus) return false;
    G.Link(Handled->GetReturnValuePin(), Focus->FindPin(TEXT("Reply")));
    G.Link(Self->FindPin(UEdGraphSchema_K2::PN_Self), Focus->FindPin(TEXT("FocusWidget")));
    G.Default(Focus->FindPin(TEXT("bInAllUsers")), TEXT("false"));
    G.Link(Focus->GetReturnValuePin(), Yes->FindPin(UEdGraphSchema_K2::PN_ReturnValue));
    G.Link(Unhandled->GetReturnValuePin(), G.Result->FindPin(UEdGraphSchema_K2::PN_ReturnValue));
    auto* Reset = G.Set(Direction, TEXT("0"));
    auto* TargetValue = G.Get(Target); auto* Guard = G.Branch();
    G.Link(Then(G.Entry), Exec(Reset)); G.Link(Then(Reset), Exec(Guard));
    G.Link(TargetValue->FindPin(Target), Empty->FindPin(TEXT("InString")));
    G.Link(Empty->GetReturnValuePin(), Guard->GetConditionPin()); G.Link(Guard->GetThenPin(), Exec(G.Result));
    // The double-click override uses different inherited parameter names.
    G.Link(G.Entry->FindPin(Name == Down ? TEXT("MouseEvent") : TEXT("InMouseEvent")), Key->FindPin(TEXT("Input")));
    G.Link(Key->GetReturnValuePin(), Left->FindPin(TEXT("A"))); G.Default(Left->FindPin(TEXT("B")), EKeys::LeftMouseButton.ToString());
    G.Link(Key->GetReturnValuePin(), Right->FindPin(TEXT("A"))); G.Default(Right->FindPin(TEXT("B")), EKeys::RightMouseButton.ToString());
    auto* IsLeft = G.Branch(); auto* IsRight = G.Branch();
    G.Link(Guard->GetElsePin(), Exec(IsLeft)); G.Link(Left->GetReturnValuePin(), IsLeft->GetConditionPin());
    G.Link(IsLeft->GetElsePin(), Exec(IsRight)); G.Link(Right->GetReturnValuePin(), IsRight->GetConditionPin());
    G.Link(IsRight->GetElsePin(), Exec(G.Result));
    auto* Minus = G.Set(Direction, TEXT("-1")); auto* Plus = G.Set(Direction, TEXT("1"));
    G.Link(IsLeft->GetThenPin(), Exec(Minus)); G.Link(IsRight->GetThenPin(), Exec(Plus));
    // The UE4SS pre-hook sees direction already assigned on this current self.
    // Exactly one dispatch per event, including the second press's double event.
    G.Link(Then(Minus), Exec(Send)); G.Link(Then(Plus), Exec(Send)); G.Link(Then(Send), Exec(Yes));
    return G.Finish();
}

static bool BuildKeys(UWidgetBlueprint* BP)
{
    FGraph G(BP, KeyDown, true);
    if (!G.Good) return false;
    auto* Yes = G.Node<UK2Node_FunctionResult>();
    Yes->FunctionReference = G.Entry->FunctionReference; Yes->AllocateDefaultPins();
    auto* Handled = G.Call(UWidgetBlueprintLibrary::StaticClass(), TEXT("Handled"));
    auto* Unhandled = G.Call(UWidgetBlueprintLibrary::StaticClass(), TEXT("Unhandled"));
    auto* Empty = G.Call(UKismetStringLibrary::StaticClass(), TEXT("IsEmpty"));
    auto* Focus = G.Call(UWidget::StaticClass(), TEXT("HasAnyUserFocus"));
    auto* Event = G.Call(UWidgetBlueprintLibrary::StaticClass(), TEXT("GetInputEventFromKeyEvent"));
    auto* Key = G.Call(UKismetInputLibrary::StaticClass(), TEXT("GetKey"));
    auto* Send = G.Call(BP->SkeletonGeneratedClass, KeyDispatch, true);
    if (!Handled || !Unhandled || !Empty || !Focus || !Event || !Key || !Send) return false;
    G.Link(Handled->GetReturnValuePin(), Yes->FindPin(UEdGraphSchema_K2::PN_ReturnValue));
    G.Link(Unhandled->GetReturnValuePin(), G.Result->FindPin(UEdGraphSchema_K2::PN_ReturnValue));
    G.Link(G.Entry->FindPin(TEXT("InKeyEvent")), Event->FindPin(TEXT("Event")));
    G.Link(G.Entry->FindPin(TEXT("InKeyEvent")), Key->FindPin(TEXT("Input")));
    auto* Reset = G.Set(Priority, TEXT("-1"));
    auto* TargetValue = G.Get(Target); auto* Armed = G.Branch(); auto* Focused = G.Branch();
    G.Link(Then(G.Entry), Exec(Reset)); G.Link(Then(Reset), Exec(Armed));
    G.Link(TargetValue->FindPin(Target), Empty->FindPin(TEXT("InString")));
    G.Link(Empty->GetReturnValuePin(), Armed->GetConditionPin());
    G.Link(Armed->GetThenPin(), Exec(G.Result)); G.Link(Armed->GetElsePin(), Exec(Focused));
    G.Link(Focus->GetReturnValuePin(), Focused->GetConditionPin());
    G.Link(Focused->GetElsePin(), Exec(G.Result));

    // Modified chords belong to vanilla. Recognized unmodified repeats are
    // consumed below without dispatch; unknown keys (including Escape) bubble.
    UEdGraphPin* Next = Focused->GetThenPin();
    for (FName Predicate : {FName(TEXT("InputEvent_IsShiftDown")), FName(TEXT("InputEvent_IsControlDown")),
        FName(TEXT("InputEvent_IsAltDown")), FName(TEXT("InputEvent_IsCommandDown"))})
    {
        auto* Modified = G.Call(UKismetInputLibrary::StaticClass(), Predicate);
        if (!Modified) return false;
        auto* Guard = G.Branch();
        G.Link(Event->GetReturnValuePin(), Modified->FindPin(TEXT("Input")));
        G.Link(Modified->GetReturnValuePin(), Guard->GetConditionPin()); G.Link(Next, Exec(Guard));
        G.Link(Guard->GetThenPin(), Exec(G.Result)); Next = Guard->GetElsePin();
    }
    // 0=X, 1..5=priority, 6..9=synchronous Lua navigation, 10=queued source
    // cell raise. Lua owns edits/focus; never also request Slate navigation.
    const FKey Keys[] = {EKeys::X, EKeys::One, EKeys::Two, EKeys::Three, EKeys::Four, EKeys::Five,
        EKeys::Up, EKeys::Down, EKeys::Left, EKeys::Right, EKeys::Enter};
    for (int32 Value = 0; Value < UE_ARRAY_COUNT(Keys); ++Value)
    {
        auto* Equal = G.Call(UKismetInputLibrary::StaticClass(), TEXT("EqualEqual_KeyKey"));
        auto* Repeat = G.Call(UKismetInputLibrary::StaticClass(), TEXT("InputEvent_IsRepeat"));
        if (!Equal || !Repeat) return false;
        auto* Match = G.Branch(); auto* Repeated = G.Branch();
        auto* SetPriority = G.Set(Priority); G.Default(SetPriority->FindPin(Priority), FString::FromInt(Value));
        G.Link(Key->GetReturnValuePin(), Equal->FindPin(TEXT("A"))); G.Default(Equal->FindPin(TEXT("B")), Keys[Value].ToString());
        G.Link(Equal->GetReturnValuePin(), Match->GetConditionPin()); G.Link(Next, Exec(Match));
        G.Link(Match->GetThenPin(), Exec(Repeated));
        G.Link(Event->GetReturnValuePin(), Repeat->FindPin(TEXT("Input")));
        G.Link(Repeat->GetReturnValuePin(), Repeated->GetConditionPin());
        G.Link(Repeated->GetThenPin(), Exec(Yes));
        G.Link(Repeated->GetElsePin(), Exec(SetPriority)); G.Link(Then(SetPriority), Exec(Send));
        Next = Match->GetElsePin();
    }
    // The polled Lua pad driver owns these edits/directions.
    // Left-stick keys are suppressed only to prevent default focus drift.
    // Consume presses/repeats without dispatch; right-face Back still bubbles.
    for (FKey SuppressedKey : {EKeys::Gamepad_FaceButton_Bottom,
        EKeys::Gamepad_LeftShoulder, EKeys::Gamepad_RightShoulder, EKeys::Gamepad_FaceButton_Left,
        EKeys::Gamepad_DPad_Up, EKeys::Gamepad_DPad_Down,
        EKeys::Gamepad_DPad_Left, EKeys::Gamepad_DPad_Right, EKeys::Gamepad_LeftStick_Up,
        EKeys::Gamepad_LeftStick_Down, EKeys::Gamepad_LeftStick_Left, EKeys::Gamepad_LeftStick_Right})
    {
        auto* Equal = G.Call(UKismetInputLibrary::StaticClass(), TEXT("EqualEqual_KeyKey"));
        if (!Equal) return false;
        auto* Match = G.Branch();
        G.Link(Key->GetReturnValuePin(), Equal->FindPin(TEXT("A"))); G.Default(Equal->FindPin(TEXT("B")), SuppressedKey.ToString());
        G.Link(Equal->GetReturnValuePin(), Match->GetConditionPin()); G.Link(Next, Exec(Match));
        G.Link(Match->GetThenPin(), Exec(Yes)); Next = Match->GetElsePin();
    }
    G.Link(Next, Exec(G.Result)); G.Link(Then(Send), Exec(Yes));
    return G.Finish();
}

static bool Build(UWidgetBlueprint* BP)
{
    if (!BP || BP->ParentClass != UUserWidget::StaticClass() || !BP->WidgetTree) return false;
    TArray<UEdGraph*> Graphs; BP->GetAllGraphs(Graphs);
    TArray<UEdGraph*> Remove;
    for (UEdGraph* Graph : Graphs)
    {
        if (Graph->GetFName() != Dispatch && Graph->GetFName() != Down && Graph->GetFName() != Double
            && Graph->GetFName() != KeyDispatch && Graph->GetFName() != KeyDown) continue;
        bool Ours = !Graph->Nodes.IsEmpty();
        const bool LegacyGraph = Graph->GetFName() == Dispatch || Graph->GetFName() == Down || Graph->GetFName() == Double;
        for (UEdGraphNode* N : Graph->Nodes) Ours &= N->NodeComment == Owner || (LegacyGraph && N->NodeComment == LegacyOwner);
        if (!Check(Ours, TEXT("owned graph ") + Graph->GetName())) return false;
        Remove.Add(Graph);
    }
    auto* Root = Cast<UBorder>(BP->WidgetTree->RootWidget);
    if (BP->WidgetTree->RootWidget && (!Root || Root->GetFName() != TEXT("HitSurface") || Root->GetChildrenCount() != 0))
        return Check(false, TEXT("unexpected existing tree"));
    for (UEdGraph* Graph : Remove) FBlueprintEditorUtils::RemoveGraph(BP, Graph);
    if (!Root) Root = BP->WidgetTree->ConstructWidget<UBorder>(UBorder::StaticClass(), TEXT("HitSurface"));
    if (!Root) return false;
    Root->bIsVariable = true; BP->WidgetTree->RootWidget = Root;
    Root->SetVisibility(ESlateVisibility::Visible); Root->SetBrushColor(FLinearColor(1, 1, 1, 0)); Root->SetPadding(FMargin(0));
    if (!Member(BP, Target, UEdGraphSchema_K2::PC_String, TEXT(""))) return false;
    for (FName Name : {Epoch, UiEpoch, Direction, Contract, Sequence, Priority, KeySequence})
        if (!Member(BP, Name, UEdGraphSchema_K2::PC_Int,
            Name == Contract ? TEXT("2") : Name == Priority ? TEXT("-1") : TEXT("0"))) return false;
    if (!Compile(BP) || !BuildDispatch(BP, Dispatch, Sequence) || !BuildDispatch(BP, KeyDispatch, KeySequence)
        || !BuildMouse(BP, Down) || !BuildMouse(BP, Double) || !BuildKeys(BP) || !Compile(BP)) return false;
    auto* Defaults = Cast<UUserWidget>(BP->GeneratedClass->GetDefaultObject());
    auto* Focus = FindFProperty<FBoolProperty>(BP->GeneratedClass, TEXT("bIsFocusable"));
    if (!Defaults || !Focus) return false;
    Defaults->SetVisibility(ESlateVisibility::Visible); Focus->SetPropertyValue_InContainer(Defaults, true);
    // Compilation cached the native-property differences before these CDO
    // edits. Without rebuilding that list, NewObject can keep UUserWidget's
    // native bIsFocusable=false even though the generated CDO reads true.
    auto* Generated = Cast<UBlueprintGeneratedClass>(BP->GeneratedClass);
    if (!Check(Generated != nullptr, TEXT("generated class for native default propagation"))) return false;
    Generated->UpdateCustomPropertyListForPostConstruction();
    return true;
}

// Executes compiled Blueprint bytecode, not a duplicate of its decision logic.
// A hidden Slate window establishes real focus; handlers are invoked directly.
// This does not prove game hit testing, UE4SS timing, or queued-edit ownership.
static bool Verify(UWidgetBlueprint* BP)
{
    UClass* Class = BP ? BP->GeneratedClass : nullptr;
    if (!Class || BP->ParentClass != UUserWidget::StaticClass()) return false;
    auto* TargetProp = FindFProperty<FStrProperty>(Class, Target);
    auto* EpochProp = FindFProperty<FIntProperty>(Class, Epoch);
    auto* UiProp = FindFProperty<FIntProperty>(Class, UiEpoch);
    auto* DirProp = FindFProperty<FIntProperty>(Class, Direction);
    auto* Version = FindFProperty<FIntProperty>(Class, Contract);
    auto* Seq = FindFProperty<FIntProperty>(Class, Sequence);
    auto* KeySeq = FindFProperty<FIntProperty>(Class, KeySequence);
    auto* Prio = FindFProperty<FIntProperty>(Class, Priority);
    auto* Focus = FindFProperty<FBoolProperty>(Class, TEXT("bIsFocusable"));
    if (!TargetProp || !EpochProp || !UiProp || !DirProp || !Version || !Seq || !KeySeq || !Prio || !Focus) return false;
    auto DefaultsOK = [&](UObject* Object)
    {
        return TargetProp->GetPropertyValue_InContainer(Object).IsEmpty()
            && EpochProp->GetPropertyValue_InContainer(Object) == 0 && UiProp->GetPropertyValue_InContainer(Object) == 0
            && DirProp->GetPropertyValue_InContainer(Object) == 0 && Version->GetPropertyValue_InContainer(Object) == 2
            && Seq->GetPropertyValue_InContainer(Object) == 0 && Focus->GetPropertyValue_InContainer(Object)
            && Prio->GetPropertyValue_InContainer(Object) == -1 && KeySeq->GetPropertyValue_InContainer(Object) == 0;
    };
    auto DescribeDefaults = [&](UUserWidget* Object, const TCHAR* Stage)
    {
        if (!Object)
        {
            Check(false, FString(Stage) + TEXT(" widget is null"));
            return;
        }
        UE_LOG(LogTemp, Display, TEXT("PWP stand input: %s object=%s class=%s archetype=%s"),
            Stage, *Object->GetPathName(), *Object->GetClass()->GetPathName(), *GetPathNameSafe(Object->GetArchetype()));
        auto Int = [&](FIntProperty* Property, int32 Expected)
        {
            const int32 Actual = Property->GetPropertyValue_InContainer(Object);
            Check(Actual == Expected, FString::Printf(TEXT("%s %s actual=%d expected=%d"),
                Stage, *Property->GetName(), Actual, Expected));
        };
        const FString TargetValue = TargetProp->GetPropertyValue_InContainer(Object);
        Check(TargetValue.IsEmpty(), FString::Printf(TEXT("%s PWP_Target actual='%s' length=%d expected=empty"),
            Stage, *TargetValue, TargetValue.Len()));
        Int(EpochProp, 0); Int(UiProp, 0); Int(DirProp, 0); Int(Version, 2);
        Int(Seq, 0); Int(Prio, -1); Int(KeySeq, 0);
        const bool CanFocus = Focus->GetPropertyValue_InContainer(Object);
        Check(CanFocus, FString::Printf(TEXT("%s bIsFocusable actual=%d expected=1"), Stage, CanFocus));
        Check(Object->GetVisibility() == ESlateVisibility::Visible,
            FString::Printf(TEXT("%s visibility actual=%d expected=%d"), Stage,
                static_cast<int32>(Object->GetVisibility()), static_cast<int32>(ESlateVisibility::Visible)));
    };
    auto* CDO = Cast<UUserWidget>(Class->GetDefaultObject());
    DescribeDefaults(CDO, TEXT("CDO"));
    if (!Check(CDO && DefaultsOK(CDO) && CDO->GetVisibility() == ESlateVisibility::Visible, TEXT("scalar and visibility defaults"))) return false;
    for (FName Name : {Dispatch, KeyDispatch, Down, Double, KeyDown})
    {
        UFunction* Fn = Class->FindFunctionByName(Name);
        if (!Check(Fn && Fn->GetOuter() == Class && !Fn->Script.IsEmpty() && !Fn->HasAnyFunctionFlags(FUNC_Native)
            && ((Name != Dispatch && Name != KeyDispatch) || Fn->NumParms == 0), TEXT("own compiled function ") + Name.ToString())) return false;
    }
    const bool CreatedSlate = !FSlateApplication::IsInitialized();
    if (CreatedSlate)
    {
        auto& Renderer = FModuleManager::LoadModuleChecked<ISlateNullRendererModule>(TEXT("SlateNullRenderer"));
        FSlateApplication::InitializeAsStandaloneApplication(Renderer.CreateSlateNullRenderer());
    }
    ON_SCOPE_EXIT { if (CreatedSlate) FSlateApplication::Shutdown(); };
    auto* Widget = NewObject<UUserWidget>(GetTransientPackage(), Class);
    // Inspect the unmodified instance: repairing fixture fields here would
    // hide a default-propagation defect in runtime-created receivers.
    DescribeDefaults(Widget, TEXT("fresh instance"));
    if (!Check(Widget && DefaultsOK(Widget) && Widget->GetVisibility() == ESlateVisibility::Visible,
        TEXT("fresh instance scalar and visibility defaults"))) return false;
    Widget->Initialize();
    auto* Root = Widget->WidgetTree ? Cast<UBorder>(Widget->WidgetTree->RootWidget) : nullptr;
    if (!Check(Root && Root->GetFName() == TEXT("HitSurface") && Root->GetChildrenCount() == 0
        && Root->GetVisibility() == ESlateVisibility::Visible && Root->GetBrushColor().A == 0, TEXT("transparent visible empty Border"))) return false;
    const TSharedRef<SWindow> Window = SNew(SWindow).ClientSize(FVector2D(320, 120))[Widget->TakeWidget()];
    FSlateApplication::Get().AddWindow(Window, false);
    ON_SCOPE_EXIT { FSlateApplication::Get().RequestDestroyWindow(Window); };
    int32 ExpectedSequence = 0;
    auto Run = [&](bool DoubleClick, FKey Button, bool Accepted, int32 ExpectedDirection)
    {
        TSet<FKey> Pressed; Pressed.Add(Button);
        const FPointerEvent Event(0, FVector2D::ZeroVector, FVector2D::ZeroVector, Pressed, Button, 0, FModifierKeysState());
        const FEventReply Reply = DoubleClick ? Widget->OnMouseButtonDoubleClick(FGeometry(), Event)
            : Widget->OnMouseButtonDown(FGeometry(), Event);
        if (Accepted) ++ExpectedSequence;
        return Check(Reply.NativeReply.IsEventHandled() == Accepted
            && (Accepted ? Reply.NativeReply.GetUserFocusRecepient() == Widget->TakeWidget()
                : !Reply.NativeReply.GetUserFocusRecepient().IsValid())
            && Seq->GetPropertyValue_InContainer(Widget) == ExpectedSequence
            && DirProp->GetPropertyValue_InContainer(Widget) == ExpectedDirection
            && KeySeq->GetPropertyValue_InContainer(Widget) == 0 && Prio->GetPropertyValue_InContainer(Widget) == -1,
            FString::Printf(TEXT("compiled %s %s handled=%d direction=%d sequence=%d"), DoubleClick ? TEXT("double") : TEXT("down"),
                *Button.ToString(), Reply.NativeReply.IsEventHandled(), DirProp->GetPropertyValue_InContainer(Widget), Seq->GetPropertyValue_InContainer(Widget)));
    };
    bool Good = true;
    for (bool DoubleClick : {false, true})
        for (FKey Key : {EKeys::LeftMouseButton, EKeys::RightMouseButton, EKeys::MiddleMouseButton})
            Good &= Run(DoubleClick, Key, false, 0); // Empty target never dispatches or consumes.
    TargetProp->SetPropertyValue_InContainer(Widget, TEXT("fixture-target"));
    EpochProp->SetPropertyValue_InContainer(Widget, 7); UiProp->SetPropertyValue_InContainer(Widget, 11);
    for (FKey Key : {EKeys::LeftMouseButton, EKeys::RightMouseButton})
    {
        const int32 Value = Key == EKeys::LeftMouseButton ? -1 : 1;
        Good &= Run(false, Key, true, Value); Good &= Run(true, Key, true, Value); // Two presses => two dispatches.
    }
    Good &= Run(false, EKeys::MiddleMouseButton, false, 0); Good &= Run(true, EKeys::MiddleMouseButton, false, 0);
    Good &= Run(false, EKeys::LeftMouseButton, true, -1);
    Good &= TargetProp->GetPropertyValue_InContainer(Widget) == TEXT("fixture-target");
    TargetProp->SetPropertyValue_InContainer(Widget, TEXT("")); // Disarming also resets stale direction.
    Good &= Run(true, EKeys::RightMouseButton, false, 0);
    Good &= EpochProp->GetPropertyValue_InContainer(Widget) == 7 && UiProp->GetPropertyValue_InContainer(Widget) == 11;
    Good &= Version->GetPropertyValue_InContainer(Widget) == 2 && DefaultsOK(CDO);

    int32 ExpectedKeySequence = 0;
    auto RunKey = [&](FKey Key, const FModifierKeysState& Modifiers, bool Repeat, bool Handled, int32 ExpectedPriority)
    {
        const FString BeforeTarget = TargetProp->GetPropertyValue_InContainer(Widget);
        const int32 BeforeDirection = DirProp->GetPropertyValue_InContainer(Widget);
        const FEventReply Reply = Widget->OnKeyDown(FGeometry(), FKeyEvent(Key, Modifiers, 0, Repeat, 0, 0));
        if (ExpectedPriority >= 0) ++ExpectedKeySequence;
        return Check(Reply.NativeReply.IsEventHandled() == Handled
            && Prio->GetPropertyValue_InContainer(Widget) == ExpectedPriority
            && KeySeq->GetPropertyValue_InContainer(Widget) == ExpectedKeySequence
            && Seq->GetPropertyValue_InContainer(Widget) == ExpectedSequence
            && DirProp->GetPropertyValue_InContainer(Widget) == BeforeDirection
            && TargetProp->GetPropertyValue_InContainer(Widget) == BeforeTarget
            && EpochProp->GetPropertyValue_InContainer(Widget) == 7 && UiProp->GetPropertyValue_InContainer(Widget) == 11
            && Version->GetPropertyValue_InContainer(Widget) == 2
            && Reply.NativeReply.GetNavigationType() == EUINavigation::Invalid
            && !Reply.NativeReply.GetNavigationDestination().IsValid()
            && !Reply.NativeReply.GetUserFocusRecepient().IsValid(),
            FString::Printf(TEXT("compiled key %s repeat=%d handled=%d priority=%d sequence=%d"), *Key.ToString(),
                Repeat, Reply.NativeReply.IsEventHandled(), Prio->GetPropertyValue_InContainer(Widget),
                KeySeq->GetPropertyValue_InContainer(Widget)));
    };
    FSlateApplication::Get().SetKeyboardFocus(Widget->TakeWidget());
    if (!Check(Widget->HasAnyUserFocus(), TEXT("fixture native Slate receiver focus"))) return false;
    // Explicit fixture expectations keep the wire mapping independent of the
    // graph builder's array order. -1 means handled without any dispatch.
    struct FKeyCase { FKey Key; int32 Priority; };
    const FKeyCase Cases[] = {{EKeys::X, 0}, {EKeys::One, 1}, {EKeys::Two, 2},
        {EKeys::Three, 3}, {EKeys::Four, 4}, {EKeys::Five, 5},
        {EKeys::Up, 6}, {EKeys::Down, 7}, {EKeys::Left, 8}, {EKeys::Right, 9},
        {EKeys::Enter, 10}, {EKeys::Gamepad_FaceButton_Bottom, -1},
        {EKeys::Gamepad_LeftShoulder, -1}, {EKeys::Gamepad_RightShoulder, -1}, {EKeys::Gamepad_FaceButton_Left, -1},
        {EKeys::Gamepad_DPad_Up, -1}, {EKeys::Gamepad_DPad_Down, -1},
        {EKeys::Gamepad_DPad_Left, -1}, {EKeys::Gamepad_DPad_Right, -1},
        {EKeys::Gamepad_LeftStick_Up, -1}, {EKeys::Gamepad_LeftStick_Down, -1},
        {EKeys::Gamepad_LeftStick_Left, -1}, {EKeys::Gamepad_LeftStick_Right, -1}};
    for (const FKeyCase& Test : Cases)
    {
        Good &= RunKey(Test.Key, FModifierKeysState(), false, false, -1); // Empty, even while focused.
        Good &= RunKey(Test.Key, FModifierKeysState(), true, false, -1);
    }
    TargetProp->SetPropertyValue_InContainer(Widget, TEXT("fixture-target"));
    for (const FKeyCase& Test : Cases)
    {
        Good &= RunKey(Test.Key, FModifierKeysState(), false, true, Test.Priority);
        Good &= RunKey(Test.Key, FModifierKeysState(), true, true, -1);
        // Both sides of every modifier, plus a combined chord.
        for (int32 Modifier = 0; Modifier <= 8; ++Modifier)
        {
            const bool All = Modifier == 8;
            const FModifierKeysState Mods(All || Modifier == 0, All || Modifier == 1,
                All || Modifier == 2, All || Modifier == 3, All || Modifier == 4, All || Modifier == 5,
                All || Modifier == 6, All || Modifier == 7, false);
            Good &= RunKey(Test.Key, Mods, false, false, -1);
            Good &= RunKey(Test.Key, Mods, true, false, -1);
        }
    }
    for (FKey Key : {EKeys::Escape, EKeys::Gamepad_FaceButton_Right, EKeys::A, EKeys::Zero, EKeys::Six, EKeys::NumPadOne})
    {
        Good &= RunKey(Key, FModifierKeysState(), false, false, -1);
        Good &= RunKey(Key, FModifierKeysState(), true, false, -1);
    }
    FSlateApplication::Get().ClearKeyboardFocus(EFocusCause::SetDirectly);
    if (!Check(!Widget->HasAnyUserFocus(), TEXT("fixture receiver focus released"))) return false;
    for (const FKeyCase& Test : Cases)
    {
        Good &= RunKey(Test.Key, FModifierKeysState(), false, false, -1);
        Good &= RunKey(Test.Key, FModifierKeysState(), true, false, -1);
    }
    Good &= DefaultsOK(CDO);
    return Check(Good, TEXT("compiled handlers, immutable epochs/contract, CDO isolation (not native routing proof)"));
}
}

UBuildStandInputWidgetCommandlet::UBuildStandInputWidgetCommandlet()
{
    IsClient = false; IsServer = false; IsEditor = true; LogToConsole = true;
}

int32 UBuildStandInputWidgetCommandlet::Main(const FString& Params)
{
    using namespace StandInput;
    const FString ObjectPath = FString(PackagePath) + TEXT(".") + AssetName;
    UObject* Existing = LoadObject<UObject>(nullptr, *ObjectPath);
    auto* BP = Cast<UWidgetBlueprint>(Existing);
    if (FParse::Param(*Params, TEXT("VerifyInputOnly"))) return Verify(BP) ? 0 : 2;
    if (Existing && !BP) return 1;
    if (!BP)
    {
        UPackage* Package = CreatePackage(PackagePath);
        auto* Factory = NewObject<UWidgetBlueprintFactory>(); Factory->ParentClass = UUserWidget::StaticClass();
        BP = Cast<UWidgetBlueprint>(Factory->FactoryCreateNew(UWidgetBlueprint::StaticClass(), Package, FName(AssetName),
            RF_Public | RF_Standalone, nullptr, GWarn));
    }
    if (!Build(BP) || !Verify(BP)) return 2;
    UPackage* Package = BP->GetOutermost(); Package->MarkPackageDirty();
    FSavePackageArgs Args; Args.TopLevelFlags = RF_Public | RF_Standalone; Args.SaveFlags = SAVE_NoError;
    const FString File = FPackageName::LongPackageNameToFilename(PackagePath, FPackageName::GetAssetPackageExtension());
    return Check(UPackage::SavePackage(Package, BP, *File, Args), TEXT("save ") + File) ? 0 : 3;
}
