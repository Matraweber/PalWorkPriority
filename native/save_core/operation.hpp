#pragma once
#include "owner.hpp"
#include "journal.hpp"
#include <atomic>
namespace pwp::experimental {
// Internal development transport, NOT a Lua admission API. The caller proves
// storage/authority and validates both old schemas + new payload before admit.
// Each queued closure retains this exact object; never resolve a current owner.
class SaveOperation {
    const std::shared_ptr<SaveOwner> owner;
    const OwnerBinding binding;
    const std::uint64_t ticket;
    const std::wstring root, storage, guild, stream;
    const journal::Preimages expected;
    const std::string encoded;
    std::atomic<bool> started{false};
    SaveOperation(std::shared_ptr<SaveOwner>,OwnerBinding,std::uint64_t,
                  std::wstring,std::wstring,std::wstring,std::wstring,
                  journal::Preimages,std::string);
public:
    static std::shared_ptr<SaveOperation> admit(std::shared_ptr<SaveOwner>,
        OwnerBinding,std::uint64_t,std::wstring,std::wstring,std::wstring,
        std::wstring,journal::Preimages,std::string);
    // At most one invocation performs IO. True means terminal delivery accepted,
    // not save success. Observing retired=true at run's owner check cancels
    // without IO. A false check is the execution-admission boundary: retirement
    // after that check may precede the first filesystem call, but accepted work
    // still finishes on its copied original destination, never a new world.
    bool run() noexcept;
};
}
