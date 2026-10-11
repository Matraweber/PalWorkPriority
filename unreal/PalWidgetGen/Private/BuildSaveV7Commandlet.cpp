#include "BuildSaveV7Commandlet.h"
#include "Engine/Blueprint.h"
#include "Engine/BlueprintGeneratedClass.h"
#include "Kismet/KismetMathLibrary.h"
#include "Kismet/KismetStringLibrary.h"
#include "Kismet/KismetSystemLibrary.h"
#include "Kismet/BlueprintMapLibrary.h"
#include "Kismet/GameplayStatics.h"
#include "Kismet2/BlueprintEditorUtils.h"
#include "Kismet2/KismetEditorUtilities.h"
#include "KismetCompiler.h"
#include "EdGraphSchema_K2.h"
#include "K2Node_CallFunction.h"
#include "K2Node_DynamicCast.h"
#include "K2Node_FunctionEntry.h"
#include "K2Node_FunctionResult.h"
#include "K2Node_IfThenElse.h"
#include "K2Node_Literal.h"
#include "K2Node_Self.h"
#include "K2Node_VariableGet.h"
#include "K2Node_VariableSet.h"
#include "Misc/PackageName.h"
#include "Misc/Parse.h"
#include "Misc/ScopeExit.h"
#include "UObject/SavePackage.h"
#include "UObject/StrongObjectPtr.h"
#include "UObject/StructOnScope.h"
#include "UObject/UnrealType.h"
#include "UObject/Stack.h"

