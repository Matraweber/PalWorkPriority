#pragma once
#include "CoreMinimal.h"
#include "Commandlets/Commandlet.h"
#include "BuildSaveRegistryCommandlet.generated.h"

// Editor fixture only. Generated assets have UObject parents and Engine nodes.
UCLASS()
class UBuildSaveRegistryCommandlet : public UCommandlet
{
    GENERATED_BODY()
public:
    UBuildSaveRegistryCommandlet();
    virtual int32 Main(const FString& Params) override;
};
