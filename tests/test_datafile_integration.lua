-- Shared persistence exercised through real store/caps APIs, using memory only.
local create_fs = require("memory_fs")
local failures = {}
local function test(name,fn)
    local ok,why=xpcall(fn,debug.traceback)
    if not ok then failures[#failures+1]=name..": "..tostring(why) end
end
local function fixture(kind)
    package.loaded.log={warn=function() end,error=function() end,say=function() end,debug=function() end}
    package.loaded.datafile=nil
    package.loaded.store=nil
    package.loaded.caps=nil
    local file=require("datafile")
    local fs=create_fs(); file.fs=fs
    local module=require(kind)
    local path=kind=="store" and "priorities" or "caps"
    local payload=kind=="store" and "PAL-A|1|X\nPAL-A|2|3\n" or "guild-A|Mining|Stone|100\n"
    assert(file.write(path,payload,0))
    local function check()
        if kind=="store" then
            assert(module.get("PAL-A",1)==false and module.get("PAL-A",2)==3,
                "recoverable priorities, including X, were lost")
        else
            assert(module.data["guild-A"] and module.data["guild-A"].Mining.Stone==100,
                "recoverable legacy ceiling was lost")
        end
    end
    local function load()
        module.load(path)
        module.set_role("authority",77)
    end
    return fs,file,module,path,load,check
end

for _,kind in ipairs({"store","caps"}) do
    test(kind..": retry must not truncate the only recoverable temporary generation",function()
        local fs,_,module,path,load,check=fixture(kind)
        fs.files[path..".tmp"],fs.files[path]=fs.files[path],nil
        load(); check()
        assert(module.state=="saving")
        fs.fault=function(op,at) return op=="write" and at==path..".tmp" end
        assert(module.save()==false,"injected write failure reported success")
        fs.fault=nil
        load(); check() -- Must survive a failed recovery save and another restart.
    end)

    test(kind..": a failed replacement after backup recovery must retain a good generation",function()
        local fs,_,module,path,load,check=fixture(kind)
        fs.files[path..".bak"]=fs.files[path]
        fs.files[path]="invalid live row\n"
        load(); check()
        fs.fault=function(op,at) return op=="rename" and at==path..".tmp>"..path end
        assert(module.save()==false)
        -- A later retry must not overwrite the last good .tmp after discarding
        -- the valid .bak and restoring the corrupt original live file.
        fs.fault=function(op,at) return op=="write" and at==path..".tmp" end
        assert(module.save()==false)
        fs.fault=nil
        load(); check()
    end)

    test(kind..": empty unfinished temporary file is not a valid empty save",function()
        local fs,_,module,path=fixture(kind)
        fs.files[path],fs.files[path..".tmp"]=nil,""
        module.load(path)
        assert(module.state=="error","unverified temporary file was accepted as durable data")
    end)

    test(kind..": ordinary read denial blocks initialization and save",function()
        local fs,_,module,path,load=fixture(kind)
        fs.fault=function(op,at) return op=="open" and at==path end
        load()
        assert(module.state=="error","permission failure was treated as fresh installation")
        assert(module.save()==false)
        assert(fs.files[path]~=nil and fs.files[path..".tmp"]==nil,"unreadable save was replaced")
    end)

    test(kind..": close failure never reports saved and leaves a valid generation",function()
        local fs,_,module,path,load,check=fixture(kind)
        load(); check()
        fs.fault=function(op,at) return op=="close" and at==path..".tmp" end
        assert(module.save()==false)
        assert(module.state=="error")
        fs.fault=nil
        load(); check()
    end)
end

test("store: duplicate X row and malformed values recover from validated backup",function()
    for _,invalid in ipairs({
        "PAL-A|1|X\nPAL-A|1|3\n",
        "PAL-A|1|1.5\n",
        "PAL-A|65|3\n",
        "PAL-A|1|0\n",
        "PAL-A|1|six\n",
    }) do
        local fs,_,module,path,load,check=fixture("store")
        fs.files[path..".bak"]=fs.files[path]
        fs.files[path]=invalid
        load(); check()
        assert(module.state=="saving")
    end
end)

test("caps: duplicate, unknown and out-of-range rows do not replace a validated backup",function()
    for _,invalid in ipairs({
        "guild-A|Mining|Stone|100\nguild-A|Mining|Stone|250\n",
        "guild-A|UnverifiedWork|Stone|100\n",
        "guild-A|Mining|Stone|1.5\n",
        "guild-A|Mining|Stone|10000000\n",
        "guild-A|Mining|Stone|-1\n",
    }) do
        local fs,_,module,path,load,check=fixture("caps")
        fs.files[path..".bak"]=fs.files[path]
        fs.files[path]=invalid
        load(); check()
        assert(module.state=="saving")
    end
end)

test("caps: failed deletion remains dirty, then persists without restoring an unrelated rule",function()
    local fs,_,module,path,load=fixture("caps")
    load()
    fs.fault=function(op,at) return op=="rename" and at==path..".tmp>"..path end
    assert(module.apply_clear("Mining","Stone","guild-A")==false)
    assert(module.state=="error")
    fs.fault=nil
    assert(module.save()==true)
    load()
    assert(next(module.data)==nil and module.state=="saved")
end)

assert(#failures==0,table.concat(failures,"\n\n"))