namespace PWPV7
{
// Bounded map: 32 retained scope entries; no eviction, no save IO.
// Complete models an IO callback; it does not prove actual async save integration.
const TCHAR* Root=TEXT("/Game/Mods/PalWorkPrioritySaveV7/");
const TCHAR* RegistryName=TEXT("BP_SaveRegistryV7");
const TCHAR* Operations[]={TEXT("Claim"),TEXT("Reserve"),TEXT("Complete"),TEXT("Consume"),TEXT("Retire"),TEXT("Release")};

FString Path(const TCHAR* Name) { return FString(Root)+Name+TEXT(".")+Name; }
template<class T> T* Node(UEdGraph* G)
{ auto* N=NewObject<T>(G);G->AddNode(N);N->CreateNewGuid();return N; }
bool Compile(UBlueprint* BP)
{
    FCompilerResultsLog Log;
    FBlueprintEditorUtils::MarkBlueprintAsStructurallyModified(BP);
    FKismetEditorUtilities::CompileBlueprint(BP,EBlueprintCompileOptions::None,&Log);
    return Log.NumErrors==0 && BP->Status!=BS_Error;
}
UBlueprint* Create(const TCHAR* Name)
{
    if(LoadObject<UObject>(nullptr,*Path(Name))) return nullptr;
    return FKismetEditorUtilities::CreateBlueprint(UObject::StaticClass(),CreatePackage(*(FString(Root)+Name)),Name,
        BPTYPE_Normal,UBlueprint::StaticClass(),UBlueprintGeneratedClass::StaticClass());
}
bool Save(UBlueprint* BP)
{
    FSavePackageArgs Args;Args.TopLevelFlags=RF_Public|RF_Standalone;
    return UPackage::SavePackage(BP->GetOutermost(),BP,
        *FPackageName::LongPackageNameToFilename(BP->GetOutermost()->GetName(),TEXT(".uasset")),Args);
}

struct FGraph
{
    const UEdGraphSchema_K2* S=GetDefault<UEdGraphSchema_K2>();
    UEdGraph* G;UK2Node_FunctionEntry* Entry=nullptr;UEdGraphPin* Exec=nullptr;bool Good=true;
    bool Guarded=false,OwnsGate=false;
    FGraph(UBlueprint* BP,const TCHAR* Name)
    {
        G=FBlueprintEditorUtils::CreateNewGraph(BP,Name,UEdGraph::StaticClass(),UEdGraphSchema_K2::StaticClass());
        FBlueprintEditorUtils::AddFunctionGraph(BP,G,true,static_cast<UFunction*>(nullptr));
        for(UEdGraphNode* N:G->Nodes) if(auto* E=Cast<UK2Node_FunctionEntry>(N)) Entry=E;
        check(Entry);Entry->AddExtraFlags(FUNC_Public|FUNC_BlueprintCallable);
        Exec=Entry->FindPin(S->PN_Then);Exec->BreakAllPinLinks();
    }
    void Link(UEdGraphPin* A,UEdGraphPin* B)
    {
        const bool Ok=A && B && S->TryCreateConnection(A,B);Good &= Ok;
        if(!Ok) UE_LOG(LogTemp,Error,TEXT("V7 REGISTRY link failed %s -> %s"),A?*A->PinName.ToString():TEXT("null"),B?*B->PinName.ToString():TEXT("null"));
    }
    UEdGraphPin* Arg(const TCHAR* Name,FName Category,UClass* Class=nullptr)
    { FEdGraphPinType T;T.PinCategory=Category;T.PinSubCategoryObject=Class;return Entry->CreateUserDefinedPin(Name,T,EGPD_Output); }
    UEdGraphPin* Get(const FString& Name)
    { auto* N=Node<UK2Node_VariableGet>(G);N->VariableReference.SetSelfMember(*Name);N->AllocateDefaultPins();return N->GetValuePin(); }
    UK2Node_CallFunction* Call(UClass* Class,const TCHAR* Name)
    { auto* N=Node<UK2Node_CallFunction>(G);auto* Fn=Class->FindFunctionByName(Name);check(Fn);N->SetFromFunction(Fn);N->AllocateDefaultPins();return N; }
    UEdGraphPin* Binary(UClass* Class,const TCHAR* Name,UEdGraphPin* A,UEdGraphPin* B,const TCHAR* Default=nullptr)
    { auto* N=Call(Class,Name);Link(A,N->FindPin(TEXT("A")));if(B) Link(B,N->FindPin(TEXT("B")));else if(Default) S->TrySetDefaultValue(*N->FindPin(TEXT("B")),Default);return N->GetReturnValuePin(); }
    UEdGraphPin* Eq(UEdGraphPin* A,UEdGraphPin* B,const TCHAR* Default=nullptr)
    { return Binary(UKismetStringLibrary::StaticClass(),TEXT("EqualEqual_StrStr"),A,B,Default); }
    UEdGraphPin* Int(const TCHAR* Name,UEdGraphPin* A,UEdGraphPin* B=nullptr,const TCHAR* Default=nullptr)
    { return Binary(UKismetMathLibrary::StaticClass(),Name,A,B,Default); }
    UEdGraphPin* Not(UEdGraphPin* A)
    { auto* N=Call(UKismetMathLibrary::StaticClass(),TEXT("Not_PreBool"));Link(A,N->FindPin(TEXT("A")));return N->GetReturnValuePin(); }
    UK2Node_IfThenElse* Branch(UEdGraphPin* Condition)
    { auto* N=Node<UK2Node_IfThenElse>(G);N->AllocateDefaultPins();Link(Exec,N->GetExecPin());Link(Condition,N->GetConditionPin());return N; }
    void Return(UEdGraphPin* From,UEdGraphPin* Value)
    {
        // Evaluate every hookable result expression while still owning the gate.
        // After unlock only raw property reads and the VM return remain.
        if(OwnsGate)
        {
            auto* SavedExec=Exec;Exec=From;
            Store(TEXT("GateResult"),Value);Store(TEXT("GateHeld"),nullptr,TEXT("false"));
            From=Exec;Value=Get(TEXT("GateResult"));Exec=SavedExec;
        }
        auto* N=Node<UK2Node_FunctionResult>(G);N->FunctionReference=Entry->FunctionReference;N->AllocateDefaultPins();
        FEdGraphPinType T;T.PinCategory=S->PC_Boolean;
        Link(Value,N->CreateUserDefinedPin(TEXT("ReturnValue"),T,EGPD_Input));Link(From,N->FindPin(S->PN_Execute));
    }
    void Return(UEdGraphPin* From,bool Value)
    {
        if(Guarded) { Return(From,Get(Value?TEXT("GateTrue"):TEXT("GateFalse")));return; }
        auto* N=Call(UKismetSystemLibrary::StaticClass(),TEXT("MakeLiteralBool"));S->TrySetDefaultValue(*N->FindPin(TEXT("Value")),Value?TEXT("true"):TEXT("false"));Return(From,N->GetReturnValuePin());
    }
    void AcquireGate()
    {
        Guarded=true;
        // No UFunction call, including boolean helpers, may precede this store.
        auto* Held=Branch(Get(TEXT("GateHeld")));
        Return(Held->GetThenPin(),false); // Nested caller does not own/unlock it.
        Exec=Held->GetElsePin();Store(TEXT("GateHeld"),nullptr,TEXT("true"));OwnsGate=true;
    }
    void Require(UEdGraphPin* Condition)
    { auto* N=Branch(Condition);Return(N->GetElsePin(),false);Exec=N->GetThenPin(); }
    void Store(const FString& Name,UEdGraphPin* Value=nullptr,const TCHAR* Default=nullptr)
    {
        auto* N=Node<UK2Node_VariableSet>(G);N->VariableReference.SetSelfMember(*Name);N->AllocateDefaultPins();
        if(Value) Link(Value,N->FindPin(*Name));else if(Default) S->TrySetDefaultValue(*N->FindPin(*Name),Default);
        Link(Exec,N->FindPin(S->PN_Execute));Exec=N->FindPin(S->PN_Then);
    }
};

bool Add(UBlueprint* BP,const TCHAR* Name,FName Category,UClass* Class=nullptr)
{
    FEdGraphPinType T;T.PinCategory=Category;T.PinSubCategoryObject=Class;
    return FBlueprintEditorUtils::AddMemberVariable(BP,Name,T);
}

// Entry instances are reachable ONLY through the fixed CDO's map. Defaults stay
// pristine. Epoch and Ticket are high-water marks, never cleared by Release.
bool Entry(UBlueprint* BP)
{
    const auto* S=GetDefault<UEdGraphSchema_K2>();bool Good=Add(BP,TEXT("Holder"),S->PC_Object,UObject::StaticClass());
    for(const TCHAR* N:{TEXT("Epoch"),TEXT("Ticket")}) Good &= Add(BP,N,S->PC_Int);
    for(const TCHAR* N:{TEXT("Busy"),TEXT("Done"),TEXT("Retiring")}) Good &= Add(BP,N,S->PC_Boolean);
    if(!Good || !Compile(BP)) return false;
    for(const TCHAR* Op:Operations)
    {
        FGraph F(BP,Op);
        auto* Holder=F.Arg(TEXT("Holder"),S->PC_Object,UObject::StaticClass());
        auto* Epoch=F.Arg(TEXT("Epoch"),S->PC_Int);auto* Ticket=F.Arg(TEXT("Ticket"),S->PC_Int);
        auto* Valid=F.Call(UKismetSystemLibrary::StaticClass(),TEXT("IsValid"));F.Link(Holder,Valid->FindPin(TEXT("Object")));F.Require(Valid->GetReturnValuePin());
        F.Require(F.Int(TEXT("Greater_IntInt"),Epoch,nullptr,TEXT("0")));
        F.Require(F.Int(TEXT("Less_IntInt"),Epoch,nullptr,TEXT("2147483647")));
        auto Same=[&](){return F.Binary(UKismetMathLibrary::StaticClass(),TEXT("EqualEqual_ObjectObject"),Holder,F.Get(TEXT("Holder")));};
        if(FCString::Strcmp(Op,TEXT("Claim"))==0)
        {
            auto* Empty=F.Branch(F.Binary(UKismetMathLibrary::StaticClass(),TEXT("EqualEqual_ObjectObject"),F.Get(TEXT("Holder")),nullptr));
            F.Exec=Empty->GetElsePin();F.Require(Same());F.Require(F.Int(TEXT("EqualEqual_IntInt"),Epoch,F.Get(TEXT("Epoch"))));
            F.Require(F.Not(F.Get(TEXT("Retiring"))));F.Return(F.Exec,true);
            F.Exec=Empty->GetThenPin();F.Require(F.Int(TEXT("Greater_IntInt"),Epoch,F.Get(TEXT("Epoch"))));
            F.Store(TEXT("Holder"),Holder);F.Store(TEXT("Epoch"),Epoch);F.Store(TEXT("Retiring"),nullptr,TEXT("false"));
            F.Return(F.Exec,true);Good &= F.Good;continue;
        }
        F.Require(Same());F.Require(F.Int(TEXT("EqualEqual_IntInt"),Epoch,F.Get(TEXT("Epoch"))));
        if(FCString::Strcmp(Op,TEXT("Reserve"))==0)
        {
            F.Require(F.Not(F.Get(TEXT("Retiring"))));F.Require(F.Not(F.Get(TEXT("Busy"))));F.Require(F.Not(F.Get(TEXT("Done"))));
            F.Require(F.Int(TEXT("Greater_IntInt"),Ticket,F.Get(TEXT("Ticket"))));
            F.Require(F.Int(TEXT("Less_IntInt"),Ticket,nullptr,TEXT("2147483647")));
            F.Store(TEXT("Ticket"),Ticket);F.Store(TEXT("Busy"),nullptr,TEXT("true"));
        }
        else if(FCString::Strcmp(Op,TEXT("Complete"))==0)
        {
            F.Require(F.Get(TEXT("Busy")));F.Require(F.Int(TEXT("EqualEqual_IntInt"),Ticket,F.Get(TEXT("Ticket"))));
            F.Store(TEXT("Done"),nullptr,TEXT("true"));F.Store(TEXT("Busy"),nullptr,TEXT("false"));
        }
        else if(FCString::Strcmp(Op,TEXT("Consume"))==0)
        {
            F.Require(F.Not(F.Get(TEXT("Busy"))));F.Require(F.Get(TEXT("Done")));
            F.Require(F.Int(TEXT("EqualEqual_IntInt"),Ticket,F.Get(TEXT("Ticket"))));F.Store(TEXT("Done"),nullptr,TEXT("false"));
        }
        else if(FCString::Strcmp(Op,TEXT("Retire"))==0) F.Store(TEXT("Retiring"),nullptr,TEXT("true"));
        else
        {
            F.Require(F.Get(TEXT("Retiring")));F.Require(F.Not(F.Get(TEXT("Busy"))));F.Require(F.Not(F.Get(TEXT("Done"))));
            F.Store(TEXT("Holder"));
        }
        F.Return(F.Exec,true);Good &= F.Good;
    }
    return Good && Compile(BP);
}

bool Registry(UBlueprint* BP,UClass* EntryClass)
{
    const auto* S=GetDefault<UEdGraphSchema_K2>();
    FEdGraphPinType T;T.PinCategory=S->PC_String;T.ContainerType=EPinContainerType::Map;
    T.PinValueType.TerminalCategory=S->PC_Object;T.PinValueType.TerminalSubCategoryObject=EntryClass;
    if(!FBlueprintEditorUtils::AddMemberVariable(BP,TEXT("Entries"),T)) return false;
    for(const TCHAR* N:{TEXT("GateHeld"),TEXT("GateResult"),TEXT("GateFalse")})
        if(!Add(BP,N,S->PC_Boolean)) return false;
    FEdGraphPinType BoolType;BoolType.PinCategory=S->PC_Boolean;
    if(!FBlueprintEditorUtils::AddMemberVariable(BP,TEXT("GateTrue"),BoolType,TEXT("true")) || !Compile(BP)) return false;
    bool Good=true;
    for(const TCHAR* Op:Operations)
    {
        FGraph F(BP,Op);
        auto* Scope=F.Arg(TEXT("Scope"),S->PC_String);auto* Holder=F.Arg(TEXT("Holder"),S->PC_Object,UObject::StaticClass());
        auto* Epoch=F.Arg(TEXT("Epoch"),S->PC_Int);auto* Ticket=F.Arg(TEXT("Ticket"),S->PC_Int);
        F.AcquireGate();
        auto RequireValid=[&](UEdGraphPin* Value){auto* N=F.Call(UKismetSystemLibrary::StaticClass(),TEXT("IsValid"));F.Link(Value,N->FindPin(TEXT("Object")));F.Require(N->GetReturnValuePin());};
        RequireValid(Holder);
        auto* Len=F.Call(UKismetStringLibrary::StaticClass(),TEXT("Len"));F.Link(Scope,Len->FindPin(TEXT("S")));
        F.Require(F.Int(TEXT("Greater_IntInt"),Len->GetReturnValuePin(),nullptr,TEXT("0")));
        F.Require(F.Int(TEXT("LessEqual_IntInt"),Len->GetReturnValuePin(),nullptr,TEXT("256")));
        F.Require(F.Int(TEXT("Greater_IntInt"),Epoch,nullptr,TEXT("0")));
        F.Require(F.Int(TEXT("Less_IntInt"),Epoch,nullptr,TEXT("2147483647")));
        auto Map=[&](const TCHAR* Name){
            auto* N=F.Call(UBlueprintMapLibrary::StaticClass(),Name);
            F.Link(F.Get(TEXT("Entries")),N->FindPin(TEXT("TargetMap")));
            N->NotifyPinConnectionListChanged(N->FindPin(TEXT("TargetMap")));
            if(auto* Key=N->FindPin(TEXT("Key"))) F.Link(Scope,Key);
            return N;
        };
        auto Invoke=[&](UEdGraphPin* Value){
            RequireValid(Value);auto* N=F.Call(EntryClass,Op);F.Link(Value,N->FindPin(S->PN_Self));
            F.Link(Holder,N->FindPin(TEXT("Holder")));F.Link(Epoch,N->FindPin(TEXT("Epoch")));F.Link(Ticket,N->FindPin(TEXT("Ticket")));
            F.Link(F.Exec,N->FindPin(S->PN_Execute));F.Return(N->FindPin(S->PN_Then),N->GetReturnValuePin());
        };
        auto* Find=Map(TEXT("Map_Find"));auto* Found=F.Branch(Find->GetReturnValuePin());
        F.Exec=Found->GetThenPin();Invoke(Find->FindPin(TEXT("Value")));F.Exec=Found->GetElsePin();
        if(FCString::Strcmp(Op,TEXT("Claim"))==0)
        {
            auto Capacity=[&](){auto* N=Map(TEXT("Map_Length"));F.Require(F.Int(TEXT("Less_IntInt"),N->GetReturnValuePin(),nullptr,TEXT("32")));};
            Capacity();
            auto* Spawn=F.Call(UGameplayStatics::StaticClass(),TEXT("SpawnObject"));
            S->TrySetDefaultObject(*Spawn->FindPin(TEXT("ObjectClass")),EntryClass);
            auto* Self=Node<UK2Node_Self>(F.G);Self->AllocateDefaultPins();F.Link(Self->FindPin(S->PN_Self),Spawn->FindPin(TEXT("Outer")));
            F.Link(F.Exec,Spawn->FindPin(S->PN_Execute));F.Exec=Spawn->FindPin(S->PN_Then);RequireValid(Spawn->GetReturnValuePin());
            // SpawnObject returns UObject in UE5.1 (no DeterminesOutputType).
            // Use the supported runtime cast, not a forged typed return pin.
            auto* Cast=Node<UK2Node_DynamicCast>(F.G);Cast->TargetType=EntryClass;Cast->AllocateDefaultPins();
            F.Link(Spawn->GetReturnValuePin(),Cast->GetCastSourcePin());F.Link(F.Exec,Cast->FindPin(S->PN_Execute));
            F.Return(Cast->GetInvalidCastPin(),false);F.Exec=Cast->GetValidCastPin();
            // Defensive recheck; the registry gate also spans Map_Add and entry
            // helpers, whose pre-call hooks otherwise invalidate this recheck.
            auto* Again=Map(TEXT("Map_Find"));auto* Exists=F.Branch(Again->GetReturnValuePin());
            F.Exec=Exists->GetThenPin();Invoke(Again->FindPin(TEXT("Value")));F.Exec=Exists->GetElsePin();Capacity();
            auto* Insert=Map(TEXT("Map_Add"));F.Link(Cast->GetCastResultPin(),Insert->FindPin(TEXT("Value")));
            F.Link(F.Exec,Insert->FindPin(S->PN_Execute));F.Exec=Insert->FindPin(S->PN_Then);Invoke(Cast->GetCastResultPin());
        }
        else F.Return(F.Exec,false);
        Good &= F.Good;
    }
    return Good && Compile(BP);
}

bool Bridge(UBlueprint* BP,UObject* FixedCDO)
{
    bool Good=true;
    for(const TCHAR* Op:Operations)
    {
        FGraph F(BP,Op);
        auto* Scope=F.Arg(TEXT("Scope"),F.S->PC_String);auto* Epoch=F.Arg(TEXT("Epoch"),F.S->PC_Int);auto* Ticket=F.Arg(TEXT("Ticket"),F.S->PC_Int);
        auto* Literal=Node<UK2Node_Literal>(F.G);Literal->SetObjectRef(FixedCDO);Literal->AllocateDefaultPins();
        auto* Self=Node<UK2Node_Self>(F.G);Self->AllocateDefaultPins();auto* N=F.Call(FixedCDO->GetClass(),Op);
        F.Link(Literal->GetValuePin(),N->FindPin(F.S->PN_Self));F.Link(Self->FindPin(F.S->PN_Self),N->FindPin(TEXT("Holder")));
        F.Link(Scope,N->FindPin(TEXT("Scope")));F.Link(Epoch,N->FindPin(TEXT("Epoch")));F.Link(Ticket,N->FindPin(TEXT("Ticket")));
        F.Link(F.Exec,N->FindPin(F.S->PN_Execute));F.Return(N->FindPin(F.S->PN_Then),N->GetReturnValuePin());Good &= F.Good;
    }
    return Good && Compile(BP);
}

// Editor-only native pre-call injection: leave the VM stack untouched and call
// the real thunk after a genuinely nested Blueprint ProcessEvent has returned.
FNativeFuncPtr HookOriginal=nullptr;
TFunction<void()> HookAction;
bool HookArmed=false;
void PreCall(UObject* Context,FFrame& Stack,RESULT_DECL)
{
    if(HookArmed) { HookArmed=false;HookAction(); }
    HookOriginal(Context,Stack,RESULT_PARAM);
}
struct FPreCallScope
{
    UFunction* Function;
    FPreCallScope(UClass* Class,const TCHAR* Name,TFunction<void()> Action)
    {
        Function=Class->FindFunctionByName(Name);check(Function && Function->HasAnyFunctionFlags(FUNC_Native));
        check(!HookOriginal);HookOriginal=Function->GetNativeFunc();HookAction=MoveTemp(Action);HookArmed=true;
        Function->SetNativeFunc(&PreCall);
    }
    ~FPreCallScope() { Function->SetNativeFunc(HookOriginal);HookOriginal=nullptr;HookAction=nullptr;HookArmed=false; }
};


} // namespace PWPV7; isolated snapshot of guarded V2 generator

