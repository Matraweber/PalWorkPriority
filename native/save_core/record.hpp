#pragma once
#include <cstdint>
#include <string>
#include <string_view>
namespace pwp::experimental::records {
constexpr std::size_t max_payload = 262144;
constexpr std::size_t max_scope = 256;
constexpr std::size_t max_record = 18 + max_scope + max_payload + 32;
enum class State { valid, missing, corrupt, unsupported, foreign, unreadable };
struct Record { std::string scope; std::uint32_t generation = 0; std::string payload; };
struct Read { State state = State::unreadable; Record record; };
// Integrity envelope only; settings schema and active storage require separate proof.
std::string encode(const Record& record);
Read decode(std::string_view bytes, std::string_view expected_scope);
// 0/1 = candidate A/B, -1 = both positively missing, -2 = blocked.
// Caller must establish read classifications and exclusive ownership before IO.
// Never grants a write, fallback or durable acknowledgement by itself.
int candidate(const Read& a, const Read& b);
}
