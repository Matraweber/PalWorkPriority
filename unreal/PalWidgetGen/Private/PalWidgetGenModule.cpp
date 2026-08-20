#include "Modules/ModuleManager.h"

// No behaviour of its own. The module exists to hold the commandlet, which is
// what actually does the work, and to give the build system something to
// compile it into.
IMPLEMENT_MODULE(FDefaultModuleImpl, PalWidgetGen);
