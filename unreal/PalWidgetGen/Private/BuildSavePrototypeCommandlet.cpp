#include "BuildSavePrototypeCommandlet.h"
#include "Engine/Blueprint.h"
#include "Engine/Engine.h"
#include "Engine/World.h"
#include "Engine/GameInstance.h"
#include "GameFramework/Actor.h"
#include "GameFramework/SaveGame.h"
#include "GameFramework/AsyncActionHandleSaveGame.h"
#include "Kismet/GameplayStatics.h"
#include "Kismet/KismetStringLibrary.h"
#include "Kismet/KismetSystemLibrary.h"
#include "Kismet/KismetGuidLibrary.h"
#include "Kismet/KismetMathLibrary.h"
#include "Kismet2/BlueprintEditorUtils.h"
#include "Kismet2/KismetEditorUtilities.h"
#include "KismetCompiler.h"
#include "EdGraphSchema_K2.h"
#include "K2Node_CustomEvent.h"
#include "K2Node_FunctionEntry.h"
#include "K2Node_FunctionResult.h"
#include "K2Node_AsyncAction.h"
#include "K2Node_AddDelegate.h"
#include "K2Node_CreateDelegate.h"
#include "K2Node_Self.h"
#include "K2Node_IfThenElse.h"
#include "K2Node_CallFunction.h"
#include "K2Node_VariableGet.h"
#include "K2Node_VariableSet.h"
#include "Misc/PackageName.h"
#include "Misc/Parse.h"
#include "UObject/SavePackage.h"
#include "UObject/UnrealType.h"
#include "UObject/StructOnScope.h"
#include "UObject/Script.h"
#include "UObject/StrongObjectPtr.h"
#include "Async/TaskGraphInterfaces.h"
#include "Containers/Ticker.h"

static bool ConfigureAsync(UK2Node_AsyncAction* Node, FName Operation = TEXT("AsyncSaveGameToSlot"))
{
    // Configure the stock node's reflected editor properties, avoiding a custom
    // editor-only node dependency in the generated asset.
    auto* Factory = FindFProperty<FNameProperty>(Node->GetClass(), TEXT("ProxyFactoryFunctionName"));
    auto* Activate = FindFProperty<FNameProperty>(Node->GetClass(), TEXT("ProxyActivateFunctionName"));
    auto* FactoryClass = FindFProperty<FObjectPropertyBase>(Node->GetClass(), TEXT("ProxyFactoryClass"));
    auto* ProxyClass = FindFProperty<FObjectPropertyBase>(Node->GetClass(), TEXT("ProxyClass"));
    if (!Factory || !Activate || !FactoryClass || !ProxyClass) return false;
    Factory->SetPropertyValue_InContainer(Node, Operation);
    Activate->SetPropertyValue_InContainer(Node, TEXT("Activate"));
    FactoryClass->SetObjectPropertyValue_InContainer(Node, UAsyncActionHandleSaveGame::StaticClass());
    ProxyClass->SetObjectPropertyValue_InContainer(Node, UAsyncActionHandleSaveGame::StaticClass());
    return true;
}

