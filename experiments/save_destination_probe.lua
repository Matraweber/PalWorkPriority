-- Observation-only classifier for copied world-save completion arguments.
-- Does NOT call native save methods, infer authority, or grant storage access.
local M={}
local function guid(s)
    if type(s)~='string' or #s~=32 or not s:match('^%x+$')
        or s==string.rep('0',32) then return end
    return s:lower()
end
function M.read(slot,success,world)
    local out={verified=false,state='unavailable',success_status='unavailable',
        slot_status='unavailable',world_status='unavailable'}
    if type(success)=='boolean' then out.success=success;out.success_status='read' end
    local world_id=guid(world)
    out.world_status=world_id and 'format_valid' or type(world)=='string' and
        (world=='' and 'empty' or 'unrecognized') or 'unavailable'
    if world_id then out.world_candidate=world_id end
    -- Expected relative slot grammar only. Do not emit arbitrary paths, display
    -- names, timestamps or prefixes. Runtime format remains to be observed.
    if type(slot)=='string' then
        out.slot_status='unrecognized'
        if #slot>0 and #slot<=1024 and not slot:find('[%c:]') then
            local normalized=slot:gsub('\\','/')
            if normalized:sub(1,1)~='/' and not normalized:find('//',1,true) then
                local parts={};local safe=true
                for part in normalized:gmatch('[^/]+') do
                    if part=='.' or part=='..' then safe=false end
                    parts[#parts+1]=part
                end
                local leaf=parts[#parts]
                local candidate=guid(parts[#parts-1])
                if safe and candidate and normalized:sub(-1)~='/' and
                    (leaf=='Level' or leaf=='Level.sav') then
                    out.slot_candidate=candidate;out.slot_status='recognized_world_slot'
                end
            end
        end
    end
    if out.success_status~='read' then out.state='unknown_completion'
    elseif not success then out.state='failed_completion'
    elseif not out.slot_candidate then out.state='unrecognized_destination'
    elseif world_id and world_id~=out.slot_candidate then out.state='conflicting_candidates'
    else out.state='successful_destination_candidate' end
    -- Even success may belong to a retired world. No ready/storage/key output.
    return out
end
return M
