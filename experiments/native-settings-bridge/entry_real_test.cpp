// Only LuaMadeSimple is mocked. Actual entry/facade/backend/owner/root/journal IO.
// Test root and typed fixtures are generated at compile time, never Lua inputs.
#include "entry.cpp"
#include "build/real_test_payload.hpp"
#include <iostream>
#include <thread>
#include <filesystem>
using namespace pwp::settings_bridge;
namespace experimental=pwp::experimental;
namespace {
void require(bool ok,const char* why){if(!ok)throw std::runtime_error(why);}
std::string hex(std::string_view bytes){std::string out;for(unsigned char c:bytes){out+="0123456789abcdef"[c>>4];out+="0123456789abcdef"[c&15];}return out;}
struct Result {int count=0,status=-99;std::string data;};
Result invoke(int command,int handle,int ticket,const std::vector<std::string>& fields={}) {
    const auto input=hex(pack(fields));lua_State s{{command,handle,ticket,input,static_cast<std::int64_t>(input.size())},{},false};
    const int count=luaopen_pwp_settings_bridge(&s);if(!count)return {};
    require(count==6&&s.stack.size()==7&&s.rooted_read,"entry stack shape");
    require(s.reads==std::vector<int>({5,3,2,1})&&s.stack[3].number==GetCurrentThreadId(),"actual parser/thread");
    return {count,static_cast<int>(s.stack[1].number),*s.stack[2].text};
}
Result worker(int handle,int ticket) {
    Result r;std::exception_ptr error;
    std::thread t([&]{try{r=invoke(4,handle,ticket);}catch(...){error=std::current_exception();}});
    t.join();if(error)std::rethrow_exception(error);return r;
}
std::vector<std::string> finish(int handle,int ticket) {
    require(worker(handle,ticket).status==1,"real backend worker");
    const auto peek=invoke(5,handle,ticket);require(peek.status==1,"real terminal");
    auto f=unpack(peek.data);require(f.size()==16&&f[4]=="1","certain exact16 reply");return f;
}
void consume(int handle,int ticket) {
    lua_State::lose_reply=true;
    require(invoke(6,handle,ticket).count==0,"drop reply after actual consume");
    require(invoke(6,handle,ticket).status==1&&invoke(6,handle,ticket).status==1,"consume repeat after loss");
}
void release(int handle) {require(invoke(7,handle,0).status==1&&invoke(8,handle,0).status==1,"explicit drained release");}
}
int main() {
    try {
        const std::string world(32,'a'),guild(32,'b'),scope="PWP-SCOPE-1:"+world+":"+guild+":priorities";
        require(std::filesystem::is_empty(pwp_settings_test_root),"disposable test root must start empty");
        require(invoke(0,0,0).status==1,"fixed test root configuration");
        const auto bound=invoke(1,1,0,{world,guild,"priorities","real:1","1"});
        require(bound.status==1,"real binding");const int h=std::stoi(unpack(bound.data)[0]);
        require(invoke(2,h,1).status==1,"admit recovery");
        require(invoke(4,h,1).status==0&&std::filesystem::is_empty(pwp_settings_test_root),"wrong-thread no journal IO");
        const auto pending=invoke(5,h,1);require(pending.status==2&&pending.data.empty(),"real pending");
        auto f=finish(h,1);
        require(f[0]==scope&&f[1]=="real:1"&&f[2]=="1"&&f[3]=="recovered"&&f[5]=="0","identity/recovery fields");
        require(f[10]=="missing"&&f[11]=="0"&&f[12].empty()&&f[13]=="missing"&&f[14]=="0"&&f[15].empty(),"real missing normalization");
        consume(h,1);
        require(invoke(3,h,2,{f[7],pwp_typed_payload_1,"1","1","1"}).status==1,"initialize typed payload");
        require(invoke(6,h,1).status==1,"old consume repeat while real new job pending");
        require(worker(h,1).status==0,"stale run no redirection");
        f=finish(h,2);require(f[3]=="initialized"&&f[5]=="1"&&f[6]=="1","real initialization terminal");
        for(unsigned i=10;i<16;++i)require(f[i].empty(),"initialization slot fields empty");
        consume(h,2);
        require(invoke(3,h,3,{f[7],pwp_typed_payload_2,"2","2","0"}).status==1,"update typed payload");
        f=finish(h,3);require(f[3]=="updated"&&f[5]=="2"&&f[6]=="2","real update terminal");consume(h,3);
        release(h);
        const auto rebound=invoke(1,1,0,{world,guild,"priorities","real:2","2"});
        require(rebound.status==1,"rebind after release");const int other=std::stoi(unpack(rebound.data)[0]);
        require(other>h&&invoke(2,other,1).status==1,"new handle fresh recovery");
        f=finish(other,1);
        require(f[0]==scope&&f[1]=="real:2"&&f[2]=="2"&&f[5]=="2","new native identity actual recovery");
        require(f[10]=="valid"&&f[11]=="1"&&f[12]==pwp_typed_payload_1
            &&f[13]=="valid"&&f[14]=="2"&&f[15]==pwp_typed_payload_2,"actual typed payloads recovered through entry packets");
        std::cout<<"TYPED_A_HEX="<<hex(f[12])<<"\nTYPED_B_HEX="<<hex(f[15])<<'\n';
        consume(other,1);release(other);
        const auto a=experimental::record_reader::read(pwp_settings_test_root,std::wstring(32,L'a'),std::wstring(32,L'b'),L"priorities",'A');
        const auto b=experimental::record_reader::read(pwp_settings_test_root,std::wstring(32,L'a'),std::wstring(32,L'b'),L"priorities",'B');
        require(a.read.state==experimental::records::State::valid&&b.read.state==experimental::records::State::valid
            &&a.read.record.payload==pwp_typed_payload_1&&b.read.record.payload==pwp_typed_payload_2,"real records independently decoded");
        std::cout<<"PASS actual entry + REAL native backend/root/owner/journal: typed A/B recovery/update, identity, wrong-thread, lost consume reply\n";
        return 0;
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
