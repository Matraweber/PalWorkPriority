// Disposable-process test ONLY. Real writer, journal, filesystem and recovery.
// The parent supplies private roots; never load this into a game process.
#include "draining_writer.hpp"
#include "draining_crash_payloads.hpp"
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <Windows.h>
#include <atomic>
#include <chrono>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <condition_variable>
#include <cstdlib>
using namespace pwp::experimental;
namespace {
const std::string storage(32,'1'),guild(32,'2');
std::atomic<bool> armed=false;
std::string selected,point,scenario,nonce;
std::filesystem::path marker;
bool concurrent=false,released[2]={false,false};
unsigned entered=0;
std::mutex gate;
std::condition_variable changed;
DrainingWriter* target_writer=nullptr;
DrainingWriter* other_writer=nullptr;
void check(bool value,const char* why){if(!value)throw std::runtime_error(why);}
std::string scope(const std::string& stream){return "PWP-SCOPE-1:"+storage+":"+guild+":"+stream;}
const std::string& payload(const std::string& stream,bool latest){
    return stream=="limits"?(latest?crash_limits_new:crash_limits_old):(latest?crash_priorities_new:crash_priorities_old);
}
std::unique_ptr<DrainingWriter> open(const std::shared_ptr<const RootCapability>& root,const std::string& stream,bool missing){
    auto w=DrainingWriter::open(root,{scope(stream),"disposable-crash-fixture",1});check(bool(w),"open original owner");
    check(w->start_recovery(),"start recovery");auto s=w->wait_recovery();
    check(s.phase==DrainPhase::awaiting_validation&&s.terminal.has_value(),"actual recovery terminal");
    const auto& slots=s.terminal->slots;
    check(records::candidate(slots[0],slots[1])==(missing?-1:1),"expected initial selection");
    if(!missing)for(const auto& slot:slots)check(slot.state==records::State::valid
        &&slot.record.payload==payload(stream,false),"both exact old typed seeds");
    check(w->approve_recovery(missing?RecoveryApproval::initialize_missing:RecoveryApproval::existing),"explicit approval");
    return w;
}
void await_commit(DrainingWriter& w,std::uint64_t revision){
    const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(10);
    while(std::chrono::steady_clock::now()<deadline){auto s=w.status();
        check(s.phase!=DrainPhase::blocked,"writer blocked");if(s.committed==revision)return;std::this_thread::yield();}
    throw std::runtime_error("commit timeout");
}
void drain(DrainingWriter& w){auto s=w.drain();check(s.phase==DrainPhase::closed&&s.accepted==s.committed,"original owner drain");}
std::string hex(std::string_view s){std::string r;for(unsigned char c:s){r+="0123456789abcdef"[c>>4];r+="0123456789abcdef"[c&15];}return r;}
}
namespace pwp::experimental {
void draining_writer_test_before_pick(){}
void draining_writer_test_before_update(std::uint64_t){
    if(!concurrent)return;
    std::unique_lock<std::mutex> lock(gate);const auto lane=entered++;
    if(lane>=2)TerminateProcess(GetCurrentProcess(),92);
    changed.notify_all();
    // This hook is BEFORE PublicationLane construction in the actual worker.
    if(!changed.wait_for(lock,std::chrono::seconds(20),[&]{return released[lane];}))
        TerminateProcess(GetCurrentProcess(),92);
}
}
namespace pwp::experimental::journal {
unsigned long journal_test_point(const char* at){
    if(!armed.load(std::memory_order_acquire)||point!=at)return 0;
    // Point evidence is outside the journal directory, flushed and closed before
    // abrupt self-termination. No C++ destructors, writer drain or CRT exit path.
    std::string text=point+"\t"+selected+"\t"+scenario+"\t"+nonce+"\t"+
        std::to_string(GetCurrentProcessId())+"\t"+std::to_string(GetCurrentThreadId());
    if(concurrent){
        const auto a=target_writer->status(),b=other_writer->status();
        if(a.accepted!=1||a.committed!=0||b.accepted!=1||b.committed!=0)TerminateProcess(GetCurrentProcess(),92);
        text+="\t1\t0\t1\t0"; // actual per-original-owner observations AT boundary
    }
    text+='\n';
    HANDLE file=CreateFileW(marker.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL|FILE_FLAG_WRITE_THROUGH,nullptr);
    if(file==INVALID_HANDLE_VALUE)TerminateProcess(GetCurrentProcess(),92);
    DWORD wrote=0;
    bool ok=WriteFile(file,text.data(),static_cast<DWORD>(text.size()),&wrote,nullptr)!=0&&wrote==text.size();
    ok=FlushFileBuffers(file)!=0&&ok;ok=CloseHandle(file)!=0&&ok;
    if(!ok)TerminateProcess(GetCurrentProcess(),92);
#ifndef PWP_CRASH_INERT
    TerminateProcess(GetCurrentProcess(),91);
    std::abort(); // a failed termination is not a successful crash test
#else
    armed=false; // negative mutant reaches the point but DOES NOT interrupt
#endif
    return 0;
}
}
int wmain(int argc,wchar_t** argv){try{
    check(argc>=3,"private root and mode required");
    const std::filesystem::path path=argv[1];const std::wstring mode=argv[2];
    auto root=RootCapability::open(path.wstring(),"disposable-writer-crash-test");check(bool(root),"private root capability");
    if(mode==L"seed"){
        check(std::filesystem::is_empty(path),"seed root must be empty");
        for(const auto& stream:{std::string("limits"),std::string("priorities")}){
            auto w=open(root,stream,true);
            check(w->submit(payload(stream,false))==1,"seed generation1");await_commit(*w,1);
            check(w->submit(payload(stream,false))==2,"seed generation2");drain(*w);
        }
        std::cout<<"SEEDED two typed existing pairs\n";return 0;
    }
    if(mode==L"recover"){
        for(const auto& stream:{std::string("limits"),std::string("priorities")}){
            auto w=DrainingWriter::open(root,{scope(stream),"fresh-recovery-process",2});check(bool(w),"fresh owner");
            check(w->start_recovery(),"fresh recovery");auto s=w->wait_recovery();
            check(s.phase==DrainPhase::awaiting_validation&&s.terminal.has_value(),"fresh readable recovery");
            const auto& slots=s.terminal->slots;const auto best=records::candidate(slots[0],slots[1]);check(best>=0,"valid recovery candidate");
            for(unsigned i=0;i<2;++i){const auto& slot=slots[i];
                check(slot.state==records::State::valid||slot.state==records::State::missing,"no unsafe recovered slot");
                if(slot.state==records::State::valid){
                    check(slot.record.payload==payload(stream,false)||slot.record.payload==payload(stream,true),"no partial/foreign bytes");
                    std::cout<<"SLOT\t"<<stream<<'\t'<<(i?'B':'A')<<"\tvalid\t"<<slot.record.generation<<'\t'<<hex(slot.record.payload)<<'\n';
                }else std::cout<<"SLOT\t"<<stream<<'\t'<<(i?'B':'A')<<"\tmissing\t0\t\n";
            }
            const auto& record=slots[best].record;
            std::cout<<"RECOVER\t"<<stream<<'\t'<<record.generation<<'\t'<<hex(record.payload)<<'\n';
            drain(*w); // unapproved read-only cleanup, never repair artifacts
        }
        return 0;
    }
    check(mode==L"crash"&&argc==7,"crash root mode stream point scenario nonce");
    selected=std::filesystem::path(argv[3]).string();point=std::filesystem::path(argv[4]).string();
    scenario=std::filesystem::path(argv[5]).string();nonce=std::filesystem::path(argv[6]).string();
    check(nonce.size()==32&&nonce.find_first_not_of("0123456789abcdef")==std::string::npos,"nonce format");
    check(selected=="limits"||selected=="priorities","explicit stream");
    marker=path.parent_path()/L"point-reached.tsv";
    const std::string other=selected=="limits"?"priorities":"limits";
    if(std::wstring(argv[5])==L"mixed"){
        auto w=open(root,other,false);check(w->submit(payload(other,true))==1,"other new payload accepted");drain(*w);
        std::cout<<"OTHER_COMMITTED\t"<<other<<'\n'<<std::flush;
    }else check(scenario=="single"||scenario=="concurrent","explicit scenario policy");
    std::unique_ptr<DrainingWriter> second;
    if(scenario=="concurrent"){
        concurrent=true;second=open(root,other,false);other_writer=second.get();
        check(second->submit(payload(other,true))==1,"other RAM tail accepted");
        std::unique_lock<std::mutex> lock(gate);
        check(changed.wait_for(lock,std::chrono::seconds(10),[]{return entered==1;}),"other parked before publication lane");
    }
    auto w=open(root,selected,false);
    target_writer=w.get();
    if(!concurrent)armed.store(true,std::memory_order_release);
    check(w->submit(payload(selected,true))==1,"designated update accepted");
    if(concurrent){
        std::unique_lock<std::mutex> lock(gate);
        check(changed.wait_for(lock,std::chrono::seconds(10),[]{return entered==2;}),"both actual updates parked");
        const auto a=w->status(),b=second->status();
        check(a.accepted==1&&a.committed==0&&b.accepted==1&&b.committed==0,"both accepted, neither acknowledged");
        armed.store(true,std::memory_order_release);released[1]=true;changed.notify_all();
        // released[0] stays false until process termination: no second publication.
    }
    drain(*w);std::cout<<"NO_CRASH\n";return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
