// Execute the actual exported entry, with only Lua/owner/operation IO replaced.
// No native save-core implementation is linked; this cannot touch a journal.
#ifdef PWP_LEGACY_ENTRY_TEST
#include "build/entry_legacy_mutant.inc"
#else
#include "entry.cpp"
#endif
#include <iostream>
#include <stdexcept>
#include <thread>

namespace fake {
unsigned claims=0, admissions=0, runs=0, consumes=0, releases=0;
std::uint64_t admitted=0;
}
namespace pwp::experimental {
struct SaveOwner::State {std::optional<OwnerResult> result;};
SaveOwner::SaveOwner(std::shared_ptr<State> s):state(std::move(s)) {}
SaveOwner::~SaveOwner()=default;
std::shared_ptr<SaveOwner> SaveOwner::claim(const OwnerBinding&) {
    ++fake::claims; return std::shared_ptr<SaveOwner>(new SaveOwner(std::make_shared<State>()));
}
bool SaveOwner::complete(std::uint64_t t,bool certain,std::string bytes) {
    state->result=OwnerResult{t,certain,std::move(bytes)};return true;
}
std::optional<OwnerResult> SaveOwner::peek(std::uint64_t t) const {
    return state->result && state->result->ticket==t ? state->result : std::nullopt;
}
bool SaveOwner::consume(std::uint64_t t) {
    if(!peek(t))return false; ++fake::consumes;state->result.reset();return true;
}
void SaveOwner::retire() {}
bool SaveOwner::release() {++fake::releases;return true;}
SaveOperation::SaveOperation(std::shared_ptr<SaveOwner> o,OwnerBinding b,std::uint64_t t,
    std::wstring r,std::wstring s,std::wstring g,std::wstring k,journal::Preimages p,std::string e)
    :owner(std::move(o)),binding(std::move(b)),ticket(t),root(std::move(r)),storage(std::move(s)),
     guild(std::move(g)),stream(std::move(k)),expected(std::move(p)),encoded(std::move(e)) {}
std::shared_ptr<SaveOperation> SaveOperation::admit(std::shared_ptr<SaveOwner> o,OwnerBinding b,
    std::uint64_t t,std::wstring r,std::wstring s,std::wstring g,std::wstring k,
    journal::Preimages p,std::string e) {
    ++fake::admissions;fake::admitted=t;
    return std::shared_ptr<SaveOperation>(new SaveOperation(std::move(o),std::move(b),t,
        std::move(r),std::move(s),std::move(g),std::move(k),std::move(p),std::move(e)));
}
bool SaveOperation::run() noexcept {
    ++fake::runs;
    return owner->complete(ticket,true,ticket==1?"initialized:fake":"updated:fake");
}
namespace records {
std::string encode(const Record& r) {return std::to_string(r.generation);}
}
}
namespace {
void require(bool ok,const char* message) {if(!ok)throw std::runtime_error(message);}
int call(std::int64_t command,std::int64_t ticket,bool check_order=true) {
    lua_State s{{{command},{ticket}}, {}};
    require(luaopen_pwp_journal_probe(&s)==5,"entry reply count");
    require(s.stack.size()==5,"entry reply stack layout");
    if(check_order)require(s.reads==std::vector<int>({2,1}),"descending extraction order");
    for(const auto& v:s.stack)require(v.is_integer,"integer reply");
    require(s.stack[1].integer==GetCurrentThreadId(),"actual calling thread reply");
    require(s.stack[3].integer>=s.stack[2].integer && s.stack[4].integer>0,"QPC reply");
    return static_cast<int>(s.stack[0].integer);
}
int worker(std::int64_t command,std::int64_t ticket) {
    int result=-99; std::exception_ptr error;
    std::thread t([&]{try {result=call(command,ticket);}catch(...) {error=std::current_exception();}});
    t.join();if(error)std::rethrow_exception(error);return result;
}
}
int main() {
    try {
        require(call(0,0,false)==1,"metadata binds control thread");
        // This is the live failure: (0,0) hides a missing ticket, (1,1) cannot.
        require(call(1,1,false)==1 && fake::admitted==1 && fake::admissions==1,
                "REGRESSION: actual entry lost ticket 1 during admission");
        for(unsigned ticket=1;ticket<=3;++ticket) {
            if(ticket>1)require(call(5,ticket)==1 && fake::admitted==ticket,"next admission");
            const auto admitted=fake::admissions, ran=fake::runs;
            require(call(ticket==1?1:5,ticket)==0,"duplicate admission rejected");
            require(worker(5,ticket)==0 && worker(3,ticket)==0 && worker(4,ticket)==0 && worker(6,ticket)==0,
                    "game commands reject worker thread");
            require(call(2,ticket)==0 && fake::runs==ran,"wrong-thread IO rejected before operation");
            require(worker(2,ticket==1?2:ticket-1)==0,"stale/future worker rejected");
            require(fake::admissions==admitted && fake::runs==ran,"rejections have no backend effects");
            require(worker(2,ticket)==1 && fake::runs==ran+1,"worker runs admitted ticket");
            require(worker(2,ticket)==0 && fake::runs==ran+1,"duplicate worker no IO");
            require(call(3,ticket)==1 && call(4,ticket)==1 && call(4,ticket)==0,"inspect/consume once");
        }
        require(call(6,3)==1 && call(6,3)==0 && fake::releases==1,"release once");
        for(auto s:std::vector<lua_State>{ {}, {{{1}},{}}, {{{1},{1},{1}},{}},
                {{{1,false},{1}},{}}, {{{1},{1,false}},{}}, {{{1},{-1}},{}},
                {{{1},{4}},{}}, {{{-1},{1}},{}}, {{{7},{1}},{}} }) {
            require(luaopen_pwp_journal_probe(&s)==0,"invalid arguments have no reply");
        }
        require(fake::claims==1 && fake::admissions==3 && fake::runs==3 && fake::consumes==3 && fake::releases==1,
                "exact backend effect counts");
        std::cout<<"PASS actual entry: popping parser, three tickets, stale/duplicate/thread guards, invalid inputs\n";
        return 0;
    } catch(const std::exception& e) {std::cerr<<e.what()<<'\n';return 1;}
}
