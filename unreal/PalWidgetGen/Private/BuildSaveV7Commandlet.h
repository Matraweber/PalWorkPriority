#pragma once
#include "CoreMinimal.h"
#include "Commandlets/Commandlet.h"
#include "BuildSaveV7Commandlet.generated.h"

class USaveGame;
class UAsyncActionHandleSaveGame;
class UPWPV7Coordinator;

// Editor-native protocol experiment. These classes MUST NOT be referenced by
// cooked assets; an Engine-only receiver graph is a separate, unproven step.
struct FPWPV7Identity
{
    FString Scope,Slot,Kind;
    int32 Epoch=0,Ticket=0;
    bool operator==(const FPWPV7Identity& B) const
    { return Scope==B.Scope && Slot==B.Slot && Kind==B.Kind && Epoch==B.Epoch && Ticket==B.Ticket; }
};

UCLASS()
class UPWPV7Operation : public UObject
{
    GENERATED_BODY()
public:
    enum class EPhase : uint8 { Prepared,Saving,Reading,Terminal,Consumed };
    enum class EOutcome : uint8 { Pending,Verified,Unreadable,WriteFailed };
    const FPWPV7Identity& Identity() const { return Id; }
    EPhase Phase() const { return State; }
    UAsyncActionHandleSaveGame* Pending() const { return Action; }
    USaveGame* Result() const { return Loaded; }
    bool Succeeded() const { return Success; }
    EOutcome Outcome() const { return Status; }
    UFUNCTION() void Saved(USaveGame* Record,bool bSuccess);
    UFUNCTION() void Read(USaveGame* Record,bool bSuccess);
private:
    friend class UPWPV7Coordinator;
    void Initialize(UPWPV7Coordinator* InOwner,const FPWPV7Identity& InId);
    FPWPV7Identity Id; // Assigned exactly once, never taken from successor state.
    FString ExpectedPayload,ExpectedNonce;
    int32 ExpectedGeneration=0;
    bool Initialized=false,Success=false;
    EPhase State=EPhase::Prepared;
    EOutcome Status=EOutcome::Pending;
    UPROPERTY() UPWPV7Coordinator* Owner=nullptr;
    UPROPERTY() UAsyncActionHandleSaveGame* Action=nullptr;
    UPROPERTY() USaveGame* Loaded=nullptr;
    UPROPERTY() UClass* ExpectedClass=nullptr;
};

UCLASS()
class UPWPV7Coordinator : public UObject
{
    GENERATED_BODY()
public:
    bool Bind(UObject* Registry,UObject* World,const FString& Scope,const FString& Slot,int32 Epoch);
    bool Submit(const FPWPV7Identity& Id,USaveGame* Record);
    bool Consume(const FPWPV7Identity& Id);
    bool Retire();
    bool Release();
    UPWPV7Operation* Current() const { return Active; }
    bool IsBusy() const { return Busy; }
    bool IsDone() const { return Done; }
    int32 Completions() const { return CompletionCount; }
    int32 RejectedCallbacks() const { return Rejected; }
    // Test-only checkpoint, after read proxy retention, before Activate.
    TFunction<void()> ReadbackCheckpoint;
private:
    friend class UPWPV7Operation;
    bool RegistryCall(const TCHAR* Op,int32 Ticket=0);
    bool Matches(const UPWPV7Operation* Op,UPWPV7Operation::EPhase Phase) const;
    void OnSaved(UPWPV7Operation* Op,USaveGame* Record,bool Success);
    void OnRead(UPWPV7Operation* Op,USaveGame* Record,bool Success);
    bool Finish(UPWPV7Operation* Op,USaveGame* Record,bool Success);
    bool Enter();
    bool Gate=false,Bound=false,Retiring=false,Busy=false,Done=false,HasConsumed=false;
    int32 Epoch=0,CompletionCount=0,Rejected=0;
    FString Scope,Slot;
    FPWPV7Identity Consumed;
    UPROPERTY() UObject* Registry=nullptr;
    UPROPERTY() UObject* WorldContext=nullptr;
    UPROPERTY() UPWPV7Operation* Active=nullptr;
};

UCLASS()
class UBuildSaveV7Commandlet : public UCommandlet
{
    GENERATED_BODY()
public:
    UBuildSaveV7Commandlet();
    virtual int32 Main(const FString& Params) override;
};
