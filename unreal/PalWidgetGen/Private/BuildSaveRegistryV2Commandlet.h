#pragma once
#include "CoreMinimal.h"
#include "Commandlets/Commandlet.h"
#include "BuildSaveRegistryV2Commandlet.generated.h"

// Editor fixture only. Generated assets have UObject parents and Engine nodes.
UCLASS()
class UBuildSaveRegistryV2Commandlet : public UCommandlet
{
    GENERATED_BODY()
public:
    UBuildSaveRegistryV2Commandlet();
    virtual int32 Main(const FString& Params) override;
};
