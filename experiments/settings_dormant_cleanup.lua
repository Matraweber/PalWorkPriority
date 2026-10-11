-- Cleanup ONLY an owned, never-used native binding when Lua construction/open
-- failed before a session queue took responsibility. No discovery, no retries.
-- Unknown command-1 result has no handle and cannot use this helper.
local root=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
    :match('^(.*)/settings_dormant_cleanup.lua$'))
local Wire=dofile(root..'/save_native_backend.lua')
local M={}
function M.new(o)
    assert(type(o)=='table' and o.enabled==true and type(o.native)=='function')
    local native,handle,game,scope,incarnation,epoch=o.native,o.handle,o.game_thread,o.scope,o.incarnation,tostring(o.epoch)
    assert(math.type(handle)=='integer' and handle>=1 and handle<=128)
    local attempted,closed=false,false
    local function call(command,ticket)
        local r=Wire.call(native,command,handle,ticket,{})
        assert(r[1]==1 and r[3]==game,'cleanup command refused/unknown')
        return r[2]
    end
    local function check(raw,phase,ticket,command)
        local f=Wire.unpack(raw,16)
        assert(f[1]==scope and f[2]==incarnation and f[3]==epoch,'owner mismatch')
        assert(f[4]=='0' and f[5]=='0' and f[6]==phase and f[7]=='none'
            and f[8]=='0' and f[9]=='0','not an unused owner')
        assert(f[10]=='' and f[11]=='' and f[12]=='','unexpected terminal')
        assert(f[13]==ticket and f[14]==command and f[15]=='0'
            and f[16]==(ticket=='0' and 'none' or 'accepted'),'unexpected mutation')
    end
    return {drain=function()
        if closed then return true end
        if attempted then return false end
        attempted=true
        local ok=pcall(function()
            check(call(6,0),'dormant','0','0')
            assert(call(7,1)=='','unexpected close data')
            check(call(8,2),'closed','2','8')
            assert(call(9,0)=='','unexpected cleanup data')
        end)
        closed=ok
        return closed
    end}
end
return M
