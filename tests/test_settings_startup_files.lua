local Reader=dofile(TEST_ROOT..'/experiments/settings_startup_files.lua')
local files={}
for _,base in ipairs({'priorities.txt','caps.txt'})do
    for _,suffix in ipairs({'','.tmp','.pending','.bak'})do files[base..suffix]=false end
end
files['caps.txt']='\0\255raw';files['priorities.txt']=''
local disk={['C:/source/caps.txt']=files['caps.txt'],['D:/backup/manifest.json']='pinned',
    ['C:/source/priorities.txt']=''}
local opens,closes=0,0
local fault
local o={enabled=true,source_root='C:\\source',backup_root='D:/backup/',manifest='pinned',files=files,
    open=function(path,mode)
        opens=opens+1;assert(mode=='rb')
        if fault=='open_throw' then error('open')end
        if fault=='denied' then return nil,'denied',13 end
        if disk[path]==nil then return nil,'missing',2 end
        return {
            read=function(_,n)
                assert(n==8*1024*1024+1 or n==96*1024*1024+1)
                if fault=='read_throw' then error('read')end
                if fault=='read_error' then return nil,'failed'end
                if fault=='wrong_type' then return 42 end
                if fault=='oversized' then return string.rep('x',n)end
                if disk[path]=='' then return nil end
                return disk[path]
            end,
            close=function()
                closes=closes+1
                if fault=='close_throw' then error('close')end
                if fault=='close_false' then return nil,'failed'end
                return true
            end}
    end}
assert(not Reader.new{} and not Reader.new{enabled=1})
local r=assert(Reader.new(o));assert(opens==0)
assert(r.read_source('caps.txt')==files['caps.txt'] and r.read_source('priorities.txt')=='')
local raw,err,code=r.read_source('caps.txt.bak');assert(raw==nil and code==2)
local n=opens;assert(not r.read_source('../caps.txt') and not r.read_backup('manifest.json') and opens==n)
assert(r.verify_receipt(files));disk['D:/backup/manifest.json']='changed';assert(not r.verify_receipt(files))
disk['D:/backup/manifest.json']='pinned'
o.source_root='C:/wrong';o.manifest='wrong';o.open=function()error('mutated')end
assert(r.read_source('caps.txt')==files['caps.txt'] and r.verify_receipt(files))
for _,f in ipairs({'read_throw','read_error','wrong_type','oversized','close_throw','close_false'})do
    fault=f;local before=closes;raw,err,code=r.read_source('caps.txt')
    assert(raw==nil and code~=2 and closes==before+1,f)
end
fault='denied';raw,err,code=r.read_source('caps.txt');assert(raw==nil and code==13)
fault='open_throw';raw,err,code=r.read_source('caps.txt');assert(raw==nil and code~=2)
fault=nil
files['caps.txt']='mutated';assert(not r.verify_receipt(files))
for _,root in ipairs({'relative','C:/source/..','C:/source/./x','C:/source/ads:stream','C:/source/bad.','C:/source//x'})do
    local bad={};for k,v in pairs(o)do bad[k]=v end;bad.source_root=root
    assert(not pcall(Reader.new,bad),root)
end
print('startup readers: fixed paths, exact receipt, binary/empty/missing distinction, checked read/close failures and immutable options passed')
