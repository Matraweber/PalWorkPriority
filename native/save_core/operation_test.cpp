#include "operation.hpp"
#include "record_reader.hpp"
#include <filesystem>
#include <iostream>
#include <thread>
#include <vector>
#ifdef PWP_OPERATION_TESTING
#include "operation_test_hooks.hpp"
#endif
using namespace pwp::experimental;
void check(bool v,const char* why) {if(!v) throw std::runtime_error(why);}
int concurrent_run(const std::shared_ptr<SaveOperation>& op) {
    std::atomic<int> ready{0}, delivered{0};
    std::atomic<bool> go{false};
    std::vector<std::thread> workers;
    for(int n=0;n<16;++n) workers.emplace_back([&]{
        ++ready;
        while(!go.load()) std::this_thread::yield();
        if(op->run()) ++delivered;
    });
    while(ready.load()!=16) std::this_thread::yield();
    go=true;
    for(auto& thread:workers) thread.join();
    return delivered.load();
}
#ifdef PWP_OPERATION_TESTING
void cleanup_case(const std::wstring& root, bool uncertain) {
    operation_test::configure(operation_test::Fault::none);
    const std::wstring s(32,L'1'),g(32,L'2'),k=L"priorities";
    OwnerBinding binding{"PWP-SCOPE-1:"+std::string(32,'1')+":"+std::string(32,'2')+":priorities","cleanup-original",1};
    auto owner=SaveOwner::claim(binding);check(bool(owner),"cleanup claim");
    journal::Preimages pre;
    for(unsigned generation=1;generation<=2;++generation) {
        const auto bytes=records::encode({binding.scope,generation,generation==1 ? "one" : "two"});
        auto op=SaveOperation::admit(owner,binding,generation,root,s,g,k,pre,bytes);
        check(op && op->run(),"cleanup setup publication");
        check(owner->peek(generation)->certain && owner->consume(generation),"cleanup setup consume");
        pre[generation-1]=bytes;
    }
    operation_test::configure(uncertain ? operation_test::Fault::cleanup_close_uncertain : operation_test::Fault::cleanup_warning);
    const auto third=records::encode({binding.scope,3,"three"});
    auto op=SaveOperation::admit(owner,binding,3,root,s,g,k,pre,third);
    check(op && op->run(),"cleanup terminal delivery");
    check(operation_test::journal_calls()==1 && operation_test::published_hooks()==1,"cleanup single publication");
    const auto result=owner->peek(3);
    check(result && result->certain==!uncertain,"cleanup certainty mapping");
    check(result->bytes==(uncertain ? "uncertain:29:A:3:cleanup-error=29" : "updated:0:A:3:cleanup-error=29"),
          "cleanup error survives mailbox with stable prefix");
    check(!op->run(),"cleanup never retries publication");
    if(uncertain) {
        check(!owner->consume(3),"uncertain cleanup cannot consume");
        check(!SaveOperation::admit(owner,binding,4,root,s,g,k,pre,third),"uncertain cleanup cannot readmit");
        owner->retire();check(!owner->release(),"uncertain cleanup cannot release");
        auto next=binding;next.incarnation="replacement";next.epoch=2;
        check(!SaveOwner::claim(next),"uncertain cleanup excludes replacement");
    } else {
        check(owner->consume(3),"warning acknowledges terminal without publication retry");
        operation_test::configure(operation_test::Fault::none);
        pre[0]=third;
        auto next=SaveOperation::admit(owner,binding,4,root,s,g,k,pre,records::encode({binding.scope,4,"four"}));
        check(next && next->run(),"subsequent generation admitted after warning");
        const auto done=owner->peek(4);
        check(done && done->certain && done->bytes=="updated:0:B:4","normal result unchanged");
        check(owner->consume(4),"consume subsequent generation");
        owner->retire();check(owner->release(),"release after warning and subsequent generation");
    }
    std::cout<<"PASS "<<(uncertain ? "cleanup-close-uncertain" : "cleanup-warning")
             <<" cleanup-error=29 mailbox-prefix-stable no-publication-retry\n";
}
void uncertain_case(const std::wstring& root, bool exception) {
    operation_test::configure(exception ? operation_test::Fault::after_return_exception : operation_test::Fault::after_publish);
    const std::wstring s(32,L'1'),g(32,L'2'),k=L"priorities";
    OwnerBinding binding{"PWP-SCOPE-1:"+std::string(32,'1')+":"+std::string(32,'2')+":priorities","uncertain-original",1};
    auto owner=SaveOwner::claim(binding); check(bool(owner),"uncertain owner claim");
    const auto encoded=records::encode({binding.scope,1,"uncertain-published"});
    auto op=SaveOperation::admit(owner,binding,1,root,s,g,k,{},encoded);
    check(bool(op),"uncertain admit");
    check(concurrent_run(op)==(exception ? 0 : 1),"uncertain delivery semantics");
    check(operation_test::journal_calls()==1,"exactly one actual uncertain journal invocation");
    check(operation_test::published_hooks()==1,"uncertainty injected after actual publication");
    const auto result=owner->peek(1);
    check(result && result->ticket==1 && !result->certain,"captured owner retains uncertain terminal");
    check(result->bytes==(exception ? "operation-exception" : "uncertain:29:A:1"),"uncertain result classification");
    check(!owner->peek(2),"wrong ticket has no result");
    check(!owner->consume(1) && !owner->consume(2),"uncertain consumption refused");
    check(!owner->complete(1,true,"forged resolution"),"uncertain completion cannot be replaced");
    check(!owner->release(),"uncertain release refused before retire");
    check(!SaveOperation::admit(owner,binding,2,root,s,g,k,{},encoded),"pending uncertainty refuses readmission");
    auto replacement=binding; replacement.incarnation="replacement"; replacement.epoch=2;
    check(!SaveOwner::claim(replacement),"uncertainty excludes replacement owner");
    owner->retire();
    check(!owner->consume(1) && !owner->release(),"uncertain retained after retire");
    check(!SaveOperation::admit(owner,binding,2,root,s,g,k,{},encoded),"retired readmission refused");
    check(!op->run() && operation_test::journal_calls()==1,"uncertain operation never reexecutes");
    const auto retained=owner->peek(1);
    check(retained && !retained->certain && retained->bytes==result->bytes,"mailbox still exact uncertain result");
    op.reset(); owner.reset();
    check(!SaveOwner::claim(replacement),"dropped uncertain owner still excludes");
    std::cout<<"PASS "<<(exception ? "operation-exception" : "after-publish-uncertainty")
             <<" journal_calls=1 publications=1 certain=false consume/release/readmission=refused\n";
}
#endif
int wmain(int argc,wchar_t** argv) {
 try {
#ifdef PWP_OPERATION_TESTING
    if(argc==3) {
        const std::wstring mode=argv[2];
        if(mode==L"cleanup-warning" || mode==L"cleanup-close-uncertain") {
            cleanup_case(argv[1],mode==L"cleanup-close-uncertain");return 0;
        }
        check(mode==L"uncertain" || mode==L"exception","unknown fault mode");
        uncertain_case(argv[1],mode==L"exception"); return 0;
    }
    operation_test::configure(operation_test::Fault::none);
#endif
    check(argc==2,"temp root required");const std::wstring root=argv[1];
    const std::wstring s(32,L'1'),g(32,L'2'),k=L"priorities";
    OwnerBinding b{"PWP-SCOPE-1:"+std::string(32,'1')+":"+std::string(32,'2')+":priorities","test-process",1};
    auto owner=SaveOwner::claim(b);check(bool(owner),"claim");
    auto bytes=records::encode({b.scope,1,"one"});
    auto bad=b;bad.epoch=2;
    check(!SaveOperation::admit(owner,bad,1,root,s,g,k,{},bytes),"wrong epoch");
    check(!SaveOperation::admit(owner,b,1,root,s,std::wstring(32,L'3'),k,{},bytes),"scope mismatch");
    auto op=SaveOperation::admit(owner,b,1,root,s,g,k,{},bytes);check(bool(op),"admit");
    bytes="caller-mutated"; // operation must retain copied original bytes
    check(concurrent_run(op)==1,"single accepted delivery");
#ifdef PWP_OPERATION_TESTING
    check(operation_test::journal_calls()==1,"16 concurrent runs invoke journal exactly once");
    check(operation_test::published_hooks()==1,"one initial publication");
#endif
    auto result=owner->peek(1);check(result && result->certain && result->bytes.find("initialized:")==0,"publication result");
    check(owner->consume(1),"consume");
    // Reserve a second operation then retire before it starts. It must cancel
    // against the exact old owner and leave generation one untouched.
    auto old=op;auto next=records::encode({b.scope,2,"two"});
    journal::Preimages pre;pre[0]=records::encode({b.scope,1,"one"});
    op=SaveOperation::admit(owner,b,2,root,s,g,k,pre,next);check(bool(op),"next");
    owner->retire();check(!owner->release(),"pending prevents release");
    check(op->run(),"cancellation delivered");result=owner->peek(2);
    check(result && result->bytes=="cancelled-before-io","cancel outcome");
#ifdef PWP_OPERATION_TESTING
    check(operation_test::journal_calls()==1,"cancellation never enters journal");
#endif
    check(owner->consume(2)&&owner->release(),"release old");
    b.incarnation="new-claim";b.epoch=2;auto newer=SaveOwner::claim(b);check(bool(newer),"new claim");
    auto fresh=SaveOperation::admit(newer,b,1,root,s,g,k,pre,next);check(bool(fresh),"ticket reuse new owner");
    check(!old->run() && !op->run() && !newer->peek(1),"stale closures cannot complete new owner");
#ifdef PWP_OPERATION_TESTING
    check(operation_test::journal_calls()==1,"stale closures never enter journal");
#endif
    check(fresh->run(),"update run");result=newer->peek(1);
    check(result && result->certain && result->bytes.find("updated:")==0,"updated result");
#ifdef PWP_OPERATION_TESTING
    check(operation_test::journal_calls()==2 && operation_test::published_hooks()==2,"two actual journal invocations total");
#endif
    check(newer->consume(1),"consume new");newer->retire();check(newer->release(),"release new");
    std::cout<<"PASS scope binding, epoch, immutable payload, concurrent run, retirement, stale callback, journal update\n";
#ifdef PWP_OPERATION_TESTING
    std::cout<<"PASS counted-journal concurrent=1 cancellation=0 stale=0 final_calls=2\n";
#endif
    return 0;
 }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