#include "GameFramework/SaveGame.h"
#include "GameFramework/AsyncActionHandleSaveGame.h"
#include "Engine/Engine.h"
#include "Engine/World.h"
#include "Engine/GameInstance.h"
#include "Async/TaskGraphInterfaces.h"
#include "Containers/Ticker.h"
#include "UObject/Script.h"
#include "Misc/Paths.h"

namespace PWPV7
{
int32 WriteDispatches=0,ReadDispatches=0;
bool Invoke(UObject* Registry,UObject* Holder,const TCHAR* Name,const FString& Scope,int32 Epoch,int32 Ticket)
{
    auto* Fn=Registry?Registry->FindFunction(FName(Name)):nullptr;if(!Fn) return false;
    FStructOnScope Args(Fn);
    FindFProperty<FObjectPropertyBase>(Fn,TEXT("Holder"))->SetObjectPropertyValue_InContainer(Args.GetStructMemory(),Holder);
    FindFProperty<FStrProperty>(Fn,TEXT("Scope"))->SetPropertyValue_InContainer(Args.GetStructMemory(),Scope);
    FindFProperty<FIntProperty>(Fn,TEXT("Epoch"))->SetPropertyValue_InContainer(Args.GetStructMemory(),Epoch);
    FindFProperty<FIntProperty>(Fn,TEXT("Ticket"))->SetPropertyValue_InContainer(Args.GetStructMemory(),Ticket);
    Registry->ProcessEvent(Fn,Args.GetStructMemory());
    return FindFProperty<FBoolProperty>(Fn,TEXT("ReturnValue"))->GetPropertyValue_InContainer(Args.GetStructMemory());
}
FString Str(UObject* O,const TCHAR* Name)
{ auto* P=O?FindFProperty<FStrProperty>(O->GetClass(),Name):nullptr;return P?P->GetPropertyValue_InContainer(O):FString(); }
bool DevSlot(const FString& Slot)
{
    const FString Prefix=TEXT("PWP_V7Dev_");
    if(!Slot.StartsWith(Prefix) || Slot.Len()!=Prefix.Len()+34 || !(Slot.EndsWith(TEXT("_A")) || Slot.EndsWith(TEXT("_B")))) return false;
    for(int32 I=Prefix.Len();I<Prefix.Len()+32;++I)
        if(!((Slot[I]>='0' && Slot[I]<='9') || (Slot[I]>='a' && Slot[I]<='f'))) return false;
    return true;
}
}

