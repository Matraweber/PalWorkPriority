#pragma once
#include <array>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace pwp::experimental {
struct RootIdentity {
    std::uint64_t volume = 0;
    std::array<unsigned char, 16> file_id{};
};
enum class RootLifetime { unconfigured, configuring, live, retiring, released, uncertain, rejected };
struct RootRelease { RootLifetime state; std::uint32_t error; };

// Internal C++ destination capability, never a Lua pathname/storage-authority
// grant. A trusted startup caller configures ONE existing mod-owned root per
// loaded implementation instance; no reset/retry/reconfiguration API. The
// immutable namespace label is independent of the unchanged PWP-SCOPE-1 wire.
// SaveOwner still supplies conservative cross-DLL/process writer exclusion.
class RootCapability final {
    const std::wstring root_;
    const std::string profile_namespace_;
    RootIdentity identity_;
    std::vector<void*> pins_;
    RootCapability(std::wstring root, std::string profile_namespace);
public:
    RootCapability(const RootCapability&) = delete;
    RootCapability& operator=(const RootCapability&) = delete;
    // Null on rejection; release_status().error is a Windows error for failed
    // construction. Exactly one configuration
    // attempt is permitted, including failures. No directory is ever created.
    static std::shared_ptr<const RootCapability> open(std::wstring root,
                                                     std::string profile_namespace) noexcept;
    const std::wstring& path() const noexcept { return root_; }
    const std::string& profile_namespace() const noexcept { return profile_namespace_; }
    const RootIdentity& identity() const noexcept { return identity_; }
    // Namespace: 1..64 lowercase ASCII letters/digits/hyphens, initial letter.
    // Trusted metadata only; never concatenated into a path or a wire scope.
    // Diagnostic retirement only: captures already admitted retain their pins.
    // Drop all shared_ptr captures to perform final checked release. Never use
    // a borrowed root reference after dropping its capturing shared_ptr.
    static RootRelease retire() noexcept;
    static RootRelease release_status() noexcept;
    ~RootCapability() noexcept;
};
// Pins deny ordinary directory rename/delete, not privileged remounts, hostile
// namespace changes, or file writes. Root paths <=140 UTF-16 units and <=64
// directory handles. On close ambiguity, never retry the attempted handle and
// retain remaining handles to process teardown (at most 64 total per instance).
// The implementation module is pinned before opening any directory handles.
}
