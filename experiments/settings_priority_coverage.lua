-- Pure baseline coverage check, NOT an engine census or ownership grant.
-- Caller must freshly obtain a COMPLETE current-camp roster while holding its
-- lifecycle/authority fence. No stored wrappers, writes, or inferred membership.
-- check(typed_recovered_settings, {complete=true, pals={
--   {key=<durable Pal key>, capable={<work enum>=true,...}}, ...}})
-- Unknown, partial or duplicate roster entries fail. Empty capable sets are
-- allowed only as an explicitly complete observation; absent sets are unknown.
local Store=require('store')
local M={}
local function fields(t,allowed)
    if type(t)~='table' or getmetatable(t)~=nil then return false end
    for k in pairs(t)do if not allowed[k]then return false end end
    return true
end
function M.check(settings,roster)
    if not fields(settings,{data=true,count=true,baseline=true,transient=true})
        or type(settings.baseline)~='boolean' or math.type(settings.count)~='integer'
        or (settings.transient~=nil and settings.transient~=0)
        or type(settings.data)~='table' or getmetatable(settings.data)~=nil
        or not fields(roster,{complete=true,pals=true}) or roster.complete~=true
        or type(roster.pals)~='table' or getmetatable(roster.pals)~=nil then return false,'unknown coverage' end
    local count=0
    for key,row in pairs(settings.data)do
        if not Store.durable_key(key) or type(row)~='table' or getmetatable(row)~=nil
            or next(row)==nil then return false,'invalid settings' end
        for work,value in pairs(row)do
            if math.type(work)~='integer' or work<1 or work>64
                or (value~=false and (math.type(value)~='integer' or value<1 or value>5)) then
                return false,'invalid settings'
            end
            count=count+1
        end
    end
    if count~=settings.count then return false,'invalid settings count' end
    local n=0
    for i in pairs(roster.pals)do
        if math.type(i)~='integer' or i<1 or i>4096 then return false,'invalid roster' end
        n=n+1
    end
    local seen={}
    for i=1,n do
        local pal=roster.pals[i]
        if not fields(pal,{key=true,capable=true}) or not Store.durable_key(pal.key)
            or seen[pal.key] or type(pal.capable)~='table' or getmetatable(pal.capable)~=nil then
            return false,'invalid roster'
        end
        seen[pal.key]=true
        for work,capable in pairs(pal.capable)do
            if math.type(work)~='integer' or work<1 or work>64 or capable~=true then
                return false,'unknown suitability'
            end
            -- X is a complete original choice. nil is not a default 1.
            if settings.baseline and (not settings.data[pal.key] or settings.data[pal.key][work]==nil) then
                return false,'baseline incomplete'
            end
        end
    end
    return true
end
return M
