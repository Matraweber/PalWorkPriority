-- Raw base-stock snapshots only. Guild grouping and permission decisions stay
-- in the scheduler, after it reads current camp/guild identities again.
local api = require('palapi')
local storage_scope = require('scheduler_storage')
local M = {}
local plan, candidate
local generation = 0

local function copy(value, depth)
    local kind=type(value)
    if kind=='string' or kind=='number' or kind=='boolean' or kind=='nil' then return value end
    assert(kind=='table' and getmetatable(value)==nil and (depth or 0)<6, 'non-scalar storage snapshot')
    local result={}
    for key,child in pairs(value) do
        assert(type(key)=='string' or type(key)=='number', 'non-scalar storage key')
        result[key]=copy(child,(depth or 0)+1)
    end
    return result
end

function M.filters(cfg)
    local parts={tostring(cfg.storage_scope)}
    for _,list in ipairs({{cfg.counted_containers},{cfg.uncounted_containers}}) do
        if list[1]==nil then parts[#parts+1]='nil'
        else
            local names={}
            for _,name in ipairs(list[1]) do
                assert(type(name)=='string','invalid storage class filter')
                names[#names+1]=#name .. ':' .. name
            end
            table.sort(names)
            parts[#parts+1]='[' .. table.concat(names,';') .. ']'
        end
    end
    return table.concat(parts,'|')
end

function M.reset()
    generation=generation+1
    plan,candidate=nil,nil
end

-- A panel reopen needs a new sample, not a new discovery of the same scalar
-- scope. Cancel any older candidate/in-flight publication, retaining only the
-- established plan. Authority, filters, TTL and fresh scope still gate use.
function M.request_refresh()
    generation=generation+1
    candidate=nil
    if plan then
        plan.requested=true
        plan.interested_at=os.clock()
    end
end

function M.observe(cfg, key, sampled_at, verified, ttl)
    if not verified or not sampled_at or ttl<5 or cfg.storage_scope~='global' then M.reset(); return end
    local filters=M.filters(cfg)
    if not plan or plan.key~=key or plan.filters~=filters or plan.ttl~=ttl then
        M.reset()
        plan={key=key,filters=filters,ttl=ttl,
            opts={include=copy(cfg.counted_containers),exclude=copy(cfg.uncounted_containers)}}
    end
    plan.at,plan.interested_at,plan.requested=sampled_at,os.clock(),false
end

function M.due(cfg, ttl)
    if not plan or cfg.enabled==false or cfg.storage_scope~='global' or ttl~=plan.ttl
        or M.filters(cfg)~=plan.filters then return false end
    local now=os.clock()
    local lease=math.max(5,(cfg.interval_seconds or 10)*2+5)
    if now<plan.at or now-plan.interested_at>lease then return false end
    if candidate then return false end -- including incomplete results awaiting adoption
    -- Refresh at most two seconds early so expiry and the next pass do not
    -- routinely coincide. This does not extend the age allowed at adoption.
    return plan.requested==true or now-plan.at >= ttl-math.min(2,ttl/10)
end

function M.refresh(cfg, ttl)
    if not M.due(cfg,ttl) or api.latch_authority()~=true then return false end
    local requested, epoch=plan,generation
    local at=os.clock()
    local ok, data=pcall(function()
        local by,counts,evidence=api.chest_totals_by_camp(requested.opts)
        assert(type(by)=='table' and type(counts)=='table' and type(evidence)=='table','invalid storage result')
        return {by=copy(by),counts=copy(counts),evidence=copy(evidence)}
    end)
    if generation~=epoch or plan~=requested or M.filters(cfg)~=requested.filters then return false end
    if not ok then
        data={by={},counts={},evidence={complete=false,deduplicated=false,unknown_scope=1,
            failed_reads=1,reasons={prefetch_read=1}}}
    end
    data.at,data.key,data.filters,data.ttl=at,requested.key,requested.filters,ttl
    candidate=data
    return true
end

function M.take(cfg,key,ttl)
    local value=candidate
    if not value then return nil end
    candidate=nil
    local age=os.clock()-value.at
    local complete=value.evidence.complete==true and value.evidence.deduplicated==true
        and (value.evidence.unknown_scope or 0)==0
    local max_age=complete and ttl or storage_scope.retry_ttl(ttl,1)
    if value.key~=key or value.filters~=M.filters(cfg) or value.ttl~=ttl or ttl<=0
        or age<0 or age>=max_age then return nil end
    return value
end

return M
