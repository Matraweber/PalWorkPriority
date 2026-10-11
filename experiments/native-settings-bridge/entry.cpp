// Isolated DEV-only bridge. No UObject access, automatic retirement or path input.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <Windows.h>
#include <LuaMadeSimple/LuaMadeSimple.hpp>
#include <settings_backend.hpp>
#include "dispatch.hpp"
static_assert(_ITERATOR_DEBUG_LEVEL==0,"Release STL required");
#if !defined(_DLL) || defined(_DEBUG)
#error Release dynamic CRT required
#endif
namespace {pwp::settings_bridge::Dispatch<pwp::settings_bridge::NativeBackend> dispatch;}
extern "C" __declspec(dllexport) int luaopen_pwp_settings_bridge(lua_State* state) {
    try {
        RC::LuaMadeSimple::Lua lua{state};
        if(lua.get_stack_size()!=5||!lua.is_integer(1)||!lua.is_integer(2)||!lua.is_integer(3)
            ||!lua.is_string(4)||!lua.is_integer(5))return 0;
        // Getters remove stack entries. Keep original hex string rooted.
        const auto length=lua.get_integer(5);
        const auto ticket=lua.get_integer(3);
        const auto handle=lua.get_integer(2);
        const auto command=lua.get_integer(1);
        if(length<0||length>static_cast<std::int64_t>(pwp::settings_bridge::max_input*2)||length%2
            ||ticket<0||ticket>=2147483647||handle<0||handle>128||command<0||command>8)return 0;
        lua.insert_value(1,2);
        const auto hex=lua.get_string(2); // original at index 1 remains a GC root
        if(hex.size()!=static_cast<std::size_t>(length))return 0;
        const auto owned=pwp::settings_bridge::unhex(hex);
        const auto fields=pwp::settings_bridge::unpack(owned);
        LARGE_INTEGER start{},end{},frequency{};
        if(!QueryPerformanceFrequency(&frequency)||frequency.QuadPart<=0||!QueryPerformanceCounter(&start))return 0;
        const auto thread=GetCurrentThreadId();
        const auto reply=dispatch.action(static_cast<int>(command),static_cast<unsigned>(handle),
            static_cast<std::uint64_t>(ticket),fields,thread);
        if(!QueryPerformanceCounter(&end))return 0;
        lua.set_integer(reply.status);
        lua.set_string(std::string_view(reply.data)); // pinned implementation copies via lua_pushlstring
        lua.set_integer(thread);lua.set_integer(start.QuadPart);lua.set_integer(end.QuadPart);lua.set_integer(frequency.QuadPart);
        return 6;
    }catch(...) {return 0;} // unknown completion: no automatic retry
}
