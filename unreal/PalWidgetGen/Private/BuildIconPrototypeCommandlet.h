#pragma once
#include "CoreMinimal.h"
#include "Commandlets/Commandlet.h"
#include "BuildIconPrototypeCommandlet.generated.h"

UCLASS()
class UBuildIconPrototypeCommandlet : public UCommandlet
{
    GENERATED_BODY()
public:
    UBuildIconPrototypeCommandlet();
    virtual int32 Main(const FString& Params) override;
};
