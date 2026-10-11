#pragma once
#include "backend.hpp"
#include <mutex>
#include <thread>

namespace pwp::experimental {
enum class DrainPhase { dormant, recovering, awaiting_validation, ready, closing, closed, blocked };
enum class DrainError { none, recovery, admission, publication, uncertain, consume, release, exception };
enum class RecoveryApproval { existing, initialize_missing };
struct DrainStatus {
    DrainPhase phase=DrainPhase::dormant;
    DrainError error=DrainError::none;
    std::uint64_t accepted=0, committed=0;
    std::uint32_t generation=0, cleanup_error=0;
    // Retained native terminal: inspect BOTH recovery slots before approval.
    std::optional<JournalTerminal> terminal;
};

// Experimental/default-off. No storage authority or settings-schema validator.
// open claims a private backend/owner ONLY: no reader IO or worker launch.
// A separate trusted postcheck/admission adapter must call start_recovery AFTER
// its grant remains valid. This is NOT a direct replacement for bridge command 1.
// Await recovery, validate BOTH valid schemas on the control side, then approve.
// initialize_missing is explicit caller authorization following positive absence;
// its FIRST admitted payload cannot be coalesced away. Later complete snapshots
// coalesce to the newest logical revision; admission is NEVER a durable ACK.
// submit copies <=records::max_payload bytes, retains at most one active/initial
// snapshot plus one latest tail. Original backend/root/owner never change.
// A dedicated native thread runs recovery and IO: no Lua, engine, logging or
// game-thread callbacks. This implementation module is pinned before launch.
// close fences new submissions but drains accepted work before retire/release.
// drain closes and joins WITHOUT holding any mutex needed by the worker. It has
// NO wall-time bound (filesystem calls can block), and must not run under loader
// lock/DllMain or locks used by filesystem filters. Destructor also closes/joins.
// Unresolved state intentionally retains itself until process teardown: at most
// eight live/unresolved coordinators per loaded implementation. No timeout reset,
// retry, cancellation, reconciliation or owner release on failure. Failures may
// already have published bytes; only committed revisions are acknowledged.
// Caller must prove invocation on each supported orderly shutdown route. This
// does not guarantee crash/power-loss durability or transactional two-stream saves.
class DrainingWriter final {
    struct State;
    std::shared_ptr<State> state;
    std::thread worker;
    std::mutex join_gate;
    explicit DrainingWriter(std::shared_ptr<State>);
    static void work(const std::shared_ptr<State>&) noexcept;
public:
    static std::unique_ptr<DrainingWriter> open(std::shared_ptr<const RootCapability>,OwnerBinding);
    DrainingWriter(const DrainingWriter&)=delete;
    DrainingWriter& operator=(const DrainingWriter&)=delete;
    ~DrainingWriter();
    bool start_recovery();
    DrainStatus wait_recovery();
    bool approve_recovery(RecoveryApproval);
    // 0 means definitely not admitted. Throws (allocation) occur before admission.
    // Logical revisions are local to this coordinator, independent of disk gen.
    std::uint64_t submit(std::string payload);
    void close();
    DrainStatus status() const;
    DrainStatus drain();
};
}
