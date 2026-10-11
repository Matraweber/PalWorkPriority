-- Pure, one-shot observational coverage. Providers are trusted synchronous code.
-- No IO, engine discovery, deletion inference, writer or authority activation.
local MAX_KEYS=256
local M={MAX_KEYS=MAX_KEYS}
local fields={'scope','storage','guild','stream','session','incarnation','epoch','camp','authority'}
local function plain(t)return type(t)=='table' and getmetatable(t)==nil end
local function copy(t)local r={};for k,v in next,t do r[k]=v end;return r end
local function equal(t,c)
    if not plain(t)then return false end
    for k,v in next,c do
        if rawget(t,k)~=v or type(rawget(t,k))~=type(v)
            or (type(v)=='number' and math.type(rawget(t,k))~=math.type(v))then return false end
    end
    for k in next,t do if rawget(c,k)==nil then return false end end
    return true
end
local function hex(s,n,nonzero)
    return type(s)=='string' and #s==n and s:match('^[0-9a-f]+$')~=nil
        and (not nonzero or s~=string.rep('0',n))
end
local function text(s)return type(s)=='string' and #s>0 and #s<=256 and not s:find('%c')end
local function valid_context(c)
    if not plain(c)then return false end
    local expected={};for _,k in ipairs(fields)do expected[k]=rawget(c,k)end
    return equal(c,expected) and hex(c.storage,32,true) and hex(c.guild,32,true)
        and c.scope=='PWP-SCOPE-1:'..c.storage..':'..c.guild..':priorities'
        and c.stream=='priorities' and text(c.session) and text(c.incarnation) and text(c.camp)
        and math.type(c.epoch)=='integer' and c.epoch>=1 and c.epoch<=2147483646 and c.authority==true
end
function M.new(o)
    if not plain(o)then return nil,'invalid_options' end
    local allowed={manifest_sha256=true,keys=true,context=true,read_context=true,reader_factory=true}
    for k in next,o do if not allowed[k]then return nil,'invalid_options' end end
    if not hex(o.manifest_sha256,64,false) or not valid_context(o.context)
        or not plain(o.keys) or type(o.read_context)~='function' or type(o.reader_factory)~='function' then
        return nil,'invalid_options'
    end
    local n=0
    for i in next,o.keys do
        if math.type(i)~='integer' or i<1 or i>MAX_KEYS then return nil,'invalid_keys' end
        n=n+1
    end
    local keys={}
    for i=1,n do
        local k=rawget(o.keys,i)
        if type(k)~='string' or #k~=64 or not k:match('^[0-9A-F]+$')
            or k:sub(33)==string.rep('0',32) or (i>1 and k<=keys[i-1])then return nil,'invalid_keys' end
        keys[i]=k
    end
    local captured,hash=copy(o.context),o.manifest_sha256
    local read,factory=o.read_context,o.reader_factory
    local used,busy,failure=false,false,nil
    local observer={}
    function observer.sample()
        if busy then failure='reentrant';return nil,'reentrant' end
        if used then return nil,'already_sampled' end
        used,busy=true,true
        local rows,contexts,readers={},{},{}
        for i,k in ipairs(keys)do rows[i]={key=k,status='not_examined'}end
        -- Retain only bounded plain scalar contexts inside this sample. Check
        -- earlier disposable arguments too: callbacks may retain/mutate them.
        local function unchanged()
            if failure then return false end
            for _,c in ipairs(contexts)do
                if not equal(c,captured)then failure='context_changed';return false end
            end
            for r,owns in next,readers do
                if not plain(r) or rawget(r,'owns_key')~=owns then failure='reader_changed';return false end
            end
            return true
        end
        local function argument()
            local c=copy(captured);contexts[#contexts+1]=c;return c
        end
        local function check()
            if not unchanged()then return false end
            local ok,c=pcall(read)
            if not unchanged()then return false end
            if not ok or not equal(c,captured)then failure='context_unavailable';return false end
            contexts[#contexts+1]=c
            return true
        end
        if check()then
            for i,k in ipairs(keys)do
                if not check()then break end
                rows[i].status='unresolved'
                local ok,reader=pcall(factory,k,argument())
                local owns=ok and plain(reader) and rawget(reader,'owns_key') or nil
                if type(owns)=='function'then
                    if readers[reader]then failure='reader_reused'
                    else readers[reader]=owns end
                end
                if not check()then break end
                if type(owns)=='function' then
                    local yes,value=pcall(owns,k,argument())
                    if not check()then break end
                    if yes and value==true then rows[i].status='current_target_confirmed' end
                end
            end
        end
        if not failure then check()end -- includes empty union and final sample boundary
        if failure then
            for _,row in ipairs(rows)do
                if row.status=='current_target_confirmed'then row.status='unresolved' end
            end
        end
        busy=false
        -- complete means every key was attempted under a stable context,
        -- including factory failures/rejections; it does NOT mean all confirmed.
        return {contract='PWP-EXPORT-MEMBERSHIP-OBSERVATION-1',manifest_sha256=hash,
            context=copy(captured),keys=rows,complete=failure==nil,fenced=failure~=nil,
            reason=failure or 'observed',ownership_verified=false,membership_verified=false,
            history_coverage_verified=false,retained_history_complete=false,
            deletion_coverage_verified=false,deletion_allowed=false,activation_allowed=false,
            replacement_allowed=false,storage_grant=false,authority_grant=false,coverage_grant=false}
    end
    return observer
end
return M
