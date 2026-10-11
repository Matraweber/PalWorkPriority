#pragma once
#include "record.hpp"
#include <array>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace pwp::experimental::journal {
// DEVELOPMENT ONLY. Same A/B namespace as record_reader:
// pwp-record-v1-<storage32>-<guild32>-<priorities|limits>-<A|B>.record
// A null expected preimage means positively observed missing; an engaged value
// is the entire exact encoded file (including an empty/corrupt existing file).
// Caller must validate settings schemas on BOTH integrity-valid preimages and
// the new payload, prove active storage, and hold cooperative SaveOwner ownership
// through the whole call. No authority booleans or automatic initialization policy.
// This primitive itself performs no owner claim and provides no durable ACK.
using Preimages = std::array<std::optional<std::string>, 2>;
enum class Status { initialized, updated, conflict, io_error, uncertain };
struct Result {
    Status status = Status::uncertain;
    std::uint32_t error = 0;
    // Planned target, not proof of publication. '?' until a decision exists.
    char slot = '?';
    std::uint32_t generation = 0;
    // Independent cleanup warning, never a reason to retry a published write.
    // With updated/error=0: delete disposition was not accepted; backup retained.
    // With uncertain: cleanup/close outcome may be ambiguous; no retention promise.
    std::uint32_t cleanup_error = 0;
};
// Root-wide budget includes ALL pwp-journal-* entries, even unrelated scopes,
// directories or reparse entries. Reserve headroom for stage + optional backup.
// No orphan cleanup. A root-file-identity kernel creation gate serializes this
// primitive's artifact creation across scopes/processes/DLL copies; external
// noncooperating artifact creation is not bounded. This is not a SaveOwner lease.
constexpr std::size_t retained_limit = 32;
// Backups: pwp-journal-backup-<random128>.record; stages:
// pwp-journal-stage-<random128>.tmp. Neither is an automatic recovery candidate.
// Only this call's exact renamed inactive backup handle is marked for deletion
// after successful publication, then closed while the new and old active records
// remain exclusively held. Pre-disposition failure retains it with cleanup_error;
// any close ambiguity is uncertain. Never delete preexisting/unknown artifacts.
// Pinned roots/exclusive file handles protect ordinary mutation, not malicious
// namespace reconfiguration or preexisting writable mappings. No power-loss claim.
// initialized/updated mean flushed nonreplacing publication and checked closes.
// conflict/io_error mean this call did NOT publish the new record; retained stage
// or inactive backup may exist. uncertain forbids retry/ACK until reconciliation.
Result update(const std::wstring& root, std::wstring_view storage,
              std::wstring_view guild, std::wstring_view stream,
              const Preimages& expected, std::string_view encoded) noexcept;
}
