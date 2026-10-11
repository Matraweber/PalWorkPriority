#pragma once
#include "owner.hpp"
#include "record_reader.hpp"
#include "journal.hpp"
#include "root_capability.hpp"
#include <array>
#include <atomic>
#include <memory>
#include <optional>

namespace pwp::experimental {
// Internal whole-journal backend, not a Lua admission API. The trusted caller
// supplies the fixed mod-root capability and freshly authorized binding once.
// Both recovered valid payloads and new payload require typed Lua validation.
struct JournalTerminal {
    std::uint64_t ticket=0, covered_revision=0;
    bool certain=false;
    std::string status, preimages;
    std::array<records::Read,2> slots;
    std::uint32_t generation=0, error=0, cleanup_error=0;
};
class JournalJob;
class JournalBackend {
    struct State;
    std::shared_ptr<State> state;
    explicit JournalBackend(std::shared_ptr<State>);
    friend class JournalJob;
public:
    static std::shared_ptr<JournalBackend> open(std::shared_ptr<const RootCapability>,OwnerBinding);
    std::shared_ptr<JournalJob> recover(std::uint64_t ticket);
    std::shared_ptr<JournalJob> update(std::uint64_t ticket,std::string preimages,
        std::string payload,std::uint32_t generation,std::uint64_t covered_revision,bool initialize);
    std::optional<JournalTerminal> peek(std::uint64_t ticket) const;
    bool consume(std::uint64_t ticket);
    // Call only AFTER Lua's accepted/coalesced work drains. No new reservations
    // after this; an already-started operation still owns the old root/binding.
    void retire();
    bool release();
};
class JournalJob {
    const std::shared_ptr<JournalBackend::State> state;
    const std::uint64_t ticket, revision;
    const bool recovery;
    const journal::Preimages before;
    const std::string encoded;
    std::atomic<bool> started{false};
    JournalJob(std::shared_ptr<JournalBackend::State>,std::uint64_t,bool,
               journal::Preimages,std::string,std::uint64_t);
    friend class JournalBackend;
public:
    // Worker only; no Lua/UObject. Returns terminal delivery, not save success.
    // Exact shared state retains owner/root/preimages through dropped callers.
    bool run() noexcept;
};
}
