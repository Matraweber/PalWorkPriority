// Isolated fixed-root, synthetic-data integration probe. NEVER real settings.
// Build only until reviewed; worker execution uses UE4SS ExecuteAsync, no thread
// creation, UObject access, borrowed Lua memory, native callbacks or DLL main.
#include "../../native/save_core/operation.hpp"
#include "dispatch.hpp"
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <Windows.h>
#include <LuaMadeSimple/LuaMadeSimple.hpp>
static_assert(_ITERATOR_DEBUG_LEVEL==0,"Release STL required");
#if !defined(_DLL) || defined(_DEBUG)
#error Release dynamic CRT required
#endif
namespace {
using namespace pwp::experimental;
const std::wstring root=L"C:\\Users\\matra\\Desktop\\palworld-priority-mod\\test-results\\native-journal-live-20261004\\store";
const std::wstring storage(32,L'7'),guild(32,L'8');
const OwnerBinding binding{"PWP-SCOPE-1:"+std::string(32,'7')+":"+std::string(32,'8')+":priorities","synthetic-journal-probe-v1",1};
// Fixed binary payload independently reproduced by external Python acceptance.
std::string payload(unsigned generation) {
    std::string bytes(262144,'\0');
    for(std::size_t i=0;i<bytes.size();++i) bytes[i]=static_cast<char>((i+generation)%256);
    return bytes;
}
struct Backend {
    using Operation=std::shared_ptr<SaveOperation>;
    std::shared_ptr<SaveOwner> owner;
    Operation admit(unsigned ticket) {
        if(ticket==1) owner=SaveOwner::claim(binding);
        if(!owner) return {};
        journal::Preimages p;
        if(ticket>=2) p[0]=records::encode({binding.scope,1,payload(1)});
        if(ticket==3) p[1]=records::encode({binding.scope,2,payload(2)});
        return SaveOperation::admit(owner,binding,ticket,root,storage,guild,L"priorities",p,
            records::encode({binding.scope,ticket,payload(ticket)}));
    }
    static int run(const Operation& captured) {return captured->run() ? 1 : 0;}
    int inspect(unsigned ticket) {
        const auto r=owner->peek(ticket);
        if(!r)return 0;if(!r->certain)return -2;
        const std::string prefix=ticket==1?"initialized:":"updated:";
        return r->bytes.find(prefix)==0 ? 1 : -1;
    }
    bool consume(unsigned ticket) {return owner->consume(ticket);}
    bool release() {owner->retire();return owner->release();}
};
pwp::journal_probe::Dispatch<Backend> dispatch{Backend{}};
}
// Exactly two integers: command, expected ticket. (0,0) binds control thread;
// 1/5 admit ticket 1/next; 2 runs that ticket on a non-control thread; 3/4/6
// inspect/consume/release that ticket on the control thread. All routing/ticket
// checks precede backend actions. Returns status,thread,start,end,freq (unchanged).
extern "C" __declspec(dllexport) int luaopen_pwp_journal_probe(lua_State* state) {
    try {
        RC::LuaMadeSimple::Lua lua{state};
        if(lua.get_stack_size()!=2 || !lua.is_integer(1) || !lua.is_integer(2))return 0;
        // LuaMadeSimple getters REMOVE their stack entry. Read descending
        // indices so reading command cannot shift ticket from index 2 to 1.
        const auto ticket=lua.get_integer(2);if(ticket<0 || ticket>3)return 0;
        const auto command=lua.get_integer(1);if(command<0 || command>6)return 0;
        LARGE_INTEGER start{},end{},frequency{};
        if(!QueryPerformanceFrequency(&frequency)||frequency.QuadPart<=0||!QueryPerformanceCounter(&start))return 0;
        const auto thread=GetCurrentThreadId();
        const int status=dispatch.action(command,ticket,thread);
        if(!QueryPerformanceCounter(&end))return 0;
        lua.set_integer(status);lua.set_integer(thread);
        lua.set_integer(start.QuadPart);lua.set_integer(end.QuadPart);lua.set_integer(frequency.QuadPart);
        return 5;
    }catch(...){return 0;} // Missing reply is uncertain; never retry the write.
}
