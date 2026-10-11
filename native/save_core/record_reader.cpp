#include "record_reader.hpp"
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <Windows.h>
#include <utility>
#include <vector>

namespace pwp::experimental::record_reader {
namespace {
struct Handle {
    HANDLE value = INVALID_HANDLE_VALUE;
    explicit Handle(HANDLE h) noexcept : value(h) {}
    Handle(const Handle&) = delete;
    Handle(Handle&& other) noexcept : value(std::exchange(other.value, INVALID_HANDLE_VALUE)) {}
    ~Handle() { if (value != INVALID_HANDLE_VALUE) CloseHandle(value); }
    DWORD close() noexcept {
        if (value == INVALID_HANDLE_VALUE) return 0;
        const HANDLE h = std::exchange(value, INVALID_HANDLE_VALUE);
        return CloseHandle(h) ? 0 : GetLastError();
    }
};
bool guid(std::wstring_view value) {
    if (value.size() != 32) return false;
    bool nonzero = false;
    for (wchar_t c : value) {
        if (!((c >= L'0' && c <= L'9') || (c >= L'a' && c <= L'f'))) return false;
        nonzero = nonzero || c != L'0';
    }
    return nonzero;
}
// Only called for the validated ASCII GUIDs and stream literals above.
std::string ascii(std::wstring_view value) {
    std::string out;
    out.reserve(value.size());
    for (wchar_t c : value) out.push_back(static_cast<char>(c));
    return out;
}
DWORD pin_root(const std::wstring& root, std::vector<Handle>& pins) {
    if (root.size() < 4 || root.size() > 140 ||
        !((root[0] >= L'A' && root[0] <= L'Z') || (root[0] >= L'a' && root[0] <= L'z')) ||
        root[1] != L':' || root[2] != L'\\' || root.back() == L'\\') return ERROR_INVALID_NAME;
    if (GetDriveTypeW(root.substr(0, 3).c_str()) != DRIVE_FIXED) return ERROR_NOT_SUPPORTED;
    for (std::size_t start = 3; start < root.size();) {
        auto end = root.find(L'\\', start);
        if (end == std::wstring::npos) end = root.size();
        const auto part = root.substr(start, end - start);
        if (part.empty() || part == L"." || part == L".." || part.back() == L'.' || part.back() == L' ' ||
            part.find_first_of(L"/:*?\"<>|") != std::wstring::npos) return ERROR_INVALID_NAME;
        for (wchar_t c : part) if (c < 32) return ERROR_INVALID_NAME;
        start = end + 1;
    }
    std::size_t end = 2;
    for (;;) {
        const auto path = root.substr(0, end + (end == 2 ? 1 : 0));
        Handle owned(CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE,
            nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
        if (owned.value == INVALID_HANDLE_VALUE) return GetLastError();
        pins.emplace_back(std::move(owned));
        FILE_ATTRIBUTE_TAG_INFO info{};
        if (!GetFileInformationByHandleEx(pins.back().value, FileAttributeTagInfo, &info, sizeof(info)))
            return GetLastError();
        if (!(info.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) || (info.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT))
            return ERROR_NOT_SUPPORTED;
        if (end == root.size()) return 0;
        end = root.find(L'\\', end == 2 ? 3 : end + 1);
        if (end == std::wstring::npos) end = root.size();
    }
}
Result unreadable(DWORD error) { return {{records::State::unreadable, {}}, error, std::nullopt}; }
Result inspect(HANDLE file, const std::string& scope) {
    FILE_ATTRIBUTE_TAG_INFO info{};
    if (!GetFileInformationByHandleEx(file, FileAttributeTagInfo, &info, sizeof(info))) return unreadable(GetLastError());
    if (info.FileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) return unreadable(ERROR_NOT_SUPPORTED);
    LARGE_INTEGER size{};
    if (!GetFileSizeEx(file, &size)) return unreadable(GetLastError());
    if (size.QuadPart < 0) return unreadable(ERROR_INVALID_DATA);
    if (size.QuadPart > static_cast<LONGLONG>(records::max_record))
        return {{records::State::unsupported, {}}, 0, std::nullopt};
    std::string bytes(static_cast<std::size_t>(size.QuadPart), '\0');
    std::size_t offset = 0;
    while (offset < bytes.size()) {
        DWORD got = 0;
        if (!ReadFile(file, bytes.data() + offset, static_cast<DWORD>(bytes.size() - offset), &got, nullptr))
            return unreadable(GetLastError());
        if (!got) return unreadable(ERROR_HANDLE_EOF);
        offset += got;
    }
    char extra = 0;
    DWORD got = 0;
    if (!ReadFile(file, &extra, 1, &got, nullptr)) return unreadable(GetLastError());
    if (got) return unreadable(ERROR_INVALID_DATA);
    auto decoded = records::decode(bytes, scope);
    if (decoded.state == records::State::unreadable || decoded.state == records::State::missing)
        return unreadable(ERROR_INVALID_DATA);
    return {std::move(decoded), 0, std::move(bytes)};
}
}
Result read(const std::wstring& root, std::wstring_view storage,
            std::wstring_view guild, std::wstring_view stream, char slot) noexcept {
    try {
        if (!guid(storage) || !guid(guild) || (stream != L"priorities" && stream != L"limits") ||
            (slot != 'A' && slot != 'B')) return unreadable(ERROR_INVALID_PARAMETER);
        std::vector<Handle> pins;
        Handle leaf(INVALID_HANDLE_VALUE);
        Result result = unreadable(ERROR_GEN_FAILURE);
        const DWORD root_error = pin_root(root, pins);
        if (root_error) result = unreadable(root_error);
        else {
            const auto name = root + L"\\pwp-record-v1-" + std::wstring(storage) + L"-" +
                std::wstring(guild) + L"-" + std::wstring(stream) + L"-" + static_cast<wchar_t>(slot) + L".record";
            leaf.value = CreateFileW(name.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, nullptr);
            if (leaf.value == INVALID_HANDLE_VALUE) {
                const DWORD error = GetLastError();
                result = error == ERROR_FILE_NOT_FOUND
                    ? Result{{records::State::missing, {}}, error, std::nullopt} : unreadable(error);
            } else {
                const std::string scope = "PWP-SCOPE-1:" + ascii(storage) + ":" + ascii(guild) + ":" + ascii(stream);
                result = inspect(leaf.value, scope);
            }
        }
        // Every checked close relinquishes ownership before the call; never retry
        // a possibly closed handle. Close failure overrides even missing/valid.
        DWORD close_error = leaf.close();
        for (auto it = pins.rbegin(); it != pins.rend(); ++it) {
            const DWORD error = it->close();
            if (!close_error) close_error = error;
        }
        return close_error ? unreadable(close_error) : result;
    } catch (...) {
        // Includes allocation/hash-service failure. Never classify as missing or
        // corruption, and never return bytes from a partial operation.
        return unreadable(ERROR_UNHANDLED_EXCEPTION);
    }
}
}
