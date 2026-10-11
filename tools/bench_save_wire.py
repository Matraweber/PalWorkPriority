"""Offline Lua 5.4 encoding microbenchmark; does not measure game frame times."""
from pathlib import Path
import json
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / '.test-deps'))
from lupa.lua54 import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
assert lua.eval('_VERSION') == 'Lua 5.4'
run = lua.eval('''function(n, repeats)
    local map={}
    local bytes={}
    for i=0,255 do
        map[string.char(i)]=string.format('%02x',i)
        bytes[#bytes+1]=string.char(i)
    end
    local payload=string.rep(table.concat(bytes),math.ceil(n/256)):sub(1,n)
    local function original()
        return (payload:gsub('.',function(c)return string.format('%02x',c:byte())end))
    end
    local function mapped() return (payload:gsub('.',map)) end
    assert(original()==mapped())
    local function measure(fn)
        collectgarbage('collect')
        local start=os.clock()
        for i=1,repeats do assert(#fn()==n*2) end
        return (os.clock()-start)*1000/repeats
    end
    return measure(original),measure(mapped)
end''')
results = []
for size in (1024, 65536, 262144):
    old, mapped = run(size, 20)
    results.append({'bytes': size, 'original_ms': old, 'lookup_ms': mapped})
print(json.dumps({'scope': 'offline Lua CPU time; not in-game frame capture',
                  'samples_per_size': 20, 'results': results}, indent=2))
