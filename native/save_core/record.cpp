#include "record.hpp"
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <Windows.h>
#include <bcrypt.h>
#include <array>
#include <stdexcept>
namespace pwp::experimental::records {
namespace {
constexpr std::string_view magic = "PWPJNL1\n";
bool scope_ok(std::string_view s) {
    constexpr std::string_view prefix = "PWP-SCOPE-1:";
    if (s.substr(0, prefix.size()) != prefix || s.size() < 78) return false;
    auto guid = [](std::string_view g) {
        if (g.size() != 32 || g == std::string(32, '0')) return false;
        for (char c : g) if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
        return true;
    };
    if (!guid(s.substr(12,32)) || s[44] != ':' || !guid(s.substr(45,32)) || s[77] != ':') return false;
    return s.substr(78) == "priorities" || s.substr(78) == "limits";
}
bool valid(const Record& r) {
    return scope_ok(r.scope) && r.generation > 0 && r.generation < 2147483647u && r.payload.size() <= max_payload;
}
void put(std::string& out, std::uint32_t n, unsigned size) {
    for (unsigned i=0; i<size; ++i) out.push_back(static_cast<char>((n >> (8*i)) & 255));
}
std::uint32_t get(std::string_view bytes, std::size_t offset, unsigned size) {
    std::uint32_t n=0;
    for (unsigned i=0; i<size; ++i) n |= static_cast<std::uint32_t>(static_cast<unsigned char>(bytes[offset+i])) << (8*i);
    return n;
}
std::array<unsigned char,32> digest(std::string_view bytes) {
    std::array<unsigned char,32> out{};
    if (BCryptHash(BCRYPT_SHA256_ALG_HANDLE, nullptr, 0,
        reinterpret_cast<PUCHAR>(const_cast<char*>(bytes.data())), static_cast<ULONG>(bytes.size()),
        out.data(), static_cast<ULONG>(out.size())) < 0) throw std::runtime_error("SHA256 unavailable");
    return out;
}
bool blocked(State s) { return s==State::unsupported || s==State::foreign || s==State::unreadable; }
}
std::string encode(const Record& r) {
    if (!valid(r)) throw std::invalid_argument("invalid record");
    std::string out(magic);
    put(out, static_cast<std::uint32_t>(r.scope.size()), 2);put(out,r.generation,4);
    put(out,static_cast<std::uint32_t>(r.payload.size()),4);
    out += r.scope;out += r.payload;
    const auto hash=digest(out);out.append(reinterpret_cast<const char*>(hash.data()),hash.size());
    return out;
}
Read decode(std::string_view bytes, std::string_view scope) {
    if (!scope_ok(scope)) return {State::unreadable,{}};
    if (bytes.size()>max_record) return {State::unsupported,{}};
    if (bytes.size()<magic.size()) return {State::corrupt,{}};
    if (bytes.substr(0,magic.size())!=magic) return {State::unsupported,{}};
    if (bytes.size()<50) return {State::corrupt,{}};
    const auto scope_size=get(bytes,8,2), generation=get(bytes,10,4), size=get(bytes,14,4);
    if (scope_size>max_scope || size>max_payload || generation>=2147483647u) return {State::unsupported,{}};
    if (bytes.size()!=18+scope_size+size+32 || scope_size==0 || generation==0) return {State::corrupt,{}};
    const auto stored=bytes.substr(18,scope_size);
    if (stored!=scope) return {State::foreign,{}};
    const auto body=bytes.substr(0,bytes.size()-32);
    const auto hash=digest(body);
    if (bytes.substr(body.size())!=std::string_view(reinterpret_cast<const char*>(hash.data()),hash.size())) return {State::corrupt,{}};
    return {State::valid,{std::string(stored),generation,std::string(bytes.substr(18+scope_size,size))}};
}
int candidate(const Read& a, const Read& b) {
    if (blocked(a.state)||blocked(b.state)) return -2;
    if (a.state==State::valid && !valid(a.record)) return -2;
    if (b.state==State::valid && !valid(b.record)) return -2;
    if (a.state==State::valid && b.state==State::valid) {
        if (a.record.scope!=b.record.scope) return -2;
        if (a.record.generation==b.record.generation && a.record.payload!=b.record.payload) return -2;
        return b.record.generation>a.record.generation ? 1 : 0;
    }
    if (a.state==State::valid) return 0;
    if (b.state==State::valid) return 1;
    return a.state==State::missing && b.state==State::missing ? -1 : -2;
}
}
