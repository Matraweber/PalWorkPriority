#ifdef PWP_LEGACY_ENTRY_TEST
#include "build/entry_legacy_mutant.inc"
#elif defined(PWP_UNROOTED_ENTRY_TEST)
#include "build/entry_unrooted_mutant.inc"
#else
#include "entry.cpp"
#endif
#include <iostream>
#include <thread>
using namespace pwp::settings_bridge;
namespace {
void require(bool ok,const char* why){if(!ok)throw std::runtime_error(why);}
std::string hex(std::string_view bytes){std::string out;for(unsigned char c:bytes){out+="0123456789abcdef"[c>>4];out+="0123456789abcdef"[c&15];}return out;}
struct Result {int count=0,status=-99;std::string data;};
Result invoke(int command,int handle,int ticket,const std::vector<std::string>& fields={}) {
    const auto input=hex(pack(fields));lua_State s{{command,handle,ticket,input,static_cast<std::int64_t>(input.size())},{},false};
    const int count=luaopen_pwp_settings_bridge(&s);
    if(!count)return {};
    require(count==6&&s.stack.size()==7,"six results above retained input root");
    require(s.reads==std::vector<int>({5,3,2,1})&&s.rooted_read,"descending popped integers and rooted string");
    require(s.stack[2].text!=nullptr&&s.stack[3].number==GetCurrentThreadId(),"result layout/thread");
    require(s.stack[5].number>=s.stack[4].number&&s.stack[6].number>0,"QPC result");
    return {count,static_cast<int>(s.stack[1].number),*s.stack[2].text};
}
Result worker(int command,int handle,int ticket,const std::vector<std::string>& fields={}) {
    Result r;std::exception_ptr error;
    std::thread t([&]{try {r=invoke(command,handle,ticket,fields);}catch(...){error=std::current_exception();}});
    t.join();if(error)std::rethrow_exception(error);return r;
}
std::vector<std::string> binding(std::string world=std::string(32,'a')) {
    return {world,std::string(32,'b'),"priorities","boot:1","12"};
}
int open(){const auto r=invoke(1,1,0,binding());require(r.status==1,"bind succeeds");return std::stoi(unpack(r.data).at(0));}
void consumed(int handle,int ticket) {
    require(worker(4,handle,ticket).status==1,"exact worker runs");
    require(invoke(5,handle,ticket).status==1,"terminal peek");
    require(invoke(6,handle,ticket).status==1,"consume");
}
}
int main(int argc,char** argv) {
    try {
        if(argc>1&&std::string(argv[1])=="configure") {
            NativeBackend::failure="configure";
            require(invoke(0,0,0).count==0&&invoke(0,0,0).status==0&&NativeBackend::configurations==1,"configuration throw no retry");
            std::cout<<"PASS configure uncertainty no retry\n";return 0;
        }
        const auto config=invoke(0,0,0);
        require(config.count==6&&config.status==1,"REGRESSION: actual entry popped-argument/rooted-input configure failed");
        require(unpack(config.data)==std::vector<std::string>({"1"}),"root capability ID");
        if(argc>1) {
            const std::string mode=argv[1];
            if(mode=="capacity") {
                for(int i=1;i<=128;++i)require(open()==i,"monotonic IDs");
                require(invoke(1,1,0,binding()).status==0&&NativeBackend::opens==128,"bounded registry");
            } else if(mode=="open") {
                NativeBackend::failure="open";require(invoke(1,1,0,binding()).count==0,"open exception uncertain");
                NativeBackend::failure.clear();require(open()==2,"failed binding burns ID");
            } else {
                const int h=open();
                if(mode=="recover") {NativeBackend::failure=mode;require(invoke(2,h,1).count==0,"admission exception uncertain");}
                else {
                    require(invoke(2,h,1).status==1,"admission");
                    if(mode=="run") {NativeBackend::failure=mode;require(worker(4,h,1).count==0,"run exception uncertain");}
                    else if(mode=="run_false") {NativeBackend::run_false=true;require(worker(4,h,1).count==0,"false delivery uncertain");require(invoke(5,h,1).status==1,"terminal remains inspectable");}
                    else if(mode=="uncertain") {NativeBackend::uncertain=true;require(worker(4,h,1).status==1,"uncertain delivered");
                        require(unpack(invoke(5,h,1).data)[4]=="0"&&invoke(6,h,1).status==0,"uncertain not consumed");}
                    else {
                        consumed(h,1);
                        if(mode=="release") {require(invoke(7,h,0).status==1,"retire");NativeBackend::failure=mode;require(invoke(8,h,0).count==0,"release exception uncertain");}
                        else if(mode=="release_false") {require(invoke(7,h,0).status==1,"retire");NativeBackend::refuse=true;require(invoke(8,h,0).count==0,"release false uncertain");}
                        else throw std::runtime_error("unknown test mode");
                    }
                }
            }
            std::cout<<"PASS isolated failure/capacity mode "<<mode<<'\n';return 0;
        }
        require(invoke(0,0,0).status==0&&NativeBackend::configurations==1,"no configure repeat");
        require(worker(1,1,0,binding()).status==0&&NativeBackend::opens==0,"bind thread preflight");
        const int a=open(),b=open();require(a==1&&b==2,"monotonic binding handles");
        require(invoke(2,a,1).status==1&&invoke(2,b,2).status==1,"two captured jobs");
        for(int cmd:{2,3,5,6,7,8})require(worker(cmd,a,cmd>=7?0:1).status==0,"game-only command thread gate");
        require(invoke(4,a,1).status==0&&NativeBackend::runs==0,"wrong-thread run no backend IO");
        require(worker(4,a,2).status==0&&worker(4,b,1).status==0&&worker(4,99,1).status==0,"wrong ticket/handle no IO");
        require(NativeBackend::runs==0,"rejected worker side effects");
        const auto pending=invoke(5,a,1);require(pending.status==2&&pending.data.empty(),"pending empty data");
        require(invoke(7,a,0).status==0&&invoke(8,a,0).status==0,"no retirement with pending work");
        NativeBackend::hold=true;NativeBackend::entered=false;
        Result work;
        std::thread first([&]{work=invoke(4,a,1);});
        while(!NativeBackend::entered.load())std::this_thread::yield();
        const auto duplicate=worker(4,a,1),busy=invoke(5,a,1),consume_busy=invoke(6,a,1);
        NativeBackend::hold=false;first.join();
        require(work.status==1&&duplicate.status==0&&busy.status==2&&consume_busy.status==0,"concurrent duplicate/run guards");
        require(NativeBackend::runs==1&&NativeBackend::last_run==1,"captured job run once");
        const auto terminal=unpack(invoke(5,a,1).data);
        require(terminal.size()==16&&terminal[0]=="PWP-SCOPE-1:"+std::string(32,'a')+":"+std::string(32,'b')+":priorities"
            &&terminal[1]=="boot:1"&&terminal[2]=="12","actual retained native binding identity prefix");
        require(terminal[12]==std::string("a\0b\xffz",5)&&terminal[14]=="0"&&terminal[15].empty(),"binary output and nonvalid normalization");
        const auto before_consume=NativeBackend::consumes;
        lua_State::lose_reply=true;
        require(invoke(6,a,1).count==0&&NativeBackend::consumes==before_consume+1,"native consumed but Lua return lost");
        require(invoke(6,a,1).status==1&&NativeBackend::consumes==before_consume+1,"exact consume retry idempotent");
        const std::string binary("a\0b\xffz",5);
        const std::vector<std::string> update{"preimage-token",binary,"8","10","0"};
        require(invoke(3,a,3,update).status==1&&NativeBackend::last_fields[1]==binary,"binary NUL hex copied intact");
        require(invoke(6,a,1).status==1&&NativeBackend::consumes==before_consume+1,"old consume retry preserves newer pending job");
        require(worker(4,a,1).status==0,"old closure cannot run new job");
        require(worker(4,a,3).status==1,"new exact job");
        const auto recovered=unpack(invoke(5,a,3).data);
        require(recovered.size()==16,"exact update field count");
        for(unsigned i=10;i<16;++i)require(recovered[i].empty(),"update slot fields empty");
        require(invoke(6,a,3).status==1,"update consume");consumed(b,2);
        require(invoke(8,a,0).status==0&&invoke(7,a,1).status==0,"release requires retire and zero ticket");
        require(invoke(7,a,0).status==1&&invoke(8,a,0).status==1,"explicit retire/release after drain");
        require(invoke(2,a,4).status==0&&invoke(8,a,0).status==0,"released handle never reused");
        require(open()==3,"IDs never recycle");
        for(auto state:{pwp::experimental::records::State::corrupt,pwp::experimental::records::State::unsupported,
                pwp::experimental::records::State::foreign,pwp::experimental::records::State::unreadable}) {
            pwp::experimental::JournalTerminal t;t.status="recovered";t.slots[0]={state,{"foreign",9,"hidden"}};
            const auto fields=unpack(terminal_data(t));require(fields.size()==13&&fields[8]=="0"&&fields[9].empty(),"all nonvalid slots scrubbed");
            t.status="cancelled-before-io";const auto cancelled=unpack(terminal_data(t));
            for(unsigned i=7;i<13;++i)require(cancelled[i].empty(),"cancel slots empty");
        }
        const auto admissions=NativeBackend::admissions,opens=NativeBackend::opens;
        for(const auto& bad:std::vector<std::vector<std::string>>{{"x"},{"","p","1","1","0"},{"t","p","01","1","0"},
            {"t","p","1","0","0"},{"t","p","1","1","2"},{"t",std::string(max_payload+1,'x'),"1","1","0"}})
            require(invoke(3,3,1,bad).status==0,"invalid update refused");
        require(invoke(1,1,0,binding(std::string(32,'0'))).status==0&&NativeBackend::opens==opens,"invalid GUID no open");
        require(NativeBackend::admissions==admissions,"invalid fields no backend effects");
        for(auto s:std::vector<lua_State>{
            {{0,0,0,std::string("00"),0},{},false},{{0,0,0,std::string("zz"),2},{},false},
            {{0,0,0,std::string("000000"),6},{},false},{{0,0,0,std::string("ffffffff"),8},{},false},
            {{0,0,0,std::string("00\0x",4),4},{},false},{{0,0,0,std::string(),1},{},false},
            {{0,0,0,std::string(),-2},{},false},{{0,0,0,7,0},{},false},{{0,0},{},false}})
            require(luaopen_pwp_settings_bridge(&s)==0,"malformed transport returns zero results");
        std::cout<<"PASS actual entry: popped arguments, retained root, binary IO, exact 16 fields, identity, threads, stale/duplicate jobs, strict transport\n";
        return 0;
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
