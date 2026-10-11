#include "journal.hpp"
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <Windows.h>
#include <bcrypt.h>
#include <cstring>
#include <new>
#include <utility>
#include <vector>

namespace pwp::experimental::journal {
#ifdef PWP_JOURNAL_TESTING
// Standalone test build only: hook may pause, terminate the helper, or return an
// injected error. Production compilation has no callback/import/environment seam.
extern DWORD journal_test_point(const char* point);
#endif
namespace {
DWORD test_point(const char* point) {
#ifdef PWP_JOURNAL_TESTING
    return journal_test_point(point);
#else
    (void)point;
    return 0;
#endif
}
struct Handle {
    HANDLE value = INVALID_HANDLE_VALUE;
    explicit Handle(HANDLE h = INVALID_HANDLE_VALUE) noexcept : value(h) {}
    Handle(const Handle&) = delete;
    Handle(Handle&& other) noexcept : value(std::exchange(other.value, INVALID_HANDLE_VALUE)) {}
    ~Handle() { if (value != INVALID_HANDLE_VALUE) CloseHandle(value); }
    DWORD close() noexcept {
        if (value == INVALID_HANDLE_VALUE) return 0;
        const HANDLE h = std::exchange(value, INVALID_HANDLE_VALUE);
        return CloseHandle(h) ? 0 : GetLastError();
    }
};
bool guid(std::wstring_view s) {
    if (s.size() != 32) return false;
    bool nonzero = false;
    for (wchar_t c : s) {
        if (!((c >= L'0' && c <= L'9') || (c >= L'a' && c <= L'f'))) return false;
        nonzero = nonzero || c != L'0';
    }
    return nonzero;
}
std::string ascii(std::wstring_view s) {
    std::string result;
    for (wchar_t c : s) result.push_back(static_cast<char>(c));
    return result;
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
        if (!GetFileInformationByHandleEx(pins.back().value, FileAttributeTagInfo, &info, sizeof(info))) return GetLastError();
        if (!(info.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) || (info.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT))
            return ERROR_NOT_SUPPORTED;
        if (end == root.size()) return 0;
        end = root.find(L'\\', end == 2 ? 3 : end + 1);
        if (end == std::wstring::npos) end = root.size();
    }
}
struct Slot {
    Handle handle;
    records::Read decoded;
    std::string bytes;
};
DWORD open_slot(const std::wstring& path, const std::string& scope, Slot& slot) {
    slot.handle.value = CreateFileW(path.c_str(), GENERIC_READ | DELETE, 0, nullptr, OPEN_EXISTING,
        FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, nullptr);
    if (slot.handle.value == INVALID_HANDLE_VALUE) {
        const DWORD error = GetLastError();
        if (error == ERROR_FILE_NOT_FOUND) { slot.decoded.state = records::State::missing; return 0; }
        return error;
    }
    FILE_ATTRIBUTE_TAG_INFO info{};
    if (!GetFileInformationByHandleEx(slot.handle.value, FileAttributeTagInfo, &info, sizeof(info))) return GetLastError();
    if (info.FileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) return ERROR_NOT_SUPPORTED;
    LARGE_INTEGER size{};
    if (!GetFileSizeEx(slot.handle.value, &size)) return GetLastError();
    if (size.QuadPart < 0) return ERROR_INVALID_DATA;
    if (size.QuadPart > static_cast<LONGLONG>(records::max_record)) {
        slot.decoded.state = records::State::unsupported; return 0;
    }
    slot.bytes.resize(static_cast<std::size_t>(size.QuadPart));
    std::size_t offset = 0;
    while (offset < slot.bytes.size()) {
        DWORD got = 0;
        if (!ReadFile(slot.handle.value, slot.bytes.data() + offset, static_cast<DWORD>(slot.bytes.size() - offset), &got, nullptr))
            return GetLastError();
        if (!got) return ERROR_HANDLE_EOF;
        offset += got;
    }
    char extra = 0;
    DWORD got = 0;
    if (!ReadFile(slot.handle.value, &extra, 1, &got, nullptr)) return GetLastError();
    if (got) return ERROR_INVALID_DATA;
    slot.decoded = records::decode(slot.bytes, scope);
    return 0;
}
// Safe refusal once enough entries have been seen: no unbounded user-space list.
DWORD budget(const std::wstring& root, std::size_t needed) {
    WIN32_FIND_DATAW data{};
    const HANDLE find = FindFirstFileW((root + L"\\pwp-journal-*").c_str(), &data);
    if (find == INVALID_HANDLE_VALUE) {
        const DWORD error = GetLastError();
        return error == ERROR_FILE_NOT_FOUND ? 0 : error;
    }
    std::size_t count = 0;
    DWORD error = 0;
    do {
        if (++count + needed > retained_limit) { error = ERROR_TOO_MANY_OPEN_FILES; break; }
    } while (FindNextFileW(find, &data));
    if (!error) {
        const DWORD next_error = GetLastError();
        if (next_error != ERROR_NO_MORE_FILES) error = next_error;
    }
    if (!FindClose(find)) error = GetLastError();
    return error;
}
DWORD rename_owned(HANDLE file, const std::wstring& target) {
    const auto name_bytes = target.size() * sizeof(wchar_t);
    std::vector<unsigned char> buffer(sizeof(FILE_RENAME_INFO) + name_bytes, 0);
    auto rename = new (buffer.data()) FILE_RENAME_INFO{};
    rename->ReplaceIfExists = FALSE;
    rename->RootDirectory = nullptr;
    rename->FileNameLength = static_cast<DWORD>(name_bytes);
    std::memcpy(rename->FileName, target.data(), name_bytes);
    return SetFileInformationByHandle(file, FileRenameInfo, rename, static_cast<DWORD>(buffer.size())) ? 0 : GetLastError();
}
Status rename_failure(DWORD error) {
    return error == ERROR_FILE_EXISTS || error == ERROR_ALREADY_EXISTS ? Status::conflict : Status::io_error;
}
}
Result update(const std::wstring& root, std::wstring_view storage, std::wstring_view guild,
              std::wstring_view stream, const Preimages& expected, std::string_view encoded) noexcept {
    Result result;
    try {
        // Destruction order matters on exception: backup first, then existing
        // slots/new stage, pins, and finally root gate. Delete-pending cleanup
        // must never outlive the handles protecting both good generations.
        Handle root_gate;
        std::vector<Handle> pins;
        Handle stage;
        Slot slots[2];
        Handle backup_handle;
        // All normal exits pass through checked closes. Exceptions conservatively
        // return uncertain after RAII cleanup, even if mutation never started.
        auto work = [&]() -> Result {
            if (!guid(storage) || !guid(guild) || (stream != L"priorities" && stream != L"limits") ||
                encoded.size() > records::max_record) return {Status::conflict, ERROR_INVALID_PARAMETER};
            for (const auto& image : expected)
                if (image && image->size() > records::max_record) return {Status::conflict, ERROR_INVALID_PARAMETER};
            const std::string scope = "PWP-SCOPE-1:" + ascii(storage) + ":" + ascii(guild) + ":" + ascii(stream);
            const auto next = records::decode(encoded, scope);
            if (next.state != records::State::valid) return {Status::conflict, ERROR_INVALID_DATA};
            DWORD error = pin_root(root, pins);
            if (error) return {Status::io_error, error};
            // Serialize developmental root-wide artifact budget across scopes.
            // Kernel creation, not thread-affine mutex acquisition; no wait/retry.
            BY_HANDLE_FILE_INFORMATION root_info{};
            if (!GetFileInformationByHandle(pins.back().value, &root_info)) return {Status::io_error, GetLastError()};
            const auto gate_name = L"Global\\PWP-JournalRoot-Dev1-" + std::to_wstring(root_info.dwVolumeSerialNumber) + L"-" +
                std::to_wstring(root_info.nFileIndexHigh) + L"-" + std::to_wstring(root_info.nFileIndexLow);
            SetLastError(ERROR_SUCCESS);
            root_gate.value = CreateMutexW(nullptr, FALSE, gate_name.c_str());
            error = GetLastError();
            if (root_gate.value == INVALID_HANDLE_VALUE || root_gate.value == nullptr) {
                root_gate.value = INVALID_HANDLE_VALUE; return {Status::io_error, error};
            }
            if (error == ERROR_ALREADY_EXISTS) return {Status::conflict, error};
            const auto stem = root + L"\\pwp-record-v1-" + std::wstring(storage) + L"-" + std::wstring(guild) + L"-" + std::wstring(stream);
            const std::wstring names[2] = {stem + L"-A.record", stem + L"-B.record"};
            // Fixed open order. No waiting/retry if another owner holds a slot.
            for (int i = 0; i < 2; ++i) {
                error = open_slot(names[i], scope, slots[i]);
                if (error) return {Status::io_error, error};
            }
            error = test_point("after_read");
            if (error) return {Status::io_error, error};
            for (int i = 0; i < 2; ++i) {
                const auto state = slots[i].decoded.state;
                if (state == records::State::unsupported || state == records::State::foreign || state == records::State::unreadable)
                    return {Status::conflict, ERROR_INVALID_DATA};
                if (expected[i].has_value() != (state != records::State::missing) ||
                    (expected[i] && *expected[i] != slots[i].bytes)) return {Status::conflict, ERROR_REVISION_MISMATCH};
            }
            const int active = records::candidate(slots[0].decoded, slots[1].decoded);
            if (active == -2) return {Status::conflict, ERROR_INVALID_DATA};
            const std::uint32_t generation = active == -1 ? 1 : slots[active].decoded.record.generation + 1;
            if (next.record.generation != generation) return {Status::conflict, ERROR_REVISION_MISMATCH};
            const int target = active == -1 ? 0 : 1 - active;
            result.slot = target == 0 ? 'A' : 'B'; result.generation = generation;
            const bool backup = slots[target].handle.value != INVALID_HANDLE_VALUE;
            error = budget(root, backup ? 2 : 1);
            if (error) return {error == ERROR_TOO_MANY_OPEN_FILES ? Status::conflict : Status::io_error, error, result.slot, generation};
            unsigned char random[16];
            if (BCryptGenRandom(nullptr, random, sizeof(random), BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0)
                return {Status::io_error, ERROR_GEN_FAILURE, result.slot, generation};
            std::wstring suffix;
            for (auto byte : random) { suffix += L"0123456789abcdef"[byte >> 4]; suffix += L"0123456789abcdef"[byte & 15]; }
            const auto stage_name = root + L"\\pwp-journal-stage-" + suffix + L".tmp";
            const auto backup_name = root + L"\\pwp-journal-backup-" + suffix + L".record";
            stage.value = CreateFileW(stage_name.c_str(), GENERIC_WRITE | DELETE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
            if (stage.value == INVALID_HANDLE_VALUE) {
                error = GetLastError(); return {rename_failure(error), error, result.slot, generation};
            }
            error = test_point("before_write");
            if (error) return {Status::io_error, error, result.slot, generation};
            DWORD written = 0;
            if (!WriteFile(stage.value, encoded.data(), static_cast<DWORD>(encoded.size()), &written, nullptr))
                return {Status::io_error, GetLastError(), result.slot, generation};
            if (written != encoded.size()) return {Status::io_error, ERROR_WRITE_FAULT, result.slot, generation};
            error = test_point("after_write");
            if (error) return {Status::io_error, error, result.slot, generation};
            if (!FlushFileBuffers(stage.value)) return {Status::io_error, GetLastError(), result.slot, generation};
            error = test_point("after_flush");
            if (error) return {Status::io_error, error, result.slot, generation};
            if (backup) {
                error = test_point("before_backup");
                if (error) return {Status::io_error, error, result.slot, generation};
                error = rename_owned(slots[target].handle.value, backup_name);
                if (error) return {rename_failure(error), error, result.slot, generation};
                backup_handle.value = std::exchange(slots[target].handle.value, INVALID_HANDLE_VALUE);
                error = test_point("after_backup");
                if (error) return {Status::io_error, error, result.slot, generation};
            }
            error = test_point("before_publish");
            if (error) return {Status::io_error, error, result.slot, generation};
            error = rename_owned(stage.value, names[target]);
            if (error) return {rename_failure(error), error, result.slot, generation};
            error = test_point("after_publish");
            if (error) return {Status::uncertain, error, result.slot, generation};
            if (active == -1) {
                // Absence cannot be locked. Any other-slot appearance or unreadable
                // post-check invalidates initial-publication acknowledgement.
                error = open_slot(names[1], scope, slots[1]);
                if (error || slots[1].decoded.state != records::State::missing)
                    return {Status::uncertain, error ? error : ERROR_REVISION_MISMATCH, result.slot, generation};
            }
            if (backup) {
                // Publication is already established. Only the exact handle just
                // renamed by THIS call may be cleaned; never reopen by pathname.
                // Both the new stage/target and previous active slot remain held.
                error = test_point("before_cleanup");
                if (!error) error = test_point("before_disposition");
                if (!error) {
                    FILE_DISPOSITION_INFO disposition{};
                    disposition.DeleteFile = TRUE;
                    if (!SetFileInformationByHandle(backup_handle.value, FileDispositionInfo,
                                                    &disposition, sizeof(disposition))) error = GetLastError();
                }
                if (error) return {Status::updated, 0, result.slot, generation, error};
                // After disposition acceptance, a close or process exit may
                // delete the backup. Never promise retention on these errors.
                error = test_point("after_disposition");
                if (!error) error = test_point("before_backup_close");
                if (error) return {Status::uncertain, error, result.slot, generation, error};
                error = backup_handle.close();
                if (!error) error = test_point("after_backup_close");
                if (error) return {Status::uncertain, error, result.slot, generation, error};
            }
            return {active == -1 ? Status::initialized : Status::updated, 0, result.slot, generation};
        };
        result = work();
        DWORD close_error = backup_handle.close();
        if (close_error) result.cleanup_error = close_error;
        const DWORD stage_error = stage.close();
        if (!close_error) close_error = stage_error;
        for (auto& slot : slots) {
            const DWORD error = slot.handle.close();
            if (!close_error) close_error = error;
        }
        for (auto it = pins.rbegin(); it != pins.rend(); ++it) {
            const DWORD error = it->close();
            if (!close_error) close_error = error;
        }
        const DWORD gate_error = root_gate.close();
        if (!close_error) close_error = gate_error;
        const DWORD injected_close_error = test_point("after_close");
        if (!close_error) close_error = injected_close_error;
        if (close_error) { result.status = Status::uncertain; result.error = close_error; }
        return result;
    } catch (...) {
        result.status = Status::uncertain; result.error = ERROR_UNHANDLED_EXCEPTION;
        return result;
    }
}
}
