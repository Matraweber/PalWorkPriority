#pragma once
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
namespace pwp::experimental {
// Copied immutable binding; validation/provenance belongs to the admission layer.
struct OwnerBinding { std::string scope, incarnation; std::uint64_t epoch=0; };
struct OwnerResult { std::uint64_t ticket=0; bool certain=false; std::string bytes; };
class SaveOwner {
    struct State;
    std::shared_ptr<State> state;
    explicit SaveOwner(std::shared_ptr<State> s);
public:
    // Kernel-name creation arbitrates even across duplicate DLL copies/processes.
    // Does not wait or acquire thread-affine mutex ownership.
    static std::shared_ptr<SaveOwner> claim(const OwnerBinding& binding);
    bool reserve(const OwnerBinding& binding,std::uint64_t ticket);
    bool complete(std::uint64_t ticket,bool certain,std::string bytes);
    std::optional<OwnerResult> peek(std::uint64_t ticket) const;
    bool consume(std::uint64_t ticket);
    void retire();
    bool release();
    bool retired() const;
    ~SaveOwner();
};
}
