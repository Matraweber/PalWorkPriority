// Actual entry + actual filesystem backend; ONLY LuaMadeSimple is mocked.
#ifdef PWP_LEGACY_ENTRY_TEST
#include "build/entry_legacy_mutant.inc"
#elif defined(PWP_UNROOTED_ENTRY_TEST)
#include "build/entry_unrooted_mutant.inc"
#else
#include "entry.cpp"
#endif
#include "build/real_test_payload.hpp"
#include <filesystem>
#include <iostream>
#include <fstream>
#include <condition_variable>
#include <chrono>
using namespace pwp::draining_bridge;
namespace ex=pwp::experimental;
namespace pwp::experimental {
// Defined only in the PWP_DRAINING_WRITER_TESTING writer object linked here.
extern void (*draining_writer_test_before_join)(std::thread::id,std::uint64_t,std::uint64_t);
}
namespace {
std::mutex test_gate;std::condition_variable changed;
bool park=false,parked=false,proceed=false;
// Separate from the legacy one-worker gate: each enrolled worker has its own
// release bit. All access is under test_gate, including bounded error release.
bool dual_park=false,dual_release[2]={false,false},join_entered[2]={false,false},control_cancel=false;
std::vector<std::thread::id> dual_workers;
std::atomic<unsigned> updates=0;
std::atomic<DWORD> worker_thread=0;
std::string fault;
const std::string world(32,'1'),guild(32,'2');
void check(bool ok,const char* why){if(!ok)throw std::runtime_error(why);}
std::string hex(std::string_view bytes){std::string out;for(unsigned char c:bytes){out+="0123456789abcdef"[c>>4];out+="0123456789abcdef"[c&15];}return out;}
struct Result{int count=0,status=-99;std::string data;};
Result call(int cmd,int handle=0,int ticket=0,const std::vector<std::string>& fields={}) {
    const auto input=hex(pack(fields));lua_State s{{cmd,handle,ticket,input,static_cast<std::int64_t>(input.size())},{},false};
    int count=luaopen_pwp_draining_bridge(&s);if(!count)return {};
    check(count==6&&s.stack.size()==7&&s.rooted_read,"rooted entry stack");
    check(s.reads==std::vector<int>({5,3,2,1})&&s.stack[3].number==GetCurrentThreadId(),"descending reads / thread metadata");
    check(s.stack[5].number>=s.stack[4].number&&s.stack[6].number>0,"QPC metadata");
    return {count,static_cast<int>(s.stack[1].number),*s.stack[2].text};
}
std::vector<std::string> reply(const Result& r,std::size_t count,const char* why){
    check(r.count==6&&r.status==1,why);auto fields=unpack(r.data);check(fields.size()==count,why);return fields;
}
std::vector<std::string> status(int h){return reply(call(6,h),16,"status16 success");}
int owner(const std::string& g=guild,const std::string& stream="priorities"){
    return std::stoi(reply(call(1,1,0,{world,g,stream,"test-inc","7"}),1,"owner reply")[0]);
}
std::vector<std::string> recovery(int h) {
    auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(10);
    while(std::chrono::steady_clock::now()<deadline) {
        auto r=call(3,h);if(r.status==1)return reply(r,16,"recovery16");
        if(status(h)[5]=="blocked")throw std::runtime_error("recovery blocked");
        std::this_thread::yield();
    }throw std::runtime_error("recovery timeout");
}
void cleanup(int h){check(call(9,h).status==1&&call(9,h).status==1,"cleanup idempotent");}
void drain(int h,int ticket){check(reply(call(8,h,ticket),16,"drain16")[5]=="closed","closed joined");}
void await_park(){std::unique_lock<std::mutex> lock(test_gate);check(changed.wait_for(lock,std::chrono::seconds(10),[]{return parked;}),"native selection gate");}
void release_park(){std::lock_guard<std::mutex> lock(test_gate);proceed=true;changed.notify_all();}
void await_dual(unsigned count){
    std::unique_lock<std::mutex> lock(test_gate);
    check(changed.wait_for(lock,std::chrono::seconds(10),[&]{return dual_workers.size()==count;}),"both native workers parked");
}
void pending_join(std::thread::id worker,std::uint64_t accepted,std::uint64_t committed){
    std::lock_guard<std::mutex> lock(test_gate);
    if(!dual_park)return; // later read-only recovery owners have no parked work
    unsigned lane=0;while(lane<dual_workers.size()&&dual_workers[lane]!=worker)++lane;
    check(lane<2&&!dual_release[lane]&&!join_entered[lane],"original pending worker at real join boundary");
    check(accepted==3&&committed==0,"real drain entered with accepted greater than committed");
    join_entered[lane]=true;changed.notify_all();
}
void pending_two_streams(int priorities){
    const int limits=owner(guild,"limits");check(limits!=priorities,"separate original stream handles");
    int handles[2]={limits,priorities};
    const std::string streams[2]={"limits","priorities"};
    const std::string first[2]={pwp_limits_payload_1,pwp_typed_payload_1};
    const std::string latest[2]={pwp_limits_payload_2,pwp_combined_priority_payload};
    // Seed real journals through entry/filesystem, then reopen as EXISTING
    // owners. The pending test concerns updates, not first-install admission.
    for(unsigned i=0;i<2;++i){
        const int seed=handles[i];check(call(2,seed,1).status==1,"seed start");
        const auto r=recovery(seed);check(r[10]=="missing"&&r[13]=="missing","seed positive absence");
        check(call(4,seed,2,{"initialize_missing"}).status==1,"seed initialization");
        check(reply(call(5,seed,3,{first[i]}),1,"seed submit")[0]=="1","seed revision1");
        drain(seed,4);cleanup(seed);handles[i]=owner(guild,streams[i]);
    }
    check(updates==2,"both seed journals published");
    {std::lock_guard<std::mutex> lock(test_gate);dual_park=true;}
    for(unsigned i=0;i<2;++i){
        const int h=handles[i];check(call(2,h,1).status==1,"two-stream start");
        const auto r=recovery(h);check(r[10]=="valid"&&r[11]=="1"&&r[12]==first[i]
            &&r[13]=="missing","two-stream existing seed recovery");
        check(call(4,h,2,{"existing"}).status==1,"two-stream existing approval");
        await_dual(i+1); // enrollment order identifies limits, then priorities
        check(reply(call(5,h,3,{first[i]}),1,"first update reply")[0]=="1","two-stream first update");
        check(reply(call(5,h,4,{first[i]}),1,"superseded update reply")[0]=="2","two-stream superseded revision");
        check(reply(call(5,h,5,{latest[i]}),1,"latest update reply")[0]=="3","two-stream latest revision");
    }
    for(int h:handles){const auto s=status(h);check(s[3]=="3"&&s[4]=="0","BOTH accepted greater than committed before drain");}
    check(updates==2,"neither parked worker published an update early");
    check(dual_workers[0]!=dual_workers[1]&&dual_workers[0]!=std::this_thread::get_id()
        &&dual_workers[1]!=std::this_thread::get_id(),"two distinct native worker threads");
    std::cout<<"BOTH_PENDING limits=3/0 priorities=3/0\n";
    // Match combined cleanup ordering: BOTH admissions closed before ANY join.
    for(int h:handles)check(call(7,h,6).status==1,"retire both original streams before either drain");
    for(int h:handles){
        const auto refused=call(5,h,7,{"late submit must be refused"});
        check(refused.count==6&&refused.status==0,"late submit refused for each closed stream");
        const auto s=status(h);check(s[3]=="3"&&s[4]=="0"&&s[5]=="closing","both fenced and still pending");
    }
    bool control_ok=true;
    // This thread touches ONLY test synchronization, never Lua/entry/owners.
    std::thread controller([&]{
        std::unique_lock<std::mutex> lock(test_gate);
        for(unsigned i=0;i<2;++i){
            if(!changed.wait_for(lock,std::chrono::seconds(10),[&]{return control_cancel||join_entered[i];})){
                control_ok=false;dual_release[0]=dual_release[1]=true;changed.notify_all();return;
            }
            if(control_cancel)return;
            dual_release[i]=true;changed.notify_all();
        }
    });
    std::exception_ptr failure;
    try{
        for(unsigned i=0;i<2;++i){
            const int h=handles[i];
            const auto s=reply(call(8,h,8),16,"original drain reply16");
            check(s[5]=="closed"&&s[3]=="3"&&s[4]=="3"&&s[7]=="2","original latest fully drained");
            if(i==0){const auto pending=status(handles[1]);check(pending[3]=="3"&&pending[4]=="0",
                "second original still pending after first drain");}
            cleanup(h);
        }
    }catch(...){failure=std::current_exception();}
    {std::lock_guard<std::mutex> lock(test_gate);control_cancel=true;dual_release[0]=dual_release[1]=true;changed.notify_all();}
    controller.join();
    if(failure)std::rethrow_exception(failure);
    check(control_ok&&updates==4,"bounded releases: one seed and one coalesced update per stream");
    check(join_entered[0]&&join_entered[1],"both original joins observed while pending");
    std::cout<<"JOIN_PENDING limits=3/0 priorities=3/0\n";
    {std::lock_guard<std::mutex> lock(test_gate);dual_park=false;}
    for(unsigned i=0;i<2;++i){
        const int fresh=owner(guild,streams[i]);check(fresh>handles[0]&&fresh>handles[1],"fresh non-reused recovery owner");
        check(call(2,fresh,1).status==1,"reopen drained stream");const auto r=recovery(fresh);
        check(r[10]=="valid"&&r[13]=="valid"&&r[11]=="1"&&r[14]=="2"
            &&r[12]==first[i]&&r[15]==latest[i],"exact initial and latest stream payloads recovered");
        std::cout<<"COMBINED_"<<streams[i]<<"_HEX="<<hex(r[15])<<'\n';
        drain(fresh,2);cleanup(fresh);
    }
    check(lua_State::worker_calls==0,"two-stream workers never call Lua wrapper");
    std::cout<<"PASS two existing pending streams: both retired, late submits refused, sequential original-owner joins, exact latest typed recovery, no worker Lua\n";
}
}
namespace pwp::experimental {
void draining_writer_test_before_pick(){
    lua_State::on_native_thread=true;worker_thread=GetCurrentThreadId();
    std::unique_lock<std::mutex> lock(test_gate);
    if(dual_park){
        const auto tid=std::this_thread::get_id();unsigned lane=0;
        while(lane<dual_workers.size()&&dual_workers[lane]!=tid)++lane;
        if(lane==dual_workers.size())dual_workers.push_back(tid);
        check(lane<2,"bounded dual-worker enrollment");changed.notify_all();
        check(changed.wait_for(lock,std::chrono::seconds(20),[&]{return dual_release[lane];}),"bounded dual-worker release");
        return;
    }
    if(!park)return;
    parked=true;changed.notify_all();changed.wait(lock,[]{return proceed;});park=false;
}
void draining_writer_test_before_update(std::uint64_t){++updates;lua_State::on_native_thread=true;worker_thread=GetCurrentThreadId();}
}
namespace pwp::experimental::journal {
unsigned long journal_test_point(const char* point){return fault==point?29UL:0UL;}
}
int main(int argc,char** argv) {
    try {
        const std::string mode=argc>1?argv[1]:"normal";
        check(call(0).status==1,"REGRESSION: actual entry popped-argument/rooted-input configure failed");
        const int h=owner();
        if(mode=="two-stream-pending"){
            ex::draining_writer_test_before_join=pending_join;
            pending_two_streams(h);ex::draining_writer_test_before_join=nullptr;return 0;
        }
        if(mode=="teardown") {
            check(call(2,h,1).status==1,"start");recovery(h);
            // Return normally with an awaiting-validation worker. No explicit
            // cleanup: CRT teardown must NOT destroy the registry and join it.
            std::cout<<"PASS intentional process-lifetime registry, live worker at normal CRT exit\n";return 0;
        }
        if(mode=="capacity") {
            std::vector<int> handles{h};for(char ch='3';ch<='9';++ch)handles.push_back(owner(std::string(32,ch)));
            check(call(1,1,0,{world,std::string(32,'a'),"priorities","capacity","1"}).status==0,"eight active bound");
            for(int id:handles){drain(id,1);cleanup(id);}
            for(int i=8;i<128;++i){int id=owner();check(id==i+1,"monotonic handle");drain(id,1);cleanup(id);}
            check(call(1,1,0,{world,guild,"priorities","full","1"}).status==0,"128 handles no reuse");
            std::cout<<"PASS bounded active/total registry\n";return 0;
        }
        check(status(h)[5]=="dormant"&&std::filesystem::is_empty(pwp_draining_test_root),"owner-only no files/recovery");
        check(call(5,h,1,{"before recovery"}).status==0&&status(h)[3]=="0","no preapproval admission");
        // Bad shape/length/hex inputs execute actual parser and cannot start IO.
        for(const auto& bad:std::vector<std::string>{"0","gg","00000000ff"}) {
            lua_State s{{2,h,2,bad,static_cast<std::int64_t>(bad.size())},{},false};
            check(luaopen_pwp_draining_bridge(&s)==0,"invalid hex/packet");
        }
        lua_State wrong_length{{2,h,2,std::string{},2},{},false};check(luaopen_pwp_draining_bridge(&wrong_length)==0,"length equality");
        lua_State wrong_shape{{2,h},{},false};check(luaopen_pwp_draining_bridge(&wrong_shape)==0,"fixed five arguments");
        for(int cmd=0;cmd<=9;++cmd) {
            Result r;std::thread t([&]{
                if(cmd==0)r=call(0);
                else if(cmd==1)r=call(1,1,0,{world,std::string(32,'3'),"priorities","wrong-thread","7"});
                else if(cmd==4)r=call(cmd,h,2,{"initialize_missing"});
                else if(cmd==5)r=call(cmd,h,2,{"otherwise-valid-payload"});
                else r=call(cmd,h,(cmd==3||cmd==6||cmd==9)?0:2);
            });t.join();
            check(r.status==0,"wrong thread refused before action");
        }
        check(status(h)[5]=="dormant"&&updates==0,"wrong thread no action");
        check(call(2,h,2).status==1,"start recovery");
        auto r=recovery(h);check(r[10]=="missing"&&r[13]=="missing","positive absence");
        check(r[11]=="0"&&r[12].empty()&&r[14]=="0"&&r[15].empty(),"invalid slot normalization");
        check(call(4,h,3,{"existing"}).status==0,"cannot approve existing on missing");
        {std::lock_guard<std::mutex> lock(test_gate);park=true;}
        check(call(4,h,4,{"initialize_missing"}).status==1,"typed-side missing approval");await_park();
        Result wrong_submit;
        std::thread wrong([&]{wrong_submit=call(5,h,5,{"ready but wrong thread"});});wrong.join();
        check(wrong_submit.status==0&&status(h)[3]=="0","otherwise admissible wrong-thread submit refused");
        check(call(9,h).status==0,"cleanup cannot destroy live writer");
        check(call(5,h,5,{std::string(max_payload+1,'x')}).status==0,"oversize refusal");
        check(reply(call(5,h,5,{pwp_typed_payload_1}),1,"init submit reply")[0]=="1","first init copied");
        lua_State::lose_reply=true;check(call(5,h,6,{"superseded"}).count==0,"lost accepted reply");
        r=status(h);check(r[3]=="2"&&r[12]=="6"&&r[13]=="5"&&r[14]=="2"&&r[15]=="accepted","recover lost reply outcome");
        check(call(5,h,6,{"must not replay"}).status==0&&status(h)[3]=="2","duplicate lost ticket refused");
        check(reply(call(5,h,7,{pwp_typed_payload_2}),1,"latest submit reply")[0]=="3","latest copied revision3");
        check(status(h)[4]=="0"&&updates==0,"accepted never durable, native selection parked");
        if(mode=="uncertain")fault="after_publish";
        release_park();
        check(call(7,h,8).status==1&&call(5,h,9,{"after close"}).status==0,"close fences submit");
        r=reply(call(8,h,10),16,"normal drain reply16");
        if(mode=="uncertain") {
            check(r[5]=="blocked"&&r[4]=="0"&&r[3]=="3"&&call(9,h).status==0,"uncertain retains registry, never acknowledges");
            check(call(1,1,0,{world,guild,"priorities","other","8"}).status==0,"uncertain owner cannot reopen");
            std::cout<<"PASS real post-publication failure retains blocked owner, no committed ACK\n";return 0;
        }
        check(r[5]=="closed"&&r[3]=="3"&&r[4]=="3"&&r[7]=="2"&&updates==2,"coalesced latest exactly completed");
        check(worker_thread!=GetCurrentThreadId()&&worker_thread!=0,"native worker route");cleanup(h);
        const int h2=owner();check(h2>h&&call(2,h,11).status==0,"no old handle resurrection");
        check(call(2,h2,1).status==1,"fresh recovery");r=recovery(h2);
        check(r[12]==pwp_typed_payload_1&&r[15]==pwp_typed_payload_2&&r[11]=="1"&&r[14]=="2","both exact typed generations");
        std::cout<<"TYPED_A_HEX="<<hex(r[12])<<"\nTYPED_B_HEX="<<hex(r[15])<<'\n';
        check(call(4,h2,2,{"initialize_missing"}).status==0,"existing cannot initialize");
        check(call(4,h2,3,{"existing"}).status==1,"both typed schemas caller approved");
        // Binary transport is opaque, not an assertion of typed settings validity.
        const std::string binary("binary\0payload",14);
        check(call(5,h2,4,{binary}).status==1,"binary NUL input copied");drain(h2,5);cleanup(h2);
        const int h3=owner();check(call(2,h3,1).status==1,"binary recovery");r=recovery(h3);
        check((r[11]=="3"&&r[12]==binary)||(r[14]=="3"&&r[15]==binary),"binary NUL exact output copied");
        drain(h3,2);cleanup(h3); // no typed approval for synthetic binary payload
        check(lua_State::worker_calls==0,"native writer never calls Lua wrapper");
        std::cout<<"PASS actual entry/real filesystem: init preserved, coalesced latest, explicit drain, lost reply, binary, bad input and thread gates\n";
        return 0;
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
