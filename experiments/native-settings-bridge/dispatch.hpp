#pragma once
#include "wire.hpp"
#include <array>
#include <mutex>
namespace pwp::settings_bridge {
template<class Native> class Dispatch {
    struct Slot {
        typename Native::Backend backend;
        typename Native::Job job;
        std::string scope,incarnation,epoch;
        std::uint64_t ticket=0,high=0,last_consumed=0;
        bool started=false,running=false,retired=false,released=false,uncertain=false;
    };
    std::mutex gate;
    typename Native::Root root;
    std::array<Slot,128> slots{};
    unsigned next=0;
    std::uint32_t control=0;
    bool configured=false;
public:
    Reply action(int command,unsigned handle,std::uint64_t ticket,const std::vector<std::string>& f,std::uint32_t thread) {
        std::unique_lock lock(gate);
        if(!thread||command<0||command>8||ticket>=2147483647)return {};
        if(command==0) {
            if(handle||ticket||!f.empty()||configured)return {};
            configured=true;control=thread; // no configure retry after throws/failure
            root=Native::configure();if(!root)throw std::runtime_error("root configuration uncertain");
            return {1,pack({"1"})};
        }
        if(!root||!control||(command==4 ? thread==control : thread!=control))return {};
        if(command==1) {
            std::uint64_t epoch=0;
            if(handle!=1||ticket||f.size()!=5||next>=slots.size()||!guid(f[0])||!guid(f[1])
                ||(f[2]!="priorities"&&f[2]!="limits")||f[3].empty()||f[3].size()>256
                ||!decimal(f[4],2147483646,epoch)||!epoch)return {};
            for(unsigned char c:f[3])if(c<32||c>126)return {};
            auto& s=slots[next++]; // burn ID even when native open rejects/throws
            s.scope="PWP-SCOPE-1:"+f[0]+":"+f[1]+":"+f[2];s.incarnation=f[3];s.epoch=f[4];
            try {s.backend=Native::open(root,f,epoch);}catch(...) {s.uncertain=true;throw;}
            return s.backend?Reply{1,pack({std::to_string(next)})}:Reply{};
        }
        if(!handle||handle>next)return {};
        auto& s=slots[handle-1];
        if(!s.backend||s.released||s.uncertain)return {};
        if(command==2||command==3) {
            if(!ticket||ticket<=s.high||s.job||s.retired)return {};
            std::uint64_t gen=0,revision=0,initialize=0;
            if(command==2) {if(!f.empty())return {};}
            else if(f.size()!=5||f[0].empty()||f[0].size()>256||f[1].size()>max_payload
                ||!decimal(f[2],UINT32_MAX,gen)||!gen||!decimal(f[3],2147483646,revision)||!revision
                ||!decimal(f[4],1,initialize))return {};
            s.high=ticket;
            try {s.job=command==2?Native::recover(s.backend,ticket):Native::update(s.backend,ticket,f,
                static_cast<std::uint32_t>(gen),revision,initialize==1);}
            catch(...) {s.uncertain=true;throw;}
            if(!s.job)return {};
            s.ticket=ticket;s.started=false;return {1,{}};
        }
        if(!f.empty())return {};
        if(command==6&&ticket&&ticket==s.last_consumed)return {1,{}};
        if(command==7||command==8) {
            if(ticket||s.job||s.running)return {};
            if(command==7) {
                if(s.retired)return {};s.retired=true;
                try {Native::retire(s.backend);}catch(...) {s.uncertain=true;throw;}
                return {1,{}};
            }
            if(!s.retired)return {};
            s.released=true; // release may have acted: never retry uncertainty
            const bool ok=Native::release(s.backend);
            if(!ok)throw std::runtime_error("release uncertain");
            s.backend.reset();return {1,{}};
        }
        if(!ticket||ticket!=s.ticket||!s.job)return {};
        if(command==4) {
            if(s.started||s.running)return {};
            auto job=s.job;s.started=true;s.running=true;
            lock.unlock();
            bool ok=false;
            try {ok=Native::run(job);}catch(...) {lock.lock();s.running=false;s.uncertain=true;throw;}
            lock.lock();s.running=false;
            if(!ok)throw std::runtime_error("worker delivery uncertain");
            return {1,{}};
        }
        if(command==5) {
            if(s.running)return {2,{}};
            auto reply=Native::peek(s.backend,ticket);
            if(reply.status==1) {
                const auto prefix=pack({s.scope,s.incarnation,s.epoch});
                if(reply.data.size()>max_output-prefix.size())throw std::runtime_error("terminal size");
                reply.data=prefix+reply.data;
            }
            return reply;
        }
        if(command==6) {
            if(s.running||!s.started)return {};
            bool ok=false;
            try {ok=Native::consume(s.backend,ticket);}catch(...) {s.uncertain=true;throw;}
            if(!ok)return {};
            s.last_consumed=ticket;s.job.reset();s.ticket=0;return {1,{}};
        }
        return {};
    }
};
}
