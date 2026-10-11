-- Fixed read-only runtime readers for an installer-verified offline backup.
-- The trusted installer must pin these exact manifest bytes/files after checked
-- backup completion and validate root identities/no redirects. This adapter
-- does NOT authenticate a supplied receipt, prove historic fsync or prevent OS
-- path replacement. It never opens a caller-selected file or writes anything.
local M={}
local MAX=8*1024*1024
local names={}
for _,base in ipairs({'priorities.txt','caps.txt'})do
    for _,suffix in ipairs({'','.tmp','.pending','.bak'})do names[base..suffix]=true end
end
local function directory(p)
    assert(type(p)=='string' and not p:find('%c'),'directory required')
    assert(not p:find('[\128-\255]'),'runtime reader requires ASCII directory')
    p=p:gsub('\\','/'):gsub('/+$','')
    assert(p:match('^[A-Za-z]:/[^/].*') and not p:find('//',1,true),'absolute Windows directory required')
    for part in p:sub(4):gmatch('[^/]+')do
        assert(part~='.' and part~='..' and not part:find('[:*?"<>|]') and not part:match('[ .]$'),'invalid directory component')
    end
    return p
end
function M.new(o)
    if type(o)~='table' or getmetatable(o) or o.enabled~=true then return nil,'disabled' end
    local source,backup=directory(o.source_root),directory(o.backup_root)
    assert(source:lower()~=backup:lower() and backup:lower():sub(1,#source+1)~=source:lower()..'/',
        'backup must be outside the legacy directory')
    local manifest=o.manifest
    assert(type(manifest)=='string' and #manifest>0 and #manifest<=96*1024*1024,'pinned manifest required')
    local expected={}
    assert(type(o.files)=='table' and not getmetatable(o.files),'frozen files required')
    for name in pairs(names)do
        local raw=o.files[name]
        assert(raw==false or type(raw)=='string' and #raw<=MAX,'explicit bytes/absence required')
        expected[name]=raw
    end
    for name in pairs(o.files)do assert(names[name],'unexpected file')end
    local open=o.open or io.open
    assert(type(open)=='function','reader required')
    local function read(path,limit)
        local ok,f,err,code=pcall(open,path,'rb')
        if not ok then return nil,'open failed' end
        if not f then return nil,err,code end
        local got,raw,why=pcall(function()return f:read(limit+1)end)
        local closed,yes=pcall(function()return f:close()end)
        if not closed or yes~=true then return nil,'close failed' end
        if not got or why~=nil then return nil,'read failed' end
        if raw==nil then raw='' end -- empty file EOF, not missing
        if type(raw)~='string' or #raw>limit then return nil,'invalid/oversized read' end
        return raw
    end
    local function scoped(root,name)
        if type(name)~='string' or not names[name] then return nil,'unapproved file' end
        return read(root..'/'..name,MAX)
    end
    return {
        read_source=function(name)return scoped(source,name)end,
        read_backup=function(name)return scoped(backup,name)end,
        verify_receipt=function(files)
            if type(files)~='table' or getmetatable(files) then return false end
            for name,raw in pairs(expected)do if files[name]~=raw then return false end end
            for name in pairs(files)do if not names[name] then return false end end
            local raw=read(backup..'/manifest.json',96*1024*1024)
            return raw==manifest -- equality to installed bytes, never independent authentication
        end,
    }
end
return M
