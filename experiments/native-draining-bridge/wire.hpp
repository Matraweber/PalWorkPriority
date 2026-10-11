#pragma once
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>
#include <stdexcept>
namespace pwp::draining_bridge {
constexpr std::size_t max_payload=262144, max_input=600000, max_output=600000;
inline std::string unhex(std::string_view hex) {
    if(hex.size()>max_input*2 || hex.size()%2)throw std::runtime_error("hex size");
    auto nibble=[](char c)->int {if(c>='0'&&c<='9')return c-'0';if(c>='a'&&c<='f')return c-'a'+10;return -1;};
    std::string out;out.reserve(hex.size()/2);
    for(std::size_t i=0;i<hex.size();i+=2) {
        const int a=nibble(hex[i]),b=nibble(hex[i+1]);
        if(a<0||b<0)throw std::runtime_error("hex digit");
        out.push_back(static_cast<char>((a<<4)|b));
    }
    return out;
}
inline std::vector<std::string> unpack(std::string_view bytes) {
    std::vector<std::string> out;
    while(!bytes.empty()) {
        if(bytes.size()<4||out.size()>=16)throw std::runtime_error("field header");
        std::uint32_t n=0;
        for(unsigned i=0;i<4;++i)n|=static_cast<std::uint32_t>(static_cast<unsigned char>(bytes[i]))<<(8*i);
        bytes.remove_prefix(4);
        if(n>bytes.size())throw std::runtime_error("field length");
        out.emplace_back(bytes.substr(0,n));bytes.remove_prefix(n);
    }
    return out;
}
inline std::string pack(const std::vector<std::string>& fields) {
    std::string out;
    for(const auto& s:fields) {
        if(s.size()>max_output || out.size()>max_output-4 || s.size()>max_output-4-out.size())throw std::runtime_error("output size");
        const auto n=static_cast<std::uint32_t>(s.size());
        for(unsigned i=0;i<4;++i)out.push_back(static_cast<char>((n>>(8*i))&255));
        out+=s;
    }
    return out;
}
inline bool decimal(std::string_view s,std::uint64_t maximum,std::uint64_t& out) {
    if(s.empty()||s.size()>20||(s.size()>1&&s[0]=='0'))return false;
    out=0;
    for(char c:s) {if(c<'0'||c>'9')return false;const auto digit=static_cast<unsigned>(c-'0');
        if(digit>maximum||out>(maximum-digit)/10)return false;out=out*10+digit;}
    return true;
}
inline bool guid(std::string_view s) {
    if(s.size()!=32)return false;bool nonzero=false;
    for(char c:s){if(!((c>='0'&&c<='9')||(c>='a'&&c<='f')))return false;nonzero|=c!='0';}return nonzero;
}
struct Reply {int status=0;std::string data;};
}