namespace PWPScratch
{
const TCHAR* Root = TEXT("/Game/Mods/PalWorkPrioritySaveScratch/");
const TCHAR* SlotA = TEXT("PWP_SaveScratch_v1_A");
const TCHAR* SlotB = TEXT("PWP_SaveScratch_v1_B");

bool Compile(UBlueprint* BP)
{
    FCompilerResultsLog Results;
    FBlueprintEditorUtils::MarkBlueprintAsStructurallyModified(BP);
    FKismetEditorUtilities::CompileBlueprint(BP, EBlueprintCompileOptions::None, &Results);
    return Results.NumErrors == 0 && BP->Status != BS_Error;
}
UBlueprint* Create(const TCHAR* Name, UClass* Parent)
{
    FString Path = FString(Root) + Name;
    // Re-runs verify existing assets; generation never silently overwrites them.
    if (LoadObject<UObject>(nullptr, *(Path + TEXT(".") + Name))) return nullptr;
    return FKismetEditorUtilities::CreateBlueprint(Parent, CreatePackage(*Path), Name,
        BPTYPE_Normal, UBlueprint::StaticClass(), UBlueprintGeneratedClass::StaticClass());
}
bool Member(UBlueprint* BP, const TCHAR* Name, FName Category, UClass* Class = nullptr)
{
    FEdGraphPinType Type; Type.PinCategory = Category; Type.PinSubCategoryObject = Class;
    if(Category==UEdGraphSchema_K2::PC_Real) Type.PinSubCategory=UEdGraphSchema_K2::PC_Double;
    return FBlueprintEditorUtils::AddMemberVariable(BP, Name, Type);
}
bool Save(UBlueprint* BP)
{
    if (!Compile(BP)) return false;
    FSavePackageArgs Args; Args.TopLevelFlags = RF_Public | RF_Standalone;
    return UPackage::SavePackage(BP->GetOutermost(), BP,
        *FPackageName::LongPackageNameToFilename(BP->GetOutermost()->GetName(), TEXT(".uasset")), Args);
}
template<class T> T* Node(UEdGraph* G)
{
    auto* N = NewObject<T>(G); G->AddNode(N); N->CreateNewGuid(); return N;
}
// A real nonempty function graph, not a custom-event/ubergraph entry alias.
// Serial is already published by the caller; Count measures actual function
// executions. Snapshots let the native fixture test state at function entry.
bool CompletionFunction(UBlueprint* BP)
{
    const auto* S = GetDefault<UEdGraphSchema_K2>();
    UEdGraph* G = FBlueprintEditorUtils::CreateNewGraph(BP, TEXT("ScratchCompleted"),
        UEdGraph::StaticClass(), UEdGraphSchema_K2::StaticClass());
    FBlueprintEditorUtils::AddFunctionGraph(BP,G,true,static_cast<UFunction*>(nullptr));
    UK2Node_FunctionEntry* Entry=nullptr; UK2Node_FunctionResult* Result=nullptr;
    for(UEdGraphNode* N:G->Nodes)
    {
        if(auto* E=Cast<UK2Node_FunctionEntry>(N)) Entry=E;
        if(auto* R=Cast<UK2Node_FunctionResult>(N)) Result=R;
    }
    if(!Entry) return false;
    Entry->AddExtraFlags(FUNC_Public | FUNC_BlueprintCallable);
    UEdGraphPin* Exec=Entry->FindPin(S->PN_Then); Exec->BreakAllPinLinks();
    bool Good=true;
    auto Link=[&](UEdGraphPin* A,UEdGraphPin* B) { Good &= A && B && S->TryCreateConnection(A,B); };
    auto Get=[&](const TCHAR* Name) {
        auto* N=Node<UK2Node_VariableGet>(G); N->VariableReference.SetSelfMember(Name); N->AllocateDefaultPins(); return N->GetValuePin();
    };
    auto Store=[&](const TCHAR* Name,UEdGraphPin* Value) {
        auto* N=Node<UK2Node_VariableSet>(G); N->VariableReference.SetSelfMember(Name); N->AllocateDefaultPins();
        Link(Value,N->FindPin(Name)); Link(Exec,N->FindPin(S->PN_Execute)); Exec=N->FindPin(S->PN_Then);
    };
    auto* Add=Node<UK2Node_CallFunction>(G);
    auto* Fn=UKismetMathLibrary::StaticClass()->FindFunctionByName(TEXT("Add_IntInt"));
    if(!Fn) return false;
    Add->SetFromFunction(Fn); Add->AllocateDefaultPins();
    Link(Get(TEXT("CompletionCount")),Add->FindPin(TEXT("A")));
    S->TrySetDefaultValue(*Add->FindPin(TEXT("B")),TEXT("1"));
    Store(TEXT("CompletionCount"),Add->GetReturnValuePin());
    Store(TEXT("CompletionObservedSerial"),Get(TEXT("CompletionSerial")));
    Store(TEXT("CompletionObservedGeneration"),Get(TEXT("CompletedGeneration")));
    Store(TEXT("CompletionObservedDone"),Get(TEXT("Done")));
    Store(TEXT("CompletionObservedBusy"),Get(TEXT("Busy")));
    Store(TEXT("CompletionObservedSuccess"),Get(TEXT("Success")));
    Store(TEXT("CompletionObservedSave"),Get(TEXT("LoadedSave")));
    if(Result) Link(Exec,Result->FindPin(S->PN_Execute));
    return Good && Compile(BP);
}

// V5 is deliberately a fixed-slot ownership/mailbox experiment, not a scoped
// production backend. Ordinary function graphs persist through cook/reload.
struct FMailboxGraph
{
    const UEdGraphSchema_K2* S=GetDefault<UEdGraphSchema_K2>();
    UEdGraph* G; UK2Node_FunctionEntry* Entry=nullptr; UEdGraphPin* Exec=nullptr;
    bool Good=true;
    FMailboxGraph(UEdGraph* Graph,UEdGraphPin* From) : G(Graph),Exec(From) {}
    FMailboxGraph(UBlueprint* BP,const TCHAR* Name)
    {
        G=FBlueprintEditorUtils::CreateNewGraph(BP,Name,UEdGraph::StaticClass(),UEdGraphSchema_K2::StaticClass());
        FBlueprintEditorUtils::AddFunctionGraph(BP,G,true,static_cast<UFunction*>(nullptr));
        for(UEdGraphNode* N:G->Nodes) if(auto* E=Cast<UK2Node_FunctionEntry>(N)) Entry=E;
        check(Entry); Entry->AddExtraFlags(FUNC_Public|FUNC_BlueprintCallable);
        Exec=Entry->FindPin(S->PN_Then); Exec->BreakAllPinLinks();
    }
    void Link(UEdGraphPin* A,UEdGraphPin* B) { Good &= A && B && S->TryCreateConnection(A,B); }
    UEdGraphPin* Arg(const TCHAR* Name,FName Category,UClass* Class=nullptr)
    { FEdGraphPinType T;T.PinCategory=Category;T.PinSubCategoryObject=Class;return Entry->CreateUserDefinedPin(Name,T,EGPD_Output); }
    UEdGraphPin* Get(const TCHAR* Name)
    { auto* N=Node<UK2Node_VariableGet>(G);N->VariableReference.SetSelfMember(Name);N->AllocateDefaultPins();return N->GetValuePin(); }
    UK2Node_CallFunction* Call(UClass* C,const TCHAR* Name)
    { auto* N=Node<UK2Node_CallFunction>(G);auto* F=C->FindFunctionByName(Name);check(F);N->SetFromFunction(F);N->AllocateDefaultPins();return N; }
    UEdGraphPin* Binary(UClass* C,const TCHAR* Name,UEdGraphPin* A,UEdGraphPin* B,const TCHAR* Default=nullptr)
    { auto* N=Call(C,Name);Link(A,N->FindPin(TEXT("A")));if(B) Link(B,N->FindPin(TEXT("B")));else S->TrySetDefaultValue(*N->FindPin(TEXT("B")),Default);return N->GetReturnValuePin(); }
    UEdGraphPin* Eq(UEdGraphPin* A,UEdGraphPin* B,const TCHAR* Value=nullptr)
    { return Binary(UKismetStringLibrary::StaticClass(),TEXT("EqualEqual_StrStr"),A,B,Value); }
    UEdGraphPin* Int(const TCHAR* Name,UEdGraphPin* A,UEdGraphPin* B=nullptr,const TCHAR* Value=nullptr)
    { return Binary(UKismetMathLibrary::StaticClass(),Name,A,B,Value); }
    UEdGraphPin* Not(UEdGraphPin* A)
    { auto* N=Call(UKismetMathLibrary::StaticClass(),TEXT("Not_PreBool"));Link(A,N->FindPin(TEXT("A")));return N->GetReturnValuePin(); }
    UK2Node_IfThenElse* Branch(UEdGraphPin* Condition)
    { auto* N=Node<UK2Node_IfThenElse>(G);N->AllocateDefaultPins();Link(Exec,N->GetExecPin());Link(Condition,N->GetConditionPin());return N; }
    void Return(UEdGraphPin* From,bool Value)
    {
        auto* N=Node<UK2Node_FunctionResult>(G);N->FunctionReference=Entry->FunctionReference;N->AllocateDefaultPins();
        FEdGraphPinType T;T.PinCategory=S->PC_Boolean;
        auto* P=N->CreateUserDefinedPin(TEXT("ReturnValue"),T,EGPD_Input);
        // A generated editable result pin's literal default can be reset when
        // its signature reconstructs on load. An ordinary linked literal node
        // persists independently of editable-pin metadata.
        auto* Literal=Call(UKismetSystemLibrary::StaticClass(),TEXT("MakeLiteralBool"));
        S->TrySetDefaultValue(*Literal->FindPin(TEXT("Value")),Value ? TEXT("true") : TEXT("false"));
        Link(Literal->GetReturnValuePin(),P);Link(From,N->FindPin(S->PN_Execute));
    }
    void Require(UEdGraphPin* Condition)
    { auto* N=Branch(Condition);Return(N->GetElsePin(),false);Exec=N->GetThenPin(); }
    void Store(const TCHAR* Name,UEdGraphPin* Value=nullptr,const TCHAR* Literal=nullptr)
    {
        auto* N=Node<UK2Node_VariableSet>(G);N->VariableReference.SetSelfMember(Name);N->AllocateDefaultPins();
        if(Value) Link(Value,N->FindPin(Name));else if(Literal) S->TrySetDefaultValue(*N->FindPin(Name),Literal);
        Link(Exec,N->FindPin(S->PN_Execute));Exec=N->FindPin(S->PN_Then);
    }
};

bool StorageFunctions(UBlueprint* BP)
{
    const auto* S=GetDefault<UEdGraphSchema_K2>();bool Good=true;
    for(const TCHAR* N:{TEXT("StorageBound"),TEXT("Retiring")}) Good &= Member(BP,N,S->PC_Boolean);
    for(const TCHAR* N:{TEXT("BoundSlotA"),TEXT("BoundSlotB")}) Good &= Member(BP,N,S->PC_String);
    Good &= Member(BP,TEXT("BoundEpoch"),S->PC_Int);
    if(!Good || !Compile(BP)) return false;
    FMailboxGraph F(BP,TEXT("BindStorage"));
    auto* Storage=F.Arg(TEXT("Storage"),S->PC_String);auto* Guild=F.Arg(TEXT("Guild"),S->PC_String);
    auto* Stream=F.Arg(TEXT("Stream"),S->PC_String);
    auto Guid=[&](UEdGraphPin* Value) {
        auto* Len=F.Call(UKismetStringLibrary::StaticClass(),TEXT("Len"));F.Link(Value,Len->FindPin(TEXT("S")));
        F.Require(F.Int(TEXT("EqualEqual_IntInt"),Len->GetReturnValuePin(),nullptr,TEXT("32")));
        auto* Parse=F.Call(UKismetGuidLibrary::StaticClass(),TEXT("Parse_StringToGuid"));F.Link(Value,Parse->FindPin(TEXT("GuidString")));
        F.Require(Parse->FindPin(TEXT("Success")));
        auto* Valid=F.Call(UKismetGuidLibrary::StaticClass(),TEXT("IsValid_Guid"));F.Link(Parse->FindPin(TEXT("OutGuid")),Valid->FindPin(TEXT("InGuid")));F.Require(Valid->GetReturnValuePin());
        auto* Canon=F.Call(UKismetGuidLibrary::StaticClass(),TEXT("Conv_GuidToString"));F.Link(Parse->FindPin(TEXT("OutGuid")),Canon->FindPin(TEXT("InGuid")));
        auto* Lower=F.Call(UKismetStringLibrary::StaticClass(),TEXT("ToLower"));F.Link(Canon->GetReturnValuePin(),Lower->FindPin(TEXT("SourceString")));return Lower->GetReturnValuePin();
    };
    auto* W=Guid(Storage);auto* G=Guid(Guild);
    F.Require(F.Binary(UKismetMathLibrary::StaticClass(),TEXT("BooleanOR"),F.Eq(Stream,nullptr,TEXT("priorities")),F.Eq(Stream,nullptr,TEXT("limits"))));
    auto Literal=[&](const TCHAR* Value) { auto* N=F.Call(UKismetSystemLibrary::StaticClass(),TEXT("MakeLiteralString"));S->TrySetDefaultValue(*N->FindPin(TEXT("Value")),Value);return N->GetReturnValuePin(); };
    auto Cat=[&](UEdGraphPin* A,UEdGraphPin* B) {return F.Binary(UKismetStringLibrary::StaticClass(),TEXT("Concat_StrStr"),A,B);};
    auto* Key=Cat(Cat(Cat(Cat(Cat(Literal(TEXT("PWP-SCOPE-1:")),W),Literal(TEXT(":"))),G),Literal(TEXT(":"))),Stream);
    auto* Bound=F.Branch(F.Get(TEXT("StorageBound")));F.Exec=Bound->GetThenPin();
    F.Require(F.Eq(Key,F.Get(TEXT("BoundScope"))));F.Return(F.Exec,true);
    F.Exec=Bound->GetElsePin();
    auto* Select=F.Call(UKismetMathLibrary::StaticClass(),TEXT("SelectString"));
    S->TrySetDefaultValue(*Select->FindPin(TEXT("A")),TEXT("p"));S->TrySetDefaultValue(*Select->FindPin(TEXT("B")),TEXT("l"));F.Link(F.Eq(Stream,nullptr,TEXT("priorities")),Select->FindPin(TEXT("bPickA")));
    auto* Stem=Cat(Cat(Cat(Cat(Cat(Literal(TEXT("PWP_AsyncDev_v1_")),W),Literal(TEXT("_"))),G),Literal(TEXT("_"))),Select->GetReturnValuePin());
    F.Store(TEXT("BoundScope"),Key);F.Store(TEXT("BoundSlotA"),Cat(Stem,Literal(TEXT("_A"))));F.Store(TEXT("BoundSlotB"),Cat(Stem,Literal(TEXT("_B"))));
    F.Store(TEXT("StorageBound"),nullptr,TEXT("true"));F.Return(F.Exec,true);
    return F.Good && Compile(BP);
}

bool MailboxFunctions(UBlueprint* BP,bool V6=false)
{
    const auto* S=GetDefault<UEdGraphSchema_K2>();bool Good=true;
    for(const TCHAR* N:{TEXT("BoundOwner"),TEXT("BoundScope"),TEXT("ActiveKind"),TEXT("ConsumedKind")}) Good &= Member(BP,N,S->PC_String);
    for(const TCHAR* N:{TEXT("Bound"),TEXT("ActiveUseA"),TEXT("ConsumedUseA")}) Good &= Member(BP,N,S->PC_Boolean);
    Good &= Member(BP,TEXT("ConsumedGeneration"),S->PC_Int);
    if(!Good || !Compile(BP)) return false;
    if(V6 && !StorageFunctions(BP)) return false;
    {
        FMailboxGraph F(BP,TEXT("BindOwner"));
        auto* Scope=F.Arg(TEXT("Scope"),S->PC_String);auto* Owner=F.Arg(TEXT("Owner"),S->PC_String);
        auto* Epoch=V6 ? F.Arg(TEXT("Epoch"),S->PC_Int) : nullptr;
        if(V6)
        {
            F.Require(F.Get(TEXT("StorageBound")));F.Require(F.Eq(Scope,F.Get(TEXT("BoundScope"))));
            F.Require(F.Int(TEXT("Greater_IntInt"),Epoch,nullptr,TEXT("0")));F.Require(F.Int(TEXT("Less_IntInt"),Epoch,nullptr,TEXT("2147483647")));
        }
        else F.Require(F.Eq(Scope,nullptr,TEXT("PWP-MAILBOX-DEV-1")));
        auto* Len=F.Call(UKismetStringLibrary::StaticClass(),TEXT("Len"));F.Link(Owner,Len->FindPin(TEXT("S")));
        F.Require(F.Int(TEXT("Greater_IntInt"),Len->GetReturnValuePin(),nullptr,TEXT("0")));
        F.Require(F.Int(TEXT("LessEqual_IntInt"),Len->GetReturnValuePin(),nullptr,TEXT("256")));
        auto* Bound=F.Branch(F.Get(TEXT("Bound")));F.Exec=Bound->GetThenPin();
        UEdGraphPin* Transfer=nullptr;
        if(V6)
        {
            auto* SameEpoch=F.Branch(F.Int(TEXT("EqualEqual_IntInt"),Epoch,F.Get(TEXT("BoundEpoch"))));
            F.Exec=SameEpoch->GetThenPin();F.Require(F.Not(F.Get(TEXT("Retiring"))));
            F.Require(F.Eq(Owner,F.Get(TEXT("BoundOwner"))));F.Return(F.Exec,true);
            F.Exec=SameEpoch->GetElsePin();F.Require(F.Get(TEXT("Retiring")));
            F.Require(F.Not(F.Get(TEXT("Busy"))));F.Require(F.Not(F.Get(TEXT("Done"))));
            F.Require(F.Int(TEXT("Greater_IntInt"),Epoch,F.Get(TEXT("BoundEpoch"))));Transfer=F.Exec;
        }
        else { F.Require(F.Eq(Owner,F.Get(TEXT("BoundOwner"))));F.Require(F.Eq(Scope,F.Get(TEXT("BoundScope"))));F.Return(F.Exec,true); }
        F.Exec=Bound->GetElsePin();
        // Both first bind and drained transfer enter the same assignment chain.
        auto* Start=Node<UK2Node_VariableSet>(F.G);Start->VariableReference.SetSelfMember(TEXT("BoundOwner"));Start->AllocateDefaultPins();
        F.Link(Owner,Start->FindPin(TEXT("BoundOwner")));F.Link(F.Exec,Start->FindPin(S->PN_Execute));if(Transfer) F.Link(Transfer,Start->FindPin(S->PN_Execute));F.Exec=Start->FindPin(S->PN_Then);
        F.Store(TEXT("BoundScope"),Scope);
        if(V6) { F.Store(TEXT("BoundEpoch"),Epoch);F.Store(TEXT("Retiring"),nullptr,TEXT("false"));F.Store(TEXT("ConsumedGeneration"),nullptr,TEXT("0")); }
        F.Store(TEXT("Bound"),nullptr,TEXT("true"));F.Return(F.Exec,true);Good &= F.Good;
    }
    if(V6)
    {
        FMailboxGraph F(BP,TEXT("RetireOwner"));
        auto* Scope=F.Arg(TEXT("Scope"),S->PC_String);auto* Owner=F.Arg(TEXT("Owner"),S->PC_String);auto* Epoch=F.Arg(TEXT("Epoch"),S->PC_Int);
        F.Require(F.Get(TEXT("Bound")));F.Require(F.Eq(Scope,F.Get(TEXT("BoundScope"))));F.Require(F.Eq(Owner,F.Get(TEXT("BoundOwner"))));
        F.Require(F.Int(TEXT("EqualEqual_IntInt"),Epoch,F.Get(TEXT("BoundEpoch"))));F.Store(TEXT("Retiring"),nullptr,TEXT("true"));F.Return(F.Exec,true);Good &= F.Good;
    }
    for(bool Consume:{false,true})
    {
        FMailboxGraph F(BP,Consume ? TEXT("ConsumeResult") : TEXT("ReserveRequest"));
        auto* Scope=F.Arg(TEXT("Scope"),S->PC_String);auto* Owner=F.Arg(TEXT("Owner"),S->PC_String);
        auto* Ticket=F.Arg(TEXT("Generation"),S->PC_Int);auto* Kind=F.Arg(TEXT("Kind"),S->PC_String);
        auto* UseA=F.Arg(TEXT("UseA"),S->PC_Boolean);
        auto* Record=Consume ? nullptr : F.Arg(TEXT("Record"),S->PC_Object,USaveGame::StaticClass());
        F.Require(F.Get(TEXT("Bound")));F.Require(F.Eq(Scope,F.Get(TEXT("BoundScope"))));F.Require(F.Eq(Owner,F.Get(TEXT("BoundOwner"))));
        if(V6) { auto* Epoch=F.Arg(TEXT("Epoch"),S->PC_Int);F.Require(F.Int(TEXT("EqualEqual_IntInt"),Epoch,F.Get(TEXT("BoundEpoch")))); }
        F.Require(F.Int(TEXT("Greater_IntInt"),Ticket,nullptr,TEXT("0")));
        F.Require(F.Int(TEXT("Less_IntInt"),Ticket,nullptr,TEXT("2147483647")));
        if(Consume)
        {
            // A lost acknowledgement may be retried even with newer IO pending.
            // The exact previous identity returns true without mutating anything.
            auto* Previous=F.Branch(F.Int(TEXT("EqualEqual_IntInt"),Ticket,F.Get(TEXT("ConsumedGeneration"))));
            F.Exec=Previous->GetThenPin();F.Require(F.Eq(Kind,F.Get(TEXT("ConsumedKind"))));
            F.Require(F.Binary(UKismetMathLibrary::StaticClass(),TEXT("EqualEqual_BoolBool"),UseA,F.Get(TEXT("ConsumedUseA"))));F.Return(F.Exec,true);
            F.Exec=Previous->GetElsePin();
            F.Require(F.Not(F.Get(TEXT("Busy"))));F.Require(F.Get(TEXT("Done")));
            F.Require(F.Int(TEXT("EqualEqual_IntInt"),Ticket,F.Get(TEXT("ActiveGeneration"))));
            F.Require(F.Int(TEXT("EqualEqual_IntInt"),Ticket,F.Get(TEXT("CompletedGeneration"))));
            F.Require(F.Eq(Kind,F.Get(TEXT("ActiveKind"))));
            F.Require(F.Binary(UKismetMathLibrary::StaticClass(),TEXT("EqualEqual_BoolBool"),UseA,F.Get(TEXT("ActiveUseA"))));
            F.Store(TEXT("ConsumedGeneration"),Ticket);F.Store(TEXT("ConsumedKind"),Kind);F.Store(TEXT("ConsumedUseA"),UseA);
            F.Store(TEXT("Done"),nullptr,TEXT("false"));F.Store(TEXT("LoadedSave"));F.Store(TEXT("ActiveSave"));F.Store(TEXT("CompletionObservedSave"));
        }
        else
        {
            if(V6) F.Require(F.Not(F.Get(TEXT("Retiring"))));
            F.Require(F.Not(F.Get(TEXT("Busy"))));F.Require(F.Not(F.Get(TEXT("Done"))));
            F.Require(F.Int(TEXT("Greater_IntInt"),Ticket,F.Get(TEXT("ActiveGeneration"))));
            F.Require(F.Binary(UKismetMathLibrary::StaticClass(),TEXT("BooleanOR"),F.Eq(Kind,nullptr,TEXT("write")),F.Eq(Kind,nullptr,TEXT("read"))));
            // Snapshot and reserve before returning through any UE4SS post-hook.
            // No event-parameter temporary may be read after this function call.
            F.Store(TEXT("Busy"),nullptr,TEXT("true"));F.Store(TEXT("ActiveGeneration"),Ticket);
            F.Store(TEXT("ActiveKind"),Kind);F.Store(TEXT("ActiveUseA"),UseA);F.Store(TEXT("ActiveSave"),Record);
            auto* Slot=F.Call(UKismetMathLibrary::StaticClass(),TEXT("SelectString"));
            if(V6) { F.Link(F.Get(TEXT("BoundSlotA")),Slot->FindPin(TEXT("A")));F.Link(F.Get(TEXT("BoundSlotB")),Slot->FindPin(TEXT("B"))); }
            else { F.S->TrySetDefaultValue(*Slot->FindPin(TEXT("A")),SlotA);F.S->TrySetDefaultValue(*Slot->FindPin(TEXT("B")),SlotB); }
            F.Link(UseA,Slot->FindPin(TEXT("bPickA")));F.Store(TEXT("ActiveSlot"),Slot->GetReturnValuePin());
        }
        F.Return(F.Exec,true);Good &= F.Good;
    }
    return Good && Compile(BP);
}

bool Bridge(UBlueprint* BP, bool V3, bool V4=false, bool V5=false,bool V6=false)
{
    const auto* S = GetDefault<UEdGraphSchema_K2>(); bool Good = true;
    for (const TCHAR* Name : {TEXT("Busy"),TEXT("Done"),TEXT("Success")}) Good &= Member(BP,Name,S->PC_Boolean);
    for (const TCHAR* Name : {TEXT("ActiveGeneration"),TEXT("CompletedGeneration")}) Good &= Member(BP,Name,S->PC_Int);
    Good &= Member(BP,TEXT("ActiveSlot"),S->PC_String);
    Good &= Member(BP,TEXT("TrialTag"),S->PC_String);
    for (const TCHAR* Name : {TEXT("StartedSeconds"),TEXT("SaveFinishedSeconds"),TEXT("ReadStartedSeconds"),TEXT("CompletedSeconds")}) Good &= Member(BP,Name,S->PC_Real);
    Good &= Member(BP,TEXT("ActiveSave"),S->PC_Object,USaveGame::StaticClass());
    Good &= Member(BP,TEXT("LoadedSave"),S->PC_Object,USaveGame::StaticClass());
    if(V4)
    {
        Good &= Member(BP,TEXT("WorldContext"),S->PC_Object,UObject::StaticClass());
        Good &= Member(BP,TEXT("PendingAction"),S->PC_Object,UAsyncActionHandleSaveGame::StaticClass());
    }
    if(V3)
    {
        for(const TCHAR* Name:{TEXT("CompletionSerial"),TEXT("CompletionCount"),TEXT("CompletionObservedSerial"),TEXT("CompletionObservedGeneration")})
            Good &= Member(BP,Name,S->PC_Int);
        for(const TCHAR* Name:{TEXT("CompletionObservedDone"),TEXT("CompletionObservedBusy"),TEXT("CompletionObservedSuccess")})
            Good &= Member(BP,Name,S->PC_Boolean);
        Good &= Member(BP,TEXT("CompletionObservedSave"),S->PC_Object,USaveGame::StaticClass());
    }
    if (!Good || !Compile(BP) || BP->UbergraphPages.Num()!=1) return false;
    if(V3 && !CompletionFunction(BP)) return false;
    if(V5 && !MailboxFunctions(BP,V6)) return false;
    UEdGraph* G = BP->UbergraphPages[0];
    auto Link = [&](UEdGraphPin* A, UEdGraphPin* B) {
        const bool Ok = A && B && S->TryCreateConnection(A,B); Good &= Ok;
        if (!Ok) UE_LOG(LogTemp,Error,TEXT("Scratch link failed: %s -> %s"),
            A ? *A->PinName.ToString() : TEXT("null"), B ? *B->PinName.ToString() : TEXT("null"));
    };
    auto Get = [&](const TCHAR* Name) {
        auto* N=Node<UK2Node_VariableGet>(G); N->VariableReference.SetSelfMember(Name); N->AllocateDefaultPins(); return N;
    };
    auto Set = [&](const TCHAR* Name, const TCHAR* Value=nullptr) {
        auto* N=Node<UK2Node_VariableSet>(G); N->VariableReference.SetSelfMember(Name); N->AllocateDefaultPins();
        if(Value) S->TrySetDefaultValue(*N->FindPin(Name),Value); return N;
    };
    struct FAsyncPins {
        TMap<FName,UEdGraphPin*> Pins;
        UEdGraphPin* FindPin(FName Name) { return Pins.FindRef(Name); }
    };
    TArray<TUniquePtr<FAsyncPins>> AsyncPins;
    auto Async = [&](FName Operation) -> FAsyncPins* {
        auto Pins=MakeUnique<FAsyncPins>();
        if(!V4)
        {
            auto* N=Node<UK2Node_AsyncAction>(G);
            if(!ConfigureAsync(N,Operation)) { Good=false; return nullptr; }
            N->AllocateDefaultPins();
            for(auto* P:N->Pins) Pins->Pins.Add(P->PinName,P);
        }
        else
        {
            // Explicit ordering is necessary: stock async nodes activate before
            // their external Then output. Keep the action BEFORE Activate can
            // synchronously complete, with no temporary editor metadata.
            UClass* Proxy=UAsyncActionHandleSaveGame::StaticClass();
            auto* Factory=Node<UK2Node_CallFunction>(G);
            Factory->SetFromFunction(Proxy->FindFunctionByName(Operation)); Factory->AllocateDefaultPins();
            for(auto* P:Factory->Pins) Pins->Pins.Add(P->PinName,P);
            Link(Get(TEXT("WorldContext"))->GetValuePin(),Factory->FindPin(TEXT("WorldContextObject")));
            auto* Hold=Set(TEXT("PendingAction"));
            Link(Factory->GetReturnValuePin(),Hold->FindPin(TEXT("PendingAction")));
            Link(Factory->FindPin(S->PN_Then),Hold->FindPin(S->PN_Execute));
            auto* Property=FindFProperty<FMulticastDelegateProperty>(Proxy,TEXT("Completed"));
            if(!Property) return nullptr;
            auto* Bind=Node<UK2Node_AddDelegate>(G);
            Bind->SetFromProperty(Property,false,Proxy); Bind->AllocateDefaultPins();
            Link(Hold->FindPin(S->PN_Then),Bind->FindPin(S->PN_Execute));
            Link(Get(TEXT("PendingAction"))->GetValuePin(),Bind->FindPin(S->PN_Self));
            auto* Event=Node<UK2Node_CustomEvent>(G);
            Event->CustomFunctionName=*FString::Printf(TEXT("LifetimeCompleted_%d"),AsyncPins.Num());
            Event->AllocateDefaultPins();
            for(TFieldIterator<FProperty> It(Property->SignatureFunction);It;++It)
            {
                if(!It->HasAnyPropertyFlags(CPF_Parm) || It->HasAnyPropertyFlags(CPF_ReturnParm)) continue;
                FEdGraphPinType Type; Good &= S->ConvertPropertyToPinType(*It,Type);
                Pins->Pins.Add(It->GetFName(),Event->CreateUserDefinedPin(It->GetFName(),Type,EGPD_Output));
            }
            auto* Self=Node<UK2Node_Self>(G); Self->AllocateDefaultPins();
            auto* Delegate=Node<UK2Node_CreateDelegate>(G); Delegate->AllocateDefaultPins();
            Link(Self->FindPin(S->PN_Self),Delegate->GetObjectInPin());
            Link(Delegate->GetDelegateOutPin(),Bind->GetDelegatePin()); Delegate->SetFunction(Event->CustomFunctionName);
            auto* Activate=Node<UK2Node_CallFunction>(G);
            Activate->FunctionReference.SetExternalMember(TEXT("Activate"),Proxy); Activate->AllocateDefaultPins();
            Link(Bind->FindPin(S->PN_Then),Activate->FindPin(S->PN_Execute));
            Link(Get(TEXT("PendingAction"))->GetValuePin(),Activate->FindPin(S->PN_Self));
            Pins->Pins.Add(TEXT("Completed"),Event->FindPin(S->PN_Then));
        }
        auto* Result=Pins.Get(); AsyncPins.Add(MoveTemp(Pins)); return Result;
    };
    for (bool Write : {true,false})
    {
        auto* Start=Node<UK2Node_CustomEvent>(G);
        Start->CustomFunctionName=Write ? TEXT("SubmitScratch") : TEXT("LoadScratch"); Start->AllocateDefaultPins();
        FEdGraphPinType Obj; Obj.PinCategory=S->PC_Object; Obj.PinSubCategoryObject=USaveGame::StaticClass();
        FEdGraphPinType Int; Int.PinCategory=S->PC_Int;
        FEdGraphPinType Bool; Bool.PinCategory=S->PC_Boolean;
        if(Write) Start->CreateUserDefinedPin(TEXT("Record"),Obj,EGPD_Output);
        Start->CreateUserDefinedPin(TEXT("Generation"),Int,EGPD_Output);
        Start->CreateUserDefinedPin(TEXT("UseA"),Bool,EGPD_Output);
        if(V5)
        { FEdGraphPinType Str;Str.PinCategory=S->PC_String;Start->CreateUserDefinedPin(TEXT("Scope"),Str,EGPD_Output);Start->CreateUserDefinedPin(TEXT("Owner"),Str,EGPD_Output); }
        if(V6) Start->CreateUserDefinedPin(TEXT("Epoch"),Int,EGPD_Output);
        auto* Guard=Node<UK2Node_IfThenElse>(G); Guard->AllocateDefaultPins();
        Link(Start->FindPin(S->PN_Then),Guard->GetExecPin());
        Link(Get(TEXT("Busy"))->GetValuePin(),Guard->GetConditionPin());
        UEdGraphPin* Exec=Guard->GetElsePin();
        if(V5)
        {
            auto* Check=Node<UK2Node_CallFunction>(G);Check->FunctionReference.SetSelfMember(TEXT("ReserveRequest"));Check->AllocateDefaultPins();
            for(const TCHAR* N:{TEXT("Scope"),TEXT("Owner"),TEXT("Generation"),TEXT("UseA")}) Link(Start->FindPin(N),Check->FindPin(N));
            S->TrySetDefaultValue(*Check->FindPin(TEXT("Kind")),Write ? TEXT("write") : TEXT("read"));
            if(Write) Link(Start->FindPin(TEXT("Record")),Check->FindPin(TEXT("Record")));
            if(V6) Link(Start->FindPin(TEXT("Epoch")),Check->FindPin(TEXT("Epoch")));
            Link(Exec,Check->FindPin(S->PN_Execute));
            auto* Admit=Node<UK2Node_IfThenElse>(G);Admit->AllocateDefaultPins();Link(Check->FindPin(S->PN_Then),Admit->GetExecPin());
            Link(Check->GetReturnValuePin(),Admit->GetConditionPin());Exec=Admit->GetThenPin();
        }
        auto Chain=[&](UK2Node_VariableSet* N) { Link(Exec,N->FindPin(S->PN_Execute)); Exec=N->FindPin(S->PN_Then); };
        auto Time=[&](const TCHAR* Name) {
            // This lifetime probe deliberately has no clock/world lookup after
            // teardown. External monotonic clocks measure it; zero is unmeasured.
            if(V4) { Chain(Set(Name,TEXT("0"))); return; }
            auto* Fn=UGameplayStatics::StaticClass()->FindFunctionByName(TEXT("GetRealTimeSeconds"));
            if(!Fn) { Good=false; return; }
            auto* Now=Node<UK2Node_CallFunction>(G); Now->SetFromFunction(Fn); Now->AllocateDefaultPins();
            auto* Store=Set(Name); Link(Now->GetReturnValuePin(),Store->FindPin(Name)); Chain(Store);
        };
        Chain(Set(TEXT("Busy"),TEXT("true"))); Chain(Set(TEXT("Done"),TEXT("false")));
        if(V4) Chain(Set(TEXT("PendingAction")));
        Chain(Set(TEXT("Success"),TEXT("false"))); Chain(Set(TEXT("LoadedSave")));
        Time(TEXT("StartedSeconds")); Chain(Set(TEXT("SaveFinishedSeconds"),TEXT("0")));
        if(V3) Chain(Set(TEXT("ReadStartedSeconds"),TEXT("0"))); // Null-save failure never starts a read.
        if(!V5)
        {
        auto* Active=Set(TEXT("ActiveSave"));
        if(Write) Link(Start->FindPin(TEXT("Record")),Active->FindPin(TEXT("ActiveSave"))); Chain(Active);
        auto* Generation=Set(TEXT("ActiveGeneration"));
        Link(Start->FindPin(TEXT("Generation")),Generation->FindPin(TEXT("ActiveGeneration"))); Chain(Generation);
        auto* Slot=Node<UK2Node_CallFunction>(G);
        auto* Select=UKismetMathLibrary::StaticClass()->FindFunctionByName(TEXT("SelectString"));
        if(!Select) return false;
        Slot->SetFromFunction(Select); Slot->AllocateDefaultPins();
        if(!Slot->FindPin(TEXT("A")) || !Slot->FindPin(TEXT("B"))) return false;
        S->TrySetDefaultValue(*Slot->FindPin(TEXT("A")),SlotA); S->TrySetDefaultValue(*Slot->FindPin(TEXT("B")),SlotB);
        Link(Start->FindPin(TEXT("UseA")),Slot->FindPin(TEXT("bPickA")));
        auto* StoreSlot=Set(TEXT("ActiveSlot")); Link(Slot->GetReturnValuePin(),StoreSlot->FindPin(TEXT("ActiveSlot"))); Chain(StoreSlot);
        }
        // Snapshot the slot before yielding. A rejected reentrant event can
        // overwrite event-parameter temporaries but never ActiveSlot.
        UK2Node_IfThenElse* Saved=nullptr;
        if(Write)
        {
            auto* SaveOp=Async(TEXT("AsyncSaveGameToSlot")); if(!SaveOp) return false;
            Link(Exec,SaveOp->FindPin(S->PN_Execute));
            Link(Get(TEXT("ActiveSave"))->GetValuePin(),SaveOp->FindPin(TEXT("SaveGameObject")));
            Link(Get(TEXT("ActiveSlot"))->GetValuePin(),SaveOp->FindPin(TEXT("SlotName")));
            Saved=Node<UK2Node_IfThenElse>(G); Saved->AllocateDefaultPins();
            Exec=SaveOp->FindPin(TEXT("Completed")); Time(TEXT("SaveFinishedSeconds"));
            Link(Exec,Saved->GetExecPin());
            Link(SaveOp->FindPin(TEXT("bSuccess")),Saved->GetConditionPin()); Exec=Saved->GetThenPin();
        }
        Time(TEXT("ReadStartedSeconds"));
        auto* LoadOp=Async(TEXT("AsyncLoadGameFromSlot")); if(!LoadOp) return false;
        Link(Exec,LoadOp->FindPin(S->PN_Execute));
        Link(Get(TEXT("ActiveSlot"))->GetValuePin(),LoadOp->FindPin(TEXT("SlotName")));
        Exec=LoadOp->FindPin(TEXT("Completed"));
        auto* Loaded=Set(TEXT("LoadedSave")); Link(LoadOp->FindPin(TEXT("SaveGame")),Loaded->FindPin(TEXT("LoadedSave"))); Chain(Loaded);
        auto* Success=Set(TEXT("Success")); Link(LoadOp->FindPin(TEXT("bSuccess")),Success->FindPin(TEXT("Success"))); Chain(Success);
        auto* Completed=Set(TEXT("CompletedGeneration"));
        Link(Get(TEXT("ActiveGeneration"))->GetValuePin(),Completed->FindPin(TEXT("CompletedGeneration")));
        if(Saved) Link(Saved->GetElsePin(),Completed->FindPin(S->PN_Execute));
        Chain(Completed); Time(TEXT("CompletedSeconds")); Chain(Set(TEXT("Done"),TEXT("true"))); Chain(Set(TEXT("Busy"),TEXT("false")));
        if(V4) { Chain(Set(TEXT("WorldContext"))); Chain(Set(TEXT("PendingAction"))); }
        if(V3)
        {
            auto* Add=Node<UK2Node_CallFunction>(G);
            auto* Fn=UKismetMathLibrary::StaticClass()->FindFunctionByName(TEXT("Add_IntInt"));
            if(!Fn) return false;
            Add->SetFromFunction(Fn); Add->AllocateDefaultPins();
            Link(Get(TEXT("CompletionSerial"))->GetValuePin(),Add->FindPin(TEXT("A")));
            S->TrySetDefaultValue(*Add->FindPin(TEXT("B")),TEXT("1"));
            auto* Serial=Set(TEXT("CompletionSerial")); Link(Add->GetReturnValuePin(),Serial->FindPin(TEXT("CompletionSerial"))); Chain(Serial);
            auto* Notify=Node<UK2Node_CallFunction>(G);
            Notify->FunctionReference.SetSelfMember(TEXT("ScratchCompleted")); Notify->AllocateDefaultPins();
            Link(Exec,Notify->FindPin(S->PN_Execute));
        }
    }
    return Good && Save(BP);
}

// Test-only unsaved graph extension: acknowledge and submit directly inside the
// native completion function. No editor test class is referenced by cooked assets.
bool MailboxReentryProbe(UClass* RecordClass,bool V6=false)
{
    FEditorScriptExecutionGuard Allow;
    TStrongObjectPtr<UClass> RecordClassOwner(RecordClass);
    auto* BP=LoadObject<UBlueprint>(nullptr,V6 ? TEXT("/Game/Mods/PalWorkPrioritySaveScratch/BP_ScratchBridgeV6.BP_ScratchBridgeV6") : TEXT("/Game/Mods/PalWorkPrioritySaveScratch/BP_ScratchBridgeV5.BP_ScratchBridgeV5"));
    if(!BP) return false;
    const FString Scope=V6 ? TEXT("PWP-SCOPE-1:")+FString::ChrN(32,TEXT('3'))+TEXT(":")+FString::ChrN(32,TEXT('c'))+TEXT(":priorities") : TEXT("PWP-MAILBOX-DEV-1");
    const auto* S=GetDefault<UEdGraphSchema_K2>();
    if(!Member(BP,TEXT("ProbeReentryBusy"),S->PC_Boolean) || !Member(BP,TEXT("ProbeReentryAccepted"),S->PC_Boolean)
        || !Member(BP,TEXT("ProbeFirstSuccess"),S->PC_Boolean)
        || !Member(BP,TEXT("ProbeReentryTicket"),S->PC_Int) || !Compile(BP)) return false;
    UEdGraph* Graph=nullptr;UK2Node_VariableSet* Tail=nullptr;
    for(UEdGraph* G:BP->FunctionGraphs) if(G->GetFName()==TEXT("ScratchCompleted")) Graph=G;
    if(!Graph) return false;
    for(UEdGraphNode* N:Graph->Nodes) if(auto* V=Cast<UK2Node_VariableSet>(N))
        if(V->VariableReference.GetMemberName()==TEXT("CompletionObservedSave")) Tail=V;
    if(!Tail) return false;
    FMailboxGraph F(Graph,Tail->FindPin(S->PN_Then));F.Exec->BreakAllPinLinks();
    auto* Branch=F.Branch(F.Int(TEXT("EqualEqual_IntInt"),F.Get(TEXT("CompletedGeneration")),nullptr,TEXT("2")));
    F.Exec=Branch->GetThenPin();
    F.Store(TEXT("ProbeFirstSuccess"),F.Get(TEXT("Success")));
    auto Invoke=[&](const TCHAR* Name,int32 Ticket,int32 Epoch=1) {
        auto* N=Node<UK2Node_CallFunction>(Graph);N->FunctionReference.SetSelfMember(Name);N->AllocateDefaultPins();
        S->TrySetDefaultValue(*N->FindPin(TEXT("Scope")),Scope);
        S->TrySetDefaultValue(*N->FindPin(TEXT("Owner")),TEXT("reentrant"));
        if(auto* P=N->FindPin(TEXT("Generation"))) S->TrySetDefaultValue(*P,FString::FromInt(Ticket));
        if(auto* P=N->FindPin(TEXT("UseA"))) S->TrySetDefaultValue(*P,TEXT("false"));
        if(V6) S->TrySetDefaultValue(*N->FindPin(TEXT("Epoch")),FString::FromInt(Epoch));
        F.Link(F.Exec,N->FindPin(S->PN_Execute));F.Exec=N->FindPin(S->PN_Then);return N;
    };
    if(V6) Invoke(TEXT("RetireOwner"),0);
    auto* Consume=Invoke(TEXT("ConsumeResult"),2);S->TrySetDefaultValue(*Consume->FindPin(TEXT("Kind")),TEXT("write"));
    F.Store(TEXT("ProbeReentryAccepted"),Consume->GetReturnValuePin());
    if(V6) Invoke(TEXT("BindOwner"),0,2);
    Invoke(TEXT("LoadScratch"),3,V6?2:1);F.Store(TEXT("ProbeReentryBusy"),F.Get(TEXT("Busy")));F.Store(TEXT("ProbeReentryTicket"),F.Get(TEXT("ActiveGeneration")));
    if(!F.Good || !Compile(BP)) return false;
    UClass* Class=BP->GeneratedClass;
    auto* Bridge=NewObject<UObject>(GetTransientPackage(),Class,NAME_None,RF_Transient|RF_MarkAsRootSet);
    auto Call=[&](const TCHAR* Name,int32 Ticket,USaveGame* Record=nullptr,const TCHAR* Kind=TEXT("read")) {
        UFunction* Fn=Class->FindFunctionByName(Name);check(Fn);FStructOnScope Args(Fn);
        auto Str=[&](const TCHAR* N,const TCHAR* V) { if(auto* P=FindFProperty<FStrProperty>(Fn,N)) P->SetPropertyValue_InContainer(Args.GetStructMemory(),V); };
        Str(TEXT("Scope"),*Scope);Str(TEXT("Owner"),TEXT("reentrant"));Str(TEXT("Kind"),Kind);
        if(V6)
        {
            if(auto* P=FindFProperty<FIntProperty>(Fn,TEXT("Epoch"))) P->SetPropertyValue_InContainer(Args.GetStructMemory(),Ticket>=3?2:1);
            Str(TEXT("Storage"),*FString::ChrN(32,TEXT('3')));Str(TEXT("Guild"),*FString::ChrN(32,TEXT('c')));Str(TEXT("Stream"),TEXT("priorities"));
        }
        if(auto* P=FindFProperty<FIntProperty>(Fn,TEXT("Generation"))) P->SetPropertyValue_InContainer(Args.GetStructMemory(),Ticket);
        if(auto* P=FindFProperty<FObjectPropertyBase>(Fn,TEXT("Record"))) P->SetObjectPropertyValue_InContainer(Args.GetStructMemory(),Record);
        Bridge->ProcessEvent(Fn,Args.GetStructMemory());
        auto* Ret=FindFProperty<FBoolProperty>(Fn,TEXT("ReturnValue"));return !Ret || Ret->GetPropertyValue_InContainer(Args.GetStructMemory());
    };
    auto Bool=[&](const TCHAR* N) {return FindFProperty<FBoolProperty>(Class,N)->GetPropertyValue_InContainer(Bridge);};
    auto Int=[&](const TCHAR* N) {return FindFProperty<FIntProperty>(Class,N)->GetPropertyValue_InContainer(Bridge);};
    if((V6 && !Call(TEXT("BindStorage"),0)) || !Call(TEXT("BindOwner"),0)) return false;
    auto* Record=UGameplayStatics::CreateSaveGameObject(RecordClass);
    const FString Unique=TEXT("Reentrant X ")+FGuid::NewGuid().ToString();
    FindFProperty<FStrProperty>(RecordClass,TEXT("Payload"))->SetPropertyValue_InContainer(Record,Unique);
    FindFProperty<FIntProperty>(RecordClass,TEXT("Generation"))->SetPropertyValue_InContainer(Record,17);
    Call(TEXT("SubmitScratch"),2,Record);
    const double Start=FPlatformTime::Seconds();
    while(!(Bool(TEXT("Done")) && Int(TEXT("CompletedGeneration"))==3) && FPlatformTime::Seconds()-Start<30)
    { FTSTicker::GetCoreTicker().Tick(0.001f);FTaskGraphInterface::Get().ProcessThreadUntilIdle(ENamedThreads::GameThread);FPlatformProcess::Sleep(0.001f); }
    auto* Loaded=FindFProperty<FObjectPropertyBase>(Class,TEXT("LoadedSave"))->GetObjectPropertyValue_InContainer(Bridge);
    bool Good=Bool(TEXT("Done")) && Bool(TEXT("Success")) && !Bool(TEXT("Busy")) && Int(TEXT("CompletedGeneration"))==3
        && Int(TEXT("ActiveGeneration"))==3 && Int(TEXT("CompletionCount"))==2 && Bool(TEXT("ProbeReentryBusy"))
        && Bool(TEXT("ProbeFirstSuccess")) && Bool(TEXT("ProbeReentryAccepted")) && Int(TEXT("ProbeReentryTicket"))==3 && Loaded && Loaded->GetClass()==RecordClass
        && FindFProperty<FStrProperty>(RecordClass,TEXT("Payload"))->GetPropertyValue_InContainer(Loaded)==Unique
        && FindFProperty<FIntProperty>(RecordClass,TEXT("Generation"))->GetPropertyValue_InContainer(Loaded)==17;
    Good &= Call(TEXT("ConsumeResult"),3) && !Bool(TEXT("Done"));
    // Restore the separately checked restart fixture, only after unique-content
    // validation. Otherwise a failed reentrant write could reuse old slot data.
    if(Good)
    {
        auto* Restore=UGameplayStatics::CreateSaveGameObject(RecordClass);
        FindFProperty<FStrProperty>(RecordClass,TEXT("Payload"))->SetPropertyValue_InContainer(Restore,TEXT("Blueprint scratch X"));
        FindFProperty<FIntProperty>(RecordClass,TEXT("Generation"))->SetPropertyValue_InContainer(Restore,2);
        Call(TEXT("SubmitScratch"),4,Restore);const double RestoreStart=FPlatformTime::Seconds();
        while(!Bool(TEXT("Done")) && FPlatformTime::Seconds()-RestoreStart<30)
        { FTSTicker::GetCoreTicker().Tick(0.001f);FTaskGraphInterface::Get().ProcessThreadUntilIdle(ENamedThreads::GameThread);FPlatformProcess::Sleep(0.001f); }
        Good &= Bool(TEXT("Done")) && Bool(TEXT("Success")) && Int(TEXT("CompletedGeneration"))==4
            && Int(TEXT("CompletionCount"))==3 && Call(TEXT("ConsumeResult"),4,nullptr,TEXT("write"));
    }
    if(!Bool(TEXT("Busy"))) Bridge->RemoveFromRoot();
    if(V6) Good &= Int(TEXT("BoundEpoch"))==2;
    UE_LOG(LogTemp,Display,TEXT("PWP SCRATCH %s completion_reentry=%d"),V6?TEXT("V6"):TEXT("V5"),Good);
    return Good;
}

bool ScopedMailboxProbe(UClass* RecordClass,bool ReadOnly)
{
    FEditorScriptExecutionGuard Allow;
    // The fixture compares this class address after explicit GC. Unlike a Lua
    // runtime cache, this owning handle keeps the test oracle itself alive.
    TStrongObjectPtr<UClass> RecordClassOwner(RecordClass);
    UClass* Class=LoadClass<UObject>(nullptr,TEXT("/Game/Mods/PalWorkPrioritySaveScratch/BP_ScratchBridgeV6.BP_ScratchBridgeV6_C"));
    if(!Class) return false;
    bool Good=true;TArray<UObject*> Bridges;TArray<FString> Keys;TSet<FString> Names;
    auto Str=[&](UObject* B,const TCHAR* N) {return FindFProperty<FStrProperty>(Class,N)->GetPropertyValue_InContainer(B);};
    auto Int=[&](UObject* B,const TCHAR* N) {return FindFProperty<FIntProperty>(Class,N)->GetPropertyValue_InContainer(B);};
    auto Bool=[&](UObject* B,const TCHAR* N) {return FindFProperty<FBoolProperty>(Class,N)->GetPropertyValue_InContainer(B);};
    auto Bind=[&](UObject* B,const FString& W,const FString& G,const FString& Stream) {
        auto* Fn=Class->FindFunctionByName(TEXT("BindStorage"));if(!Fn) return false;FStructOnScope Args(Fn);
        for(auto Pair:{TPair<const TCHAR*,FString>(TEXT("Storage"),W),{TEXT("Guild"),G},{TEXT("Stream"),Stream}})
            FindFProperty<FStrProperty>(Fn,Pair.Key)->SetPropertyValue_InContainer(Args.GetStructMemory(),Pair.Value);
        B->ProcessEvent(Fn,Args.GetStructMemory());return FindFProperty<FBoolProperty>(Fn,TEXT("ReturnValue"))->GetPropertyValue_InContainer(Args.GetStructMemory());
    };
    auto Call=[&](UObject* B,const TCHAR* Name,const FString& Scope,int32 Epoch,int32 Ticket,const TCHAR* Kind=TEXT("read"),USaveGame* Record=nullptr,const TCHAR* Owner=TEXT("same-owner"),bool UseA=false) {
        auto* Fn=Class->FindFunctionByName(Name);check(Fn);FStructOnScope Args(Fn);
        auto SetStr=[&](const TCHAR* N,const FString& V) {if(auto* P=FindFProperty<FStrProperty>(Fn,N)) P->SetPropertyValue_InContainer(Args.GetStructMemory(),V);};
        SetStr(TEXT("Scope"),Scope);SetStr(TEXT("Owner"),Owner);SetStr(TEXT("Kind"),Kind);
        for(auto Pair:{TPair<const TCHAR*,int32>(TEXT("Epoch"),Epoch),{TEXT("Generation"),Ticket}})
            if(auto* P=FindFProperty<FIntProperty>(Fn,Pair.Key)) P->SetPropertyValue_InContainer(Args.GetStructMemory(),Pair.Value);
        if(auto* P=FindFProperty<FBoolProperty>(Fn,TEXT("UseA"))) P->SetPropertyValue_InContainer(Args.GetStructMemory(),UseA);
        if(auto* P=FindFProperty<FObjectPropertyBase>(Fn,TEXT("Record"))) P->SetObjectPropertyValue_InContainer(Args.GetStructMemory(),Record);
        B->ProcessEvent(Fn,Args.GetStructMemory());auto* Ret=FindFProperty<FBoolProperty>(Fn,TEXT("ReturnValue"));return !Ret || Ret->GetPropertyValue_InContainer(Args.GetStructMemory());
    };
    auto Wait=[&](UObject* B) {
        const double Start=FPlatformTime::Seconds();
        while(!Bool(B,TEXT("Done")) && FPlatformTime::Seconds()-Start<30)
        {FTSTicker::GetCoreTicker().Tick(0.001f);FTaskGraphInterface::Get().ProcessThreadUntilIdle(ENamedThreads::GameThread);FPlatformProcess::Sleep(0.001f);}
        return Bool(B,TEXT("Done")) && Bool(B,TEXT("Success")) && !Bool(B,TEXT("Busy"));
    };
    auto Exact=[&](UObject* B,const FString& Scope,int32 Gen) {
        auto* R=FindFProperty<FObjectPropertyBase>(Class,TEXT("LoadedSave"))->GetObjectPropertyValue_InContainer(B);
        return R && R->GetClass()==RecordClass && FindFProperty<FStrProperty>(RecordClass,TEXT("Payload"))->GetPropertyValue_InContainer(R)==TEXT("scope X ")+Scope
            && FindFProperty<FStrProperty>(RecordClass,TEXT("Session"))->GetPropertyValue_InContainer(R)==Scope
            && FindFProperty<FIntProperty>(RecordClass,TEXT("Generation"))->GetPropertyValue_InContainer(R)==Gen;
    };
    // Two worlds x two guilds x two streams, both slots, including canonical case.
    for(int32 W=1;W<=2;++W) for(int32 G=10;G<=11;++G) for(bool Limits:{false,true})
    {
        const FString World=FString::ChrN(32,TCHAR('0'+W)),Guild=FString::ChrN(32,TCHAR('a'+G-10)),Stream=Limits?TEXT("limits"):TEXT("priorities");
        const FString Key=TEXT("PWP-SCOPE-1:")+World+TEXT(":")+Guild+TEXT(":")+Stream;
        auto* B=NewObject<UObject>(GetTransientPackage(),Class,NAME_None,RF_Transient|RF_MarkAsRootSet);Bridges.Add(B);Keys.Add(Key);
        Good &= !Call(B,TEXT("BindOwner"),Key,1,0);
        for(const FString& Bad:{FString(),FString(TEXT("../world")),FString::ChrN(32,TEXT('0')),FString::ChrN(32,TEXT('z')),FString::ChrN(33,TEXT('1'))})
        {Good &= !Bind(B,Bad,Guild,Stream);Good &= !Bind(B,World,Bad,Stream);}
        Good &= !Bind(B,World,Guild,TEXT("../priorities")) && !Bool(B,TEXT("StorageBound"));
        Good &= Bind(B,World,Guild.ToUpper(),Stream) && Bind(B,World,Guild,Stream);
        Good &= !Bind(B,FString::ChrN(32,TEXT('3')),Guild,Stream) && !Bind(B,World,Guild,Limits?TEXT("priorities"):TEXT("limits"));
        Good &= Str(B,TEXT("BoundScope"))==Key;
        const FString Stem=TEXT("PWP_AsyncDev_v1_")+World+TEXT("_")+Guild+(Limits?TEXT("_l"):TEXT("_p"));
        for(const TCHAR* Suffix:{TEXT("A"),TEXT("B")})
        {
            FString Name=Str(B,*(FString(TEXT("BoundSlot"))+Suffix));
            Good &= Name==Stem+TEXT("_")+Suffix && !Names.Contains(Name);Names.Add(Name);
        }
        for(int32 Bad:{0,-1,MAX_int32}) Good &= !Call(B,TEXT("BindOwner"),Key,Bad,0);
        Good &= Call(B,TEXT("BindOwner"),Key,1,0) && Call(B,TEXT("BindOwner"),Key,1,0) && !Call(B,TEXT("BindOwner"),Key,2,0);
        if(!Good) break;
        if(!ReadOnly)
        {
            for(bool UseA:{true,false})
            {
                auto* Record=UGameplayStatics::CreateSaveGameObject(RecordClass);
                FindFProperty<FStrProperty>(RecordClass,TEXT("Payload"))->SetPropertyValue_InContainer(Record,TEXT("scope X ")+Key);
                FindFProperty<FStrProperty>(RecordClass,TEXT("Session"))->SetPropertyValue_InContainer(Record,Key);
                FindFProperty<FIntProperty>(RecordClass,TEXT("Generation"))->SetPropertyValue_InContainer(Record,UseA?41:42);
                Call(B,TEXT("SubmitScratch"),Key,1,UseA?1:2,TEXT("write"),Record,TEXT("same-owner"),UseA);
                Good &= Wait(B) && Exact(B,Key,UseA?41:42) && Call(B,TEXT("ConsumeResult"),Key,1,UseA?1:2,TEXT("write"),nullptr,TEXT("same-owner"),UseA);
            }
        }
    }
    Good &= Bridges.Num()==8 && Names.Num()==16;
    UE_LOG(LogTemp,Display,TEXT("PWP SCRATCH V6 canonical_scope_separation=%d slots=%d"),Good,Names.Num());
    // Read only after ALL writes, so accidental collisions cannot hide behind
    // immediate readback. This also runs in a genuinely fresh editor process.
    for(int32 Index=0;Index<Bridges.Num() && Good;++Index)
    {
        auto* B=Bridges[Index];const auto& Key=Keys[Index];
        for(bool UseA:{true,false})
        {
            Call(B,TEXT("LoadScratch"),Key,1,UseA?11:12,TEXT("read"),nullptr,TEXT("same-owner"),UseA);
            if(!UseA)
            {
                Good &= Bool(B,TEXT("Busy")) && Call(B,TEXT("RetireOwner"),Key,1,0) && Call(B,TEXT("RetireOwner"),Key,1,0);
                Good &= !Call(B,TEXT("BindOwner"),Key,2,0) && !Call(B,TEXT("BindOwner"),Key,1,0);
                Call(B,TEXT("LoadScratch"),Key,1,99);Good &= Int(B,TEXT("ActiveGeneration"))==12;
                CollectGarbage(RF_NoFlags);
            }
            const bool Waited=Wait(B),Matched=Exact(B,Key,UseA?41:42);Good &= Waited && Matched;
            if(!UseA) Good &= !Call(B,TEXT("BindOwner"),Key,2,0); // terminal mailbox must drain too
            Good &= !Call(B,TEXT("ConsumeResult"),Key,2,UseA?11:12,TEXT("read"),nullptr,TEXT("same-owner"),UseA);
            Good &= Call(B,TEXT("ConsumeResult"),Key,1,UseA?11:12,TEXT("read"),nullptr,TEXT("same-owner"),UseA);
        }
        Call(B,TEXT("LoadScratch"),Key,1,99);Good &= !Bool(B,TEXT("Busy")) && Int(B,TEXT("ActiveGeneration"))==12;
        Good &= Call(B,TEXT("BindOwner"),Key,2,0); // Same owner text, newer incarnation
        Good &= !Call(B,TEXT("RetireOwner"),Key,1,0) && !Call(B,TEXT("ConsumeResult"),Key,1,12);
        Call(B,TEXT("LoadScratch"),Key,1,99);Call(B,TEXT("LoadScratch"),Key,2,12);
        Good &= !Bool(B,TEXT("Busy")) && Int(B,TEXT("ActiveGeneration"))==12;
        Call(B,TEXT("LoadScratch"),Key,2,13);Good &= Wait(B) && Exact(B,Key,42) && Call(B,TEXT("ConsumeResult"),Key,2,13);
        Good &= Call(B,TEXT("RetireOwner"),Key,2,0) && !Call(B,TEXT("BindOwner"),Key,1,0)
            && Call(B,TEXT("BindOwner"),Key,3,0,TEXT("read"),nullptr,TEXT("new-owner"));
        Good &= !Call(B,TEXT("RetireOwner"),Key,3,0); // old name cannot act at the new epoch
    }
    if(!ReadOnly && Good)
    {
        const FString W=FString::ChrN(32,TEXT('4')),G=FString::ChrN(32,TEXT('d'));
        const FString Key=TEXT("PWP-SCOPE-1:")+W+TEXT(":")+G+TEXT(":limits");
        auto* B=NewObject<UObject>(GetTransientPackage(),Class,NAME_None,RF_Transient|RF_MarkAsRootSet);Bridges.Add(B);
        Good &= Bind(B,W,G,TEXT("limits")) && Call(B,TEXT("BindOwner"),Key,1,0);
        auto* R=UGameplayStatics::CreateSaveGameObject(RecordClass);
        FindFProperty<FStrProperty>(RecordClass,TEXT("Payload"))->SetPropertyValue_InContainer(R,TEXT("scope X ")+Key);
        FindFProperty<FStrProperty>(RecordClass,TEXT("Session"))->SetPropertyValue_InContainer(R,Key);
        FindFProperty<FIntProperty>(RecordClass,TEXT("Generation"))->SetPropertyValue_InContainer(R,44);
        Call(B,TEXT("SubmitScratch"),Key,1,21,TEXT("write"),R);
        Good &= Bool(B,TEXT("Busy")) && Call(B,TEXT("RetireOwner"),Key,1,0) && !Call(B,TEXT("BindOwner"),Key,2,0);
        CollectGarbage(RF_NoFlags);
        Good &= Wait(B) && Exact(B,Key,44) && !Call(B,TEXT("BindOwner"),Key,2,0)
            && Call(B,TEXT("ConsumeResult"),Key,1,21,TEXT("write")) && Call(B,TEXT("BindOwner"),Key,2,0);
        Call(B,TEXT("LoadScratch"),Key,1,99);Good &= !Bool(B,TEXT("Busy")) && Int(B,TEXT("ActiveGeneration"))==21;
        Call(B,TEXT("LoadScratch"),Key,2,22);Good &= Wait(B) && Exact(B,Key,44) && Call(B,TEXT("ConsumeResult"),Key,2,22);
        UE_LOG(LogTemp,Display,TEXT("PWP SCRATCH V6 retire_during_save_readback=%d"),Good);
    }
    for(auto* B:Bridges) if(!Bool(B,TEXT("Busy"))) B->RemoveFromRoot();
    UE_LOG(LogTemp,Display,TEXT("PWP SCRATCH V6 drained_handover_and_epoch_fence=%d fresh_process=%d"),Good,ReadOnly);
    return Good;
}

TStrongObjectPtr<USaveGame> ReadSlotAsync(const TCHAR* Slot)
{
    struct FRead { bool Done=false, GameThread=false; TStrongObjectPtr<USaveGame> Object; };
    auto Result=MakeShared<FRead>(); const double Start=FPlatformTime::Seconds();
    UGameplayStatics::AsyncLoadGameFromSlot(Slot,0,FAsyncLoadGameFromSlotDelegate::CreateLambda(
        [Result](const FString&,int32,USaveGame* Object) {
            Result->Object.Reset(Object); Result->GameThread=IsInGameThread(); Result->Done=true;
        }));
    const double Enqueued=FPlatformTime::Seconds();
    while(!Result->Done && FPlatformTime::Seconds()-Start<30)
    { FTSTicker::GetCoreTicker().Tick(0.001f); FTaskGraphInterface::Get().ProcessThreadUntilIdle(ENamedThreads::GameThread); FPlatformProcess::Sleep(0.001f); }
    UE_LOG(LogTemp,Display,TEXT("PWP SCRATCH async_read slot=%s enqueue_ms=%.3f completion_ms=%.3f done=%d game_thread=%d"),
        Slot,(Enqueued-Start)*1000,(FPlatformTime::Seconds()-Start)*1000,Result->Done,Result->GameThread);
    return Result->Done && Result->GameThread ? MoveTemp(Result->Object) : TStrongObjectPtr<USaveGame>();
}

bool NativeProbe(UClass* Class, bool ReadOnly)
{
    auto* Payload = FindFProperty<FStrProperty>(Class, TEXT("Payload"));
    auto* Gen = FindFProperty<FIntProperty>(Class, TEXT("Generation"));
    if (!Payload || !Gen) return false;
    const FString Expected = TEXT("PWP scratch only: 1|2|3|4|5|X\n");
    if (!ReadOnly)
    {
        auto* Record = UGameplayStatics::CreateSaveGameObject(Class);
        if (!Record) return false;
        Record->AddToRoot();
        Payload->SetPropertyValue_InContainer(Record, Expected); Gen->SetPropertyValue_InContainer(Record, 1);
        struct FCompletion { bool Done=false, Success=false, GameThread=false; };
        auto Completion = MakeShared<FCompletion>();
        const double Start = FPlatformTime::Seconds();
        UGameplayStatics::AsyncSaveGameToSlot(Record, SlotA, 0,
            FAsyncSaveGameToSlotDelegate::CreateLambda([Completion](const FString&, int32, bool Ok) {
                Completion->Success = Ok; Completion->GameThread = IsInGameThread(); Completion->Done = true;
            }));
        const double Enqueued = FPlatformTime::Seconds();
        while (!Completion->Done && FPlatformTime::Seconds() - Start < 30.0)
        { FTSTicker::GetCoreTicker().Tick(0.001f); FTaskGraphInterface::Get().ProcessThreadUntilIdle(ENamedThreads::GameThread); FPlatformProcess::Sleep(0.001f); }
        UE_LOG(LogTemp, Display, TEXT("PWP SCRATCH enqueue_ms=%.3f completion_ms=%.3f done=%d success=%d game_thread=%d"),
            (Enqueued-Start)*1000, (FPlatformTime::Seconds()-Start)*1000,
            Completion->Done, Completion->Success, Completion->GameThread);
        Record->RemoveFromRoot();
        if (!Completion->Done || !Completion->Success || !Completion->GameThread) return false;
    }
    auto ReadOwner = ReadSlotAsync(SlotA);
    auto* Read = ReadOwner.Get();
    bool Ok = Read && Read->GetClass() == Class && Payload->GetPropertyValue_InContainer(Read) == Expected
        && Gen->GetPropertyValue_InContainer(Read) == 1;
    if (ReadOnly)
    {
        auto ReadBOwner = ReadSlotAsync(SlotB);
        auto* ReadB = ReadBOwner.Get();
        const bool BGood = ReadB && ReadB->GetClass()==Class
            && Payload->GetPropertyValue_InContainer(ReadB)==TEXT("Blueprint scratch X")
            && Gen->GetPropertyValue_InContainer(ReadB)==2;
        Ok &= BGood;
        UE_LOG(LogTemp, Display, TEXT("PWP SCRATCH fresh_process_blueprint_slot=%d"), BGood);
    }
    UE_LOG(LogTemp, Display, TEXT("PWP SCRATCH readback=%d fresh_process=%d"), Ok, ReadOnly);
    return Ok;
}

bool BridgeProbe(UClass* RecordClass, bool V3, bool V4, UBuildSavePrototypeCommandlet* Observer, bool V5=false)
{
    FEditorScriptExecutionGuard AllowEditorFixtureScript;
    UClass* Class = LoadClass<UObject>(nullptr,
        V5 ? TEXT("/Game/Mods/PalWorkPrioritySaveScratch/BP_ScratchBridgeV5.BP_ScratchBridgeV5_C") :
        V4 ? TEXT("/Game/Mods/PalWorkPrioritySaveScratch/BP_ScratchBridgeV4.BP_ScratchBridgeV4_C") :
        V3 ? TEXT("/Game/Mods/PalWorkPrioritySaveScratch/BP_ScratchBridgeV3.BP_ScratchBridgeV3_C")
           : TEXT("/Game/Mods/PalWorkPrioritySaveScratch/BP_ScratchBridgeV2.BP_ScratchBridgeV2_C"));
    if (!Class) return false;
    UWorld::InitializationValues Init;
    Init.AllowAudioPlayback(false).CreatePhysicsScene(false).CreateNavigation(false)
        .CreateAISystem(false).ShouldSimulatePhysics(false);
    // CreateWorld already initializes its level. Initializing it twice collides
    // with PalWorldSettings in this kit and is a fixture bug, not a save failure.
    UWorld* World = UWorld::CreateWorld(EWorldType::Game, false, NAME_None, nullptr,
        true, ERHIFeatureLevel::Num, &Init);
    if (!World) return false;
    GEngine->CreateNewWorldContext(EWorldType::Game).SetCurrentWorld(World);
    World->SetGameInstance(NewObject<UGameInstance>(GEngine));
    UObject* Bridge = V4 ? NewObject<UObject>(GetTransientPackage(),Class,TEXT("PWP_LifetimeV4"),RF_Transient|RF_MarkAsRootSet)
        : static_cast<UObject*>(World->SpawnActor<AActor>(Class));
    bool WorldDestroyed=false;
    auto* Context=FindFProperty<FObjectPropertyBase>(Class,TEXT("WorldContext"));
    auto* PendingAction=FindFProperty<FObjectPropertyBase>(Class,TEXT("PendingAction"));
    if(V4 && (!Context || !PendingAction || !Bridge || !Bridge->IsRooted())) return false;
    if(V4) Context->SetObjectPropertyValue_InContainer(Bridge,World);
    UFunction* Submit = Class->FindFunctionByName(TEXT("SubmitScratch"));
    auto* Busy = FindFProperty<FBoolProperty>(Class, TEXT("Busy"));
    auto* Done = FindFProperty<FBoolProperty>(Class, TEXT("Done"));
    auto* Success = FindFProperty<FBoolProperty>(Class, TEXT("Success"));
    auto* Completed = FindFProperty<FIntProperty>(Class, TEXT("CompletedGeneration"));
    auto* Loaded = FindFProperty<FObjectPropertyBase>(Class, TEXT("LoadedSave"));
    auto* RecordArg = Submit ? FindFProperty<FObjectPropertyBase>(Submit, TEXT("Record")) : nullptr;
    auto* GenerationArg = Submit ? FindFProperty<FIntProperty>(Submit, TEXT("Generation")) : nullptr;
    auto* UseAArg = Submit ? FindFProperty<FBoolProperty>(Submit, TEXT("UseA")) : nullptr;
    auto* Payload = FindFProperty<FStrProperty>(RecordClass, TEXT("Payload"));
    auto* Gen = FindFProperty<FIntProperty>(RecordClass, TEXT("Generation"));
    bool Good = Bridge && Submit && Busy && Done && Success && Completed && Loaded && RecordArg && GenerationArg && UseAArg && Payload && Gen;
    auto* Serial=FindFProperty<FIntProperty>(Class,TEXT("CompletionSerial"));
    auto* Count=FindFProperty<FIntProperty>(Class,TEXT("CompletionCount"));
    auto* ObservedSerial=FindFProperty<FIntProperty>(Class,TEXT("CompletionObservedSerial"));
    auto* ObservedGeneration=FindFProperty<FIntProperty>(Class,TEXT("CompletionObservedGeneration"));
    auto* ObservedDone=FindFProperty<FBoolProperty>(Class,TEXT("CompletionObservedDone"));
    auto* ObservedBusy=FindFProperty<FBoolProperty>(Class,TEXT("CompletionObservedBusy"));
    auto* ObservedSuccess=FindFProperty<FBoolProperty>(Class,TEXT("CompletionObservedSuccess"));
    auto* ObservedSave=FindFProperty<FObjectPropertyBase>(Class,TEXT("CompletionObservedSave"));
    UFunction* Notify=Class->FindFunctionByName(TEXT("ScratchCompleted"));
    if(V3)
    {
        bool Callable=Notify && Notify->NumParms==0 && Notify->Script.Num()>1
            && Notify->HasAnyFunctionFlags(FUNC_BlueprintCallable)
            && !Notify->HasAnyFunctionFlags(FUNC_Native | FUNC_Event)
            && Notify->GetOuterUClass()==Class
            && !Notify->GetName().StartsWith(TEXT("ExecuteUbergraph"));
#if UE_BLUEPRINT_EVENTGRAPH_FASTCALLS
        Callable &= Notify && Notify->EventGraphFunction==nullptr;
#endif
        Good &= Callable && Serial && Count && ObservedSerial && ObservedGeneration
            && ObservedDone && ObservedBusy && ObservedSuccess && ObservedSave;
        UE_LOG(LogTemp,Display,TEXT("PWP SCRATCH V3 callable=%d path=%s parms=%d script_bytes=%d"),
            Callable,Notify ? *Notify->GetPathName() : TEXT("missing"),Notify ? Notify->NumParms : -1,Notify ? Notify->Script.Num() : 0);
    }
    auto Counts=[&](int32 Expected) {
        return !V3 || (Serial->GetPropertyValue_InContainer(Bridge)==Expected && Count->GetPropertyValue_InContainer(Bridge)==Expected);
    };
    auto Notification=[&](int32 Expected,int32 Generation,bool Succeeded) {
        if(!V3) return true;
        const bool Ok=Counts(Expected) && IsInGameThread()
            && ObservedSerial->GetPropertyValue_InContainer(Bridge)==Expected
            && ObservedGeneration->GetPropertyValue_InContainer(Bridge)==Generation
            && ObservedDone->GetPropertyValue_InContainer(Bridge) && !ObservedBusy->GetPropertyValue_InContainer(Bridge)
            && ObservedSuccess->GetPropertyValue_InContainer(Bridge)==Succeeded
            && ObservedSave->GetObjectPropertyValue_InContainer(Bridge)==Loaded->GetObjectPropertyValue_InContainer(Bridge)
            && (Succeeded || ObservedSave->GetObjectPropertyValue_InContainer(Bridge)==nullptr);
        UE_LOG(LogTemp,Display,TEXT("PWP SCRATCH V3 completion_order=%d serial=%d count=%d generation=%d success=%d"),
            Ok,Serial->GetPropertyValue_InContainer(Bridge),Count->GetPropertyValue_InContainer(Bridge),Generation,Succeeded);
        return Ok;
    };
    const FString Owner=TEXT("fixture-session-one"),Scope=TEXT("PWP-MAILBOX-DEV-1");
    auto SetStr=[](UFunction* Fn,void* Args,const TCHAR* Name,const FString& Value) {
        auto* P=FindFProperty<FStrProperty>(Fn,Name);check(P);P->SetPropertyValue_InContainer(Args,Value);
    };
    auto BindOwner=[&](const FString& Who,const FString& Where) {
        auto* Fn=Class->FindFunctionByName(TEXT("BindOwner"));check(Fn);FStructOnScope Args(Fn);
        SetStr(Fn,Args.GetStructMemory(),TEXT("Owner"),Who);SetStr(Fn,Args.GetStructMemory(),TEXT("Scope"),Where);
        Bridge->ProcessEvent(Fn,Args.GetStructMemory());const bool Accepted=FindFProperty<FBoolProperty>(Fn,TEXT("ReturnValue"))->GetPropertyValue_InContainer(Args.GetStructMemory());
        UE_LOG(LogTemp,Display,TEXT("PWP V5 bind ownerlen=%d scope=%s accepted=%d bound=%d owner=%s"),Who.Len(),*Where,Accepted,
            FindFProperty<FBoolProperty>(Class,TEXT("Bound"))->GetPropertyValue_InContainer(Bridge),*FindFProperty<FStrProperty>(Class,TEXT("BoundOwner"))->GetPropertyValue_InContainer(Bridge));return Accepted;
    };
    auto Consume=[&](int32 Ticket,const FString& Kind,bool UseA,const FString& Who,const FString& Where) {
        auto* Fn=Class->FindFunctionByName(TEXT("ConsumeResult"));check(Fn);FStructOnScope Args(Fn);
        SetStr(Fn,Args.GetStructMemory(),TEXT("Owner"),Who);SetStr(Fn,Args.GetStructMemory(),TEXT("Scope"),Where);SetStr(Fn,Args.GetStructMemory(),TEXT("Kind"),Kind);
        FindFProperty<FIntProperty>(Fn,TEXT("Generation"))->SetPropertyValue_InContainer(Args.GetStructMemory(),Ticket);
        FindFProperty<FBoolProperty>(Fn,TEXT("UseA"))->SetPropertyValue_InContainer(Args.GetStructMemory(),UseA);
        Bridge->ProcessEvent(Fn,Args.GetStructMemory());return FindFProperty<FBoolProperty>(Fn,TEXT("ReturnValue"))->GetPropertyValue_InContainer(Args.GetStructMemory());
    };
    auto Send = [&](USaveGame* Record, int32 Generation, bool UseA=false,const FString& Who=TEXT("fixture-session-one"),const FString& Where=TEXT("PWP-MAILBOX-DEV-1")) {
        FStructOnScope Args(Submit);
        RecordArg->SetObjectPropertyValue_InContainer(Args.GetStructMemory(), Record);
        GenerationArg->SetPropertyValue_InContainer(Args.GetStructMemory(), Generation);
        UseAArg->SetPropertyValue_InContainer(Args.GetStructMemory(), UseA);
        if(V5) { SetStr(Submit,Args.GetStructMemory(),TEXT("Owner"),Who);SetStr(Submit,Args.GetStructMemory(),TEXT("Scope"),Where); }
        Bridge->ProcessEvent(Submit, Args.GetStructMemory());
    };
    USaveGame* Record = Good ? UGameplayStatics::CreateSaveGameObject(RecordClass) : nullptr;
    Good &= Record != nullptr;
    if (Good)
    {
        if(V5)
        {
            Send(nullptr,1);Good &= Counts(0) && !Busy->GetPropertyValue_InContainer(Bridge) && !Done->GetPropertyValue_InContainer(Bridge);
            Good &= !BindOwner(TEXT(""),Scope) && !BindOwner(FString::ChrN(257,TEXT('a')),Scope) && !BindOwner(Owner,TEXT("foreign"));
            Good &= BindOwner(Owner,Scope) && BindOwner(Owner,Scope) && !BindOwner(TEXT("other"),Scope) && !BindOwner(Owner,TEXT("other"));
            for(int32 Bad:{-1,0,MAX_int32}) Send(nullptr,Bad);
            Send(nullptr,1,false,TEXT("other"));Send(nullptr,1,false,Owner,TEXT("foreign"));
            Good &= Counts(0) && !Busy->GetPropertyValue_InContainer(Bridge) && !Done->GetPropertyValue_InContainer(Bridge);
            Good &= !Consume(1,TEXT("write"),false,Owner,Scope);
            UE_LOG(LogTemp,Display,TEXT("PWP SCRATCH V5 bind_and_invalid_admission=%d"),Good);
        }
        Payload->SetPropertyValue_InContainer(Record, TEXT("Blueprint scratch X"));
        Gen->SetPropertyValue_InContainer(Record, 2);
        const double Start = FPlatformTime::Seconds(); Send(Record, 2);
        const double Enqueued = FPlatformTime::Seconds();
        Good &= Busy->GetPropertyValue_InContainer(Bridge);
        Good &= Counts(0);
        Send(nullptr, 999, true); // Must be rejected while busy; cannot replace the active generation.
        const bool BusyRejected=Counts(0) && Busy->GetPropertyValue_InContainer(Bridge);
        if(V5) Good &= !Consume(2,TEXT("write"),false,Owner,Scope) && !BindOwner(TEXT("other"),Scope);
        Good &= BusyRejected;
        if(V3) UE_LOG(LogTemp,Display,TEXT("PWP SCRATCH V3 busy_rejection_no_completion=%d"),BusyRejected);
        if(V4)
        {
            const bool Held=PendingAction->GetObjectPropertyValue_InContainer(Bridge)!=nullptr;
            auto* Executing=Cast<UAsyncActionHandleSaveGame>(PendingAction->GetObjectPropertyValue_InContainer(Bridge));
            if(!Executing) { UE_LOG(LogTemp,Error,TEXT("PWP fixture failed: expected pending save action")); return false; }
            Observer->WatchReadback(Executing,Bridge);
            TWeakObjectPtr<UWorld> OldWorld=World;
            TWeakObjectPtr<UGameInstance> OldInstance=World->GetGameInstance();
            Context->SetObjectPropertyValue_InContainer(Bridge,nullptr);
            World->DestroyWorld(false); GEngine->DestroyWorldContext(World); World->RemoveFromRoot();
            WorldDestroyed=true; World=nullptr;
            CollectGarbage(RF_NoFlags);
            const bool Survived=Held && Bridge->IsRooted() && Busy->GetPropertyValue_InContainer(Bridge)
                && StaticFindObject(Class,GetTransientPackage(),TEXT("PWP_LifetimeV4"))==Bridge;
            Good &= Survived;
            UE_LOG(LogTemp,Display,TEXT("PWP SCRATCH V4 rooted_teardown_pending=%d"),Survived);
            const bool Released=!OldWorld.IsValid() && !OldInstance.IsValid(); Good &= Released;
            UE_LOG(LogTemp,Display,TEXT("PWP SCRATCH V4 old_world_and_instance_released=%d"),Released);
        }
        CollectGarbage(RF_NoFlags); // GameInstance must own the pending async action.
        while (!Done->GetPropertyValue_InContainer(Bridge) && FPlatformTime::Seconds()-Start < 30)
        {
            FTSTicker::GetCoreTicker().Tick(0.001f); FTaskGraphInterface::Get().ProcessThreadUntilIdle(ENamedThreads::GameThread);
            FPlatformProcess::Sleep(0.001f);
        }
        const double CompletionTime = FPlatformTime::Seconds();
        Good &= Done->GetPropertyValue_InContainer(Bridge) && Success->GetPropertyValue_InContainer(Bridge)
            && !Busy->GetPropertyValue_InContainer(Bridge) && Completed->GetPropertyValue_InContainer(Bridge)==2;
        USaveGame* Read = Done->GetPropertyValue_InContainer(Bridge) ? Cast<USaveGame>(Loaded->GetObjectPropertyValue_InContainer(Bridge)) : nullptr;
        Good &= Read && Read->GetClass()==RecordClass
            && FindFProperty<FStrProperty>(RecordClass,TEXT("Payload"))->GetPropertyValue_InContainer(Read)==TEXT("Blueprint scratch X");
        Good &= Notification(1,2,true);
        if(V4) { Good &= Observer->ReadbackCollected; UE_LOG(LogTemp,Display,TEXT("PWP SCRATCH V4 readback_gc=%d"),Observer->ReadbackCollected); }
        UE_LOG(LogTemp, Display, TEXT("PWP SCRATCH blueprint_gc_busy_readback=%d enqueue_ms=%.3f completion_including_forced_gc_ms=%.3f"),
            Good, (Enqueued-Start)*1000, (CompletionTime-Start)*1000);
        if (Done->GetPropertyValue_InContainer(Bridge))
        {
            if(V5)
            {
                // Simulate a missed hook: no consumer ran; duplicate/reloaded
                // callers cannot replace the retained terminal record.
                Send(nullptr,999,true);Good &= Counts(1) && Completed->GetPropertyValue_InContainer(Bridge)==2;
                Good &= !Consume(2,TEXT("write"),false,TEXT("other"),Scope) && !Consume(2,TEXT("write"),false,Owner,TEXT("foreign"))
                    && !Consume(2,TEXT("read"),false,Owner,Scope) && !Consume(2,TEXT("write"),true,Owner,Scope) && !Consume(1,TEXT("write"),false,Owner,Scope);
                CollectGarbage(RF_NoFlags);
                Good &= Loaded->GetObjectPropertyValue_InContainer(Bridge)!=nullptr && Done->GetPropertyValue_InContainer(Bridge);
                Good &= Consume(2,TEXT("write"),false,Owner,Scope) && Consume(2,TEXT("write"),false,Owner,Scope);
                Good &= !Done->GetPropertyValue_InContainer(Bridge) && !Loaded->GetObjectPropertyValue_InContainer(Bridge);
                Good &= BindOwner(Owner,Scope);Send(nullptr,2);Send(nullptr,1);
                Good &= Counts(1) && !Done->GetPropertyValue_InContainer(Bridge);
                UE_LOG(LogTemp,Display,TEXT("PWP SCRATCH V5 retained_exact_idempotent_consume=%d"),Good);
            }
            Send(nullptr, 3); // Real engine failure path, not a fake filesystem success.
            const bool Failed = Done->GetPropertyValue_InContainer(Bridge) && !Success->GetPropertyValue_InContainer(Bridge)
                && !Busy->GetPropertyValue_InContainer(Bridge) && Completed->GetPropertyValue_InContainer(Bridge)==3;
            Good &= Failed;
            if(V4)
            {
                const bool Cleared=PendingAction->GetObjectPropertyValue_InContainer(Bridge)==nullptr;
                Good &= Cleared; UE_LOG(LogTemp,Display,TEXT("PWP SCRATCH V4 inline_failure_cleared_proxy=%d"),Cleared);
            }
            Good &= Notification(2,3,false);
            if(V5)
            {
                // A repeated previous acknowledgement must not clear this
                // newer synchronous failure result.
                Good &= Consume(2,TEXT("write"),false,Owner,Scope) && Done->GetPropertyValue_InContainer(Bridge)
                    && Completed->GetPropertyValue_InContainer(Bridge)==3 && Consume(3,TEXT("write"),false,Owner,Scope);
                UE_LOG(LogTemp,Display,TEXT("PWP SCRATCH V5 stale_ack_preserves_newer_result=%d"),Good);
            }
            UE_LOG(LogTemp, Display, TEXT("PWP SCRATCH blueprint_null_failure=%d"), Failed);
            UFunction* Load = Class->FindFunctionByName(TEXT("LoadScratch"));
            auto* LoadGen = Load ? FindFProperty<FIntProperty>(Load,TEXT("Generation")) : nullptr;
            auto* LoadA = Load ? FindFProperty<FBoolProperty>(Load,TEXT("UseA")) : nullptr;
            if (!Load || !LoadGen || !LoadA) Good=false;
            else
            {
                FStructOnScope Args(Load); LoadGen->SetPropertyValue_InContainer(Args.GetStructMemory(),4);
                LoadA->SetPropertyValue_InContainer(Args.GetStructMemory(),true);
                if(V5) { SetStr(Load,Args.GetStructMemory(),TEXT("Owner"),Owner);SetStr(Load,Args.GetStructMemory(),TEXT("Scope"),Scope); }
                const double LoadStart=FPlatformTime::Seconds(); Bridge->ProcessEvent(Load,Args.GetStructMemory());
                Good &= Busy->GetPropertyValue_InContainer(Bridge);
                if(V5) Good &= Consume(3,TEXT("write"),false,Owner,Scope) && Busy->GetPropertyValue_InContainer(Bridge)
                    && !Consume(4,TEXT("read"),true,Owner,Scope);
                while (!Done->GetPropertyValue_InContainer(Bridge) && FPlatformTime::Seconds()-LoadStart<30)
                { FTSTicker::GetCoreTicker().Tick(0.001f); FTaskGraphInterface::Get().ProcessThreadUntilIdle(ENamedThreads::GameThread); FPlatformProcess::Sleep(0.001f); }
                auto* Restored=Done->GetPropertyValue_InContainer(Bridge) ? Cast<USaveGame>(Loaded->GetObjectPropertyValue_InContainer(Bridge)) : nullptr;
                const bool LoadedA=Restored && Restored->GetClass()==RecordClass && Success->GetPropertyValue_InContainer(Bridge)
                    && Completed->GetPropertyValue_InContainer(Bridge)==4 && Gen->GetPropertyValue_InContainer(Restored)==1;
                Good &= LoadedA;
                Good &= Notification(3,4,true);
                UE_LOG(LogTemp,Display,TEXT("PWP SCRATCH blueprint_async_recovery=%d"),LoadedA);
                if(V3)
                {
                    // Drain callbacks after completion; no duplicate may arrive.
                    for(int32 I=0;I<100;++I)
                    { FTSTicker::GetCoreTicker().Tick(0.001f); FTaskGraphInterface::Get().ProcessThreadUntilIdle(ENamedThreads::GameThread); FPlatformProcess::Sleep(0.001f); }
                    const bool Once=Counts(3); Good &= Once;
                    UE_LOG(LogTemp,Display,TEXT("PWP SCRATCH V3 exactly_once_accepted=%d"),Once);
                }
                if(V5)
                {
                    Good &= !Consume(4,TEXT("write"),true,Owner,Scope) && !Consume(4,TEXT("read"),false,Owner,Scope);
                    Good &= Consume(4,TEXT("read"),true,Owner,Scope) && Consume(4,TEXT("read"),true,Owner,Scope);
                    Good &= !Consume(2,TEXT("write"),false,Owner,Scope); // bounded one-result tombstone
                    UE_LOG(LogTemp,Display,TEXT("PWP SCRATCH V5 read_consume_and_pending_ack=%d"),Good);
                }
            }

        }
        else Good = false;
    }
    if(!WorldDestroyed) { World->DestroyWorld(false); GEngine->DestroyWorldContext(World); World->RemoveFromRoot(); }
    if(V4)
    {
        const bool Drained=(V5 ? Counts(3) : Done->GetPropertyValue_InContainer(Bridge)) && !Busy->GetPropertyValue_InContainer(Bridge);
        UE_LOG(LogTemp,Display,TEXT("PWP SCRATCH V4 teardown_completion=%d"),Good && Drained);
        // Never unroot unresolved native IO. Process exit is the final boundary.
        if(Drained) Bridge->RemoveFromRoot();
    }
    return Good;
}
}

