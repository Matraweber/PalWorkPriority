// Standalone test driver. Opens/pins directories only; never writes fixtures.
#include "root_capability.hpp"
#include <functional>
#include <iomanip>
#include <iostream>
#include <string>
using namespace pwp::experimental;
namespace { bool fail_close=false; unsigned close_calls=0; }
#ifdef PWP_ROOT_CAPABILITY_TESTING
extern "C" unsigned long pwp_root_test_close_error() noexcept {
    ++close_calls;return fail_close ? 29UL : 0UL;
}
#endif
void status() {
    const auto s=RootCapability::release_status();
    std::cout<<"STATE "<<static_cast<int>(s.state)<<' '<<s.error<<' '<<close_calls<<std::endl;
}
int wmain(int argc,wchar_t** argv) {
    if(argc!=3)return 2;
    std::string label;
    for(const wchar_t* p=argv[2];*p;++p) {
        if(*p>127) {label="!";break;} label+=static_cast<char>(*p);
    }
    auto cap=RootCapability::open(argv[1],label);
    if(!cap) {std::cout<<"REJECT ";status();return 0;}
    const auto id=cap->identity();
    std::cout<<"READY "<<id.volume<<' ';
    for(auto b:id.file_id)std::cout<<std::hex<<std::setw(2)<<std::setfill('0')<<static_cast<unsigned>(b);
    std::cout<<std::dec<<' '<<cap->profile_namespace()<<std::endl;
    std::function<std::wstring()> captured;
    std::string command;
    while(std::getline(std::cin,command)) {
        if(command=="capture") {captured=[cap]{return cap->path();};std::cout<<"CAPTURED"<<std::endl;}
        else if(command=="drop") {cap.reset();status();}
        else if(command=="uncapture") {captured={};status();}
        else if(command=="captured-path") std::cout<<(captured && captured()==argv[1]?"MATCH":"MISMATCH")<<std::endl;
        else if(command=="retire") {RootCapability::retire();status();}
        else if(command=="reopen") std::cout<<(RootCapability::open(argv[1],label)?"REOPENED":"DENIED")<<std::endl;
#ifdef PWP_ROOT_CAPABILITY_TESTING
        else if(command=="fail-close") {fail_close=true;std::cout<<"FAULT-ARMED"<<std::endl;}
#endif
        else if(command=="status") status();
        else if(command=="quit") break;
        else return 3;
    }
    return 0;
}
