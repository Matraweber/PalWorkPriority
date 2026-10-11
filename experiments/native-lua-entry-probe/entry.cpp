// Compile/link feasibility only. Never installed or loaded by this probe.
// Uses the untouched, exact-revision public LuaMadeSimple class declaration.
#include <vector>
#include <memory>
#include <unordered_map>
#include <LuaMadeSimple/LuaMadeSimple.hpp>
static_assert(_ITERATOR_DEBUG_LEVEL == 0, "Release STL required");
#if !defined(_DLL) || defined(_DEBUG)
#error Release dynamic CRT required
#endif

extern "C" __declspec(dllexport) int luaopen_pwp_entry_probe(lua_State* state)
{
    RC::LuaMadeSimple::Lua borrowed{state};
    borrowed.set_integer(2281);
    return 1;
}
