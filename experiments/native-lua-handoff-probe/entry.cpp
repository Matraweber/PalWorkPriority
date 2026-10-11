// Isolated handoff experiment. No native threads or retained Lua state.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <vector>
#include <memory>
#include <unordered_map>
#include <string>
#include <limits>
#include <stdexcept>
#include <LuaMadeSimple/LuaMadeSimple.hpp>
static_assert(_ITERATOR_DEBUG_LEVEL == 0, "Release STL required");
#if !defined(_DLL) || defined(_DEBUG)
#error Release dynamic CRT required
#endif

static int64_t qpc_us(int64_t frequency)
{
    LARGE_INTEGER counter{};
    if (!QueryPerformanceCounter(&counter) || counter.QuadPart < 0)
        throw std::runtime_error("QPC unavailable");
    const auto seconds = counter.QuadPart / frequency;
    if (seconds > (std::numeric_limits<int64_t>::max() - 1000000) / 1000000)
        throw std::runtime_error("QPC conversion overflow");
    return seconds * 1000000 + (counter.QuadPart % frequency) * 1000000 / frequency;
}

extern "C" __declspec(dllexport) int luaopen_pwp_handoff_probe(lua_State* state)
{
    try {
        RC::LuaMadeSimple::Lua lua{state};
        if (lua.get_stack_size() != 3 || !lua.is_string(1) || !lua.is_integer(2) || !lua.is_integer(3)) return 0;
        const auto length = lua.get_integer(3);
        const auto delay = lua.get_integer(2); // removes delay, retains string
        if (delay < 0 || delay > 200 || length < 0 || length > 512 * 1024 || length % 2) return 0;
        // Verified insert_value uses lua_pushvalue + lua_insert. get_string
        // removes only the duplicate; original remains a GC root throughout.
        // This getter is NUL-terminated: accept ASCII hex only, never binary.
        lua.insert_value(1, 2);
        const auto view = lua.get_string(2); // original at index 1 remains rooted
        if (view.size() != static_cast<size_t>(length)) return 0;
        std::string owned;
        owned.reserve(view.size() / 2);
        auto nibble = [](char c) -> int {
            if (c >= '0' && c <= '9') return c - '0';
            if (c >= 'a' && c <= 'f') return c - 'a' + 10;
            return -1;
        };
        for (size_t i = 0; i < view.size(); i += 2) {
            const int high = nibble(view[i]), low = nibble(view[i + 1]);
            if (high < 0 || low < 0) return 0;
            owned.push_back(static_cast<char>((high << 4) | low));
        }
        const auto tid = GetCurrentThreadId();
        LARGE_INTEGER frequency{};
        // <=1 us counter ticks; bound multiplication in qpc_us.
        if (!QueryPerformanceFrequency(&frequency) || frequency.QuadPart < 1000000 ||
            frequency.QuadPart > std::numeric_limits<int64_t>::max() / 1000000) return 0;
        const auto start = qpc_us(frequency.QuadPart);
        if (delay) {
            Sleep(static_cast<DWORD>(delay));
            // Preserve the full minimum: compensate early wakeups, not the gate.
            // Integer conversion guard is 2 us. At most eight additional sleeps.
            const auto required = delay * 1000 + 2;
            for (int attempt = 0; ; ++attempt) {
                const auto elapsed = qpc_us(frequency.QuadPart) - start;
                if (elapsed < 0) return 0;
                if (elapsed >= required) break;
                if (attempt == 8) return 0;
                Sleep(static_cast<DWORD>((required - elapsed + 999) / 1000));
            }
        }
        uint32_t checksum = 5381;
        for (unsigned char byte : owned) checksum = checksum * 33u + byte;
        const auto end = qpc_us(frequency.QuadPart);
        lua.set_integer(checksum);
        lua.set_integer(tid);
        lua.set_integer(static_cast<int64_t>(start));
        lua.set_integer(static_cast<int64_t>(end));
        lua.set_integer(frequency.QuadPart);
        return 5;
    } catch (...) {
        // No throwing error conversion here: zero results is a driver failure.
        return 0;
    }
}
