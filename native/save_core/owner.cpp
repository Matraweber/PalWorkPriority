#include "owner.hpp"
#include "record.hpp"
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <Windows.h>
#include <mutex>
#include <vector>
namespace pwp::experimental {
struct SaveOwner::State {
    HANDLE lease=nullptr;
    OwnerBinding binding;
    mutable std::mutex gate;
    std::uint64_t high=0,pending=0,consumed=0;
    bool retired=false,released=false;
    std::optional<OwnerResult> result;
    ~State() { if(lease) CloseHandle(lease); }
};
namespace {
// Retain claims even if Lua/dispatch drops its reference. An unresolved writer
// must block handover until explicit reconciliation or process termination.
std::mutex registry_gate;
std::vector<std::shared_ptr<void>> registry;
constexpr std::size_t max_owners=128;
bool same(const OwnerBinding& a,const OwnerBinding& b) {
    return a.scope==b.scope && a.incarnation==b.incarnation && a.epoch==b.epoch;
}
}
SaveOwner::SaveOwner(std::shared_ptr<State> s):state(std::move(s)){}
SaveOwner::~SaveOwner()=default;
std::shared_ptr<SaveOwner> SaveOwner::claim(const OwnerBinding& b) {
    if(b.epoch==0 || b.incarnation.empty() || b.incarnation.size()>256) return {};
    // Reuse the exact scope validator; discarded envelope performs no file IO.
    try { records::encode({b.scope,1,{}}); } catch(...) {return {};}
    std::lock_guard<std::mutex> lock(registry_gate);
    if(registry.size()>=max_owners) return {};
    auto s=std::make_shared<State>();s->binding=b;
    const std::string ascii="Global\\PWP-AsyncOwner-Dev1-"+b.scope;
    const std::wstring name(ascii.begin(),ascii.end());
    SetLastError(ERROR_SUCCESS);
    s->lease=CreateMutexW(nullptr,FALSE,name.c_str());
    const auto error=GetLastError();
    if(!s->lease || error==ERROR_ALREADY_EXISTS) return {};
    // Once admitted, keep this implementation resident until process teardown.
    // Lua reload or FreeLibrary must not destruct the retained registry beneath
    // queued/running IO. This is deliberately not a hot-unloadable helper.
    HMODULE module=nullptr;
    if(!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
        reinterpret_cast<LPCWSTR>(&registry_gate),&module)) return {};
    auto owner=std::shared_ptr<SaveOwner>(new SaveOwner(s));
    registry.push_back(s);
    return owner;
}
bool SaveOwner::reserve(const OwnerBinding& b,std::uint64_t ticket) {
    std::lock_guard<std::mutex> lock(state->gate);
    if(state->released || state->retired || !same(b,state->binding) || state->pending ||
       ticket==0 || ticket<=state->high || ticket>=2147483647) return false;
    state->pending=state->high=ticket;return true;
}
bool SaveOwner::complete(std::uint64_t ticket,bool certain,std::string bytes) {
    std::lock_guard<std::mutex> lock(state->gate);
    if(state->released || !ticket || state->pending!=ticket || state->result || bytes.size()>records::max_record) return false;
    state->result=OwnerResult{ticket,certain,std::move(bytes)};return true;
}
std::optional<OwnerResult> SaveOwner::peek(std::uint64_t ticket) const {
    std::lock_guard<std::mutex> lock(state->gate);
    if(state->released || !ticket || state->pending!=ticket) return {};
    return state->result;
}
bool SaveOwner::consume(std::uint64_t ticket) {
    std::lock_guard<std::mutex> lock(state->gate);
    if(state->released || !ticket) return false;
    if(state->consumed==ticket) return true;
    // Uncertain completion cannot release ownership or authorize retry.
    if(state->pending!=ticket || !state->result || !state->result->certain) return false;
    state->result.reset();state->pending=0;state->consumed=ticket;return true;
}
void SaveOwner::retire() {std::lock_guard<std::mutex> lock(state->gate);state->retired=true;}
bool SaveOwner::retired() const {std::lock_guard<std::mutex> lock(state->gate);return state->retired;}
bool SaveOwner::release() {
    std::lock_guard<std::mutex> registry_lock(registry_gate);
    std::lock_guard<std::mutex> lock(state->gate);
    if(state->released) return true;
    if(!state->retired || state->pending) return false;
    // Never retry a possibly closed handle. A close error leaves the claim
    // poisoned and retained; no subsequent call is allowed to reuse that handle.
    const auto handle=state->lease;state->lease=nullptr;
    if(!handle || !CloseHandle(handle)) return false;
    state->released=true;
    for(auto it=registry.begin();it!=registry.end();++it) if(it->get()==state.get()) {registry.erase(it);break;}
    return true;
}
}
