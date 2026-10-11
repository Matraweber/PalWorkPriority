#include "draining_writer.hpp"
#include <condition_variable>
#include <utility>
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <Windows.h>
#ifdef PWP_LIVE_PENDING_GATE_DEV_ONLY
#include "../../experiments/native-draining-bridge/live_pending_gate.hpp"
#endif

namespace pwp::experimental {
#ifdef PWP_DRAINING_LANE_TESTING
void draining_writer_test_lane_waiting();
#endif
namespace {
// One native publication lane per loaded implementation. The journal's named
// root reservation remains a nonwaiting external-conflict check across DLLs and
// processes. Only worker threads wait here, before backend update admission;
// submit/status/close never acquire this lock. SRWLOCK has no CRT destructor,
// and the implementation is pinned before any worker can start. No joins or
// Lua/engine callbacks occur while the lane is held. Different roots may also
// serialize (the current implementation configures just one fixed root).
SRWLOCK publication_lane=SRWLOCK_INIT;
struct PublicationLane {
    PublicationLane() noexcept {
#ifdef PWP_DRAINING_LANE_TESTING
        if(TryAcquireSRWLockExclusive(&publication_lane))return;
        draining_writer_test_lane_waiting();
#endif
        AcquireSRWLockExclusive(&publication_lane);
    }
    ~PublicationLane(){ReleaseSRWLockExclusive(&publication_lane);}
    PublicationLane(const PublicationLane&)=delete;
    PublicationLane& operator=(const PublicationLane&)=delete;
};
std::atomic<unsigned> live{0};
const char module_anchor=0;
constexpr std::uint64_t limit=2147483647;
bool pin() {
    HMODULE module=nullptr;
    return GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_PIN,
        reinterpret_cast<LPCWSTR>(&module_anchor),&module)!=0;
}
}
#ifdef PWP_DRAINING_WRITER_TESTING
void draining_writer_test_before_update(std::uint64_t revision);
void draining_writer_test_before_pick();
// Optional test-only observer. Other writer tests need no extra link symbol;
// production builds contain neither this pointer nor the call below.
void (*draining_writer_test_before_join)(std::thread::id,std::uint64_t,std::uint64_t)=nullptr;
#endif
struct DrainingWriter::State {
#ifdef PWP_LIVE_PENDING_GATE_DEV_ONLY
    live_pending::Gate live_gate;
#endif
    struct Snapshot { const std::string bytes; const std::uint64_t revision;
        Snapshot(std::string b,std::uint64_t r):bytes(std::move(b)),revision(r){} };
    const std::shared_ptr<JournalBackend> backend;
    mutable std::mutex gate;
    std::condition_variable changed;
    DrainStatus status;
    bool closing=false, approved=false, initialize=false;
    std::shared_ptr<const Snapshot> initial,latest,active;
    // Self-retention also covers exceptions after a backend reservation. Cleared
    // only once release is positively confirmed, never merely when thread exits.
    std::shared_ptr<State> retained;
    explicit State(std::shared_ptr<JournalBackend> b):backend(std::move(b)){}
    ~State(){--live;}
};
DrainingWriter::DrainingWriter(std::shared_ptr<State> s):state(std::move(s)){}
std::unique_ptr<DrainingWriter> DrainingWriter::open(std::shared_ptr<const RootCapability> root,OwnerBinding binding) {
    if(!pin())return {};
    unsigned count=live.load();
    do {if(count>=8)return {};} while(!live.compare_exchange_weak(count,count+1));
    std::shared_ptr<JournalBackend> backend;
    std::shared_ptr<State> s;
    try {
#ifdef PWP_LIVE_PENDING_GATE_DEV_ONLY
        const auto live_scope=binding.scope;
#endif
        backend=JournalBackend::open(std::move(root),std::move(binding));
        if(!backend){--live;return {};}
        s=std::make_shared<State>(backend);
#ifdef PWP_LIVE_PENDING_GATE_DEV_ONLY
        s->live_gate.scope=live_scope;
#endif
        auto out=std::unique_ptr<DrainingWriter>(new DrainingWriter(s));
        s->retained=s;
        return out;
    }catch(...) {
        // No worker started if construction threw. No job was reserved.
        if(backend){backend->retire();if(backend->release()&&s)s->retained.reset();}
        if(!s)--live;
        throw;
    }
}
DrainingWriter::~DrainingWriter(){close();std::lock_guard<std::mutex> lock(join_gate);if(worker.joinable())worker.join();}
bool DrainingWriter::start_recovery() {
    std::lock_guard<std::mutex> join_lock(join_gate);
    std::lock_guard<std::mutex> lock(state->gate);
    if(state->closing||state->status.phase!=DrainPhase::dormant)return false;
    state->status.phase=DrainPhase::recovering;
    try {auto s=state;worker=std::thread([s]{work(s);});return true;}
    catch(...) {
        state->closing=true;state->status.phase=DrainPhase::blocked;
        state->status.error=DrainError::exception;state->changed.notify_all();return false;
    }
}
DrainStatus DrainingWriter::status() const {std::lock_guard<std::mutex> lock(state->gate);return state->status;}
DrainStatus DrainingWriter::wait_recovery() {
    std::unique_lock<std::mutex> lock(state->gate);
    state->changed.wait(lock,[&]{return state->status.phase!=DrainPhase::recovering;});
    return state->status;
}
bool DrainingWriter::approve_recovery(RecoveryApproval approval) {
    std::lock_guard<std::mutex> lock(state->gate);
    if(state->closing||state->status.phase!=DrainPhase::awaiting_validation||!state->status.terminal)return false;
    const auto& slots=state->status.terminal->slots;
    const auto candidate=records::candidate(slots[0],slots[1]);
    if((approval==RecoveryApproval::existing&&candidate<0)
       ||(approval==RecoveryApproval::initialize_missing&&candidate!=-1)
       ||(approval!=RecoveryApproval::existing&&approval!=RecoveryApproval::initialize_missing))return false;
    state->initialize=candidate==-1;state->approved=true;state->status.phase=DrainPhase::ready;
#ifdef PWP_LIVE_PENDING_GATE_DEV_ONLY
    state->live_gate.arm(approval==RecoveryApproval::existing
        &&slots[0].state==records::State::valid&&slots[1].state==records::State::valid);
#endif
    state->changed.notify_all();return true;
}
std::uint64_t DrainingWriter::submit(std::string payload) {
    if(payload.size()>records::max_payload)return 0;
    std::lock_guard<std::mutex> lock(state->gate);
    if(state->closing||!state->approved||state->status.phase!=DrainPhase::ready||state->status.accepted+1>=limit)return 0;
    const auto revision=state->status.accepted+1;
    auto snapshot=std::make_shared<const State::Snapshot>(std::move(payload),revision);
    if(state->initialize&&revision==1)state->initial=snapshot;
    state->latest=std::move(snapshot);state->status.accepted=revision;
    state->changed.notify_all();return revision;
}
void DrainingWriter::close() {
    std::lock_guard<std::mutex> lock(state->gate);state->closing=true;
    // No worker exists in dormant phase, and start_recovery uses this same gate.
    // Releasing an inert owner needs no filesystem read/write or thread join.
    if(state->status.phase==DrainPhase::dormant) {
        state->backend->retire();
        if(state->backend->release()){state->status.phase=DrainPhase::closed;state->retained.reset();}
        else {state->status.phase=DrainPhase::blocked;state->status.error=DrainError::release;}
    }
    // Keep recovering visible until the recovery terminal is actually available.
    if(state->status.phase==DrainPhase::ready)state->status.phase=DrainPhase::closing;
    state->changed.notify_all();
}
DrainStatus DrainingWriter::drain() {
    close();{
        std::lock_guard<std::mutex> lock(join_gate);
        if(worker.joinable()){
#ifdef PWP_LIVE_PENDING_GATE_DEV_ONLY
            const auto live_pending_status=status();
            state->live_gate.before_join(live_pending_status.accepted,live_pending_status.committed);
#endif
#ifdef PWP_DRAINING_WRITER_TESTING
            if(draining_writer_test_before_join){
                const auto pending=status();
                draining_writer_test_before_join(worker.get_id(),pending.accepted,pending.committed);
            }
#endif
            worker.join();
        }
    }
    return status();
}
void DrainingWriter::work(const std::shared_ptr<State>& s) noexcept {
    auto fail=[&](DrainError error) {
        std::lock_guard<std::mutex> lock(s->gate);s->closing=true;
        s->status.error=error;s->status.phase=DrainPhase::blocked;s->changed.notify_all();
    };
    try {
        std::uint64_t ticket=1;
        auto job=s->backend->recover(ticket);
        if(!job||!job->run()){fail(DrainError::recovery);return;}
        auto terminal=s->backend->peek(ticket);
        if(!terminal){fail(DrainError::recovery);return;}
        {
            std::lock_guard<std::mutex> lock(s->gate);s->status.terminal=terminal;
            s->status.generation=terminal->generation;
        }
        if(!terminal->certain||terminal->status!="recovered"
           ||records::candidate(terminal->slots[0],terminal->slots[1])==-2){fail(DrainError::recovery);return;}
        {
            std::unique_lock<std::mutex> lock(s->gate);
            s->status.phase=DrainPhase::awaiting_validation;s->changed.notify_all();
            s->changed.wait(lock,[&]{return s->approved||s->closing;});
        }
        auto token=terminal->preimages;
        auto generation=terminal->generation;
        if(!s->backend->consume(ticket)){fail(DrainError::consume);return;}
        for(;;) {
#ifdef PWP_DRAINING_WRITER_TESTING
            draining_writer_test_before_pick();
#endif
            std::shared_ptr<const State::Snapshot> snapshot;
            bool initialize=false;
            {
                std::unique_lock<std::mutex> lock(s->gate);
                s->changed.wait(lock,[&]{return s->latest||s->closing;});
                if(!s->latest)break;
                snapshot=s->initial?s->initial:s->latest;
                s->initial.reset();s->active=snapshot;
                if(s->latest==snapshot)s->latest.reset();
                initialize=s->initialize;
            }
#ifdef PWP_DRAINING_WRITER_TESTING
            draining_writer_test_before_update(snapshot->revision);
#endif
#ifdef PWP_LIVE_PENDING_GATE_DEV_ONLY
            DrainStatus live_pending_status;
            {std::lock_guard<std::mutex> lock(s->gate);live_pending_status=s->status;}
            s->live_gate.before_update(live_pending_status.accepted,live_pending_status.committed);
#endif
            if(++ticket>=limit||generation+1>=limit){fail(DrainError::admission);return;}
            // No State/backend mutex is held while waiting. Keep the lane through
            // run, checked completion and consumption; never retry a conflict.
            PublicationLane publication;
            job=s->backend->update(ticket,token,snapshot->bytes,generation+1,snapshot->revision,initialize);
            if(!job){fail(DrainError::admission);return;}
            const bool delivered=job->run();
            terminal=s->backend->peek(ticket);
            if(terminal){std::lock_guard<std::mutex> lock(s->gate);s->status.terminal=terminal;}
            if(!delivered||!terminal||!terminal->certain){fail(DrainError::uncertain);return;}
            if(terminal->status!=(initialize?"initialized":"updated")
               ||terminal->generation!=generation+1||terminal->covered_revision!=snapshot->revision
               ||terminal->preimages.empty()){fail(DrainError::publication);return;}
            auto next_token=terminal->preimages; // allocation before consumption/ACK
            if(!s->backend->consume(ticket)){fail(DrainError::consume);return;}
            token=std::move(next_token);generation=terminal->generation;
            {
                std::lock_guard<std::mutex> lock(s->gate);
                s->status.committed=snapshot->revision;s->status.generation=generation;
                // Preserve an observable warning even if a later write is clean.
                if(terminal->cleanup_error)s->status.cleanup_error=terminal->cleanup_error;
                s->initialize=false;s->active.reset();s->changed.notify_all();
            }
        }
        s->backend->retire();
        if(!s->backend->release()){fail(DrainError::release);return;}
        std::lock_guard<std::mutex> lock(s->gate);
        s->status.phase=DrainPhase::closed;s->retained.reset();s->changed.notify_all();
    }catch(...){fail(DrainError::exception);}
}
}
