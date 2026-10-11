#include "initialization.hpp"
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <Windows.h>
#include <bcrypt.h>
#include <vector>
#include <utility>
#include <cstddef>
#include <cstring>
#include <new>
namespace pwp::experimental {
#ifdef PWP_INITIALIZATION_TESTING
// Test build only; shipping compilation has no callbacks or injected failures.
extern DWORD initialization_test_point(const char* point);
#define TEST_POINT(name) do { const DWORD e = initialization_test_point(name); if (e) return {Status::io_error, e, stage}; } while (false)
#else
#define TEST_POINT(name) do {} while (false)
#endif
namespace {
struct Handle {
    HANDLE h = INVALID_HANDLE_VALUE;
    explicit Handle(HANDLE v) : h(v) {}
    Handle(Handle&& other) noexcept : h(std::exchange(other.h, INVALID_HANDLE_VALUE)) {}
    Handle(const Handle&) = delete;
    ~Handle() { if (h != INVALID_HANDLE_VALUE) CloseHandle(h); }
};
bool hex_id(std::wstring_view s) {
    if (s.size() != 32) return false;
    for (wchar_t c : s) if (!((c >= L'0' && c <= L'9') || (c >= L'a' && c <= L'f'))) return false;
    return true;
}
// Narrow contract: ordinary absolute local fixed-drive paths. Pin every
// ancestor against rename/deletion and refuse junctions/symlinks.
bool pin_root(const std::wstring& root, std::vector<Handle>& pins, DWORD& error) {
    if (root.size() < 4 || root.size() > 140 ||
        !((root[0] >= L'A' && root[0] <= L'Z') || (root[0] >= L'a' && root[0] <= L'z')) ||
        root[1] != L':' || root[2] != L'\\' || root.back() == L'\\') {
        error = ERROR_INVALID_NAME; return false;
    }
    if (GetDriveTypeW(root.substr(0, 3).c_str()) != DRIVE_FIXED) {
        error = ERROR_NOT_SUPPORTED; return false;
    }
    for (std::size_t start = 3; start < root.size();) {
        auto end = root.find(L'\\', start);
        if (end == std::wstring::npos) end = root.size();
        auto part = root.substr(start, end - start);
        if (part.empty() || part == L"." || part == L".." || part.back() == L'.' || part.back() == L' ' ||
            part.find_first_of(L"/:*?\"<>|") != std::wstring::npos) {
            error = ERROR_INVALID_NAME; return false;
        }
        for (auto c : part) if (c < 32) { error = ERROR_INVALID_NAME; return false; }
        start = end + 1;
    }
    std::size_t end = 2;
    for (;;) {
        auto path = root.substr(0, end + (end == 2 ? 1 : 0));
        HANDLE h = CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
        if (h == INVALID_HANDLE_VALUE) { error = GetLastError(); return false; }
        Handle owned(h);
        pins.emplace_back(std::move(owned));
        FILE_ATTRIBUTE_TAG_INFO info{};
        if (!GetFileInformationByHandleEx(h, FileAttributeTagInfo, &info, sizeof(info))) {
            error = GetLastError(); return false;
        }
        if (!(info.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) || (info.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
            error = ERROR_NOT_SUPPORTED; return false;
        }
        if (end == root.size()) break;
        end = root.find(L'\\', end == 2 ? 3 : end + 1);
        if (end == std::wstring::npos) end = root.size();
    }
    return true;
}
}
Result initialize(const std::wstring& root, std::wstring_view storage,
                  std::wstring_view guild, std::wstring_view stream, std::string_view bytes) {
    if (!hex_id(storage) || !hex_id(guild) || (stream != L"priorities" && stream != L"limits") ||
        bytes.empty() || bytes.size() > max_publication_bytes) return {Status::invalid, ERROR_INVALID_PARAMETER, {}};
    std::vector<Handle> pins;
    DWORD error = 0;
    if (!pin_root(root, pins, error)) return {Status::io_error, error, {}};
    const auto target = root + L"\\pwp-init-" + std::wstring(storage) + L"-" + std::wstring(guild) + L"-" + std::wstring(stream) + L".record";
    unsigned char random[16];
    if (BCryptGenRandom(nullptr, random, sizeof(random), BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0)
        return {Status::io_error, ERROR_GEN_FAILURE, {}};
    std::wstring suffix;
    for (auto b : random) { suffix += L"0123456789abcdef"[b >> 4]; suffix += L"0123456789abcdef"[b & 15]; }
    const auto stage = root + L"\\pwp-stage-" + suffix + L".tmp";
    Handle file(CreateFileW(stage.c_str(), GENERIC_WRITE | DELETE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr));
    if (file.h == INVALID_HANDLE_VALUE) return {Status::io_error, GetLastError(), {}};
    TEST_POINT("before_write");
    DWORD written = 0;
    if (!WriteFile(file.h, bytes.data(), static_cast<DWORD>(bytes.size()), &written, nullptr))
        return {Status::io_error, GetLastError(), stage};
    if (written != bytes.size()) return {Status::io_error, ERROR_WRITE_FAULT, stage};
    TEST_POINT("after_write");
    if (!FlushFileBuffers(file.h)) return {Status::io_error, GetLastError(), stage};
    TEST_POINT("after_flush");
    TEST_POINT("before_publish");
    // Publish the still-exclusively-open file, not a pathname that could have
    // been substituted after close. No absence check authorizes replacement.
    const auto name_bytes = target.size() * sizeof(wchar_t);
    std::vector<unsigned char> rename_buffer(sizeof(FILE_RENAME_INFO) + name_bytes, 0);
    auto rename = new (rename_buffer.data()) FILE_RENAME_INFO{};
    rename->ReplaceIfExists = FALSE;
    rename->RootDirectory = nullptr;
    rename->FileNameLength = static_cast<DWORD>(name_bytes);
    std::memcpy(rename->FileName, target.data(), name_bytes);
    if (!SetFileInformationByHandle(file.h, FileRenameInfo, rename, static_cast<DWORD>(rename_buffer.size()))) {
        error = GetLastError();
        return {error == ERROR_ALREADY_EXISTS || error == ERROR_FILE_EXISTS ? Status::conflict : Status::io_error, error, stage};
    }
#ifdef PWP_INITIALIZATION_TESTING
    error = initialization_test_point("after_publish");
    if (error) return {Status::published_close_error, error, {}};
#endif
    // Never retry an ambiguous close from the destructor (handle values can be
    // reused). A failed close is terminal/uncertain and needs reconciliation.
    const HANDLE closing = std::exchange(file.h, INVALID_HANDLE_VALUE);
    if (!CloseHandle(closing)) return {Status::published_close_error, GetLastError(), {}};
    // Published != power-loss durable. No directory-flush guarantee claimed.
    return {Status::published, 0, {}};
}
}