void UPWPV7Operation::Initialize(UPWPV7Coordinator* InOwner,const FPWPV7Identity& InId)
{ check(!Initialized);Owner=InOwner;Id=InId;Initialized=true; }
void UPWPV7Operation::Saved(USaveGame* Record,bool bSuccess)
{ if(Owner) Owner->OnSaved(this,Record,bSuccess); }
void UPWPV7Operation::Read(USaveGame* Record,bool bSuccess)
{ if(Owner) Owner->OnRead(this,Record,bSuccess); }

bool UPWPV7Coordinator::Enter()
{
    if(!IsInGameThread() || Gate) return false;
    Gate=true;return true;
}
bool UPWPV7Coordinator::RegistryCall(const TCHAR* Op,int32 Ticket)
{ return PWPV7::Invoke(Registry,this,Op,Scope,Epoch,Ticket); }
bool UPWPV7Coordinator::Bind(UObject* InRegistry,UObject* World,const FString& InScope,const FString& InSlot,int32 InEpoch)
{
    if(!Enter()) return false;ON_SCOPE_EXIT { Gate=false; };
    if(Bound || Active || !InRegistry || InRegistry!=InRegistry->GetClass()->GetDefaultObject()
        || InRegistry->GetClass()->GetPathName()!=PWPV7::Path(PWPV7::RegistryName)+TEXT("_C")
        || InScope!=InSlot || !PWPV7::DevSlot(InSlot) || InEpoch<=0 || InEpoch>=MAX_int32) return false;
    // Scope==physical slot is deliberately narrow: callers cannot alias one
    // fixture slot with two unrelated registry keys. Canonical V6 binding TBD.
    if(!PWPV7::Invoke(InRegistry,this,TEXT("Claim"),InScope,InEpoch,0)) return false;
    Registry=InRegistry;WorldContext=World;Scope=InScope;Slot=InSlot;Epoch=InEpoch;
    Bound=true;Retiring=false;HasConsumed=false;return true;
}
bool UPWPV7Coordinator::Submit(const FPWPV7Identity& Id,USaveGame* Record)
{
    UAsyncActionHandleSaveGame* Dispatch=nullptr;
    {
        if(!Enter()) return false;ON_SCOPE_EXIT { Gate=false; };
        if(!Bound || Retiring || Busy || Done || Active || Id.Scope!=Scope || Id.Slot!=Slot || Id.Epoch!=Epoch
            || Id.Ticket<=0 || Id.Ticket>=MAX_int32 || !(Id.Kind==TEXT("write") || Id.Kind==TEXT("read"))) return false;
        // Stage under the local guard before the hookable registry call. On
        // rejection no IO occurs; after acceptance no hook intervenes before
        // publishing local Busy. Registry Busy excludes independent holders.
        auto* Op=NewObject<UPWPV7Operation>(this);Op->Initialize(this,Id);Active=Op;
        if(Record)
        {
            Op->ExpectedClass=Record->GetClass();Op->ExpectedPayload=PWPV7::Str(Record,TEXT("Payload"));
            Op->ExpectedNonce=PWPV7::Str(Record,TEXT("Nonce"));
            auto* P=FindFProperty<FIntProperty>(Record->GetClass(),TEXT("Generation"));
            if(!P) { Active=nullptr;return false; }Op->ExpectedGeneration=P->GetPropertyValue_InContainer(Record);
        }
        if(!RegistryCall(TEXT("Reserve"),Id.Ticket)) { Active=nullptr;return false; }
        Busy=true;Done=false;
        Op->State=Id.Kind==TEXT("write")?UPWPV7Operation::EPhase::Saving:UPWPV7Operation::EPhase::Reading;
        Op->Action=Id.Kind==TEXT("write")?UAsyncActionHandleSaveGame::AsyncSaveGameToSlot(WorldContext,Record,Id.Slot,0)
            :UAsyncActionHandleSaveGame::AsyncLoadGameFromSlot(WorldContext,Id.Slot,0);
        if(!Op->Action) { Finish(Op,nullptr,false);return true; }
        if(Id.Kind==TEXT("write")) Op->Action->Completed.AddDynamic(Op,&UPWPV7Operation::Saved);
        else Op->Action->Completed.AddDynamic(Op,&UPWPV7Operation::Read);
        Dispatch=Op->Action;
    }
    // Activation may complete inline. Both reservations and retention are
    // already committed, and the local gate has been released before Activate.
    if(Id.Kind==TEXT("write")) ++PWPV7::WriteDispatches;else ++PWPV7::ReadDispatches;
    Dispatch->Activate();return true;
}
bool UPWPV7Coordinator::Matches(const UPWPV7Operation* Op,UPWPV7Operation::EPhase Phase) const
{
    return Bound && Busy && !Done && Active==Op && Op && Op->Owner==this && Op->Initialized
        && Op->State==Phase && Op->Id.Scope==Scope && Op->Id.Slot==Slot && Op->Id.Epoch==Epoch;
}
bool UPWPV7Coordinator::Finish(UPWPV7Operation* Op,USaveGame* Record,bool Success)
{
    check(Gate && Active==Op);
    if(!RegistryCall(TEXT("Complete"),Op->Id.Ticket)) return false; // stuck busy is fail-closed
    Op->Status=Success?UPWPV7Operation::EOutcome::Verified:
        Op->State==UPWPV7Operation::EPhase::Saving?UPWPV7Operation::EOutcome::WriteFailed:UPWPV7Operation::EOutcome::Unreadable;
    Op->Loaded=Record;Op->Success=Success;Op->State=UPWPV7Operation::EPhase::Terminal;Op->Action=nullptr;
    Done=true;Busy=false;++CompletionCount;return true;
}
void UPWPV7Coordinator::OnSaved(UPWPV7Operation* Op,USaveGame* Record,bool Success)
{
    UAsyncActionHandleSaveGame* Dispatch=nullptr;
    TStrongObjectPtr<UAsyncActionHandleSaveGame> Executing;
    {
        if(!Enter()) { ++Rejected;return; }ON_SCOPE_EXIT { Gate=false; };
        if(!Matches(Op,UPWPV7Operation::EPhase::Saving)) { ++Rejected;return; }
        Executing.Reset(Op->Action);
        if(!Success) { Finish(Op,nullptr,false);return; }
        Op->State=UPWPV7Operation::EPhase::Reading;
        // No registry Complete/Consume here: Busy and ownership span readback.
        Op->Action=UAsyncActionHandleSaveGame::AsyncLoadGameFromSlot(WorldContext,Op->Id.Slot,0);
        if(!Op->Action) { Finish(Op,nullptr,false);return; }
        Op->Action->Completed.AddDynamic(Op,&UPWPV7Operation::Read);Dispatch=Op->Action;
        if(ReadbackCheckpoint) ReadbackCheckpoint();
    }
    ++PWPV7::ReadDispatches;Dispatch->Activate();
}
void UPWPV7Coordinator::OnRead(UPWPV7Operation* Op,USaveGame* Record,bool Success)
{
    if(!Enter()) { ++Rejected;return; }ON_SCOPE_EXIT { Gate=false; };
    if(!Matches(Op,UPWPV7Operation::EPhase::Reading)) { ++Rejected;return; }
    TStrongObjectPtr<UAsyncActionHandleSaveGame> Executing(Op->Action);
    bool Exact=Success && Record && Record->GetClass()->GetPathName()==PWPV7::Path(TEXT("BP_SaveRecordV7"))+TEXT("_C")
        && PWPV7::Str(Record,TEXT("Payload")).Len()<=40000
        && PWPV7::Str(Record,TEXT("Nonce"))==Op->Id.Slot.Mid(10,32);
    if(Exact && Op->Id.Kind==TEXT("write"))
    {
        auto* P=FindFProperty<FIntProperty>(Record->GetClass(),TEXT("Generation"));
        Exact=Record->GetClass()==Op->ExpectedClass && P && P->GetPropertyValue_InContainer(Record)==Op->ExpectedGeneration
            && PWPV7::Str(Record,TEXT("Payload"))==Op->ExpectedPayload && PWPV7::Str(Record,TEXT("Nonce"))==Op->ExpectedNonce;
    }
    Finish(Op,Record,Exact);
}
bool UPWPV7Coordinator::Consume(const FPWPV7Identity& Id)
{
    if(!Enter()) return false;ON_SCOPE_EXIT { Gate=false; };
    if(!Bound || Id.Scope!=Scope || Id.Slot!=Slot || Id.Epoch!=Epoch) return false;
    // One exact tombstone survives newer pending IO; it never calls Consume on
    // the newer registry ticket. Different kind/slot/epoch/scope cannot ACK it.
    if(HasConsumed && Id==Consumed) return true;
    if(Busy || !Done || !Active || !(Id==Active->Id) || Active->State!=UPWPV7Operation::EPhase::Terminal) return false;
    if(!RegistryCall(TEXT("Consume"),Id.Ticket)) return false;
    Consumed=Id;HasConsumed=true;Active->State=UPWPV7Operation::EPhase::Consumed;
    Active=nullptr;Done=false;return true;
}
bool UPWPV7Coordinator::Retire()
{
    if(!Enter()) return false;ON_SCOPE_EXIT { Gate=false; };
    if(!Bound || !RegistryCall(TEXT("Retire"))) return false;Retiring=true;return true;
}
bool UPWPV7Coordinator::Release()
{
    if(!Enter()) return false;ON_SCOPE_EXIT { Gate=false; };
    if(!Bound || !Retiring || Busy || Done || Active || !RegistryCall(TEXT("Release"))) return false;
    Bound=false;WorldContext=nullptr;return true;
}

