#pragma once
#include <cstdint>
#include <vector>

// Pinned LuaMadeSimple.cpp: get_integer reads AND removes its indexed value.
// Only valid positive indices are modeled faithfully. For an absent index we
// model the observed zero conversion and pop; this is not a Lua ABI emulator.
struct lua_State {
    struct Value { std::int64_t integer; bool is_integer=true; };
    std::vector<Value> stack;
    std::vector<int> reads;
};
namespace RC::LuaMadeSimple {
class Lua {
    lua_State* state;
public:
    explicit Lua(lua_State* s):state(s) {}
    int get_stack_size() const {return static_cast<int>(state->stack.size());}
    bool is_integer(int index) const {
        return index>0 && index<=get_stack_size() && state->stack[index-1].is_integer;
    }
    std::int64_t get_integer(int index) const {
        state->reads.push_back(index);
        if(index<=0 || index>get_stack_size()) {
            if(!state->stack.empty()) state->stack.pop_back();
            return 0;
        }
        const auto value=state->stack[index-1];
        state->stack.erase(state->stack.begin()+index-1);
        return value.is_integer ? value.integer : 0;
    }
    void set_integer(std::int64_t value) const {state->stack.push_back({value});}
};
}
