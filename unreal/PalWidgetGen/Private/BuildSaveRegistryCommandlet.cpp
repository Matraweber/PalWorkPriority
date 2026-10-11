#include "BuildSaveRegistryCommandlet.h"
#include "Engine/Blueprint.h"
#include "Engine/BlueprintGeneratedClass.h"
#include "Kismet/KismetMathLibrary.h"
#include "Kismet/KismetStringLibrary.h"
#include "Kismet/KismetSystemLibrary.h"
#include "Kismet2/BlueprintEditorUtils.h"
#include "Kismet2/KismetEditorUtilities.h"
#include "KismetCompiler.h"
#include "EdGraphSchema_K2.h"
#include "K2Node_CallFunction.h"
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

namespace PWPRegistry
{
// Deliberately bounded: two immutable scope entries, no eviction, no disk IO.
// Complete models an IO callback; it does not prove actual async save integration.
const TCHAR* Root=TEXT("/Game/Mods/PalWorkPrioritySaveRegistry/");
const TCHAR* RegistryName=TEXT("BP_SaveRegistryV1");
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
        if(!Ok) UE_LOG(LogTemp,Error,TEXT("REGISTRY link failed %s -> %s"),A?*A->PinName.ToString():TEXT("null"),B?*B->PinName.ToString():TEXT("null"));
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
        auto* N=Node<UK2Node_FunctionResult>(G);N->FunctionReference=Entry->FunctionReference;N->AllocateDefaultPins();
        FEdGraphPinType T;T.PinCategory=S->PC_Boolean;
        Link(Value,N->CreateUserDefinedPin(TEXT("ReturnValue"),T,EGPD_Input));Link(From,N->FindPin(S->PN_Execute));
    }
    void Return(UEdGraphPin* From,bool Value)
    { auto* N=Call(UKismetSystemLibrary::StaticClass(),TEXT("MakeLiteralBool"));S->TrySetDefaultValue(*N->FindPin(TEXT("Value")),Value?TEXT("true"):TEXT("false"));Return(From,N->GetReturnValuePin()); }
    void Require(UEdGraphPin* Condition)
    { auto* N=Branch(Condition);Return(N->GetElsePin(),false);Exec=N->GetThenPin(); }
    void Store(const FString& Name,UEdGraphPin* Value=nullptr,const TCHAR* Default=nullptr)
    {
        auto* N=Node<UK2Node_VariableSet>(G);N->VariableReference.SetSelfMember(*Name);N->AllocateDefaultPins();
        if(Value) Link(Value,N->FindPin(*Name));else if(Default) S->TrySetDefaultValue(*N->FindPin(*Name),Default);
        Link(Exec,N->FindPin(S->PN_Execute));Exec=N->FindPin(S->PN_Then);
    }
};

