#pragma once
#include <cstdint>
#include <atomic>
#include <thread>
#include <memory>
#include <string>
#include <string_view>
#include <vector>
#include <stdexcept>
struct lua_State {
    struct Value {
        std::int64_t number=0;std::shared_ptr<std::string> text;
        Value(std::int64_t n):number(n){}
        Value(std::string s):text(std::make_shared<std::string>(std::move(s))){}
    };
    std::vector<Value> stack;
    std::vector<int> reads;
    bool rooted_read=false;
    static inline bool lose_reply=false;
    static inline thread_local bool on_native_thread=false;
    static inline std::atomic<unsigned> worker_calls=0;
};
namespace RC::LuaMadeSimple {
class Lua {
    lua_State* s;
public:
    explicit Lua(lua_State* state):s(state){if(lua_State::on_native_thread)++lua_State::worker_calls;}
    int get_stack_size()const {return static_cast<int>(s->stack.size());}
    bool is_integer(int i)const {return i>0&&i<=get_stack_size()&&!s->stack[i-1].text;}
    bool is_string(int i)const {return i>0&&i<=get_stack_size()&&s->stack[i-1].text!=nullptr;}
    std::int64_t get_integer(int i)const {
        s->reads.push_back(i);const auto n=is_integer(i)?s->stack[i-1].number:0;
        // Valid-index removal matches pinned wrapper. Out-of-range zero/pop
        // only models the observed legacy failure, not arbitrary Lua UB.
        if(i>0&&i<=get_stack_size())s->stack.erase(s->stack.begin()+i-1);
        else if(!s->stack.empty())s->stack.pop_back();return n;
    }
    void insert_value(int from,int to)const {
        const auto value=s->stack.at(from-1);s->stack.insert(s->stack.begin()+to-1,value);
    }
    std::string_view get_string(int i)const {
        if(!is_string(i))throw std::runtime_error("string index");
        const auto text=s->stack[i-1].text;s->stack.erase(s->stack.begin()+i-1);
        bool rooted=false;for(const auto& v:s->stack)if(v.text==text)rooted=true;
        if(!rooted)throw std::runtime_error("original Lua root lost");
        s->rooted_read=true;return std::string_view(text->c_str()); // actual getter truncates at NUL
    }
    void set_integer(std::int64_t n)const {s->stack.emplace_back(n);}
    void set_string(std::string_view data)const {
        if(lua_State::lose_reply){lua_State::lose_reply=false;throw std::runtime_error("lost Lua reply");}
        s->stack.emplace_back(std::string(data));
    }
};
}
