#include "BuildSaveRegistryV2Commandlet.h"
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

namespace PWPRegistryV2
{
// Bounded map: 32 retained scope entries; no eviction, no save IO.
// Complete models an IO callback; it does not prove actual async save integration.
const TCHAR* Root=TEXT("/Game/Mods/PalWorkPrioritySaveRegistryV2/");
const TCHAR* RegistryName=TEXT("BP_SaveRegistryV2");
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
        if(!Ok) UE_LOG(LogTemp,Error,TEXT("REGISTRY V2 link failed %s -> %s"),A?*A->PinName.ToString():TEXT("null"),B?*B->PinName.ToString():TEXT("null"));
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

bool Probe()
{
    auto Load=[](const TCHAR* N){return LoadClass<UObject>(nullptr,*(Path(N)+TEXT("_C")));};
    TStrongObjectPtr<UClass> R(Load(RegistryName)),E(Load(TEXT("BP_RegistryEntryV2"))),CA(Load(TEXT("BP_RegistryBridgeV2A"))),CB(Load(TEXT("BP_RegistryBridgeV2B")));
    if(!R || !E || !CA || !CB) return false;
    UObject* CDO=R->GetDefaultObject();
    auto* Gate=FindFProperty<FBoolProperty>(R.Get(),TEXT("GateHeld"));if(!Gate) return false;
    auto Held=[&](){return Gate->GetPropertyValue_InContainer(CDO);};
    bool GateLifetimeGood=!Held();
    auto* MapProperty=FindFProperty<FMapProperty>(R.Get(),TEXT("Entries"));
    if(!MapProperty || !CastField<FStrProperty>(MapProperty->KeyProp) || !CastField<FObjectPropertyBase>(MapProperty->ValueProp)) return false;
    auto Map=[&](){return FScriptMapHelper(MapProperty,MapProperty->ContainerPtrToValuePtr<void>(CDO));};
    auto Key=[](int32 I){return FString::Printf(TEXT("PWP-REGISTRY-V2-DEV:%02d"),I);};
    auto EntryAt=[&](int32 I)->UObject*{
        auto M=Map();for(int32 J=0;J<M.GetMaxIndex();++J) if(M.IsValidIndex(J) && CastFieldChecked<FStrProperty>(MapProperty->KeyProp)->GetPropertyValue(M.GetKeyPtr(J))==Key(I))
            return CastFieldChecked<FObjectPropertyBase>(MapProperty->ValueProp)->GetObjectPropertyValue(M.GetValuePtr(J));
        return nullptr;
    };
    auto HolderAt=[&](int32 I)->UObject*{auto* V=EntryAt(I);return V?FindFProperty<FObjectPropertyBase>(V->GetClass(),TEXT("Holder"))->GetObjectPropertyValue_InContainer(V):nullptr;};
    auto High=[&](int32 I,const TCHAR* N){auto* V=EntryAt(I);return V?FindFProperty<FIntProperty>(V->GetClass(),N)->GetPropertyValue_InContainer(V):-1;};
    bool Good=true;int32 Checks=0;
    auto Check=[&](bool Value,const TCHAR* Name){++Checks;Good &= Value;UE_LOG(LogTemp,Display,TEXT("PWP REGISTRY V2 check=%s pass=%d"),Name,Value);};
    Check(Map().Num()==0,TEXT("fresh_empty_typed_map"));
    Check(CastFieldChecked<FObjectPropertyBase>(MapProperty->ValueProp)->PropertyClass==E.Get(),TEXT("map_value_entry_type"));
    Check(R->GetSuperClass()==UObject::StaticClass() && E->GetSuperClass()==UObject::StaticClass() && CA->GetSuperClass()==UObject::StaticClass() && CB->GetSuperClass()==UObject::StaticClass(),TEXT("engine_only_parents"));
    UObject* Anchor=NewObject<UObject>(GetTransientPackage(),R.Get(),TEXT("PWP_SaveRegistryV2Anchor"),RF_Transient|RF_MarkAsRootSet);
    ON_SCOPE_EXIT { Anchor->RemoveFromRoot(); };
    Check(Anchor->IsRooted() && Anchor->GetClass()->GetDefaultObject()==CDO,TEXT("explicit_root_anchor"));
    auto Call=[&](UObject* B,const TCHAR* Op,const FString& Scope,int32 Epoch=1,int32 Ticket=0){
        auto* Fn=B->FindFunction(FName(Op));if(!Fn) return false;FStructOnScope Args(Fn);
        FindFProperty<FStrProperty>(Fn,TEXT("Scope"))->SetPropertyValue_InContainer(Args.GetStructMemory(),Scope);
        FindFProperty<FIntProperty>(Fn,TEXT("Epoch"))->SetPropertyValue_InContainer(Args.GetStructMemory(),Epoch);
        FindFProperty<FIntProperty>(Fn,TEXT("Ticket"))->SetPropertyValue_InContainer(Args.GetStructMemory(),Ticket);
        const bool WasHeld=Held();B->ProcessEvent(Fn,Args.GetStructMemory());
        GateLifetimeGood &= Held()==WasHeld;
        return FindFProperty<FBoolProperty>(Fn,TEXT("ReturnValue"))->GetPropertyValue_InContainer(Args.GetStructMemory());
    };
    TStrongObjectPtr<UObject> A(NewObject<UObject>(GetTransientPackage(),CA.Get()));
    TStrongObjectPtr<UObject> Duplicate(NewObject<UObject>(GetTransientPackage(),CA.Get()));
    TStrongObjectPtr<UObject> B(NewObject<UObject>(GetTransientPackage(),CB.Get()));
    Check(!Call(A.Get(),TEXT("Reserve"),Key(0),1,1) && Map().Num()==0,TEXT("unknown_nonclaim_no_allocation"));
    Check(!Call(A.Get(),TEXT("Claim"),TEXT("")) && !Call(A.Get(),TEXT("Claim"),FString::ChrN(257,TEXT('x'))) && !Call(A.Get(),TEXT("Claim"),Key(0),0) && !Call(A.Get(),TEXT("Claim"),Key(0),MAX_int32) && Map().Num()==0,TEXT("invalid_claim_no_allocation"));
    bool MapNested=false;
    {
        FPreCallScope Hook(UBlueprintMapLibrary::StaticClass(),TEXT("Map_Add"),[&](){
            MapNested=Held() && !Call(Duplicate.Get(),TEXT("Claim"),Key(0)) && Held()
                && !Call(B.Get(),TEXT("Claim"),Key(1)) && Held() && Map().Num()==0;
        });
        Check(Call(A.Get(),TEXT("Claim"),Key(0)) && HolderAt(0)==A.Get() && Map().Num()==1,TEXT("map_add_find_fixed_cdo"));
    }
    Check(MapNested && !Held(),TEXT("map_add_precall_nested_claims_refused"));
    bool EntryNested=false;
    {
        FPreCallScope Hook(UKismetMathLibrary::StaticClass(),TEXT("EqualEqual_ObjectObject"),[&](){
            EntryNested=Held() && !Call(Duplicate.Get(),TEXT("Claim"),Key(1)) && Held()
                && !Call(A.Get(),TEXT("Claim"),Key(1)) && Held() && HolderAt(1)==nullptr;
        });
        Check(Call(B.Get(),TEXT("Claim"),Key(1)) && HolderAt(1)==B.Get(),TEXT("entry_comparison_outer_claim_survives"));
    }
    Check(EntryNested && !Held(),TEXT("entry_comparison_precall_nested_claims_refused"));
    // Exercise every outer operation and every nested operation at the first
    // hookable validation, including failed outer calls. No fake counter proof.
    bool FirstHookGood=true;
    for(const TCHAR* Outer:Operations)
    {
        bool Fired=false,NestedGood=true;
        {
            FPreCallScope Hook(UKismetSystemLibrary::StaticClass(),TEXT("IsValid"),[&](){
                Fired=true;NestedGood &= Held();
                for(const TCHAR* Inner:Operations)
                    NestedGood &= !Call(Duplicate.Get(),Inner,Key(0),1,1) && Held();
            });
            Call(Duplicate.Get(),Outer,Key(0),1,1);
        }
        FirstHookGood &= Fired && NestedGood && !Held() && HolderAt(0)==A.Get() && High(0,TEXT("Ticket"))==0;
    }
    Check(FirstHookGood,TEXT("all_six_gates_before_first_native_hook"));
    Check(Call(A.Get(),TEXT("Claim"),Key(0)) && !Call(A.Get(),TEXT("Claim"),Key(0),2),TEXT("same_holder_exact_epoch_only"));
    Check(!Call(Duplicate.Get(),TEXT("Claim"),Key(0)) && !Call(Duplicate.Get(),TEXT("Claim"),Key(0),2) && !Call(Duplicate.Get(),TEXT("Reserve"),Key(0),1,1),TEXT("same_class_duplicate_refused"));
    Check(!Call(B.Get(),TEXT("Claim"),Key(0)) && !Call(B.Get(),TEXT("Reserve"),Key(0),1,1),TEXT("independent_class_duplicate_refused"));
    Check(Call(B.Get(),TEXT("Claim"),Key(1)) && Call(B.Get(),TEXT("Reserve"),Key(1),1,9) && HolderAt(1)==B.Get(),TEXT("distinct_scope_independent_holder"));
    Check(!Call(A.Get(),TEXT("Release"),Key(0)),TEXT("nonretired_release_refused"));
    Check(!Call(A.Get(),TEXT("Reserve"),Key(0),1,0) && !Call(A.Get(),TEXT("Reserve"),Key(0),1,MAX_int32) && High(0,TEXT("Ticket"))==0,TEXT("invalid_ticket_no_highwater_change"));
    Check(Call(A.Get(),TEXT("Reserve"),Key(0),1,10) && !Call(A.Get(),TEXT("Reserve"),Key(0),1,11),TEXT("busy_reserve_refused"));
    Check(Call(A.Get(),TEXT("Retire"),Key(0)) && !Call(A.Get(),TEXT("Release"),Key(0)) && !Call(Duplicate.Get(),TEXT("Claim"),Key(0),2),TEXT("busy_owner_retained"));
    Check(!Call(A.Get(),TEXT("Complete"),Key(0),2,10) && !Call(A.Get(),TEXT("Complete"),Key(0),1,11) && !Call(B.Get(),TEXT("Complete"),Key(0),1,10),TEXT("wrong_epoch_ticket_holder_completion_refused"));
    TArray<TWeakObjectPtr<UObject>> Holders,Entries;
    bool Filled=true;
    for(int32 I=2;I<32;++I)
    {
        auto* H=NewObject<UObject>(GetTransientPackage(),I%2?CB.Get():CA.Get());Holders.Add(H);
        Filled &= Call(H,TEXT("Claim"),Key(I)) && Call(H,TEXT("Reserve"),Key(I),1,100+I)
            && Call(H,TEXT("Complete"),Key(I),1,100+I) && Call(H,TEXT("Consume"),Key(I),1,100+I);
        Entries.Add(EntryAt(I));
    }
    Check(Filled && Map().Num()==32,TEXT("all_32_scopes_filled"));
    Check(!Call(Duplicate.Get(),TEXT("Claim"),Key(32)) && !EntryAt(32) && Map().Num()==32,TEXT("scope_33_capacity_refused"));
    TWeakObjectPtr<UObject> WeakA(A.Get());A.Reset();R.Reset();E.Reset();CA.Reset();CB.Reset();CollectGarbage(RF_NoFlags);
    bool Alive=WeakA.IsValid() && HolderAt(0)==WeakA.Get();
    for(int32 I=0;I<Holders.Num();++I) Alive &= Holders[I].IsValid() && Entries[I].IsValid() && HolderAt(I+2)==Holders[I].Get();
    Check(Alive && Map().Num()==32,TEXT("map_entries_and_busy_holder_survive_gc"));if(!Alive) return false;
    auto* Old=WeakA.Get();
    Check(Call(Old,TEXT("Complete"),Key(0),1,10) && !Call(Old,TEXT("Release"),Key(0)) && !Call(Duplicate.Get(),TEXT("Claim"),Key(0),2),TEXT("terminal_result_retained"));
    CollectGarbage(RF_NoFlags);Check(WeakA.IsValid() && HolderAt(0)==WeakA.Get(),TEXT("terminal_holder_survives_gc"));if(!WeakA.IsValid()) return false;Old=WeakA.Get();
    Check(!Call(Old,TEXT("Consume"),Key(0),1,9) && !Call(Old,TEXT("Consume"),Key(0),2,10),TEXT("wrong_ack_refused"));
    Check(Call(Old,TEXT("Consume"),Key(0),1,10) && !Call(Old,TEXT("Reserve"),Key(0),1,11) && Call(Old,TEXT("Release"),Key(0)),TEXT("retired_drain_release"));
    Check(!HolderAt(0) && High(0,TEXT("Epoch"))==1 && High(0,TEXT("Ticket"))==10 && Map().Num()==32,TEXT("release_retains_entry_and_highwater"));
    Check(!Call(Duplicate.Get(),TEXT("Claim"),Key(0),1) && Call(Duplicate.Get(),TEXT("Claim"),Key(0),2)
        && !Call(Duplicate.Get(),TEXT("Reserve"),Key(0),2,10) && Call(Duplicate.Get(),TEXT("Reserve"),Key(0),2,11),TEXT("reclaim_advances_epoch_preserves_ticket"));
    Check(!Call(Old,TEXT("Complete"),Key(0),2,11) && !Call(Old,TEXT("Consume"),Key(0),2,11) && !Call(Old,TEXT("Retire"),Key(0),2)
        && !Call(Old,TEXT("Release"),Key(0),2) && !Call(Duplicate.Get(),TEXT("Complete"),Key(0),1,11),TEXT("stale_holder_and_epoch_refused"));
    CollectGarbage(RF_NoFlags);Check(!WeakA.IsValid(),TEXT("released_holder_collectible"));
    bool Reclaimed=true;
    for(int32 I=2;I<32;++I)
    {
        auto* H=HolderAt(I);
        Reclaimed &= H && Call(H,TEXT("Retire"),Key(I)) && Call(H,TEXT("Release"),Key(I));
        Reclaimed &= !Call(Duplicate.Get(),TEXT("Claim"),Key(I),1) && Call(Duplicate.Get(),TEXT("Claim"),Key(I),2)
            && !Call(Duplicate.Get(),TEXT("Reserve"),Key(I),2,100+I) && Call(Duplicate.Get(),TEXT("Reserve"),Key(I),2,200+I)
            && Call(Duplicate.Get(),TEXT("Complete"),Key(I),2,200+I) && Call(Duplicate.Get(),TEXT("Consume"),Key(I),2,200+I)
            && Call(Duplicate.Get(),TEXT("Retire"),Key(I),2) && Call(Duplicate.Get(),TEXT("Release"),Key(I),2)
            && High(I,TEXT("Epoch"))==2 && High(I,TEXT("Ticket"))==200+I && EntryAt(I)==Entries[I-2].Get();
    }
    Check(Reclaimed && Map().Num()==32,TEXT("all_30_entries_reclaimed_without_eviction"));
    Check(!Call(B.Get(),TEXT("Claim"),Key(32)) && !EntryAt(32) && Map().Num()==32,TEXT("released_capacity_not_reusable_for_new_scope"));
    Check(Call(Duplicate.Get(),TEXT("Complete"),Key(0),2,11) && Call(Duplicate.Get(),TEXT("Consume"),Key(0),2,11)
        && Call(Duplicate.Get(),TEXT("Retire"),Key(0),2) && Call(Duplicate.Get(),TEXT("Release"),Key(0),2),TEXT("replacement_drain"));
    Check(Call(B.Get(),TEXT("Complete"),Key(1),1,9) && Call(B.Get(),TEXT("Consume"),Key(1),1,9)
        && Call(B.Get(),TEXT("Retire"),Key(1)) && Call(B.Get(),TEXT("Release"),Key(1)),TEXT("independent_scope_drain"));
    Check(Call(B.Get(),TEXT("Claim"),Key(2),MAX_int32-1) && Call(B.Get(),TEXT("Reserve"),Key(2),MAX_int32-1,MAX_int32-1)
        && Call(B.Get(),TEXT("Complete"),Key(2),MAX_int32-1,MAX_int32-1) && Call(B.Get(),TEXT("Consume"),Key(2),MAX_int32-1,MAX_int32-1)
        && !Call(B.Get(),TEXT("Reserve"),Key(2),MAX_int32-1,MAX_int32) && Call(B.Get(),TEXT("Retire"),Key(2),MAX_int32-1)
        && Call(B.Get(),TEXT("Release"),Key(2),MAX_int32-1) && !Call(B.Get(),TEXT("Claim"),Key(2),MAX_int32-1)
        && !Call(B.Get(),TEXT("Claim"),Key(2),MAX_int32),TEXT("counter_exhaustion_fail_closed"));
    CollectGarbage(RF_NoFlags);
    bool Retained=Map().Num()==32;for(int32 I=0;I<32;++I) Retained &= EntryAt(I)!=nullptr && HolderAt(I)==nullptr;
    Check(Retained,TEXT("all_entries_retained_after_final_gc"));
    Check(GateLifetimeGood && !Held(),TEXT("owner_only_unlock_all_exercised_returns"));
    UE_LOG(LogTemp,Display,TEXT("PWP REGISTRY V2 fixture_pass=%d capacity=32 map=1 disk_io=0 checks=%d"),Good,Checks);
    return Good;
}
}

