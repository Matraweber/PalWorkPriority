#pragma once
#include <cstdint>
#include <string_view>

namespace pwp::file_probe {
// Deliberately not configurable by Lua, CLI arguments, environment, or cwd.
inline constexpr wchar_t root[] = L"C:\\Users\\matra\\Desktop\\palworld-priority-mod\\test-results\\native-file-probe-scratch";
inline constexpr wchar_t storage[] = L"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
inline constexpr wchar_t guild[] = L"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
inline constexpr wchar_t stream[] = L"priorities";
inline constexpr std::size_t max_hex = 524288;
// 0 published, 1 invalid, 2 conflict, 3 IO failure, 4 published-close-error,
// 5 exception/unknown outcome. Neither 4 nor 5 authorizes a retry.
struct Result {
    std::int64_t status = 1, error = 87, thread = 0;
    std::int64_t start = 0, end = 0, checksum = 0, frequency = 0;
};
Result publish_hex(std::string_view hex, std::int64_t declared_length) noexcept;
}
