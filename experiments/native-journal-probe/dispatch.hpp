#pragma once
#include <cstdint>
#include <mutex>
#include <utility>

namespace pwp::journal_probe {
// Shared by the production entry and a standalone fake-backend regression exe.
// Thread identity comes ONLY from native GetCurrentThreadId at the real entry.
// Command (0,0), invoked by the scheduled game-thread entry, binds the control
// thread once. This is not independent UE game-thread discovery.
template<class Backend> class Dispatch {
    Backend backend;
    std::mutex gate;
    typename Backend::Operation operation{};
    std::uint32_t control_thread=0;
    unsigned phase=0, attempted_ticket=0;
    bool consumed=false, started=false, running=false, closed=false;
public:
    explicit Dispatch(Backend value):backend(std::move(value)){}
    int action(std::int64_t command,std::int64_t ticket,std::uint32_t thread) {
        if(command<0 || command>6 || ticket<0 || ticket>3 || thread==0) return 0;
        std::unique_lock<std::mutex> lock(gate);
        if(closed) return 0;
        if(command==0) {
            if(ticket!=0 || (control_thread && control_thread!=thread)) return 0;
            control_thread=thread; return 1;
        }
        // Validate routing and ticket BEFORE any backend access/reservation/IO.
        if(!control_thread || ticket==0 || (command==2 ? thread==control_thread : thread!=control_thread)) return 0;
        const auto expected=static_cast<unsigned>(ticket);
        if(command==1 || command==5) {
            if(running || (command==1 ? phase!=0 : (phase==0 || phase>=3 || !consumed))) return 0;
            if(expected!=phase+1 || expected<=attempted_ticket) return 0;
            attempted_ticket=expected; // exceptions/missing admission never retry
            auto next=backend.admit(expected);
            if(!next) return 0;
            operation=std::move(next);phase=expected;consumed=false;started=false;
            return 1;
        }
        if(expected!=phase || !operation) return 0;
        if(command==2) {
            if(consumed || started || running) return 0;
            started=true;running=true;
            // Exact operation chosen under the same lock as generation checks.
            auto captured=operation;
            lock.unlock();
            int result;
            try {result=Backend::run(captured);}
            catch(...) {lock.lock();running=false;throw;}
            lock.lock();running=false;
            return result;
        }
        if(running) return 0;
        if(command==3) return consumed ? 0 : backend.inspect(expected);
        if(command==4) {
            if(consumed || backend.inspect(expected)!=1) return 0;
            consumed=backend.consume(expected);return consumed ? 1 : 0;
        }
        if(command==6 && phase==3 && consumed) {
            closed=true; // no repeated release, even if backend reports failure
            return backend.release() ? 1 : 0;
        }
        return 0;
    }
};
}
