#include "backend.hpp"
#include <atomic>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <thread>
#include <vector>
#ifdef PWP_JOURNAL_TESTING
namespace pwp::experimental::journal {
unsigned long journal_test_point(const char* point) {
    return std::string(point)=="after_publish" ? 29UL : 0UL;
}
}
#endif
using namespace pwp::experimental;
void check(bool yes,const char* why) {if(!yes)throw std::runtime_error(why);}
void consume(const std::shared_ptr<JournalBackend>& b,std::uint64_t ticket) {
    check(b->consume(ticket)&&b->consume(ticket),"consume exact idempotent terminal");
}
void finish(const std::shared_ptr<JournalBackend>& b) {b->retire();check(b->release(),"retire release");}
int wmain(int argc,wchar_t** argv) {
    try {
        check(argc==2,"root argument");
        auto root=RootCapability::open(argv[1],"local-test-profile");check(bool(root),"root capability");
        const std::string scope="PWP-SCOPE-1:"+std::string(32,'1')+":"+std::string(32,'2')+":priorities";
        OwnerBinding binding{scope,"first",1};
        auto b=JournalBackend::open(root,binding);check(bool(b),"backend");
        check(!JournalBackend::open(root,binding),"duplicate owner refused");
        check(!b->update(1,"invented","bad",1,1,true),"update before recovery");
        auto recovery=b->recover(1);check(bool(recovery)&&recovery->run(),"recover missing pair");
        auto r=b->peek(1);check(r&&r->certain&&r->status=="recovered"&&r->generation==0,"missing recovery");
        check(r->slots[0].state==records::State::missing&&r->slots[1].state==records::State::missing,"positive missing slots");
        check(!b->peek(2)&&!b->consume(2),"wrong ticket");consume(b,1);
        const auto old_recovery_token=r->preimages;
#ifdef PWP_JOURNAL_TESTING
        auto uncertain=b->update(2,r->preimages,"uncertain",1,1,true);
        check(uncertain&&uncertain->run(),"uncertain terminal delivered");
        r=b->peek(2);check(r&&!r->certain&&r->status=="uncertain","published uncertainty retained");
        check(!b->consume(2)&&!uncertain->run(),"uncertain cannot consume/re-execute");
        check(!b->update(3,r->preimages,"never",2,2,false),"uncertain cannot reserve");
        b->retire();check(!b->release()&&!JournalBackend::open(root,binding),"uncertain blocks replacement");
        std::cout<<"PASS native backend: actual post-publication uncertainty retains owner, no ACK/retry\n";
        return 0;
#endif
        check(!b->update(2,r->preimages,"one",1,1,false),"initialization must be explicit");
        check(!b->update(2,"wrong","one",1,1,true),"token must match");
        auto first=b->update(2,r->preimages,"one",1,1,true);check(bool(first),"initialization admission");
        check(!b->update(3,r->preimages,"two",2,2,false),"one pending operation");
        std::atomic<unsigned> success{0};std::vector<std::thread> workers;
        for(unsigned i=0;i<16;++i)workers.emplace_back([&]{if(first->run())++success;});
        for(auto& t:workers)t.join();check(success==1,"16 starts one write");
        r=b->peek(2);check(r&&r->status=="initialized"&&r->generation==1&&r->covered_revision==1,"first terminal");
        consume(b,2);check(!first->run(),"old closure cannot run again");
        check(!b->update(3,r->preimages,"three",3,3,false),"logical revision is not journal generation");
        auto next=b->update(3,r->preimages,"three",2,3,false);check(next&&next->run(),"coalesced physical second write");
        r=b->peek(3);check(r&&r->status=="updated"&&r->generation==2&&r->covered_revision==3,"second terminal");consume(b,3);
        const auto leaf=std::filesystem::path(argv[1])/(L"pwp-record-v1-"+std::wstring(32,L'1')+L"-"+std::wstring(32,L'2')+L"-priorities-A.record");
        {auto damaged=records::encode({scope,1,"external change"});damaged.back()^=1;
         std::ofstream out(leaf,std::ios::binary|std::ios::trunc);out.write(damaged.data(),damaged.size());check(bool(out),"fixture drift");}
        auto conflict=b->update(4,r->preimages,"blocked",3,4,false);check(conflict&&conflict->run(),"conflict delivery");
        r=b->peek(4);check(r&&r->certain&&r->status=="conflict","exact preimage protects external changes");consume(b,4);
        check(!b->update(5,r->preimages,"blocked",3,5,false),"no implicit retry after conflict");finish(b);
        binding.incarnation="second";binding.epoch=2;
        auto reopened=JournalBackend::open(root,binding);check(bool(reopened),"new owner after explicit release");
        recovery=reopened->recover(1);check(recovery&&recovery->run(),"recovery after drift");
        r=reopened->peek(1);check(r&&r->generation==2&&r->slots[0].state==records::State::corrupt
            &&r->slots[1].record.payload=="three","exact valid/corrupt pair recovery");consume(reopened,1);
        check(r->preimages!=old_recovery_token&&!reopened->update(2,old_recovery_token,"stale",3,1,false),
            "reopened backend rejects prior incarnation token at reused ticket");
        auto repair=reopened->update(2,r->preimages,"recovered-four",3,1,false);check(repair&&repair->run(),"replace observed corrupt inactive slot");
        r=reopened->peek(2);check(r&&r->status=="updated"&&r->generation==3,"repair terminal");consume(reopened,2);
        auto cancelled=reopened->update(3,r->preimages,"never",4,2,false);check(bool(cancelled),"admit before retirement");
        reopened->retire();check(!reopened->release(),"pending prevents release");
        check(cancelled->run(),"cancel before IO");r=reopened->peek(3);
        check(r&&r->status=="cancelled-before-io","cancelled result");consume(reopened,3);check(reopened->release(),"drained retirement");
        std::cout<<"PASS native backend: recovery, initialization, 16 concurrent starts, coalesced revisions, exact preimages, conflict/recovery, retirement\n";
        return 0;
    } catch(const std::exception& e) {std::cerr<<"FAIL "<<e.what()<<'\n';return 1;}
}
