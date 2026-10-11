#pragma once
#include "../../native/save_core/draining_writer.hpp"
#include "wire.hpp"
#include "terminal.hpp"
#include <array>
#include <mutex>
#ifdef PWP_DRAINING_BRIDGE_TEST
#include "build/real_test_root.hpp"
#endif
namespace pwp::draining_bridge {
using experimental::DrainPhase;
inline const char* phase(DrainPhase p) {
    switch(p) {
    case DrainPhase::dormant:return "dormant";case DrainPhase::recovering:return "recovering";
    case DrainPhase::awaiting_validation:return "awaiting_validation";case DrainPhase::ready:return "ready";
    case DrainPhase::closing:return "closing";case DrainPhase::closed:return "closed";case DrainPhase::blocked:return "blocked";
    }throw std::runtime_error("phase");
}
inline const char* error(experimental::DrainError e) {
    using E=experimental::DrainError;
    switch(e) {case E::none:return "none";case E::recovery:return "recovery";case E::admission:return "admission";
    case E::publication:return "publication";case E::uncertain:return "uncertain";case E::consume:return "consume";
    case E::release:return "release";case E::exception:return "exception";}throw std::runtime_error("error");
}
class Registry {
    struct Slot {
        const experimental::OwnerBinding binding;
        std::unique_ptr<experimental::DrainingWriter> writer;
        std::uint64_t ticket=0,revision=0;
        int command=0;
        const char* outcome="none";
        bool joined=false,cleaned=false;
        Slot(experimental::OwnerBinding b,std::unique_ptr<experimental::DrainingWriter> w):binding(std::move(b)),writer(std::move(w)){}
    };
    std::mutex gate;
    DWORD control=0;
    bool configured=false;
    std::shared_ptr<const experimental::RootCapability> root;
    std::array<std::unique_ptr<Slot>,128> slots;
    unsigned used=0,active=0;
    static std::string status_data(const Slot& slot,const experimental::DrainStatus& s) {
        const auto& t=s.terminal;
        return pack({slot.binding.scope,slot.binding.incarnation,std::to_string(slot.binding.epoch),
            std::to_string(s.accepted),std::to_string(s.committed),phase(s.phase),error(s.error),
            std::to_string(s.generation),std::to_string(s.cleanup_error),t?t->status:"",t?(t->certain?"1":"0"):"",
            t?std::to_string(t->error):"",std::to_string(slot.ticket),std::to_string(slot.command),
            std::to_string(slot.revision),slot.outcome});
    }
public:
    Reply action(int command,unsigned handle,std::uint64_t ticket,const std::vector<std::string>& f,DWORD thread) {
        std::lock_guard<std::mutex> lock(gate);
        // No backend action, including status/cleanup, may precede this route check.
        if(control && thread!=control)return {};
        if(command==0) {
            if(handle||ticket||!f.empty()||configured)return {};
            configured=true;control=thread;
            root=experimental::RootCapability::open(
#ifdef PWP_DRAINING_BRIDGE_TEST
                pwp_draining_test_root,
#else
                L"C:\\Users\\matra\\Desktop\\palworld-priority-mod\\test-results\\native-limits-live-20261007\\store",
#endif
                "local-test-profile");
            return root?Reply{1,pack({"1"})}:Reply{};
        }
        if(!root)return {};
        if(command==1) {
            std::uint64_t epoch=0;
            if(handle!=1||ticket||f.size()!=5||!guid(f[0])||!guid(f[1])
                ||(f[2]!="priorities"&&f[2]!="limits")||f[3].empty()||f[3].size()>128
                ||!decimal(f[4],2147483646,epoch)||!epoch||used==slots.size()||active==8)return {};
            for(unsigned char ch:f[3])if(ch<33||ch>126)return {};
            experimental::OwnerBinding binding{"PWP-SCOPE-1:"+f[0]+":"+f[1]+":"+f[2],f[3],epoch};
            auto writer=experimental::DrainingWriter::open(root,binding); // owner only, no reader IO
            if(!writer)return {};
            auto slot=std::make_unique<Slot>(std::move(binding),std::move(writer));
            slots[used++]=std::move(slot);++active;
            return {1,pack({std::to_string(used)})};
        }
        if(!handle||handle>used)return {};
        auto& slot=*slots[handle-1];
        if(command==9) {
            if(ticket||!f.empty())return {};
            if(slot.cleaned)return {1,{}};
            if(!slot.joined||slot.writer->status().phase!=DrainPhase::closed)return {};
            slot.writer.reset();slot.cleaned=true;--active;return {1,{}};
        }
        if(slot.cleaned)return {};
        if(command==3 || command==6) {
            if(ticket||!f.empty())return {};
            auto s=slot.writer->status();
            if(command==6)return {1,status_data(slot,s)};
            if(s.phase==DrainPhase::dormant||s.phase==DrainPhase::recovering)return {2,{}};
            if(s.phase!=DrainPhase::awaiting_validation||!s.terminal)return {};
            return {1,pack({slot.binding.scope,slot.binding.incarnation,std::to_string(slot.binding.epoch)})+terminal_data(*s.terminal)};
        }
        if(command!=2&&command!=4&&command!=5&&command!=7&&command!=8)return {};
        if(!ticket||ticket<=slot.ticket)return {};
        if(command==4) {if(f.size()!=1||(f[0]!="existing"&&f[0]!="initialize_missing"))return {};}
        else if(command==5) {if(f.size()!=1||f[0].size()>max_payload)return {};}
        else if(!f.empty())return {};
        // Consume the ticket BEFORE the native call. Never replay after a lost
        // reply or exception. Status remains queryable with the immutable owner.
        slot.ticket=ticket;slot.command=command;slot.revision=0;slot.outcome="unknown";
        bool accepted=false;
        if(command==2)accepted=slot.writer->start_recovery();
        if(command==4)accepted=slot.writer->approve_recovery(f[0]=="existing"
            ?experimental::RecoveryApproval::existing:experimental::RecoveryApproval::initialize_missing);
        if(command==5) {slot.revision=slot.writer->submit(f[0]);accepted=slot.revision!=0;}
        if(command==7) {slot.writer->close();accepted=true;}
        if(command==8) {slot.writer->drain();slot.joined=true;accepted=true;}
        slot.outcome=accepted?"accepted":"refused";
        if(command==8)return {1,status_data(slot,slot.writer->status())};
        return accepted?Reply{1,command==5?pack({std::to_string(slot.revision)}):std::string{}}:Reply{};
    }
};
// Deliberately process-lifetime allocation: NO registry destructor/autojoin in
// CRT detach/DllMain. Only command 9 destroys a positively joined/closed writer.
// Native writer pins this implementation before launching any native thread.
inline Registry& registry() {static Registry* const instance=new Registry;return *instance;}
}