bool Registry(UBlueprint* BP)
{
    const auto* S=GetDefault<UEdGraphSchema_K2>();bool Good=true;
    for(int32 I=0;I<2;++I)
    {
        auto Add=[&](const TCHAR* Name,FName Category,UClass* Class=nullptr) {
            FEdGraphPinType T;T.PinCategory=Category;T.PinSubCategoryObject=Class;
            Good &= FBlueprintEditorUtils::AddMemberVariable(BP,*(FString(Name)+FString::FromInt(I)),T);
        };
        Add(TEXT("Scope"),S->PC_String);Add(TEXT("Holder"),S->PC_Object,UObject::StaticClass());
        Add(TEXT("Ticket"),S->PC_Int);
        for(const TCHAR* N:{TEXT("Busy"),TEXT("Done"),TEXT("Retiring")}) Add(N,S->PC_Boolean);
    }
    if(!Good || !Compile(BP)) return false;
    for(const TCHAR* Operation:Operations)
    {
        const bool Claim=FCString::Strcmp(Operation,TEXT("Claim"))==0;
        FGraph F(BP,Operation);
        auto* Scope=F.Arg(TEXT("Scope"),S->PC_String);
        auto* Holder=F.Arg(TEXT("Holder"),S->PC_Object,UObject::StaticClass());
        auto* Ticket=F.Arg(TEXT("Ticket"),S->PC_Int);
        auto* Valid=F.Call(UKismetSystemLibrary::StaticClass(),TEXT("IsValid"));F.Link(Holder,Valid->FindPin(TEXT("Object")));F.Require(Valid->GetReturnValuePin());
        auto* Len=F.Call(UKismetStringLibrary::StaticClass(),TEXT("Len"));F.Link(Scope,Len->FindPin(TEXT("S")));
        F.Require(F.Int(TEXT("Greater_IntInt"),Len->GetReturnValuePin(),nullptr,TEXT("0")));
        F.Require(F.Int(TEXT("LessEqual_IntInt"),Len->GetReturnValuePin(),nullptr,TEXT("256")));
        // First visit existing keys; only then allocate an empty entry. A released
        // entry keeps its key/ticket so stale callbacks cannot reset the fence.
        auto Handle=[&](int32 I) {
            const FString Suffix=FString::FromInt(I);
            auto Name=[&](const TCHAR* N){return FString(N)+Suffix;};
            auto Read=[&](const TCHAR* N){return F.Get(Name(N));};
            auto Same=[&](){return F.Binary(UKismetMathLibrary::StaticClass(),TEXT("EqualEqual_ObjectObject"),Holder,Read(TEXT("Holder")));};
            if(Claim)
            {
                auto* Empty=F.Branch(F.Binary(UKismetMathLibrary::StaticClass(),TEXT("EqualEqual_ObjectObject"),Read(TEXT("Holder")),nullptr));
                F.Exec=Empty->GetElsePin();F.Require(Same());F.Require(F.Not(Read(TEXT("Retiring"))));F.Return(F.Exec,true);
                F.Exec=Empty->GetThenPin();F.Store(Name(TEXT("Holder")),Holder);F.Store(Name(TEXT("Retiring")),nullptr,TEXT("false"));F.Return(F.Exec,true);
                return;
            }
            F.Require(Same());
            if(FCString::Strcmp(Operation,TEXT("Reserve"))==0)
            {
                F.Require(F.Not(Read(TEXT("Retiring"))));F.Require(F.Not(Read(TEXT("Busy"))));F.Require(F.Not(Read(TEXT("Done"))));
                F.Require(F.Int(TEXT("Greater_IntInt"),Ticket,Read(TEXT("Ticket"))));
                F.Require(F.Int(TEXT("Less_IntInt"),Ticket,nullptr,TEXT("2147483647")));
                F.Store(Name(TEXT("Ticket")),Ticket);F.Store(Name(TEXT("Busy")),nullptr,TEXT("true"));
            }
            else if(FCString::Strcmp(Operation,TEXT("Complete"))==0)
            {
                F.Require(Read(TEXT("Busy")));F.Require(F.Int(TEXT("EqualEqual_IntInt"),Ticket,Read(TEXT("Ticket"))));
                F.Store(Name(TEXT("Done")),nullptr,TEXT("true"));F.Store(Name(TEXT("Busy")),nullptr,TEXT("false"));
            }
            else if(FCString::Strcmp(Operation,TEXT("Consume"))==0)
            {
                F.Require(F.Not(Read(TEXT("Busy"))));F.Require(Read(TEXT("Done")));
                F.Require(F.Int(TEXT("EqualEqual_IntInt"),Ticket,Read(TEXT("Ticket"))));F.Store(Name(TEXT("Done")),nullptr,TEXT("false"));
            }
            else if(FCString::Strcmp(Operation,TEXT("Retire"))==0) F.Store(Name(TEXT("Retiring")),nullptr,TEXT("true"));
            else
            {
                F.Require(Read(TEXT("Retiring")));F.Require(F.Not(Read(TEXT("Busy"))));F.Require(F.Not(Read(TEXT("Done"))));
                F.Store(Name(TEXT("Holder")));
            }
            F.Return(F.Exec,true);
        };
        for(int32 I=0;I<2;++I)
        {
            auto* Match=F.Branch(F.Eq(Scope,F.Get(TEXT("Scope")+FString::FromInt(I))));
            F.Exec=Match->GetThenPin();Handle(I);F.Exec=Match->GetElsePin();
        }
        if(Claim) for(int32 I=0;I<2;++I)
        {
            auto* Empty=F.Branch(F.Eq(F.Get(TEXT("Scope")+FString::FromInt(I)),nullptr,TEXT("")));
            F.Exec=Empty->GetThenPin();F.Store(TEXT("Scope")+FString::FromInt(I),Scope);Handle(I);F.Exec=Empty->GetElsePin();
        }
        F.Return(F.Exec,false);Good &= F.Good;
    }
    return Good && Compile(BP);
}

