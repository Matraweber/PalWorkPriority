#include "probe.hpp"
#include "../../native/save_core/initialization.hpp"
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <Windows.h>
#include <string>

namespace pwp::file_probe {
Result publish_hex(std::string_view hex, std::int64_t declared_length) noexcept {
    Result r;
    r.thread = GetCurrentThreadId();
    LARGE_INTEGER frequency{}, start{}, end{};
    if (!QueryPerformanceFrequency(&frequency) || frequency.QuadPart <= 0 ||
        !QueryPerformanceCounter(&start) || start.QuadPart < 0) {
        r.status = 3; r.error = ERROR_GEN_FAILURE; return r;
    }
    r.frequency = frequency.QuadPart;
    r.start = start.QuadPart;
    try {
        if (declared_length > 0 && declared_length <= static_cast<std::int64_t>(max_hex) &&
            declared_length % 2 == 0 && hex.size() == static_cast<std::size_t>(declared_length)) {
            std::string bytes;
            bytes.reserve(hex.size() / 2);
            const auto nibble = [](char c) {
                if (c >= '0' && c <= '9') return c - '0';
                if (c >= 'a' && c <= 'f') return c - 'a' + 10;
                return -1;
            };
            bool valid = true;
            std::uint32_t checksum = 5381;
            for (std::size_t i = 0; i < hex.size(); i += 2) {
                const int high = nibble(hex[i]), low = nibble(hex[i + 1]);
                if (high < 0 || low < 0) { valid = false; break; }
                const auto byte = static_cast<unsigned char>((high << 4) | low);
                bytes.push_back(static_cast<char>(byte));
                checksum = checksum * 33u + byte;
            }
            if (valid) {
                r.checksum = checksum; // attempted payload, NOT disk-readback proof
                const auto result = experimental::initialize(root, storage, guild, stream, bytes);
                switch (result.status) {
                case experimental::Status::published: r.status = 0; break;
                case experimental::Status::invalid: r.status = 1; break;
                case experimental::Status::conflict: r.status = 2; break;
                case experimental::Status::io_error: r.status = 3; break;
                case experimental::Status::published_close_error: r.status = 4; break;
                default: r.status = 5; break;
                }
                r.error = result.error;
            }
        }
    } catch (...) {
        // Never translate an exception into a definite no-publication promise.
        r.status = 5; r.error = ERROR_UNHANDLED_EXCEPTION;
    }
    // Preserve publication status even if post-publication telemetry fails.
    r.end = QueryPerformanceCounter(&end) && end.QuadPart >= r.start ? end.QuadPart : -1;
    return r;
}
}
