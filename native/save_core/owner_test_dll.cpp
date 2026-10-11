// Test-only exports, no production Lua entry or settings IO.
#include "owner.hpp"
using namespace pwp::experimental;
static std::shared_ptr<SaveOwner> owner;
static OwnerBinding binding;
#define EXPORT extern "C" __declspec(dllexport) int
EXPORT claim(const char* scope,const char* incarnation,unsigned epoch) {
    if(owner || !scope || !incarnation) return 0;
    binding={scope,incarnation,epoch};owner=SaveOwner::claim(binding);return owner?1:0;
}
EXPORT reserve(unsigned ticket,unsigned epoch) {auto b=binding;b.epoch=epoch;return owner && owner->reserve(b,ticket);}
EXPORT complete(unsigned ticket,int certain) {return owner && owner->complete(ticket,certain==1,"result");}
EXPORT peek(unsigned ticket) {return owner && owner->peek(ticket).has_value();}
EXPORT consume(unsigned ticket) {return owner && owner->consume(ticket);}
EXPORT retire() {if(!owner)return 0;owner->retire();return 1;}
EXPORT release() {if(!owner || !owner->release())return 0;owner.reset();return 1;}
EXPORT drop() {owner.reset();return 1;}
