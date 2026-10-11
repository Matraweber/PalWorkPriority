#pragma once

#include "CoreMinimal.h"
#include "Commandlets/Commandlet.h"
#include "BuildStandInputWidgetCommandlet.generated.h"

// Editor-only generator; the cooked widget depends only on shipped UMG/Kismet.
UCLASS()
class UBuildStandInputWidgetCommandlet : public UCommandlet
{
    GENERATED_BODY()
public:
    UBuildStandInputWidgetCommandlet();
    virtual int32 Main(const FString& Params) override;
};
