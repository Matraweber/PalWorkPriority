#pragma once
#include "../../native/save_core/backend.hpp"
#include "wire.hpp"
namespace pwp::draining_bridge {
inline const char* slot_state(experimental::records::State s) {
    using S=experimental::records::State;
    switch(s){case S::valid:return "valid";case S::missing:return "missing";case S::corrupt:return "corrupt";
        case S::unsupported:return "unsupported";case S::foreign:return "foreign";case S::unreadable:return "unreadable";}
    throw std::runtime_error("slot state");
}
// Shared by actual facade and entry mocks: never expose invalid record bytes.
inline std::string terminal_data(const experimental::JournalTerminal& r) {
    const bool recovery=r.status=="recovered";
    const auto slot=[&](unsigned i) {
        const auto& s=r.slots[i];
        const bool valid=s.state==experimental::records::State::valid;
        return recovery?std::vector<std::string>{slot_state(s.state),valid?std::to_string(s.record.generation):"0",valid?s.record.payload:""}
            :std::vector<std::string>{"","",""};
    };
    const auto a=slot(0),b=slot(1);
    return pack({r.status,r.certain?"1":"0",std::to_string(r.generation),std::to_string(r.covered_revision),
        r.preimages,std::to_string(r.error),std::to_string(r.cleanup_error),a[0],a[1],a[2],b[0],b[1],b[2]});
}
}
