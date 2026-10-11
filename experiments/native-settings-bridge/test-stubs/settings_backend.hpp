#pragma once
#include "../wire.hpp"
#include "../terminal.hpp"
#include <memory>
#include <atomic>
#include <thread>
namespace pwp::settings_bridge {
struct NativeBackend {
    struct State {std::uint64_t ticket=0;bool done=false,certain=true,recovery=true;std::string payload=std::string("a\0b\xffz",5);};
    struct Work {std::shared_ptr<State> owner;std::uint64_t ticket;};
    using Root=std::shared_ptr<int>;
    using Backend=std::shared_ptr<State>;
    using Job=std::shared_ptr<Work>;
    static inline unsigned configurations=0,opens=0,admissions=0,runs=0,consumes=0,retires=0,releases=0;
    static inline std::string failure;
    static inline bool refuse=false,uncertain=false,run_false=false;
    static inline std::atomic<bool> hold{false},entered{false};
    static inline std::vector<std::string> last_fields;
    static inline std::uint64_t last_epoch=0,last_run=0;
    static void fail(const char* point){if(failure==point)throw std::runtime_error(point);}
    static Root configure(){++configurations;fail("configure");return std::make_shared<int>(1);}
    static Backend open(const Root&,const std::vector<std::string>& f,std::uint64_t epoch){
        ++opens;fail("open");last_fields=f;last_epoch=epoch;if(refuse)return {};return std::make_shared<State>();}
    static Job recover(const Backend& b,std::uint64_t t){
        ++admissions;fail("recover");if(refuse)return {};b->ticket=t;b->done=false;b->certain=true;
        return std::make_shared<Work>(Work{b,t});}
    static Job update(const Backend& b,std::uint64_t t,const std::vector<std::string>& f,
        std::uint32_t,std::uint64_t,bool){
        ++admissions;fail("update");if(refuse)return {};last_fields=f;b->payload=f[1];b->ticket=t;b->done=false;b->recovery=false;
        return std::make_shared<Work>(Work{b,t});}
    static bool run(const Job& j){
        ++runs;entered=true;while(hold.load())std::this_thread::yield();fail("run");
        last_run=j->ticket;j->owner->done=true;j->owner->certain=!uncertain;return !run_false;}
    static Reply peek(const Backend& b,std::uint64_t t){
        fail("peek");if(!b->done||b->ticket!=t)return {2,{}};
        experimental::JournalTerminal r;r.ticket=t;r.status=b->recovery?"recovered":"updated";
        r.certain=b->certain;r.generation=7;r.covered_revision=9;r.preimages="preimage-token";
        r.slots[0]={experimental::records::State::valid,{"scope",7,b->payload}};
        r.slots[1]={experimental::records::State::missing,{"scope",99,"must not leak"}};
        return {1,terminal_data(r)};}
    static bool consume(const Backend& b,std::uint64_t t){
        fail("consume");if(!b->done||!b->certain||b->ticket!=t)return false;++consumes;b->done=false;return true;}
    static void retire(const Backend&){++retires;fail("retire");}
    static bool release(const Backend&){++releases;fail("release");return !refuse;}
};
}
