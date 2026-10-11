-- One-shot constant-only native entry check. No save writer or UObject access.
local source=debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
local root=assert(source:match('^(.*)/Scripts/main.lua$'))
local arm=io.open(root..'/run.txt','r');if not arm then return end
local request=arm:read('*a');assert(arm:close())
local nonce=request and request:match('^PWP_ENTRY_PROBE ([%w%-]+)%s*$')
if not nonce or #nonce>64 then return end
local f=assert(io.open(root..'/run.txt','w'));assert(f:write('DISABLED\n'));assert(f:close())
local function report(message)
    local line=os.date('!%Y-%m-%dT%H:%M:%SZ ')..'PWP_ENTRY '..nonce..' '..message
    local out=assert(io.open(root..'/entry.log','a'));assert(out:write(line..'\n'));assert(out:close())
    print(line..'\n')
end
local ok,err=pcall(function()
    report('START')
    assert(type(package.loadlib)=='function','native loader unavailable')
    local entry,why=package.loadlib(root..'/Scripts/pwp_entry_probe.dll','luaopen_pwp_entry_probe')
    assert(type(entry)=='function','loader failed: '..tostring(why))
    local sentinel={text='state-alive',numbers={1,2,3}}
    for i=1,1000 do
        local result=table.pack(entry())
        assert(result.n==1 and math.type(result[1])=='integer' and result[1]==2281,'bad native return at '..i)
    end
    collectgarbage('collect')
    assert(sentinel.text=='state-alive' and table.concat(sentinel.numbers,',')=='1,2,3','Lua state corrupted')
    assert(load('return 6*7','entry-sentinel','t',{})()==42,'Lua execution failed')
    report('PASS calls=1000 value=2281 lua_alive=true gc=true')
end)
if not ok then report('FAIL '..tostring(err)) end
