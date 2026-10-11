#include "backend.hpp"
#include <mutex>
#include <stdexcept>
#include <type_traits>
#include <utility>
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <Windows.h>
#include <bcrypt.h>

namespace pwp::experimental {
struct JournalBackend::State {
    const std::shared_ptr<const RootCapability> root;
    const OwnerBinding binding;
    const std::wstring storage,guild,stream;
    const std::shared_ptr<SaveOwner> owner;
    const std::string token_prefix;
    mutable std::mutex gate;
    journal::Preimages preimages;
    std::string token;
    int selected=-2;
    std::uint32_t generation=0;
    std::uint64_t pending=0,last_consumed=0,last_revision=0;
    bool recovered=false,retired=false,released=false;
    std::optional<JournalTerminal> result;
    State(std::shared_ptr<const RootCapability> r,OwnerBinding b,std::wstring s,
          std::wstring g,std::wstring k,std::shared_ptr<SaveOwner> o,std::string prefix)
        :root(std::move(r)),binding(std::move(b)),storage(std::move(s)),
         guild(std::move(g)),stream(std::move(k)),owner(std::move(o)),token_prefix(std::move(prefix)){}
};
JournalBackend::JournalBackend(std::shared_ptr<State> s):state(std::move(s)){}
std::shared_ptr<JournalBackend> JournalBackend::open(std::shared_ptr<const RootCapability> root,OwnerBinding binding) {
    if(!root||RootCapability::release_status().state!=RootLifetime::live)return {};
    // Encode validates the complete canonical scope. Derive all leaf components
    // from it: no second caller-supplied world/guild/path can disagree.
    try {records::encode({binding.scope,1,{}});}catch(...){return {};}
    const auto widen=[](std::string s){return std::wstring(s.begin(),s.end());};
    unsigned char nonce[16]{};
    if(BCryptGenRandom(nullptr,nonce,sizeof(nonce),BCRYPT_USE_SYSTEM_PREFERRED_RNG)<0)return {};
    std::string prefix;prefix.reserve(33);
    constexpr char hex[]="0123456789abcdef";
    for(auto byte:nonce) {prefix+=hex[byte>>4];prefix+=hex[byte&15];}prefix+=':';
    auto owner=SaveOwner::claim(binding);if(!owner)return {};
    try {
        auto s=std::make_shared<State>(std::move(root),binding,widen(binding.scope.substr(12,32)),
            widen(binding.scope.substr(45,32)),widen(binding.scope.substr(78)),owner,std::move(prefix));
        return std::shared_ptr<JournalBackend>(new JournalBackend(std::move(s)));
    }catch(...) {owner->retire();owner->release();throw;}
}
JournalJob::JournalJob(std::shared_ptr<JournalBackend::State> s,std::uint64_t t,bool r,
                      journal::Preimages p,std::string e,std::uint64_t v)
    :state(std::move(s)),ticket(t),revision(v),recovery(r),before(std::move(p)),encoded(std::move(e)){}
std::shared_ptr<JournalJob> JournalBackend::recover(std::uint64_t ticket) {
    std::lock_guard<std::mutex> lock(state->gate);
    if(state->retired||state->released||state->pending||state->recovered)return {};
    auto job=std::shared_ptr<JournalJob>(new JournalJob(state,ticket,true,{}, {},0));
    if(!state->owner->reserve(state->binding,ticket))return {};
    state->pending=ticket;return job;
}
std::shared_ptr<JournalJob> JournalBackend::update(std::uint64_t ticket,std::string token,
    std::string payload,std::uint32_t generation,std::uint64_t revision,bool initialize) {
    std::lock_guard<std::mutex> lock(state->gate);
    if(state->retired||state->released||state->pending||!state->recovered||state->selected==-2
       || token.empty()||token!=state->token||generation!=state->generation+1
       || initialize!=(state->selected==-1)||revision==0||revision<=state->last_revision
       ||revision>=2147483647||payload.size()>records::max_payload)return {};
    auto bytes=records::encode({state->binding.scope,generation,std::move(payload)});
    auto job=std::shared_ptr<JournalJob>(new JournalJob(state,ticket,false,state->preimages,std::move(bytes),revision));
    if(!state->owner->reserve(state->binding,ticket))return {};
    state->pending=ticket;return job;
}
std::optional<JournalTerminal> JournalBackend::peek(std::uint64_t ticket) const {
    std::lock_guard<std::mutex> lock(state->gate);
    if(!ticket||state->released||state->pending!=ticket)return {};
    return state->result;
}
bool JournalBackend::consume(std::uint64_t ticket) {
    std::lock_guard<std::mutex> lock(state->gate);
    if(!ticket||state->released)return false;
    if(state->last_consumed==ticket)return true;
    if(state->pending!=ticket||!state->result||!state->result->certain)return false;
    if(!state->owner->consume(ticket))return false;
    state->last_consumed=ticket;state->pending=0;state->result.reset();return true;
}
void JournalBackend::retire() {
    std::lock_guard<std::mutex> lock(state->gate);state->retired=true;state->owner->retire();
}
bool JournalBackend::release() {
    std::lock_guard<std::mutex> lock(state->gate);
    if(state->released)return true;
    if(!state->retired||state->pending)return false;
    state->released=state->owner->release();return state->released;
}
bool JournalJob::run() noexcept {
    if(started.exchange(true))return false;
    try {
        JournalTerminal out;out.ticket=ticket;out.covered_revision=revision;
        journal::Preimages after;
        int candidate=-2;
        if(state->owner->retired()) {out.certain=true;out.status="cancelled-before-io";}
        else if(recovery) {
            for(unsigned i=0;i<2;++i) {
                auto r=record_reader::read(state->root->path(),state->storage,state->guild,state->stream,i==0?'A':'B');
                out.slots[i]=std::move(r.read);after[i]=std::move(r.encoded);
                if(r.error && out.slots[i].state!=records::State::missing)out.error=r.error;
            }
            candidate=records::candidate(out.slots[0],out.slots[1]);
            out.generation=candidate>=0?out.slots[static_cast<unsigned>(candidate)].record.generation:0;
            // A completed blocked read can be consumed; it never permits update.
            out.certain=true;out.status="recovered";out.preimages=state->token_prefix+std::to_string(ticket);
        } else {
            const auto r=journal::update(state->root->path(),state->storage,state->guild,state->stream,before,encoded);
            out.error=r.error;out.cleanup_error=r.cleanup_error;out.generation=r.generation;
            switch(r.status) {
            case journal::Status::initialized:out.status="initialized";break;
            case journal::Status::updated:out.status="updated";break;
            case journal::Status::conflict:out.status="conflict";break;
            case journal::Status::io_error:out.status="io_error";break;
            case journal::Status::uncertain:out.status="uncertain";break;
            }
            out.certain=r.status!=journal::Status::uncertain;
            if(r.status==journal::Status::initialized||r.status==journal::Status::updated) {
                if(r.slot!='A'&&r.slot!='B')throw std::runtime_error("invalid published slot");
                after=before;candidate=r.slot=='A'?0:1;after[static_cast<unsigned>(candidate)]=encoded;
                out.preimages=state->token_prefix+std::to_string(ticket);
            }
        }
        // No mutable current-operation lookup: publish to the captured owner.
        std::lock_guard<std::mutex> lock(state->gate);
        if(state->pending!=ticket||state->result)return false;
        // Prepare every allocating copy before completing the owner mailbox.
        auto next_token=out.preimages;
        static_assert(std::is_nothrow_move_assignable_v<JournalTerminal>);
        static_assert(std::is_nothrow_move_assignable_v<journal::Preimages>);
        if(!state->owner->complete(ticket,out.certain,out.status))return false;
        if(out.status=="recovered"||out.status=="initialized"||out.status=="updated") {
            state->preimages=std::move(after);state->token=std::move(next_token);state->selected=candidate;
            state->generation=out.generation;state->recovered=true;
            if(!recovery)state->last_revision=revision;
        } else state->selected=-2; // certain failures require reconciliation
        state->result=std::move(out);return true;
    }catch(...) {
        try {
            std::lock_guard<std::mutex> lock(state->gate);
            state->owner->complete(ticket,false,"backend-exception");
            state->selected=-2;
            if(!state->result) {JournalTerminal r;r.ticket=ticket;r.status="uncertain";state->result=std::move(r);}
        }catch(...){}
        return false;
    }
}
}
