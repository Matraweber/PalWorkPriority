#include "draining_writer.hpp"
#include <condition_variable>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <chrono>
#include <vector>
using namespace pwp::experimental;
namespace {
std::mutex gate;
std::condition_variable changed;
std::uint64_t pause_revision=0,entered=0;
bool proceed=false;
bool park_pick=false,pick_entered=false,pick_proceed=false;
std::string fault;
bool fault_second=false;
bool two_streams=false, lane_waiting=false, journal_parked=false, journal_release=false;
std::atomic<unsigned> journal_entries{0};
std::atomic<unsigned> io_calls{0};
const std::string storage(32,'1'),guild(32,'2');
const std::string scope="PWP-SCOPE-1:"+storage+":"+guild+":priorities";
void check(bool ok,const char* message){if(!ok)throw std::runtime_error(message);}
void pause_at(std::uint64_t revision){std::lock_guard<std::mutex> lock(gate);pause_revision=revision;entered=0;proceed=false;}
void await_pause(){std::unique_lock<std::mutex> lock(gate);check(changed.wait_for(lock,std::chrono::seconds(10),[]{return entered!=0;}),"worker reached native test gate");}
void unpause(){std::lock_guard<std::mutex> lock(gate);proceed=true;changed.notify_all();}
void await_pick(){std::unique_lock<std::mutex> lock(gate);check(changed.wait_for(lock,std::chrono::seconds(10),[]{return pick_entered;}),"worker parked BEFORE snapshot selection");}
void release_pick(){std::lock_guard<std::mutex> lock(gate);pick_proceed=true;changed.notify_all();}
std::filesystem::path leaf(const std::wstring& root,char slot){return std::filesystem::path(root)/("pwp-record-v1-"+storage+"-"+guild+"-priorities-"+slot+".record");}
void fixture(const std::wstring& root,char slot,std::uint32_t gen,const std::string& payload){
    auto bytes=records::encode({scope,gen,payload});
    std::ofstream out(leaf(root,slot),std::ios::binary|std::ios::trunc);
    out.write(bytes.data(),static_cast<std::streamsize>(bytes.size()));check(bool(out),"fixture write");
}
records::Read read(const std::wstring& root,char slot){
    auto r=record_reader::read(root,std::wstring(32,L'1'),std::wstring(32,L'2'),L"priorities",slot);
    check(r.error==0,"checked read error");return r.read;
}
void recovered(const std::unique_ptr<DrainingWriter>& w,bool missing){
    auto r=w->wait_recovery();check(r.phase==DrainPhase::awaiting_validation&&r.terminal.has_value(),"recovery awaited");
    check(!w->submit("unvalidated"),"no admission before caller schema validation");
    check(!w->approve_recovery(missing?RecoveryApproval::existing:RecoveryApproval::initialize_missing),"wrong recovery approval refused");
    // Fixtures deliberately use opaque synthetic payloads. In an integration the
    // caller must validate BOTH typed schemas here, not just records::candidate.
    if(!missing){
        check(r.terminal->slots[0].record.payload=="seed-a"&&r.terminal->slots[1].record.payload=="seed-b","caller inspected BOTH fixtures");
    }
    check(w->approve_recovery(missing?RecoveryApproval::initialize_missing:RecoveryApproval::existing),"explicit recovery approval");
    check(!w->approve_recovery(RecoveryApproval::existing),"approval once");
}
}
namespace pwp::experimental {
void draining_writer_test_lane_waiting(){
    std::lock_guard<std::mutex> lock(gate);lane_waiting=true;changed.notify_all();
}
void draining_writer_test_before_pick(){
    std::unique_lock<std::mutex> lock(gate);
    if(!park_pick)return;
    pick_entered=true;changed.notify_all();changed.wait(lock,[]{return pick_proceed;});park_pick=false;
}
void draining_writer_test_before_update(std::uint64_t revision){
    ++io_calls;
    std::unique_lock<std::mutex> lock(gate);
    if(revision!=pause_revision)return;
    entered=revision;changed.notify_all();changed.wait(lock,[]{return proceed;});
}
}
#ifdef PWP_JOURNAL_TESTING
namespace pwp::experimental::journal {
unsigned long journal_test_point(const char* point){
    if(two_streams && std::string(point)=="after_read") {
        const auto count=++journal_entries;
        if(count==3) {
            std::unique_lock<std::mutex> lock(gate);journal_parked=true;changed.notify_all();
            check(changed.wait_for(lock,std::chrono::seconds(20),[]{return journal_release;}),"release held real journal gate");
        }
    }
    return fault==point&&(!fault_second||io_calls==2)?29UL:0UL;
}
}
#endif
int wmain(int argc,wchar_t** argv){
    try {
        check(argc==3,"root and scenario required");
        const std::wstring path=argv[1],scenario=argv[2];
        auto root=RootCapability::open(path,"draining-writer-test");check(bool(root),"pinned root");
        OwnerBinding binding{scope,"native-drain",1};
        if(scenario==L"two-streams") {
            two_streams=true;
            auto a=DrainingWriter::open(root,binding);
            auto b=DrainingWriter::open(root,{"PWP-SCOPE-1:"+storage+":"+guild+":limits","native-drain",1});
            check(a&&b,"two distinct stream owners");
            for(auto* w:{a.get(),b.get()}) {
                check(w->start_recovery(),"two-stream recovery start");
                check(w->wait_recovery().phase==DrainPhase::awaiting_validation,"two-stream missing recovery");
                check(w->approve_recovery(RecoveryApproval::initialize_missing),"approve positive missing");
                check(w->submit("first")==1,"first exact initialization");
                const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(10);
                while(w->status().committed!=1 && std::chrono::steady_clock::now()<deadline)std::this_thread::yield();
                check(w->status().committed==1,"initialization committed");
            }
            check(a->submit("middle-priorities")==2,"first worker admitted");
            {std::unique_lock<std::mutex> lock(gate);check(changed.wait_for(lock,std::chrono::seconds(10),[]{return journal_parked;}),"first holds actual root journal gate");}
            check(b->submit("middle-limits")==2,"second worker admitted");
            const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(10);
            bool waiting=false;
            while(std::chrono::steady_clock::now()<deadline) {
                {std::lock_guard<std::mutex> lock(gate);waiting=lane_waiting;}
                if(waiting||b->status().phase==DrainPhase::blocked)break;
                std::this_thread::yield();
            }
            const auto before=b->status();
            const auto ar=a->submit("latest-priorities"),br=b->submit("latest-limits");
            {std::lock_guard<std::mutex> lock(gate);journal_release=true;changed.notify_all();}
            const auto ra=a->drain(),rb=b->drain();
            if(before.phase==DrainPhase::blocked) {
                std::cerr<<"REPRO second worker blocked status="<<(before.terminal?before.terminal->status:"missing")
                    <<" error="<<(before.terminal?before.terminal->error:0)<<" third_admission="<<br<<'\n';
            }
            check(waiting&&before.phase==DrainPhase::ready&&ar==3&&br==3,"second waits on native lane, third revisions still admitted");
            check(ra.phase==DrainPhase::closed&&rb.phase==DrainPhase::closed&&ra.committed==3&&rb.committed==3,"both streams drain latest");
            check(ra.generation==3&&rb.generation==3&&ra.cleanup_error==0&&rb.cleanup_error==0,"both exact physical generations and clean release");
            for(const auto* stream:{L"priorities",L"limits"}) {
                const auto r=record_reader::read(path,std::wstring(32,L'1'),std::wstring(32,L'2'),stream,'A');
                check(r.error==0&&r.read.state==records::State::valid&&r.read.record.generation==3,"checked latest generation");
                check(r.read.record.payload==(std::wstring(stream)==L"priorities"?"latest-priorities":"latest-limits"),"exact latest stream payload");
            }
            check(std::distance(std::filesystem::directory_iterator(path),std::filesystem::directory_iterator{})==4,"no retained artifacts");
            std::cout<<"PASS deterministic same-root workers: held real journal gate, native wait, both latest revisions\n";return 0;
        }
        if(scenario==L"capacity") {
            std::vector<std::unique_ptr<DrainingWriter>> writers;
            for(unsigned i=0;i<8;++i){
                auto different=binding;different.scope="PWP-SCOPE-1:"+storage+":"+std::string(32,"3456789a"[i])+":priorities";
                auto one=DrainingWriter::open(root,different);check(bool(one),"bounded coordinator admission");
                check(one->start_recovery(),"postcheck start");
                check(one->wait_recovery().phase==DrainPhase::awaiting_validation,"bounded recovery");
                writers.push_back(std::move(one));
            }
            check(!DrainingWriter::open(root,binding),"ninth live coordinator refused");
            for(auto& one:writers)check(one->drain().phase==DrainPhase::closed,"bounded coordinators close");
            writers.clear();
            auto again=DrainingWriter::open(root,binding);check(bool(again),"released capacity reusable");
            check(again->drain().phase==DrainPhase::closed,"dormant close needs no IO");
            std::cout<<"PASS bounded eight coordinators and immediate close\n";return 0;
        }
        const bool existing=scenario==L"existing"||scenario==L"warning";
        if(existing){fixture(path,'A',4,"seed-a");fixture(path,'B',5,"seed-b");}
        if(scenario==L"blocked"||scenario==L"inert") {
            std::ofstream out(leaf(path,'A'),std::ios::binary);out<<"corrupt";out.close();
        }
        auto w=DrainingWriter::open(root,binding);check(bool(w),"coordinator");
        check(w->status().phase==DrainPhase::dormant&&!w->submit("ungranted"),"open is inert owner claim only");
        if(scenario==L"inert") {
            check(!w->status().terminal&&w->drain().phase==DrainPhase::closed,"inert close ignores corrupt disk rather than reading it");
            check(!w->start_recovery()&&io_calls==0,"no delayed start after close");
            check(read(path,'A').state==records::State::corrupt,"corrupt fixture unchanged");
            auto b=JournalBackend::open(root,binding);check(bool(b),"inert owner released");b->retire();check(b->release(),"cleanup");
            std::cout<<"PASS inert owner claim does not recover or activate corrupt disk\n";return 0;
        }
        check(w->start_recovery()&&!w->start_recovery(),"separate one-shot postcheck recovery start");
        if(scenario==L"blocked") {
            auto r=w->wait_recovery();check(r.phase==DrainPhase::blocked,"no recovery candidate blocks");
            check(!w->approve_recovery(RecoveryApproval::initialize_missing)&&!w->submit("no"),"corrupt is not missing");
            check(w->drain().phase==DrainPhase::blocked,"blocked drain");
            w.reset();check(!JournalBackend::open(root,binding),"dropped failed coordinator retains owner");
            std::cout<<"PASS blocked recovery retains owner\n";return 0;
        }
        if(scenario==L"unapproved") {
            check(w->wait_recovery().phase==DrainPhase::awaiting_validation,"unapproved recovery");
            check(w->drain().phase==DrainPhase::closed&&io_calls==0,"close without approval performs no writes");
            auto b=JournalBackend::open(root,binding);check(bool(b),"empty close releases");b->retire();check(b->release(),"cleanup");
            std::cout<<"PASS unapproved close no writes\n";return 0;
        }
        {std::lock_guard<std::mutex> lock(gate);park_pick=!existing;}
        recovered(w,!existing);
        if(!existing)await_pick();
        check(!w->submit(std::string(records::max_payload+1,'x')),"oversize definitely refused");
        pause_at(1);
        std::string first="exact-init";
        check(w->submit(first)==1,"first admission");first="mutated by caller";
        if(existing)await_pause();
        check(w->submit("superseded")==2,"second admission");
        const std::string latest(records::max_payload,'z');
        check(w->submit(latest)==3,"latest admission");
        if(!existing){
            check(io_calls==0,"all three accepted BEFORE any worker snapshot selection");
            release_pick();await_pause();
        }
        if(scenario==L"destructor") {
            unpause();w.reset(); // actual destructor closes and joins its worker
            auto a=read(path,'A'),b=read(path,'B');
            check(a.record.payload=="exact-init"&&b.record.payload==latest&&b.record.generation==2,"destructor drains exact latest");
            auto reopened=JournalBackend::open(root,binding);check(bool(reopened),"destructor released owner only after drain");
            reopened->retire();check(reopened->release(),"fixture release");
            std::cout<<"PASS destructor drains accepted native tail\n";return 0;
        }
        if(scenario==L"conflict")fixture(path,'B',1,"external");
        if(scenario==L"uncertain")fault="after_publish";
        if(scenario==L"uncertain-tail"){fault="after_publish";fault_second=true;}
        if(scenario==L"ioerror")fault="before_write";
        if(scenario==L"warning")fault="before_disposition";
        std::atomic<bool> returned{false};DrainStatus result;
        w->close(); // deterministic fence independent of test-thread scheduling
        std::thread barrier([&]{result=w->drain();returned=true;});
        DrainStatus concurrent_result;
        std::thread second_barrier([&]{concurrent_result=w->drain();});
        check(w->status().phase==DrainPhase::closing,"close admission fence");
        check(!w->submit("late")&&!returned,"barrier waits while worker owns pending bytes");
        check(!JournalBackend::open(root,binding),"cannot replace draining owner");
        const std::weak_ptr<const RootCapability> captured=root;
        root.reset(); // worker/coordinator alone retain the original capability
        unpause();barrier.join();second_barrier.join();
        check(concurrent_result.phase==result.phase&&concurrent_result.committed==result.committed,"concurrent barriers agree");
        const bool uncertain_tail=scenario==L"uncertain-tail";
        const bool failure=scenario==L"conflict"||scenario==L"uncertain"||scenario==L"ioerror"||uncertain_tail;
        if(failure){
            check(result.phase==DrainPhase::blocked&&result.accepted==3&&result.committed==(uncertain_tail?1U:0U),"no false ACK");
            check(io_calls==(uncertain_tail?2U:1U)&&result.terminal.has_value(),"failure never dispatches further work");
            check(result.terminal->status==(scenario==L"conflict"?"conflict":scenario==L"uncertain"||uncertain_tail?"uncertain":"io_error"),"actual journal fault classification");
            check(!w->submit("retry")&&w->drain().phase==DrainPhase::blocked,"no retry/release");
            w.reset();check(!SaveOwner::claim(binding),"failure retains owner after destruction");
            if(scenario==L"uncertain")check(read(path,'A').record.payload=="exact-init","uncertain actually published first bytes");
            if(uncertain_tail)check(read(path,'A').record.payload=="exact-init"&&read(path,'B').record.payload==latest,"uncertain tail published but not acknowledged");
            if(scenario==L"conflict")check(read(path,'B').record.payload=="external","external preimage preserved");
            std::cout<<"PASS failure retains owner and unresolved accepted tail\n";return 0;
        }
        check(result.phase==DrainPhase::closed&&result.committed==3&&result.accepted==3,"drain covers latest");
        check(result.generation==(existing?7U:2U)&&io_calls==2,"logical3 is two publications");
        check(result.cleanup_error==(scenario==L"warning"?29U:0U),"cleanup warning survives drain summary");
        check(w->drain().phase==DrainPhase::closed,"idempotent barrier");
        auto a=read(path,'A'),b=read(path,'B');
        const auto selected=records::candidate(a,b);
        check(selected>=0&&(selected==0?a:b).record.payload==latest,"checked reopen newest full maximum bytes");
        check((selected==0?b:a).record.payload=="exact-init","first snapshot was not coalesced or mutated");
        root=captured.lock();check(bool(root),"original capability survived caller drop");
        auto reopened=JournalBackend::open(root,{scope,"after-drain",2});
        check(bool(reopened),"successful drain releases to real backend reopen");
        auto job=reopened->recover(1);check(job&&job->run(),"reopened backend recovery");
        auto terminal=reopened->peek(1);
        check(terminal&&terminal->certain&&terminal->generation==result.generation,"reopen physical generation");
        const auto newest=records::candidate(terminal->slots[0],terminal->slots[1]);
        check(newest>=0&&terminal->slots[static_cast<unsigned>(newest)].record.payload==latest,"reopened backend exact latest payload");
        check(reopened->consume(1),"consume reopened recovery");reopened->retire();check(reopened->release(),"release reopened owner");
        const auto files=std::distance(std::filesystem::directory_iterator(path),std::filesystem::directory_iterator{});
        check(files==(scenario==L"warning"?4:2),"only observable cleanup failure retains this-call backups");
        std::cout<<"PASS native drain: exact first + latest, logical3/physical2, no Lua callbacks, checked reopen\n";
        return 0;
    }catch(const std::exception& e){release_pick();unpause();std::cerr<<"FAIL "<<e.what()<<'\n';return 1;}
}
