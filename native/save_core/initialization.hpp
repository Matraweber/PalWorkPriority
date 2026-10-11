#pragma once
#include <string>
#include <string_view>
#include <cstdint>
namespace pwp::experimental {
// Encoded bytes, not settings payload capacity. Fits 256 KiB plus bounded envelope.
constexpr std::size_t max_publication_bytes = 262450;
// First-publication primitive only: caller must establish authority, active
// storage and typed payload semantics. Not yet integrated into any save backend.
enum class Status { published, invalid, conflict, io_error, published_close_error };
struct Result { Status status; std::uint32_t error; std::wstring stage; };
Result initialize(const std::wstring& root, std::wstring_view storage,
                  std::wstring_view guild, std::wstring_view stream,
                  std::string_view bytes);
}
