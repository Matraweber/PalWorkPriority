-- One in-flight request; native event context is used only inside receive.
-- The inbox retains plain scalars/strings, never Unreal wrappers or delegates.
local M = {}
local function text(value)
    return type(value)=='string' and value or value:ToString()
end
function M.new(tag)
    local path, ticket, result, closed
    local box={}
    function box:bind(name) assert(not path); path=name end
    function box:arm(value)
        assert(not closed and path and not ticket and not result,'completion overlap')
        ticket=value
    end
    function box:receive(context)
        if closed or not ticket or result then return end
        local ok, snapshot=pcall(function()
            local actor=context:get()
            if not actor or not actor:IsValid() then return end
            if text(actor.TrialTag)~=tag or actor:GetFullName():match('^%S+ (.+)$')~=path then return end
            if actor.CompletedGeneration~=ticket then return end
            assert(actor.Done==true and actor.Busy==false,'completion fired before terminal state')
            assert(type(actor.Success)=='boolean','ambiguous engine result')
            local record=actor.LoadedSave
            local copied
            if record and record:IsValid() then
                copied={Generation=record.Generation,Session=text(record.Session),
                    Payload=text(record.Payload),Checksum=text(record.Checksum)}
                assert(type(copied.Generation)=='number' and copied.Generation%1==0,
                    'invalid record generation')
                assert(#copied.Session<=256 and #copied.Payload<=65536 and #copied.Checksum<=64,
                    'oversized completion record')
            end
            local snapshot={CompletedGeneration=ticket,Busy=false,Success=actor.Success,
                LoadedSave=copied,StartedSeconds=actor.StartedSeconds,
                SaveFinishedSeconds=actor.SaveFinishedSeconds,ReadStartedSeconds=actor.ReadStartedSeconds,
                CompletedSeconds=actor.CompletedSeconds}
            for _,key in ipairs({'StartedSeconds','SaveFinishedSeconds','ReadStartedSeconds','CompletedSeconds'}) do
                local n=snapshot[key]
                assert(type(n)=='number' and n==n and n>-math.huge and n<math.huge,'invalid engine time')
            end
            return snapshot
        end)
        if not ok then result={error=tostring(snapshot)}
        elseif snapshot then result=snapshot end
    end
    function box:take(value)
        assert(value==ticket,'completion ticket mismatch')
        if not result then return end
        local copied=result
        ticket,result=nil,nil
        return copied
    end
    function box:close() closed=true; ticket,result=nil,nil end
    return box
end
return M
