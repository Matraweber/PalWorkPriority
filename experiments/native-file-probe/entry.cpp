// Offline-built loadlib entry. No UObject, native threads, retained state or DLL main.
#include "probe.hpp"
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <Windows.h>
#include <vector>
#include <memory>
#include <unordered_map>
#include <string>
#include <LuaMadeSimple/LuaMadeSimple.hpp>
static_assert(_ITERATOR_DEBUG_LEVEL == 0, "Release STL required");
#if !defined(_DLL) || defined(_DEBUG)
#error Release dynamic CRT required
#endif

// Read-only metadata entry: never calls the file primitive.
extern "C" __declspec(dllexport) int luaopen_pwp_file_probe_identity(lua_State* state) {
    try {
        RC::LuaMadeSimple::Lua lua{state};
        if (lua.get_stack_size() != 0) return 0;
        LARGE_INTEGER tick{}, frequency{};
        if (!QueryPerformanceFrequency(&frequency) || frequency.QuadPart <= 0 ||
            !QueryPerformanceCounter(&tick) || tick.QuadPart < 0) return 0;
        lua.set_integer(GetCurrentThreadId());
        lua.set_integer(tick.QuadPart);
        lua.set_integer(frequency.QuadPart);
        return 3;
    } catch (...) { return 0; }
}

extern "C" __declspec(dllexport) int luaopen_pwp_file_probe(lua_State* state) {
    try {
        RC::LuaMadeSimple::Lua lua{state};
        if (lua.get_stack_size() != 2 || !lua.is_string(1) || !lua.is_integer(2)) return 0;
        const auto length = lua.get_integer(2);
        if (length <= 0 || length > static_cast<std::int64_t>(pwp::file_probe::max_hex) || length % 2) return 0;
        // Public getter is NUL-terminated. driver.lua enforces scalar ASCII hex
        // and supplies its actual length. Preserve original stack GC root while
        // copying the duplicate's view; no borrowed view crosses into file IO.
        lua.insert_value(1, 2);
        const auto view = lua.get_string(2);
        if (view.size() != static_cast<std::size_t>(length)) return 0;
        const std::string owned_hex(view);
        const auto r = pwp::file_probe::publish_hex(owned_hex, length);
        lua.set_integer(r.status); lua.set_integer(r.error); lua.set_integer(r.thread);
        lua.set_integer(r.start); lua.set_integer(r.end); lua.set_integer(r.checksum);
        lua.set_integer(r.frequency);
        return 7;
    } catch (...) {
        // Missing/malformed response is uncertain, never authorizes a retry.
        return 0;
    }
}
