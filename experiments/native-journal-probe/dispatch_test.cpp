// Runs the EXACT entry dispatcher with an instrumented in-memory backend.
// No Lua runtime, helper DLL, SaveOwner, filesystem IO or game installation.
#include "dispatch.hpp"
#include <array>
#include <atomic>
#include <condition_variable>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <thread>
#include <vector>
namespace {
void check(bool value,const char* message) {if(!value) throw std::runtime_error(message);}
struct Stats {
    std::array<std::atomic<unsigned>,5> calls{}; // admit, run/IO, inspect, consume, release
    std::atomic<unsigned> done{0}, last_run{0};
    int outcome=1;
    bool fail_admit=false,throw_admit=false,throw_run=false,fail_release=false;
    std::mutex gate;
    std::condition_variable cv;
    bool block=false,entered=false,proceed=false;
    std::array<unsigned,5> snapshot() const {
        return {calls[0].load(),calls[1].load(),calls[2].load(),calls[3].load(),calls[4].load()};
    }
};
struct Op {std::shared_ptr<Stats> stats;unsigned ticket;};
struct Backend {
    using Operation=std::shared_ptr<Op>;
    std::shared_ptr<Stats> s;
    Operation admit(unsigned ticket) {
        ++s->calls[0];
        if(s->throw_admit) throw std::runtime_error("admission ambiguity");
        if(s->fail_admit) return {};
        return std::make_shared<Op>(Op{s,ticket});
    }
    static int run(const Operation& op) {
        auto& s=*op->stats;++s.calls[1];s.last_run=op->ticket;
        {
            std::unique_lock<std::mutex> lock(s.gate);
            s.entered=true;s.cv.notify_all();
            if(s.block) s.cv.wait(lock,[&]{return s.proceed;});
        }
        s.done=op->ticket;
        if(s.throw_run) throw std::runtime_error("after IO ambiguity");
        return 1;
    }
    int inspect(unsigned ticket) {++s->calls[2];return s->done==ticket ? s->outcome : 0;}
    bool consume(unsigned ticket) {++s->calls[3];return s->done==ticket && s->outcome==1;}
    bool release() {++s->calls[4];return !s->fail_release;}
};
struct Fixture {
    std::shared_ptr<Stats> s=std::make_shared<Stats>();
    pwp::journal_probe::Dispatch<Backend> d{Backend{s}};
    void reject(std::int64_t command,std::int64_t ticket,std::uint32_t thread) {
        const auto before=s->snapshot();check(d.action(command,ticket,thread)==0,"rejection status");
        check(s->snapshot()==before,"rejected call touched backend");
    }
    void bind() {check(d.action(0,0,1)==1,"bind control thread");}
    void admit(unsigned ticket) {check(d.action(ticket==1?1:5,ticket,1)==1,"admit");}
    void finish(unsigned ticket) {
        check(d.action(2,ticket,2)==1,"worker delivery");
        reject(3,ticket,2);reject(4,ticket,2); // result is ready: only thread gate can deny
        check(d.action(3,ticket,1)==1,"inspect ticket");
        check(d.action(4,ticket,1)==1,"consume ticket");
        if(ticket<3) reject(5,ticket+1,2); // next ticket is otherwise admissible
    }
};
}
int main() {
    try {
        {
            Fixture f;
            for(int cmd=1;cmd<=6;++cmd) f.reject(cmd,1,1);
            f.reject(0,1,1);f.reject(0,0,0);f.reject(7,1,1);f.reject(-1,1,1);
            f.bind();f.reject(0,0,2);f.reject(1,0,1);f.reject(1,2,1);f.reject(1,4,1);f.reject(1,-1,1);
            for(int cmd : {0,1,3,4,5,6}) f.reject(cmd,cmd==0?0:1,2);
            f.admit(1);f.reject(1,1,1);f.reject(2,1,1); // wrong IO thread, ZERO backend calls
            f.reject(2,2,2);f.reject(2,0,2);
            f.finish(1);f.reject(4,1,1);f.reject(2,1,2);
            f.admit(2);
            for(int cmd : {2,3,4,5,6}) f.reject(cmd,1,cmd==2?2:1); // late phase-1 calls
            f.reject(5,2,1);f.reject(2,2,1);
            f.finish(2);check(f.s->last_run==2 && f.s->calls[1]==2,"old worker did not run newer ticket");
            f.admit(3);f.reject(4,2,1);f.reject(6,2,1);f.finish(3);
            f.reject(6,3,2);check(f.d.action(6,3,1)==1,"release");
            f.reject(6,3,1);f.reject(0,0,1);f.reject(2,3,2);
            check(f.s->calls[0]==3 && f.s->calls[1]==3 && f.s->calls[3]==3 && f.s->calls[4]==1,
                "exactly three admissions/IO/consumptions and one release");
        }
        // Actual concurrent dispatch: one worker starts, all duplicates and all
        // phase-advance/consume attempts while it is running stay outside backend.
        {
            Fixture f;f.bind();f.admit(1);f.s->block=true;
            std::atomic<int> successes{0};
            std::vector<std::thread> threads;
            for(std::uint32_t n=2;n<18;++n) threads.emplace_back([&,n]{
                if(f.d.action(2,1,n)==1) ++successes;
            });
            {
                std::unique_lock<std::mutex> lock(f.s->gate);
                f.s->cv.wait(lock,[&]{return f.s->entered;});
            }
            // Defer assertions until every thread joins, including on failure.
            const auto before=f.s->snapshot();
            const bool denied=f.d.action(4,1,1)==0 && f.d.action(5,2,1)==0
                && f.d.action(2,1,1)==0 && f.d.action(3,1,1)==0;
            const bool untouched=f.s->snapshot()==before;
            {std::lock_guard<std::mutex> lock(f.s->gate);f.s->proceed=true;f.s->cv.notify_all();}
            for(auto& t:threads) t.join();
            check(denied && untouched,"in-flight dispatch gates");
            check(successes==1 && f.s->calls[1]==1,"16 duplicate workers perform one IO");
            check(f.d.action(4,1,1)==1,"consume exact completed ticket");
        }
        // Failure or exception during admission cannot retry the same ticket.
        for(unsigned failed_ticket : {1u,2u}) for(bool throws : {false,true}) {
            Fixture f;f.bind();f.s->fail_admit=!throws;f.s->throw_admit=throws;
            if(failed_ticket==2) {
                f.s->fail_admit=false;f.s->throw_admit=false;f.admit(1);f.finish(1);
                f.s->fail_admit=!throws;f.s->throw_admit=throws;
            }
            const int command=failed_ticket==1 ? 1 : 5;
            bool caught=false;int result=0;
            try {result=f.d.action(command,failed_ticket,1);} catch(...) {caught=true;}
            check(result==0 && caught==throws,"failed/throwing admission result");
            f.reject(command,failed_ticket,1);f.reject(2,failed_ticket,2);
            check(f.s->calls[0]==failed_ticket,"single admission attempt per ticket");
        }
        // Preserve uncertainty: no execute retry, consumption, next admission or
        // release; a lost worker reply cannot turn into a retryable operation.
        for(bool throws : {false,true}) {
            Fixture f;f.bind();f.admit(1);f.s->outcome=-2;f.s->throw_run=throws;
            bool caught=false;int result=0;
            try {result=f.d.action(2,1,2);} catch(...) {caught=true;}
            check(caught==throws && result==(throws?0:1),"worker uncertainty result");
            check(f.d.action(3,1,1)==-2,"uncertainty visible");
            check(f.d.action(4,1,1)==0 && f.s->calls[3]==0,"uncertain never consumed");
            f.reject(2,1,2);f.reject(5,2,1);f.reject(6,1,1);
            check(f.s->calls[1]==1,"uncertain IO never retried");
        }
        {
            Fixture f;f.bind();
            for(unsigned ticket=1;ticket<=3;++ticket) {f.admit(ticket);f.finish(ticket);}
            f.s->fail_release=true;check(f.d.action(6,3,1)==0,"failed release reported");
            f.reject(6,3,1);check(f.s->calls[4]==1,"no close-handle retry");
        }
        std::cout<<"PASS exact dispatcher: ticket/thread preflight, stale commands, 16 concurrent duplicates, "
            "three generations, failed admission, uncertainty, release failure; fake backend only\n";
        return 0;
    } catch(const std::exception& e) {std::cerr<<"FAIL "<<e.what()<<'\n';return 1;}
}