bool Bridge(UBlueprint* BP,UObject* FixedCDO)
{
    bool Good=true;
    for(const TCHAR* Operation:Operations)
    {
        FGraph F(BP,Operation);
        auto* Scope=F.Arg(TEXT("Scope"),F.S->PC_String);auto* Ticket=F.Arg(TEXT("Ticket"),F.S->PC_Int);
        auto* Literal=Node<UK2Node_Literal>(F.G);Literal->SetObjectRef(FixedCDO);Literal->AllocateDefaultPins();
        auto* Self=Node<UK2Node_Self>(F.G);Self->AllocateDefaultPins();
        auto* Call=F.Call(FixedCDO->GetClass(),Operation);
        F.Link(Literal->GetValuePin(),Call->FindPin(F.S->PN_Self));
        F.Link(Self->FindPin(F.S->PN_Self),Call->FindPin(TEXT("Holder")));
        F.Link(Scope,Call->FindPin(TEXT("Scope")));F.Link(Ticket,Call->FindPin(TEXT("Ticket")));
        F.Link(F.Exec,Call->FindPin(F.S->PN_Execute));F.Return(Call->FindPin(F.S->PN_Then),Call->GetReturnValuePin());
        Good &= F.Good;
    }
    return Good && Compile(BP);
}

bool Probe()
{
    auto Load=[](const TCHAR* Name){return LoadClass<UObject>(nullptr,*(Path(Name)+TEXT("_C")));};
    TStrongObjectPtr<UClass> R(Load(RegistryName)),CA(Load(TEXT("BP_RegistryBridgeA"))),CB(Load(TEXT("BP_RegistryBridgeB")));
    if(!R || !CA || !CB) return false;
    UObject* CDO=R->GetDefaultObject();bool Good=true;int32 Checks=0;
    // Bootstrap requirement, NOT generated Blueprint behavior: a process-rooted
    // instance anchors this fixed class/CDO. A runtime adapter must establish
    // and verify the same lifetime before admission (as V6 roots its bridge).
    // Construct while defaults are pristine, never clone a live registry's fields.
    UObject* Anchor=NewObject<UObject>(GetTransientPackage(),R.Get(),TEXT("PWP_SaveRegistryAnchorV1"),RF_Transient|RF_MarkAsRootSet);
    ON_SCOPE_EXIT { Anchor->RemoveFromRoot(); };
    auto Check=[&](bool Result,const TCHAR* Name){++Checks;Good &= Result;UE_LOG(LogTemp,Display,TEXT("PWP REGISTRY check=%s pass=%d"),Name,Result);};
    auto ReadHolder=[&](int32 I){return FindFProperty<FObjectPropertyBase>(CDO->GetClass(),*(TEXT("Holder")+FString::FromInt(I)))->GetObjectPropertyValue_InContainer(CDO);};
    Check(R->GetSuperClass()==UObject::StaticClass() && CA->GetSuperClass()==UObject::StaticClass() && CB->GetSuperClass()==UObject::StaticClass(),TEXT("engine_only_parents"));
    Check(!ReadHolder(0) && !ReadHolder(1),TEXT("fresh_cdo_no_persisted_holder"));
    Check(Anchor->IsRooted() && Anchor->GetClass()->GetDefaultObject()==CDO,TEXT("explicit_root_anchor_targets_fixed_cdo"));
    auto Call=[&](UObject* B,const TCHAR* Operation,const TCHAR* Scope,int32 Ticket=0){
        auto* Fn=B->FindFunction(FName(Operation));if(!Fn) return false;FStructOnScope Args(Fn);
        FindFProperty<FStrProperty>(Fn,TEXT("Scope"))->SetPropertyValue_InContainer(Args.GetStructMemory(),Scope);
        FindFProperty<FIntProperty>(Fn,TEXT("Ticket"))->SetPropertyValue_InContainer(Args.GetStructMemory(),Ticket);
        B->ProcessEvent(Fn,Args.GetStructMemory());return FindFProperty<FBoolProperty>(Fn,TEXT("ReturnValue"))->GetPropertyValue_InContainer(Args.GetStructMemory());
    };
    TStrongObjectPtr<UObject> A(NewObject<UObject>(GetTransientPackage(),CA.Get()));
    TStrongObjectPtr<UObject> Duplicate(NewObject<UObject>(GetTransientPackage(),CA.Get()));
    TStrongObjectPtr<UObject> OtherClass(NewObject<UObject>(GetTransientPackage(),CB.Get()));
    Check(!Call(A.Get(),TEXT("Reserve"),TEXT("scope-one"),1),TEXT("unclaimed_admission_refused"));
    Check(!Call(A.Get(),TEXT("Claim"),TEXT("")),TEXT("empty_scope_refused"));
    Check(Call(A.Get(),TEXT("Claim"),TEXT("scope-one")) && ReadHolder(0)==A.Get(),TEXT("literal_mutates_actual_cdo"));
    Check(Call(A.Get(),TEXT("Claim"),TEXT("scope-one")),TEXT("claim_idempotent"));
    Check(!Call(Duplicate.Get(),TEXT("Claim"),TEXT("scope-one")) && !Call(Duplicate.Get(),TEXT("Reserve"),TEXT("scope-one"),1),TEXT("duplicate_instance_refused"));
    Check(!Call(OtherClass.Get(),TEXT("Claim"),TEXT("scope-one")) && !Call(OtherClass.Get(),TEXT("Reserve"),TEXT("scope-one"),1),TEXT("independent_class_same_cdo_refused"));
    Check(Call(OtherClass.Get(),TEXT("Claim"),TEXT("scope-two")) && Call(OtherClass.Get(),TEXT("Reserve"),TEXT("scope-two"),1),TEXT("distinct_scope_allowed"));
    Check(!Call(Duplicate.Get(),TEXT("Claim"),TEXT("scope-three")),TEXT("bounded_capacity_refused"));
    Check(!Call(A.Get(),TEXT("Release"),TEXT("scope-one")),TEXT("active_release_refused"));
    Check(!Call(A.Get(),TEXT("Reserve"),TEXT("scope-one"),0) && !Call(A.Get(),TEXT("Reserve"),TEXT("scope-one"),MAX_int32),TEXT("invalid_ticket_refused"));
    Check(Call(A.Get(),TEXT("Reserve"),TEXT("scope-one"),1) && !Call(A.Get(),TEXT("Reserve"),TEXT("scope-one"),2),TEXT("busy_admission_refused"));
    Check(Call(A.Get(),TEXT("Retire"),TEXT("scope-one")) && !Call(A.Get(),TEXT("Release"),TEXT("scope-one")),TEXT("busy_retirement_retains_owner"));
    Check(!Call(Duplicate.Get(),TEXT("Complete"),TEXT("scope-one"),1) && !Call(A.Get(),TEXT("Complete"),TEXT("scope-one"),2),TEXT("foreign_and_wrong_ticket_completion_refused"));
    // Drop ALL owning fixture references to A. Only the registry's reflected
    // Holder should keep it alive; class handles merely keep the oracle valid.
    TWeakObjectPtr<UObject> WeakA(A.Get());A.Reset();
    // The rooted anchor is the explicit registry lifetime boundary. Do not rely
    // on strong fixture class handles for this GC test. Other coordinators also
    // reference the fixed CDO; this is not a shipping-world teardown experiment.
    R.Reset();CA.Reset();CB.Reset();CollectGarbage(RF_NoFlags);
    Check(WeakA.IsValid() && ReadHolder(0)==WeakA.Get(),TEXT("busy_holder_survives_gc_without_fixture_root"));
    if(!WeakA.IsValid()) return false;
    UObject* Reacquired=ReadHolder(0);
    Check(Call(Reacquired,TEXT("Complete"),TEXT("scope-one"),1),TEXT("retired_completion_allowed"));
    Check(!Call(Reacquired,TEXT("Release"),TEXT("scope-one")) && !Call(Duplicate.Get(),TEXT("Claim"),TEXT("scope-one")),TEXT("terminal_result_retains_owner"));
    CollectGarbage(RF_NoFlags);
    Check(WeakA.IsValid() && ReadHolder(0)==WeakA.Get(),TEXT("terminal_holder_survives_gc"));
    if(!WeakA.IsValid()) return false;
    Reacquired=ReadHolder(0);
    Check(!Call(Reacquired,TEXT("Consume"),TEXT("scope-one"),2),TEXT("wrong_ack_refused"));
    Check(Call(Reacquired,TEXT("Consume"),TEXT("scope-one"),1) && !Call(Reacquired,TEXT("Reserve"),TEXT("scope-one"),2),TEXT("retired_drained_admission_refused"));
    Check(Call(Reacquired,TEXT("Release"),TEXT("scope-one")) && !ReadHolder(0),TEXT("drained_release"));
    Check(Call(Duplicate.Get(),TEXT("Claim"),TEXT("scope-one")) && !Call(Duplicate.Get(),TEXT("Reserve"),TEXT("scope-one"),1) && Call(Duplicate.Get(),TEXT("Reserve"),TEXT("scope-one"),2),TEXT("handover_keeps_ticket_fence"));
    Check(!Call(Reacquired,TEXT("Reserve"),TEXT("scope-one"),3) && !Call(Reacquired,TEXT("Complete"),TEXT("scope-one"),2) && !Call(Reacquired,TEXT("Consume"),TEXT("scope-one"),2) && !Call(Reacquired,TEXT("Release"),TEXT("scope-one")),TEXT("old_holder_cannot_bypass_registry"));
    CollectGarbage(RF_NoFlags);
    Check(!WeakA.IsValid(),TEXT("released_holder_collectible"));
    Check(Call(Duplicate.Get(),TEXT("Complete"),TEXT("scope-one"),2) && Call(Duplicate.Get(),TEXT("Consume"),TEXT("scope-one"),2) && Call(Duplicate.Get(),TEXT("Retire"),TEXT("scope-one")) && Call(Duplicate.Get(),TEXT("Release"),TEXT("scope-one")),TEXT("new_holder_drain"));
    Check(Call(OtherClass.Get(),TEXT("Complete"),TEXT("scope-two"),1) && Call(OtherClass.Get(),TEXT("Consume"),TEXT("scope-two"),1) && Call(OtherClass.Get(),TEXT("Retire"),TEXT("scope-two")) && Call(OtherClass.Get(),TEXT("Release"),TEXT("scope-two")),TEXT("independent_scope_drain"));
    UE_LOG(LogTemp,Display,TEXT("PWP REGISTRY fixture_pass=%d checks=%d disk_io=0"),Good,Checks);
    return Good;
}
}

