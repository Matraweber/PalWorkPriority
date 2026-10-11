#pragma once
#include "CoreMinimal.h"
#include "Commandlets/Commandlet.h"
#include "BuildSavePrototypeCommandlet.generated.h"

UCLASS()
class UBuildSavePrototypeCommandlet : public UCommandlet
{
    GENERATED_BODY()
public:
    UBuildSavePrototypeCommandlet();
    virtual int32 Main(const FString& Params) override;
    // Editor-only deterministic GC checkpoint after save completion has started
    // Blueprint readback, but before the ticker can deliver its completion.
    void WatchReadback(class UAsyncActionHandleSaveGame* SaveAction, UObject* Bridge);
    bool ReadbackCollected = false;
    UFUNCTION() void ObserveSaveCompletion(class USaveGame* Record, bool Success);
private:
    TWeakObjectPtr<UObject> WatchedBridge;
    TWeakObjectPtr<UObject> WatchedSave;
};
