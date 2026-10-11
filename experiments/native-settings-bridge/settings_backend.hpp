#pragma once
#include "../../native/save_core/backend.hpp"
#include "wire.hpp"
#include "terminal.hpp"
#ifdef PWP_SETTINGS_BRIDGE_REAL_TEST
#include "build/real_test_root.hpp"
#endif
namespace pwp::settings_bridge {
struct NativeBackend {
    using Root=std::shared_ptr<const experimental::RootCapability>;
    using Backend=std::shared_ptr<experimental::JournalBackend>;
    using Job=std::shared_ptr<experimental::JournalJob>;
    static Root configure() {
        return experimental::RootCapability::open(
#ifdef PWP_SETTINGS_BRIDGE_REAL_TEST
            pwp_settings_test_root,
#else
            L"C:\\Users\\matra\\Desktop\\palworld-priority-mod\\test-results\\native-settings-live-20261004\\store",
#endif
            "local-test-profile");
    }
    static Backend open(const Root& root,const std::vector<std::string>& f,std::uint64_t epoch) {
        return experimental::JournalBackend::open(root,{"PWP-SCOPE-1:"+f[0]+":"+f[1]+":"+f[2],f[3],epoch});
    }
    static Job recover(const Backend& b,std::uint64_t t) {return b->recover(t);}
    static Job update(const Backend& b,std::uint64_t t,const std::vector<std::string>& f,
        std::uint32_t gen,std::uint64_t revision,bool initialize) {return b->update(t,f[0],f[1],gen,revision,initialize);}
    static bool run(const Job& j) {return j->run();}
    static Reply peek(const Backend& b,std::uint64_t t) {
        const auto r=b->peek(t);if(!r)return {2,{}};
        if(r->ticket!=t)throw std::runtime_error("terminal ticket mismatch");
        return {1,terminal_data(*r)};
    }
    static bool consume(const Backend& b,std::uint64_t t){return b->consume(t);}
    static void retire(const Backend& b){b->retire();}
    static bool release(const Backend& b){return b->release();}
};
}