UBuildSaveRegistryCommandlet::UBuildSaveRegistryCommandlet()
{ IsClient=false;IsServer=false;IsEditor=true;LogToConsole=true; }

int32 UBuildSaveRegistryCommandlet::Main(const FString& Params)
{
    using namespace PWPRegistry;
    if(FParse::Param(*Params,TEXT("Generate")))
    {
        // Refuse all existing assets, including partially generated fixtures.
        for(const TCHAR* N:{RegistryName,TEXT("BP_RegistryBridgeA"),TEXT("BP_RegistryBridgeB")})
            if(LoadObject<UObject>(nullptr,*Path(N))) { UE_LOG(LogTemp,Error,TEXT("REGISTRY existing asset; use Verify or explicit isolated regeneration"));return 2; }
        auto* R=Create(RegistryName);if(!R || !Registry(R)) return 3;
        auto* A=Create(TEXT("BP_RegistryBridgeA"));auto* B=Create(TEXT("BP_RegistryBridgeB"));
        if(!A || !B || !Bridge(A,R->GeneratedClass->GetDefaultObject()) || !Bridge(B,R->GeneratedClass->GetDefaultObject())) return 4;
        // Persist pristine defaults BEFORE the fixture mutates its in-memory CDO.
        if(!Save(R) || !Save(A) || !Save(B)) return 5;
    }
    return Probe()?0:6;
}
