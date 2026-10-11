#pragma once

#include "Blueprint/UserWidget.h"
#include "Blueprint/WidgetTree.h"
#include "Blueprint/WidgetBlueprintLibrary.h"
#include "Components/EditableTextBox.h"
#include "Components/CanvasPanel.h"
#include "Framework/Application/SlateApplication.h"
#include "Widgets/SWindow.h"
#include "Interfaces/ISlateNullRendererModule.h"
#include "Modules/ModuleManager.h"
#include "Misc/ScopeExit.h"
#include "Kismet/KismetInputLibrary.h"
#include "WidgetBlueprint.h"
#include "EdGraphSchema_K2.h"
#include "K2Node_CallFunction.h"
#include "K2Node_CreateDelegate.h"
#include "K2Node_Event.h"
#include "K2Node_FunctionEntry.h"
#include "K2Node_FunctionResult.h"
#include "K2Node_IfThenElse.h"
#include "K2Node_Self.h"
#include "K2Node_VariableGet.h"
#include "K2Node_VariableSet.h"
#include "Kismet2/BlueprintEditorUtils.h"
#include "Kismet2/KismetEditorUtilities.h"
#include "Kismet2/CompilerResultsLog.h"
#include "Kismet/KismetSystemLibrary.h"
#include "UObject/UnrealType.h"