UBuildSaveRegistryV2Commandlet::UBuildSaveRegistryV2Commandlet()
{ IsClient=false;IsServer=false;IsEditor=true;LogToConsole=true; }
int32 UBuildSaveRegistryV2Commandlet::Main(const FString& Params)
{
    using namespace PWPRegistryV2;
    if(FParse::Param(*Params,TEXT("Generate")))
    {
        for(const TCHAR* N:{RegistryName,TEXT("BP_RegistryEntryV2"),TEXT("BP_RegistryBridgeV2A"),TEXT("BP_RegistryBridgeV2B")})
            if(LoadObject<UObject>(nullptr,*Path(N))) { UE_LOG(LogTemp,Error,TEXT("REGISTRY V2 existing assets; verify or explicitly regenerate isolated V2 only"));return 2; }
        auto* E=Create(TEXT("BP_RegistryEntryV2"));if(!E || !Entry(E)) return 3;
        auto* R=Create(RegistryName);if(!R || !Registry(R,E->GeneratedClass)) return 4;
        auto* A=Create(TEXT("BP_RegistryBridgeV2A"));auto* B=Create(TEXT("BP_RegistryBridgeV2B"));
        if(!A || !B || !Bridge(A,R->GeneratedClass->GetDefaultObject()) || !Bridge(B,R->GeneratedClass->GetDefaultObject())) return 5;
        if(!Save(E) || !Save(R) || !Save(A) || !Save(B)) return 6;
    }
    return Probe()?0:7;
}