namespace PWPV7
{
UObject* EntryFor(UObject* CDO,const FString& Scope)
{
    auto* P=FindFProperty<FMapProperty>(CDO->GetClass(),TEXT("Entries"));
    FScriptMapHelper M(P,P->ContainerPtrToValuePtr<void>(CDO));
    for(int32 I=0;I<M.GetMaxIndex();++I) if(M.IsValidIndex(I)
        && CastFieldChecked<FStrProperty>(P->KeyProp)->GetPropertyValue(M.GetKeyPtr(I))==Scope)
        return CastFieldChecked<FObjectPropertyBase>(P->ValueProp)->GetObjectPropertyValue(M.GetValuePtr(I));
    return nullptr;
}
bool Flag(UObject* O,const TCHAR* Name)
{ auto* P=O?FindFProperty<FBoolProperty>(O->GetClass(),Name):nullptr;return P && P->GetPropertyValue_InContainer(O); }
int32 Number(UObject* O,const TCHAR* Name)
{ auto* P=O?FindFProperty<FIntProperty>(O->GetClass(),Name):nullptr;return P?P->GetPropertyValue_InContainer(O):-1; }
FString Payload(const FString& Nonce,int32 Generation,const TCHAR* Side)
{ return FString::Printf(TEXT("V7 nonce=%s generation=%d side=%s\n"),*Nonce,Generation,Side)+FString::ChrN(32768,TEXT('x')); }
bool Wait(UPWPV7Coordinator* C)
{
    const double Start=FPlatformTime::Seconds();
    while(!C->IsDone() && FPlatformTime::Seconds()-Start<20)
    { FTSTicker::GetCoreTicker().Tick(0.001f);FTaskGraphInterface::Get().ProcessThreadUntilIdle(ENamedThreads::GameThread);FPlatformProcess::Sleep(0.001f); }
    return C->IsDone();
}
bool Probe(const FString& Nonce,bool ReadOnly)
{
    FEditorScriptExecutionGuard Allow;
    auto Load=[](const TCHAR* N){return LoadClass<UObject>(nullptr,*(Path(N)+TEXT("_C")));};
    TStrongObjectPtr<UClass> R(Load(RegistryName)),RC(Load(TEXT("BP_SaveRecordV7")));
    if(!R || !RC) return false;
    UObject* CDO=R->GetDefaultObject();
    UObject* Anchor=NewObject<UObject>(GetTransientPackage(),R.Get(),TEXT("PWP_V7_RegistryAnchor"),RF_Transient|RF_MarkAsRootSet);
    // Deliberately keep the anchor rooted if a test times out with unresolved IO.
    UWorld::InitializationValues Init;
    Init.AllowAudioPlayback(false).CreatePhysicsScene(false).CreateNavigation(false).CreateAISystem(false).ShouldSimulatePhysics(false);
    UWorld* World=UWorld::CreateWorld(EWorldType::Game,false,NAME_None,nullptr,true,ERHIFeatureLevel::Num,&Init);
    if(!World) return false;
    GEngine->CreateNewWorldContext(EWorldType::Game).SetCurrentWorld(World);
    World->SetGameInstance(NewObject<UGameInstance>(GEngine));
    ON_SCOPE_EXIT { World->DestroyWorld(false);GEngine->DestroyWorldContext(World);World->RemoveFromRoot(); };
    const FString SlotA=TEXT("PWP_V7Dev_")+Nonce+TEXT("_A"),SlotB=TEXT("PWP_V7Dev_")+Nonce+TEXT("_B");
    if(!DevSlot(SlotA) || !DevSlot(SlotB)) return false;
    UE_LOG(LogTemp,Display,TEXT("PWP V7 slots=%s,%s project_saved=%s readonly=%d editor_native_receiver=1"),*SlotA,*SlotB,*FPaths::ConvertRelativePathToFull(FPaths::ProjectSavedDir()),ReadOnly);
    bool Good=true;int32 Checks=0;
    auto Check=[&](bool Value,const TCHAR* Name){++Checks;Good &= Value;UE_LOG(LogTemp,Display,TEXT("PWP V7 check=%s pass=%d"),Name,Value);};
    auto Make=[&](int32 Generation,const TCHAR* Side){
        auto* Record=UGameplayStatics::CreateSaveGameObject(RC.Get());
        FindFProperty<FStrProperty>(RC.Get(),TEXT("Payload"))->SetPropertyValue_InContainer(Record,Payload(Nonce,Generation,Side));
        FindFProperty<FStrProperty>(RC.Get(),TEXT("Nonce"))->SetPropertyValue_InContainer(Record,Nonce);
        FindFProperty<FIntProperty>(RC.Get(),TEXT("Generation"))->SetPropertyValue_InContainer(Record,Generation);
        return Record;
    };
    auto Exact=[&](UPWPV7Coordinator* C,int32 Generation,const TCHAR* Side){
        auto* Op=C->Current();auto* Loaded=Op?Op->Result():nullptr;
        return C->IsDone() && !C->IsBusy() && Op && Op->Succeeded() && Loaded && Loaded->GetClass()==RC.Get()
            && Str(Loaded,TEXT("Payload"))==Payload(Nonce,Generation,Side) && Str(Loaded,TEXT("Nonce"))==Nonce
            && Number(Loaded,TEXT("Generation"))==Generation;
    };
    TStrongObjectPtr<UPWPV7Coordinator> AOwner(NewObject<UPWPV7Coordinator>()),Duplicate(NewObject<UPWPV7Coordinator>()),Other(NewObject<UPWPV7Coordinator>());
    auto* A=AOwner.Get();auto* C=Duplicate.Get();
    TStrongObjectPtr<UObject> RegistryClone(NewObject<UObject>(GetTransientPackage(),R.Get()));
    Check(!C->Bind(RegistryClone.Get(),World,SlotA,SlotA,1)
        && !C->Bind(RC->GetDefaultObject(),World,SlotA,SlotA,1),TEXT("only_fixed_registry_cdo_accepted"));
    Check(A->Bind(CDO,World,SlotA,SlotA,1) && Other->Bind(CDO,World,SlotB,SlotB,1),TEXT("fixed_registry_distinct_slots_claimed"));
    Check(!C->Bind(CDO,World,SlotA,SlotA,1) && !C->Bind(CDO,World,SlotA,SlotA,2),TEXT("independent_same_class_duplicate_refused"));
    FPWPV7Identity Id1{SlotA,SlotA,TEXT("write"),1,1};
    FPWPV7Identity OtherId{SlotB,SlotB,TEXT("write"),1,1};
    if(ReadOnly)
    {
        Id1.Kind=OtherId.Kind=TEXT("read");
        Check(A->Submit(Id1,nullptr) && Wait(A) && Exact(A,2,TEXT("A")),TEXT("fresh_process_readonly_A"));
        Check(Other->Submit(OtherId,nullptr) && Wait(Other.Get()) && Exact(Other.Get(),2,TEXT("B")),TEXT("fresh_process_readonly_B"));
        Check(A->Consume(Id1) && A->Retire() && A->Release() && Other->Consume(OtherId) && Other->Retire() && Other->Release(),TEXT("readonly_drain"));
        if(!A->IsBusy() && !Other->IsBusy()) Anchor->RemoveFromRoot();
        Check(WriteDispatches==0 && ReadDispatches==2,TEXT("readonly_zero_write_dispatches"));
        UE_LOG(LogTemp,Display,TEXT("PWP V7 readonly_pass=%d checks=%d"),Good,Checks);return Good;
    }
    TStrongObjectPtr<USaveGame> Rec1(Make(1,TEXT("A"))),Rec2(Make(2,TEXT("A"))),RecB(Make(2,TEXT("B")));
    FPWPV7Identity UnreadableId=OtherId;UnreadableId.Kind=TEXT("read");
    Check(Other->Submit(UnreadableId,nullptr) && Wait(Other.Get()) && Other->Current()
        && Other->Current()->Outcome()==UPWPV7Operation::EOutcome::Unreadable && WriteDispatches==0
        && Other->Consume(UnreadableId),TEXT("null_load_unreadable_no_initialization"));
    OtherId.Ticket=2;
    FPWPV7Identity Next=Id1;Next.Ticket=2;
    Check(!C->Bind(CDO,World,SlotB,SlotA,1) && !C->Bind(CDO,World,TEXT("../bad"),TEXT("../bad"),1),TEXT("slot_alias_and_path_escape_refused"));
    bool Nested=false;
    {
        FPreCallScope Hook(UKismetSystemLibrary::StaticClass(),TEXT("IsValid"),[&](){
            Nested=!A->Submit(Next,Rec2.Get()) && !A->Consume(Id1) && !A->Retire() && !A->Release()
                && !C->Bind(CDO,World,SlotA,SlotA,2) && Flag(CDO,TEXT("GateHeld"));
        });
        Check(A->Submit(Id1,Rec1.Get()),TEXT("native_async_write_admitted"));
    }
    Check(Nested && A->IsBusy() && Number(EntryFor(CDO,SlotA),TEXT("Ticket"))==1,TEXT("reserve_local_registry_nested_atomicity"));
    if(!A->Current()) return false;
    TWeakObjectPtr<UPWPV7Operation> WeakFirst(A->Current());
    const FPWPV7Identity FirstIdentity=WeakFirst->Identity();
    WeakFirst->Read(Rec1.Get(),true);
    Check(A->IsBusy() && !A->IsDone() && A->Completions()==0 && A->RejectedCallbacks()==1,TEXT("read_callback_before_save_rejected"));
    Check(A->Retire() && !A->Release() && !A->Submit(Next,Rec2.Get()) && !C->Bind(CDO,World,SlotA,SlotA,2),TEXT("retire_pending_retains_registry"));
    bool ReadbackHeld=false,ReadbackGC=false,ReadbackNested=false;
    TWeakObjectPtr<UPWPV7Coordinator> WeakA(A);
    A->ReadbackCheckpoint=[&](){
        auto* Op=A->Current();auto* E=EntryFor(CDO,SlotA);
        ReadbackHeld=A->IsBusy() && !A->IsDone() && Flag(E,TEXT("Busy")) && !Flag(E,TEXT("Done")) && Number(E,TEXT("Ticket"))==1
            && Op && Op->Identity()==FirstIdentity && Op->Phase()==UPWPV7Operation::EPhase::Reading;
        TWeakObjectPtr<UAsyncActionHandleSaveGame> WeakProxy(Op?Op->Pending():nullptr);
        ReadbackNested=!C->Bind(CDO,World,SlotA,SlotA,2) && !A->Release() && !A->Consume(Id1);
        Op->Saved(Rec1.Get(),true); // duplicate save delivery cannot start another readback
        CollectGarbage(RF_NoFlags);
        ReadbackGC=WeakA.IsValid() && WeakFirst.IsValid() && WeakProxy.IsValid() && A->Current()==WeakFirst.Get() && Op->Pending()==WeakProxy.Get();
    };
    AOwner.Reset(); // CDO -> entry -> holder -> receiver -> proxy is now necessary.
    Check(Wait(A) && Exact(A,1,TEXT("A")),TEXT("actual_write_exact_readback"));
    A->ReadbackCheckpoint=nullptr;
    Check(ReadbackHeld && ReadbackNested,TEXT("registry_busy_through_readback"));
    Check(ReadbackGC,TEXT("registry_receiver_proxy_retained_gc"));
    TStrongObjectPtr<UPWPV7Operation> Old1(WeakFirst.Get());if(!Old1) return false;
    auto Wrong=Id1;Wrong.Kind=TEXT("read");bool WrongACK=!A->Consume(Wrong);Wrong=Id1;Wrong.Slot=SlotB;WrongACK &= !A->Consume(Wrong);
    Wrong=Id1;Wrong.Scope=SlotB;WrongACK &= !A->Consume(Wrong);Wrong=Id1;Wrong.Epoch=2;WrongACK &= !A->Consume(Wrong);
    Wrong=Id1;Wrong.Ticket=2;WrongACK &= !A->Consume(Wrong);
    Check(WrongACK && A->IsDone() && Flag(EntryFor(CDO,SlotA),TEXT("Done")) && !A->Release(),TEXT("terminal_retained_wrong_ack_refused"));
    Check(A->Consume(Id1) && A->Consume(Id1) && A->Release() && !C->Bind(CDO,World,SlotA,SlotA,1)
        && C->Bind(CDO,World,SlotA,SlotA,2),TEXT("exact_ack_retry_release_reclaim_epoch"));
    FPWPV7Identity Id2{SlotA,SlotA,TEXT("write"),2,2};
    auto Reused=Id2;Reused.Ticket=1;
    Check(!C->Submit(Reused,Rec2.Get()) && !C->Current() && !C->IsBusy() && Number(EntryFor(CDO,SlotA),TEXT("Ticket"))==1,TEXT("reserve_rejection_rolls_back_local_only"));
    bool CompletionNested=false;
    TUniquePtr<FPreCallScope> CompletionHook;
    C->ReadbackCheckpoint=[&](){
        CompletionHook=MakeUnique<FPreCallScope>(UKismetSystemLibrary::StaticClass(),TEXT("IsValid"),[&](){
            CompletionNested=!C->Submit(Id2,Rec2.Get()) && !C->Consume(Id2) && !C->Retire() && !C->Release()
                && !Invoke(CDO,A,TEXT("Claim"),SlotA,3,0) && Flag(CDO,TEXT("GateHeld"));
        });
    };
    Check(C->Submit(Id2,Rec2.Get()),TEXT("successor_write_admitted"));
    auto* Second=C->Current();
    for(int I=0;I<3;++I) { Old1->Saved(Rec1.Get(),I%2==0);Old1->Read(Rec1.Get(),I%2==0); }
    Check(C->Current()==Second && C->IsBusy() && !C->IsDone() && C->Completions()==0 && Old1->Identity()==FirstIdentity
        && Flag(EntryFor(CDO,SlotA),TEXT("Busy")) && Number(EntryFor(CDO,SlotA),TEXT("Ticket"))==2,TEXT("stale_previous_holder_callbacks_preserve_successor"));
    Check(Wait(C) && Exact(C,2,TEXT("A")) && C->Completions()==1,TEXT("successor_write_exact_readback"));
    CompletionHook.Reset();C->ReadbackCheckpoint=nullptr;
    Check(CompletionNested,TEXT("completion_local_registry_nested_atomicity"));
    TStrongObjectPtr<UPWPV7Operation> Old2(C->Current());
    bool ConsumeNested=false;
    {
        FPreCallScope Hook(UKismetSystemLibrary::StaticClass(),TEXT("IsValid"),[&](){
            ConsumeNested=!C->Submit(Id2,Rec2.Get()) && !C->Consume(Id2) && !C->Retire() && !C->Release()
                && !Invoke(CDO,A,TEXT("Claim"),SlotA,3,0) && Flag(CDO,TEXT("GateHeld"));
        });
        Check(C->Consume(Id2) && C->Consume(Id2),TEXT("second_exact_ack_retry"));
    }
    Check(ConsumeNested,TEXT("consume_local_registry_nested_atomicity"));
    FPWPV7Identity Id3{SlotA,SlotA,TEXT("read"),2,3};
    Check(C->Submit(Id3,nullptr),TEXT("same_holder_successor_read_admitted"));
    auto* Third=C->Current();
    Old2->Saved(Rec2.Get(),true);Old2->Read(Rec2.Get(),true);Old2->Read(nullptr,false);
    auto WrongRetry=Id2;WrongRetry.Kind=TEXT("read");
    Check(C->Current()==Third && C->IsBusy() && !C->IsDone() && C->Completions()==1 && C->Consume(Id2) && !C->Consume(WrongRetry)
        && Flag(EntryFor(CDO,SlotA),TEXT("Busy")) && Number(EntryFor(CDO,SlotA),TEXT("Ticket"))==3,TEXT("same_holder_stale_callbacks_and_ack_preserve_pending"));
    Check(Wait(C) && Exact(C,2,TEXT("A")) && C->Completions()==2,TEXT("actual_independent_read"));
    Check(C->Consume(Id2) && C->IsDone() && C->Current()==Third && C->Consume(Id3) && C->Consume(Id3) && !C->Consume(Id2),TEXT("ack_retry_preserves_new_terminal_bounded_tombstone"));
    FPWPV7Identity Id4{SlotA,SlotA,TEXT("write"),2,4};
    Check(C->Submit(Id4,nullptr) && C->IsDone() && !C->IsBusy() && C->Current() && !C->Current()->Succeeded()
        && C->Completions()==3 && Flag(EntryFor(CDO,SlotA),TEXT("Done")),TEXT("actual_null_save_inline_failure_retained"));
    Check(C->Consume(Id4) && C->Retire() && C->Release() && Number(EntryFor(CDO,SlotA),TEXT("Ticket"))==4,TEXT("failure_drain_preserves_highwater"));
    Check(Other->Submit(OtherId,RecB.Get()) && Wait(Other.Get()) && Exact(Other.Get(),2,TEXT("B")) && Other->Consume(OtherId),TEXT("independent_slot_real_write_readback"));
    bool DrainNested=true;
    for(bool Releasing:{false,true})
    {
        bool Fired=false,NestedGood=false;
        {
            FPreCallScope Hook(UKismetSystemLibrary::StaticClass(),TEXT("IsValid"),[&](){
                Fired=true;NestedGood=!Other->Submit(OtherId,RecB.Get()) && !Other->Consume(OtherId) && !Other->Retire()
                    && !Other->Release() && !C->Bind(CDO,World,SlotB,SlotB,2) && Flag(CDO,TEXT("GateHeld"));
            });
            DrainNested &= Releasing?Other->Release():Other->Retire();
        }
        DrainNested &= Fired && NestedGood && !Flag(CDO,TEXT("GateHeld"));
    }
    Check(DrainNested,TEXT("retire_release_local_registry_nested_atomicity"));
    // Fill remaining retained entries without IO; release never evicts keys.
    bool Capacity=true;
    for(int32 I=0;I<30;++I)
    {
        const FString K=FString::Printf(TEXT("V7-CAPACITY-%d"),I);
        Capacity &= Invoke(CDO,Other.Get(),TEXT("Claim"),K,1,0) && Invoke(CDO,Other.Get(),TEXT("Retire"),K,1,0)
            && Invoke(CDO,Other.Get(),TEXT("Release"),K,1,0);
    }
    auto* MP=FindFProperty<FMapProperty>(CDO->GetClass(),TEXT("Entries"));FScriptMapHelper M(MP,MP->ContainerPtrToValuePtr<void>(CDO));
    Check(Capacity && M.Num()==32 && !Invoke(CDO,Other.Get(),TEXT("Claim"),TEXT("V7-CAPACITY-33"),1,0),TEXT("integrated_registry_32_retained_33_refused"));
    Check(WriteDispatches==4 && ReadDispatches==5,TEXT("exact_native_dispatch_counts_no_rejected_io"));
    Check(!Flag(CDO,TEXT("GateHeld")) && !C->IsBusy() && !Other->IsBusy() && !A->IsBusy(),TEXT("all_native_operations_drained"));
    if(!C->IsBusy() && !Other->IsBusy() && !A->IsBusy()) Anchor->RemoveFromRoot();
    UE_LOG(LogTemp,Display,TEXT("PWP V7 fixture_pass=%d checks=%d editor_native_receiver=1 shipping_ready=0"),Good,Checks);
    return Good;
}
bool Generate()
{
    const auto* S=GetDefault<UEdGraphSchema_K2>();
    auto* E=Create(TEXT("BP_RegistryEntryV7"));if(!E || !Entry(E)) return false;
    auto* R=Create(RegistryName);if(!R || !Registry(R,E->GeneratedClass)) return false;
    const TCHAR* Name=TEXT("BP_SaveRecordV7");
    if(LoadObject<UObject>(nullptr,*Path(Name))) return false;
    auto* Record=FKismetEditorUtilities::CreateBlueprint(USaveGame::StaticClass(),CreatePackage(*(FString(Root)+Name)),Name,
        BPTYPE_Normal,UBlueprint::StaticClass(),UBlueprintGeneratedClass::StaticClass());
    return Record && Add(Record,TEXT("Payload"),S->PC_String) && Add(Record,TEXT("Nonce"),S->PC_String)
        && Add(Record,TEXT("Generation"),S->PC_Int) && Compile(Record) && Save(E) && Save(R) && Save(Record);
}
}
UBuildSaveV7Commandlet::UBuildSaveV7Commandlet()
{ IsClient=false;IsServer=false;IsEditor=true;LogToConsole=true; }
int32 UBuildSaveV7Commandlet::Main(const FString& Params)
{
    FString Nonce;if(!FParse::Value(*Params,TEXT("Nonce="),Nonce) || !PWPV7::DevSlot(TEXT("PWP_V7Dev_")+Nonce+TEXT("_A"))) return 2;
    if(FParse::Param(*Params,TEXT("Generate")) && !PWPV7::Generate()) return 3;
    return PWPV7::Probe(Nonce,FParse::Param(*Params,TEXT("ReadOnly")))?0:4;
}
