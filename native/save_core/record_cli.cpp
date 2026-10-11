#include "record.hpp"
#include <iostream>
#include <iterator>
#include <fstream>
#include <fcntl.h>
#include <io.h>
using namespace pwp::experimental::records;
static Read read(const char* path,const char* scope) {
    std::string p(path);
    if(p=="MISSING") return {State::missing,{}};
    if(p=="UNREADABLE") return {State::unreadable,{}};
    std::ifstream f(path,std::ios::binary);if(!f) return {State::unreadable,{}};
    std::string data(max_record+1,'\0');f.read(data.data(),static_cast<std::streamsize>(data.size()));
    data.resize(static_cast<std::size_t>(f.gcount()));if(f.bad())return {State::unreadable,{}};
    return decode(data,scope);
}
int main(int argc,char** argv) {
    _setmode(_fileno(stdin),_O_BINARY);_setmode(_fileno(stdout),_O_BINARY);
    try {
        if(argc==4 && std::string(argv[1])=="encode") {
            std::string data(max_payload+1,'\0');std::cin.read(data.data(),static_cast<std::streamsize>(data.size()));
            data.resize(static_cast<std::size_t>(std::cin.gcount()));
            std::size_t consumed=0;const auto generation=std::stoull(argv[3],&consumed);
            if(consumed!=std::string(argv[3]).size() || generation==0 || generation>=2147483647) return 3;
            const auto out=encode({argv[2],static_cast<std::uint32_t>(generation),data});
            std::cout.write(out.data(),static_cast<std::streamsize>(out.size()));return 0;
        }
        if(argc==5 && std::string(argv[1])=="recover") {
            auto a=read(argv[3],argv[2]),b=read(argv[4],argv[2]);const int pick=candidate(a,b);
            std::cout<<pick<<'\n';if(pick>=0) {const auto& r=pick==0?a.record:b.record;std::cout<<r.generation<<'\n';std::cout.write(r.payload.data(),static_cast<std::streamsize>(r.payload.size()));}
            return pick==-2?2:0;
        }
    } catch(...) {return 3;}
    return 4;
}
