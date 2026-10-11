local Cleanup=dofile(TEST_ROOT..'/experiments/settings_dormant_cleanup.lua')
local Wire=dofile(TEST_ROOT..'/experiments/save_native_backend.lua')
local scope='PWP-SCOPE-1:'..string.rep('3',32)..':'..string.rep('4',32)..':limits'
for _,fault in ipairs({'none','used','foreign','lost_close','lost_drain','lost_cleanup','bad_phase'})do
    local calls={}
    local function native(command,handle,ticket,hex,length)
        assert(handle==1 and length==0 and hex=='')
        calls[#calls+1]=command
        if (fault=='lost_close' and command==7) or (fault=='lost_drain' and command==8)
            or (fault=='lost_cleanup' and command==9) then error('lost reply')end
        local out=''
        if command==6 or command==8 then
            out=Wire.pack({fault=='foreign' and 'foreign' or scope,'boot','1',fault=='used' and '1' or '0','0',
                command==6 and 'dormant' or fault=='bad_phase' and 'blocked' or 'closed','none','0','0','','','',
                command==6 and '0' or '2',command==6 and '0' or '8','0',command==6 and 'none' or 'accepted'})
        end
        return 1,out,123,0,1,1000
    end
    local c=Cleanup.new{enabled=true,native=native,handle=1,game_thread=123,scope=scope,incarnation='boot',epoch=1}
    assert(c.drain()==(fault=='none'))
    local n=#calls;assert(c.drain()==(fault=='none') and #calls==n)
    if fault=='none' then assert(table.concat(calls,',')=='6,7,8,9')end
    if fault=='used' or fault=='foreign' then assert(#calls==1)end
end
print('unused native binding cleanup: exact zero-activity owner proof; no mutation retries')
