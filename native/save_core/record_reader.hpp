#pragma once
#include "record.hpp"
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace pwp::experimental::record_reader {
// Read-only namespace, distinct from initialization's pwp-init-* records:
// <root>\pwp-record-v1-<storage32>-<guild32>-<priorities|limits>-<A|B>.record
// Root must already exist on an ordinary local fixed drive. No caller leaf/path.
// Missing is an observation, never an initialization or write grant. Caller must
// supply active-storage/ownership proof and validate BOTH recovered schemas.
// Pins prevent ordinary rename/deletion; hostile namespace reconfiguration and
// memory-mapped/external writers require separate ownership enforcement.
struct Result {
    records::Read read;
    std::uint32_t error = 0;
    // Exact bounded leaf bytes, including the envelope/digest (or an engaged
    // empty string for an empty corrupt file). Present only after complete IO
    // and successful checked closes, for valid/corrupt/unsupported/foreign.
    // Missing/unreadable and oversized unsupported files have no bytes. Never
    // map this absence directly to a missing journal Preimage: check state first.
    // Retention grants no write permission; foreign/unsupported still block.
    std::optional<std::string> encoded;
};
Result read(const std::wstring& root, std::wstring_view storage,
            std::wstring_view guild, std::wstring_view stream, char slot) noexcept;
}