UBuildSavePrototypeCommandlet::UBuildSavePrototypeCommandlet()
{ IsClient = false; IsServer = false; IsEditor = true; LogToConsole = true; }

void UBuildSavePrototypeCommandlet::WatchReadback(UAsyncActionHandleSaveGame* Action,UObject* Bridge)
{
    WatchedBridge=Bridge; WatchedSave=Action; ReadbackCollected=false;
    Action->Completed.AddDynamic(this,&UBuildSavePrototypeCommandlet::ObserveSaveCompletion);
}
void UBuildSavePrototypeCommandlet::ObserveSaveCompletion(USaveGame*,bool Success)
{
    if(!Success || !WatchedBridge.IsValid()) return;
    UObject* Bridge=WatchedBridge.Get();
    auto* Pending=FindFProperty<FObjectPropertyBase>(Bridge->GetClass(),TEXT("PendingAction"));
    auto* Busy=FindFProperty<FBoolProperty>(Bridge->GetClass(),TEXT("Busy"));
    if(!Pending || !Busy || !Busy->GetPropertyValue_InContainer(Bridge)) return;
    TWeakObjectPtr<UObject> ReadAction=Pending->GetObjectPropertyValue_InContainer(Bridge);
    if(!ReadAction.IsValid() || ReadAction==WatchedSave) return;
    // Keep the executing save delegate safe, without holding the read action.
    TStrongObjectPtr<UObject> ExecutingSave(WatchedSave.Get());
    CollectGarbage(RF_NoFlags);
    ReadbackCollected=ReadAction.IsValid() && WatchedBridge.IsValid()
        && Pending->GetObjectPropertyValue_InContainer(WatchedBridge.Get())==ReadAction.Get();
}