// Editor-only graph construction. The generated asset calls shipped Pal/CommonUI
// functions; it has no dependency on this module at runtime.
namespace WorkRulesInput
{
static const FName Request(TEXT("PWP_CancelRequested"));
static const FName Contract(TEXT("PWP_InputContract"));
static const FName Handle(TEXT("PWP_CancelBinding"));
static const FName Attempted(TEXT("PWP_CancelBindingAttempted"));
static const FName Callback(TEXT("PWP_RequestCancel"));
static const FName Lifecycle(TEXT("PWP_InputLifecycle"));
static const FName Editor(TEXT("PWP_AmountEditor"));
static const FName Held(TEXT("PWP_EditorEscapeHeld"));
static const FString Owner(TEXT("PWP generated action input contract 3"));

static void Log(const FString& Message) { UE_LOG(LogTemp, Display, TEXT("PWP input: %s"), *Message); }
static UClass* Parent() { return LoadObject<UClass>(nullptr, TEXT("/Script/Pal.PalUserWidget")); }
static bool Compile(UWidgetBlueprint* BP)
{
    FCompilerResultsLog Results;
    FKismetEditorUtilities::CompileBlueprint(BP, EBlueprintCompileOptions::None, &Results);
    Log(FString::Printf(TEXT("compile errors=%d warnings=%d status=%d"), Results.NumErrors, Results.NumWarnings, int32(BP->Status)));
    return Results.NumErrors == 0 && BP->Status != BS_Error && BP->GeneratedClass;
}
static bool Member(UWidgetBlueprint* BP, FName Name, const FEdGraphPinType& Type, const FString& Default)
{
    const int32 Index = FBlueprintEditorUtils::FindNewVariableIndex(BP, Name);
    if (Index == INDEX_NONE) return FBlueprintEditorUtils::AddMemberVariable(BP, Name, Type, Default);
    if (BP->NewVariables[Index].VarType != Type) { Log(TEXT("FAILED member type: ") + Name.ToString()); return false; }
    BP->NewVariables[Index].DefaultValue = Default;
    return true;
}
struct FGraph
{
    UEdGraph* Graph;
    const UEdGraphSchema_K2* Schema = GetDefault<UEdGraphSchema_K2>();
    bool Good = true;
    TArray<TPair<UEdGraphPin*, UEdGraphPin*>> Links;
    explicit FGraph(UEdGraph* InGraph) : Graph(InGraph) {}
    template<class T> T* Node()
    {
        T* N = NewObject<T>(Graph); Graph->AddNode(N); N->CreateNewGuid(); N->NodeComment = Owner;
        N->NodePosX = Graph->Nodes.Num() * 200; return N;
    }
    void Link(UEdGraphPin* A, UEdGraphPin* B)
    {
        const bool Ok = A && B && Schema->TryCreateConnection(A, B) && A->LinkedTo.Contains(B) && B->LinkedTo.Contains(A);
        Good &= Ok;
        Log(FString::Printf(TEXT("%s pin %s.%s -> %s.%s %s"), *Graph->GetName(),
            A ? *A->GetOwningNode()->GetName() : TEXT("MISSING"), A ? *A->PinName.ToString() : TEXT("?"),
            B ? *B->GetOwningNode()->GetName() : TEXT("MISSING"), B ? *B->PinName.ToString() : TEXT("?"), Ok ? TEXT("PASS") : TEXT("FAILED")));
        if (Ok) Links.Emplace(A, B);
    }
    void Default(UEdGraphPin* Pin, const FString& Value)
    {
        if (!Pin) { Good = false; return; }
        Schema->TrySetDefaultValue(*Pin, Value);
        Good &= Pin->DefaultValue == Value;
        Log(FString::Printf(TEXT("default %s=%s type=%s"), *Pin->PinName.ToString(), *Pin->DefaultValue, *Pin->PinType.PinCategory.ToString()));
    }
    UK2Node_VariableSet* Set(FName Name, const TCHAR* Value = nullptr)
    {
        auto* N = Node<UK2Node_VariableSet>(); N->VariableReference.SetSelfMember(Name); N->AllocateDefaultPins();
        if (Value) Default(N->FindPin(Name), Value); return N;
    }
    UK2Node_VariableGet* Get(FName Name)
    {
        auto* N = Node<UK2Node_VariableGet>(); N->VariableReference.SetSelfMember(Name); N->AllocateDefaultPins(); return N;
    }
    UK2Node_CallFunction* Call(UFunction* Function)
    {
        auto* N = Node<UK2Node_CallFunction>(); N->SetFromFunction(Function); N->AllocateDefaultPins(); return N;
    }
    UK2Node_Event* Event(FName Name)
    {
        auto* N = Node<UK2Node_Event>(); N->EventReference.SetExternalMember(Name, UUserWidget::StaticClass());
        N->bOverrideFunction = true; N->AllocateDefaultPins(); return N;
    }
    UK2Node_IfThenElse* Branch()
    {
        auto* N = Node<UK2Node_IfThenElse>(); N->AllocateDefaultPins(); return N;
    }
    bool Check()
    {
        for (const auto& Pair : Links) Good &= Pair.Key->LinkedTo.Contains(Pair.Value) && Pair.Value->LinkedTo.Contains(Pair.Key);
        Log(FString::Printf(TEXT("graph %s nodes=%d checked-links=%d %s"), *Graph->GetName(), Graph->Nodes.Num(), Links.Num(), Good ? TEXT("PASS") : TEXT("FAILED")));
        return Good;
    }
};
static UEdGraphPin* Exec(UEdGraphNode* N) { return N->FindPin(UEdGraphSchema_K2::PN_Execute); }
static UEdGraphPin* Then(UEdGraphNode* N) { return N->FindPin(UEdGraphSchema_K2::PN_Then); }

// Slate preview runs before EditableTextBox clears its own focus on Escape.
// The native reference belongs to this widget and is cleared by Lua on cancel;
// no Lua wrapper is retained. CommonUI still owns ordinary panel/controller Back.
static bool BuildEditorKeys(UWidgetBlueprint* BP, bool KeyUp)
{
    const FName Name(KeyUp ? TEXT("OnKeyUp") : TEXT("OnPreviewKeyDown"));
    UEdGraph* Graph = FBlueprintEditorUtils::CreateNewGraph(BP, Name, UEdGraph::StaticClass(), UEdGraphSchema_K2::StaticClass());
    FBlueprintEditorUtils::AddFunctionGraph(BP, Graph, false, UUserWidget::StaticClass());
    FGraph G(Graph);
    UK2Node_FunctionEntry* Entry = nullptr;
    UK2Node_FunctionResult* No = nullptr;
    for (UEdGraphNode* N : Graph->Nodes)
    {
        if (auto* E = Cast<UK2Node_FunctionEntry>(N)) Entry = E;
        if (auto* R = Cast<UK2Node_FunctionResult>(N)) No = R;
    }
    if (!Entry || !No) return false;
    Entry->NodeComment = No->NodeComment = Owner;
    Then(Entry)->BreakAllPinLinks();
    auto* Yes = G.Node<UK2Node_FunctionResult>();
    Yes->FunctionReference = Entry->FunctionReference; Yes->AllocateDefaultPins();
    auto Call = [&](UClass* Class, FName Function) -> UK2Node_CallFunction*
    {
        UFunction* Fn = Class->FindFunctionByName(Function);
        return Fn ? G.Call(Fn) : nullptr;
    };
    auto* Key = Call(UKismetInputLibrary::StaticClass(), TEXT("GetKey"));
    auto* Equal = Call(UKismetInputLibrary::StaticClass(), TEXT("EqualEqual_KeyKey"));
    auto* Handled = Call(UWidgetBlueprintLibrary::StaticClass(), TEXT("Handled"));
    auto* Unhandled = Call(UWidgetBlueprintLibrary::StaticClass(), TEXT("Unhandled"));
    if (!Key || !Equal || !Handled || !Unhandled) return false;
    G.Link(Handled->GetReturnValuePin(), Yes->FindPin(UEdGraphSchema_K2::PN_ReturnValue));
    G.Link(Unhandled->GetReturnValuePin(), No->FindPin(UEdGraphSchema_K2::PN_ReturnValue));
    auto* Escape = G.Branch();
    G.Link(Then(Entry), Exec(Escape));
    G.Link(Entry->FindPin(TEXT("InKeyEvent")), Key->FindPin(TEXT("Input")));
    G.Link(Key->GetReturnValuePin(), Equal->FindPin(TEXT("A")));
    G.Default(Equal->FindPin(TEXT("B")), EKeys::Escape.ToString());
    G.Link(Equal->GetReturnValuePin(), Escape->GetConditionPin());
    G.Link(Escape->GetElsePin(), Exec(No));
    auto* WasHeld = G.Get(Held); auto* HeldBranch = G.Branch();
    G.Link(Escape->GetThenPin(), Exec(HeldBranch));
    G.Link(WasHeld->FindPin(Held), HeldBranch->GetConditionPin());
    if (KeyUp)
    {
        auto* Clear = G.Set(Held, TEXT("false"));
        G.Link(HeldBranch->GetThenPin(), Exec(Clear)); G.Link(Then(Clear), Exec(Yes));
        G.Link(HeldBranch->GetElsePin(), Exec(No));
        return G.Check();
    }
    // A repeat is consumed after the editor has disappeared, too. A distinct
    // non-repeat press can recover if focus changes swallowed the earlier Up.
    auto* Event = Call(UWidgetBlueprintLibrary::StaticClass(), TEXT("GetInputEventFromKeyEvent"));
    auto* Repeat = Call(UKismetInputLibrary::StaticClass(), TEXT("InputEvent_IsRepeat"));
    auto* Active = Call(Parent(), TEXT("IsActivated"));
    auto* Valid = Call(UKismetSystemLibrary::StaticClass(), TEXT("IsValid"));
    auto* Direct = Call(UWidget::StaticClass(), TEXT("HasAnyUserFocus"));
    auto* Descendants = Call(UWidget::StaticClass(), TEXT("HasFocusedDescendants"));
    if (!Event || !Repeat || !Active || !Valid || !Direct || !Descendants) return false;
    auto* IsRepeat = G.Branch();
    G.Link(Entry->FindPin(TEXT("InKeyEvent")), Event->FindPin(TEXT("Event")));
    G.Link(Event->GetReturnValuePin(), Repeat->FindPin(TEXT("Input")));
    G.Link(Repeat->GetReturnValuePin(), IsRepeat->GetConditionPin());
    G.Link(HeldBranch->GetThenPin(), Exec(IsRepeat));
    auto* StillActive = G.Branch();
    G.Link(IsRepeat->GetThenPin(), Exec(StillActive));
    G.Link(Active->GetReturnValuePin(), StillActive->GetConditionPin());
    G.Link(StillActive->GetThenPin(), Exec(Yes)); G.Link(StillActive->GetElsePin(), Exec(No));
    auto* Clear = G.Set(Held, TEXT("false"));
    G.Link(IsRepeat->GetElsePin(), Exec(Clear));
    auto* ActiveBranch = G.Branch();
    G.Link(HeldBranch->GetElsePin(), Exec(ActiveBranch)); G.Link(Then(Clear), Exec(ActiveBranch));
    G.Link(Active->GetReturnValuePin(), ActiveBranch->GetConditionPin());
    G.Link(ActiveBranch->GetElsePin(), Exec(No));
    auto* Target = G.Get(Editor); auto* ValidBranch = G.Branch();
    G.Link(Target->FindPin(Editor), Valid->FindPin(TEXT("Object")));
    G.Link(ActiveBranch->GetThenPin(), Exec(ValidBranch));
    G.Link(Valid->GetReturnValuePin(), ValidBranch->GetConditionPin());
    G.Link(ValidBranch->GetElsePin(), Exec(No));
    auto* Focus = G.Branch(); auto* ChildFocus = G.Branch();
    G.Link(Target->FindPin(Editor), Direct->FindPin(UEdGraphSchema_K2::PN_Self));
    G.Link(Target->FindPin(Editor), Descendants->FindPin(UEdGraphSchema_K2::PN_Self));
    G.Link(ValidBranch->GetThenPin(), Exec(Focus));
    G.Link(Direct->GetReturnValuePin(), Focus->GetConditionPin());
    G.Link(Focus->GetElsePin(), Exec(ChildFocus));
    G.Link(Descendants->GetReturnValuePin(), ChildFocus->GetConditionPin());
    G.Link(ChildFocus->GetElsePin(), Exec(No));
    auto* FreshPress = G.Branch();
    G.Link(Focus->GetThenPin(), Exec(FreshPress)); G.Link(ChildFocus->GetThenPin(), Exec(FreshPress));
    G.Link(Repeat->GetReturnValuePin(), FreshPress->GetConditionPin());
    G.Link(FreshPress->GetThenPin(), Exec(Yes));
    auto* Arm = G.Set(Held, TEXT("true")); auto* Pending = G.Set(Request, TEXT("true"));
    G.Link(FreshPress->GetElsePin(), Exec(Arm)); G.Link(Then(Arm), Exec(Pending)); G.Link(Then(Pending), Exec(Yes));
    return G.Check();
}

static bool Build(UWidgetBlueprint* BP)
{
    UClass* Pal = Parent();
    if (!Pal || (BP->ParentClass != UUserWidget::StaticClass() && BP->ParentClass != Pal)) return false;
    UFunction* Register = Pal->FindFunctionByName(TEXT("RegisterActionBinding"));
    UFunction* Unregister = Pal->FindFunctionByName(TEXT("UnregisterActionBinding"));
    if (!Register || !Unregister) return false;
    auto* Delegate = FindFProperty<FDelegateProperty>(Register, TEXT("Callback"));
    auto* Result = CastField<FStructProperty>(Register->GetReturnProperty());
    auto* BindingArg = FindFProperty<FStructProperty>(Unregister, TEXT("BindingData"));
    auto* InputType = FindFProperty<FByteProperty>(Register, TEXT("InputType"));
    if (!Delegate || !Delegate->SignatureFunction || Delegate->SignatureFunction->NumParms != 0
        || !Result || !BindingArg || Result->Struct != BindingArg->Struct || !InputType || !InputType->Enum
        || InputType->Enum->GetValueByNameString(TEXT("IE_Pressed")) != 0) return false;
    Log(TEXT("parent=") + Pal->GetPathName() + TEXT(" register=") + Register->GetPathName());
    for (TFieldIterator<FProperty> It(Register); It && It->HasAnyPropertyFlags(CPF_Parm); ++It)
        Log(TEXT("declaration ") + It->GetName() + TEXT(" : ") + It->GetCPPType());
    Log(TEXT("delegate=") + Delegate->SignatureFunction->GetPathName() + TEXT(" zero parameters; IE_Pressed=0"));

    TArray<UEdGraph*> Graphs; BP->GetAllGraphs(Graphs);
    TArray<UEdGraph*> Remove;
    for (UEdGraph* Graph : Graphs)
    {
        const bool Legacy = Graph->GetFName() == TEXT("OnPreviewKeyDown") || Graph->GetFName() == TEXT("OnKeyUp");
        const bool Ours = Graph->GetFName() == Callback || Graph->GetFName() == Lifecycle;
        if (!Legacy && !Ours) continue;
        bool Marked = false;
        for (UEdGraphNode* N : Graph->Nodes)
            Marked |= N->NodeComment == Owner || N->NodeComment == TEXT("PWP generated action input contract 2") || (Legacy &&
                (N->NodeComment == TEXT("PWP generated Escape input contract v1") || N->NodeComment == TEXT("PWP generated Escape armed release v2")));
        if (!Marked) { Log(TEXT("FAILED unowned graph ") + Graph->GetName()); return false; }
        Remove.Add(Graph);
    }
    // The stock WidgetBlueprint factory seeds disconnected lifecycle events.
    // Remove only those inert placeholders; never replace an authored handler.
    TArray<UK2Node_Event*> Placeholders;
    for (UEdGraph* Graph : Graphs) if (!Remove.Contains(Graph))
        for (UEdGraphNode* N : Graph->Nodes) if (auto* E = Cast<UK2Node_Event>(N))
            if (E->EventReference.GetMemberName() == TEXT("Construct") || E->EventReference.GetMemberName() == TEXT("Destruct"))
            {
                bool Inert = E->IsAutomaticallyPlacedGhostNode() && !E->IsNodeEnabled();
                for (UEdGraphPin* Pin : E->Pins) Inert &= Pin->LinkedTo.IsEmpty();
                if (!Inert) { Log(TEXT("FAILED unowned Construct/Destruct event")); return false; }
                Placeholders.Add(E);
            }
    for (UK2Node_Event* E : Placeholders)
    {
        Log(TEXT("remove disconnected factory placeholder ") + E->EventReference.GetMemberName().ToString());
        E->GetGraph()->RemoveNode(E);
    }
    for (UEdGraph* Graph : Remove) FBlueprintEditorUtils::RemoveGraph(BP, Graph);
    BP->ParentClass = Pal;
    FEdGraphPinType Bool; Bool.PinCategory = UEdGraphSchema_K2::PC_Boolean;
    FEdGraphPinType Int; Int.PinCategory = UEdGraphSchema_K2::PC_Int;
    FEdGraphPinType EditorType; EditorType.PinCategory = UEdGraphSchema_K2::PC_Object;
    EditorType.PinSubCategoryObject = UEditableTextBox::StaticClass();
    FEdGraphPinType HandleType; HandleType.PinCategory = UEdGraphSchema_K2::PC_Struct; HandleType.PinSubCategoryObject = Result->Struct;
    if (!Member(BP, Request, Bool, TEXT("false")) || !Member(BP, Contract, Int, TEXT("3"))
        || !Member(BP, Editor, EditorType, TEXT("None")) || !Member(BP, Held, Bool, TEXT("false"))
        || !Member(BP, Attempted, Bool, TEXT("false")) || !Member(BP, Handle, HandleType, TEXT(""))) return false;
    FBlueprintEditorUtils::MarkBlueprintAsStructurallyModified(BP);
    if (!Compile(BP)) return false;

    UEdGraph* CallbackGraph = FBlueprintEditorUtils::CreateNewGraph(BP, Callback, UEdGraph::StaticClass(), UEdGraphSchema_K2::StaticClass());
    FBlueprintEditorUtils::AddFunctionGraph(BP, CallbackGraph, true, Delegate->SignatureFunction);
    FGraph CB(CallbackGraph);
    UK2Node_FunctionEntry* Entry = nullptr;
    for (UEdGraphNode* N : CallbackGraph->Nodes) if (auto* E = Cast<UK2Node_FunctionEntry>(N)) Entry = E;
    if (!Entry) return false;
    Entry->NodeComment = Owner;
    auto* Pending = CB.Set(Request, TEXT("true"));
    CB.Link(Then(Entry), Exec(Pending));
    FBlueprintEditorUtils::MarkBlueprintAsStructurallyModified(BP);
    if (!CB.Check() || !Compile(BP)) return false; // Delegate resolves against the compiled skeleton.

    UEdGraph* EventGraph = FBlueprintEditorUtils::CreateNewGraph(BP, Lifecycle, UEdGraph::StaticClass(), UEdGraphSchema_K2::StaticClass());
    FBlueprintEditorUtils::AddUbergraphPage(BP, EventGraph);
    FGraph G(EventGraph);
    auto* Construct = G.Event(TEXT("Construct"));
    auto* Already = G.Get(Attempted); auto* Guard = G.Branch();
    auto* OldHandle = G.Get(Handle); auto* Replace = G.Call(Unregister); auto* Bind = G.Call(Register);
    // ActionName is a const-reference pin: supply a shipped literal node, not
    // an ignored input-pin default (which would otherwise remain None).
    UFunction* LiteralFunction = UKismetSystemLibrary::StaticClass()->FindFunctionByName(TEXT("MakeLiteralName"));
    if (!LiteralFunction) return false;
    auto* ActionName = G.Call(LiteralFunction);
    G.Default(ActionName->FindPin(TEXT("Value")), TEXT("RadialMenuCancel"));
    G.Link(ActionName->GetReturnValuePin(), Bind->FindPin(TEXT("ActionName")));
    G.Default(Bind->FindPin(TEXT("IsDisplayActionBar")), TEXT("false"));
    G.Default(Bind->FindPin(TEXT("InputType")), TEXT("IE_Pressed"));
    auto* CreateDelegate = G.Node<UK2Node_CreateDelegate>(); CreateDelegate->AllocateDefaultPins();
    auto* Self = G.Node<UK2Node_Self>(); Self->AllocateDefaultPins();
    G.Link(Self->FindPin(UEdGraphSchema_K2::PN_Self), CreateDelegate->GetObjectInPin());
    G.Link(CreateDelegate->GetDelegateOutPin(), Bind->FindPin(TEXT("Callback")));
    CreateDelegate->SetFunction(Callback); CreateDelegate->HandleAnyChange();
    auto* Store = G.Set(Handle); auto* Mark = G.Set(Attempted, TEXT("true"));
    G.Link(Then(Construct), Exec(Guard)); G.Link(Already->FindPin(Attempted), Guard->GetConditionPin());
    G.Link(Guard->GetThenPin(), Exec(Replace)); G.Link(OldHandle->FindPin(Handle), Replace->FindPin(TEXT("BindingData")));
    G.Link(Then(Replace), Exec(Bind)); G.Link(Guard->GetElsePin(), Exec(Bind));
    G.Link(Then(Bind), Exec(Store)); G.Link(Bind->GetReturnValuePin(), Store->FindPin(Handle)); G.Link(Then(Store), Exec(Mark));

    auto* Destruct = G.Event(TEXT("Destruct")); auto* HasBinding = G.Get(Attempted); auto* CleanupGuard = G.Branch();
    auto* SavedHandle = G.Get(Handle); auto* Cleanup = G.Call(Unregister); auto* Clear = G.Set(Attempted, TEXT("false"));
    G.Link(Then(Destruct), Exec(CleanupGuard)); G.Link(HasBinding->FindPin(Attempted), CleanupGuard->GetConditionPin());
    G.Link(CleanupGuard->GetThenPin(), Exec(Cleanup)); G.Link(SavedHandle->FindPin(Handle), Cleanup->FindPin(TEXT("BindingData")));
    G.Link(Then(Cleanup), Exec(Clear));
    if (!G.Check() || !BuildEditorKeys(BP, false) || !BuildEditorKeys(BP, true)) return false;
    FBlueprintEditorUtils::MarkBlueprintAsStructurallyModified(BP);
    return Compile(BP);
}

static bool Verify(UWidgetBlueprint* BP, bool SetDefaults)
{
    UClass* Class = BP->GeneratedClass;
    if (!Class || BP->ParentClass != Parent()) return false;
    auto* Pending = FindFProperty<FBoolProperty>(Class, Request);
    auto* Version = FindFProperty<FIntProperty>(Class, Contract);
    auto* Tried = FindFProperty<FBoolProperty>(Class, Attempted);
    auto* Focus = FindFProperty<FBoolProperty>(Class, TEXT("bIsFocusable"));
    auto* Auto = FindFProperty<FBoolProperty>(Class, TEXT("bAutoActivate"));
    auto* Back = FindFProperty<FBoolProperty>(Class, TEXT("bIsBackHandler"));
    auto* EditorRef = FindFProperty<FObjectPropertyBase>(Class, Editor);
    auto* KeyHeld = FindFProperty<FBoolProperty>(Class, Held);
    auto* IsActive = FindFProperty<FBoolProperty>(Class, TEXT("bIsActive"));
    UFunction* Fn = Class->FindFunctionByName(Callback);
    if (!Pending || !Version || !Tried || !Focus || !Auto || !Back || !EditorRef || !KeyHeld || !IsActive
        || !Fn || Fn->GetOuter() != Class || Fn->NumParms || Fn->Script.Num() == 0) return false;
    for (FName Name : {FName(TEXT("OnPreviewKeyDown")), FName(TEXT("OnKeyUp"))})
    {
        UFunction* KeyFn = Class->FindFunctionByName(Name);
        if (!KeyFn || KeyFn->GetOuter() != Class || KeyFn->Script.IsEmpty()) return false;
    }
    UObject* CDO = Class->GetDefaultObject();
    if (SetDefaults)
    {
        Pending->SetPropertyValue_InContainer(CDO, false); Version->SetPropertyValue_InContainer(CDO, 3);
        Tried->SetPropertyValue_InContainer(CDO, false); Focus->SetPropertyValue_InContainer(CDO, true);
        Auto->SetPropertyValue_InContainer(CDO, false); Back->SetPropertyValue_InContainer(CDO, false);
        EditorRef->SetObjectPropertyValue_InContainer(CDO, nullptr); KeyHeld->SetPropertyValue_InContainer(CDO, false);
    }
    Log(FString::Printf(TEXT("CDO parent=%s contract=%d pending=%d attempted=%d focusable=%d autoactivate=%d backhandler=%d callback-bytes=%d"),
        *BP->ParentClass->GetPathName(), Version->GetPropertyValue_InContainer(CDO), Pending->GetPropertyValue_InContainer(CDO),
        Tried->GetPropertyValue_InContainer(CDO), Focus->GetPropertyValue_InContainer(CDO), Auto->GetPropertyValue_InContainer(CDO), Back->GetPropertyValue_InContainer(CDO), Fn->Script.Num()));
    if (Version->GetPropertyValue_InContainer(CDO) != 3 || Pending->GetPropertyValue_InContainer(CDO) || Tried->GetPropertyValue_InContainer(CDO)
        || EditorRef->GetObjectPropertyValue_InContainer(CDO) || KeyHeld->GetPropertyValue_InContainer(CDO)
        || !Focus->GetPropertyValue_InContainer(CDO) || Auto->GetPropertyValue_InContainer(CDO) || Back->GetPropertyValue_InContainer(CDO)) return false;
    int32 Widgets = 0; bool NamedProperties = true;
    BP->WidgetTree->ForEachWidget([&](UWidget* W)
    {
        ++Widgets;
        auto* Property = FindFProperty<FObjectPropertyBase>(Class, W->GetFName());
        const bool Matches = Property && Property->PropertyClass == W->GetClass();
        NamedProperties &= Matches;
        Log(FString::Printf(TEXT("shell property %s %s %s"), *W->GetName(), *W->GetClass()->GetName(), Matches ? TEXT("PASS") : TEXT("FAILED")));
    });
    if (Widgets != 21 || !NamedProperties) return false;
    auto* Widget = NewObject<UUserWidget>(GetTransientPackage(), Class);
    // Execute a real engine-bound dynamic delegate. Registration itself is a
    // Pal kit stub, so no editor result is advertised as native routing proof.
    FOnInputAction Action; Action.BindUFunction(Widget, Callback);
    for (int32 Step = 0; Step != 3; ++Step)
    {
        if (Step == 2) Pending->SetPropertyValue_InContainer(Widget, false); // Lua acknowledgement equivalent.
        Action.Execute();
        if (!Pending->GetPropertyValue_InContainer(Widget) || Pending->GetPropertyValue_InContainer(CDO)) return false;
        Log(FString::Printf(TEXT("engine delegate callback step=%d pending=true CDO=false PASS"), Step));
    }
    // These execute the generated lifecycle bytecode against kit stubs. They
    // verify the local guard, not action-router registration or consumption.
    for (bool Construct : {true, true, false, false, true, false})
    {
        if (Construct) Widget->Construct(); else Widget->Destruct();
        if (Tried->GetPropertyValue_InContainer(Widget) != Construct || !Pending->GetPropertyValue_InContainer(Widget)) return false;
        Log(FString::Printf(TEXT("compiled lifecycle %s attempted=%d pending unchanged PASS (kit stubs)"), Construct ? TEXT("Construct") : TEXT("Destruct"), Construct));
    }
    Log(TEXT("routing unverified: Pal kit RegisterActionBinding/UnregisterActionBinding implementations are stubs"));
    const bool CreatedSlate = !FSlateApplication::IsInitialized();
    if (CreatedSlate)
    {
        auto& Renderer = FModuleManager::LoadModuleChecked<ISlateNullRendererModule>(TEXT("SlateNullRenderer"));
        FSlateApplication::InitializeAsStandaloneApplication(Renderer.CreateSlateNullRenderer());
    }
    ON_SCOPE_EXIT { if (CreatedSlate) FSlateApplication::Shutdown(); };
    Widget->Initialize(); // Already initialized returns false; inspect the tree instead.
    if (!Widget->WidgetTree) { Log(TEXT("FAILED fixture: no WidgetTree")); return false; }
    auto* Amount = Widget->WidgetTree->ConstructWidget<UEditableTextBox>(UEditableTextBox::StaticClass());
    auto* Root = Cast<UCanvasPanel>(Widget->WidgetTree->RootWidget);
    if (!Root || !Amount) return false;
    Root->AddChild(Amount);
    const TSharedRef<SWindow> Window = SNew(SWindow).ClientSize(FVector2D(640, 480))[Widget->TakeWidget()];
    FSlateApplication::Get().AddWindow(Window, false);
    FSlateApplication::Get().SetKeyboardFocus(Amount->TakeWidget());
    const bool Focused = Amount->HasAnyUserFocus() || Amount->HasFocusedDescendants();
    Log(FString::Printf(TEXT("editor fixture native Slate focus=%d"), Focused));
    bool Good = Focused;
    EditorRef->SetObjectPropertyValue_InContainer(Widget, Amount);
    IsActive->SetPropertyValue_InContainer(Widget, true);
    Pending->SetPropertyValue_InContainer(Widget, false);
    auto Down = [&](FKey Key, bool Repeat, bool ExpectedHandled, bool ExpectedPending)
    {
        FEventReply Reply = Widget->OnPreviewKeyDown(FGeometry(), FKeyEvent(Key, FModifierKeysState(), 0, Repeat, 0, 0));
        const bool Pass = Reply.NativeReply.IsEventHandled() == ExpectedHandled && Pending->GetPropertyValue_InContainer(Widget) == ExpectedPending;
        Log(FString::Printf(TEXT("editor compiled key=%s repeat=%d handled=%d pending=%d %s"), *Key.ToString(), Repeat,
            Reply.NativeReply.IsEventHandled(), Pending->GetPropertyValue_InContainer(Widget), Pass ? TEXT("PASS") : TEXT("FAILED")));
        Good &= Pass;
    };
    Down(EKeys::BackSpace, false, false, false);
    Down(EKeys::Enter, false, false, false);
    Down(EKeys::Gamepad_FaceButton_Right, false, false, false);
    Down(EKeys::Escape, false, true, true);
    Pending->SetPropertyValue_InContainer(Widget, false); // Lua cancels the editor.
    EditorRef->SetObjectPropertyValue_InContainer(Widget, nullptr);
    Down(EKeys::Escape, true, true, false); // Holding cannot close the panel.
    IsActive->SetPropertyValue_InContainer(Widget, false);
    Down(EKeys::Escape, true, false, false);
    IsActive->SetPropertyValue_InContainer(Widget, true);
    Good &= Widget->OnKeyUp(FGeometry(), FKeyEvent(EKeys::Escape, FModifierKeysState(), 0, false, 0, 0)).NativeReply.IsEventHandled();
    Good &= !KeyHeld->GetPropertyValue_InContainer(Widget);
    Down(EKeys::Escape, false, false, false); // Ordinary panel Back stays with CommonUI.
    EditorRef->SetObjectPropertyValue_InContainer(Widget, Amount);
    Down(EKeys::Escape, false, true, true);
    Pending->SetPropertyValue_InContainer(Widget, false);
    EditorRef->SetObjectPropertyValue_InContainer(Widget, nullptr);
    Down(EKeys::Escape, false, false, false); // Lost Up cannot eat a new press.
    Good &= !KeyHeld->GetPropertyValue_InContainer(Widget);
    FSlateApplication::Get().RequestDestroyWindow(Window);
    if (!Good) return false;
    return true;
}
}