int32 UBuildSavePrototypeCommandlet::Main(const FString& Params)
{
    using namespace PWPScratch;
    const bool V6=FParse::Param(*Params,TEXT("V6"));
    const bool V5=V6 || FParse::Param(*Params,TEXT("V5"));
    const bool V4=V5 || FParse::Param(*Params,TEXT("V4"));
    const bool V3=V4 || FParse::Param(*Params,TEXT("V3"));
    if(V4) { SlotA=TEXT("PWP_SaveLifetime_v4_A"); SlotB=TEXT("PWP_SaveLifetime_v4_B"); }
    if(V5) { SlotA=TEXT("PWP_SaveMailbox_v5_A"); SlotB=TEXT("PWP_SaveMailbox_v5_B"); }
    if (!FParse::Param(*Params, TEXT("Verify")) && !FParse::Param(*Params, TEXT("ReadOnly")))
    {
        auto* Existing = LoadObject<UBlueprint>(nullptr,
            TEXT("/Game/Mods/PalWorkPrioritySaveScratch/BP_ScratchRecord.BP_ScratchRecord"));
        if (!Existing)
        {
            auto* Record = Create(TEXT("BP_ScratchRecord"), USaveGame::StaticClass());
            if (!Record) return 1;
            for (const TCHAR* Name : {TEXT("Payload"), TEXT("Session"), TEXT("Checksum")})
                if (!Member(Record, Name, UEdGraphSchema_K2::PC_String)) return 2;
            if (!Member(Record, TEXT("Generation"), UEdGraphSchema_K2::PC_Int) || !Save(Record)) return 3;
        }
        auto* Controller = Create(V6 ? TEXT("BP_ScratchBridgeV6") : V5 ? TEXT("BP_ScratchBridgeV5") : V4 ? TEXT("BP_ScratchBridgeV4") : V3 ? TEXT("BP_ScratchBridgeV3") : TEXT("BP_ScratchBridgeV2"), V4 ? UObject::StaticClass() : AActor::StaticClass());
        if (!Controller || !Bridge(Controller,V3,V4,V5,V6)) return 4;
    }
    UClass* Class = LoadClass<USaveGame>(nullptr,
        TEXT("/Game/Mods/PalWorkPrioritySaveScratch/BP_ScratchRecord.BP_ScratchRecord_C"));
    const bool ReadOnly = FParse::Param(*Params, TEXT("ReadOnly"));
    if(V6) return Class && ScopedMailboxProbe(Class,ReadOnly) && (ReadOnly || MailboxReentryProbe(Class,true)) ? 0 : 5;
    return Class && NativeProbe(Class, ReadOnly) && (ReadOnly || (BridgeProbe(Class,V3,V4,this,V5)
        && (!V5 || MailboxReentryProbe(Class)))) ? 0 : 5;
}
