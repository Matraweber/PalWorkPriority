-- Development-only typed payload envelope. No IO or active-scope proof.
-- Stable storage/guild identity is persisted; process/incarnation is NOT.
-- Real serializers/parsers supply canonical bodies. Unknown schema, scope or
-- noncanonical bytes fail closed, even when the outer native checksum is valid.
local root=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
    :match('^(.*)/save_settings_codec.lua$'))
local Scope=dofile(root..'/save_scope.lua')
local Store,Caps=require('store'),require('caps')
local M={}
local function plain(t) return type(t)=='table' and getmetatable(t)==nil end
function M.new(options)
    assert(plain(options))
    local scope=Scope.new(options.storage,options.guild,options.stream)
    local max=options.max_payload_bytes
    if max==nil then max=65536 end
    assert(math.type(max)=='integer' and max>=65536 and max<=262144)
    local prefix='PWP-SETTINGS-1\n'..scope.storage..'\n'..scope.guild..'\n'..scope.stream..'\n'
    local module=scope.stream=='priorities' and Store or Caps
    local function decode_body(body)
        local decoded,why=module.decode_snapshot(body)
        if not decoded then return nil,why end
        if scope.stream=='limits' then
            for guild in pairs(decoded.data) do
                if guild~=scope.guild then return nil,'foreign or legacy limit group' end
            end
        end
        local canonical=module.serialize_snapshot(decoded.data,decoded.baseline)
        if canonical~=body then return nil,'noncanonical or unsupported settings body' end
        return decoded
    end
    local codec={}
    -- Takes already serialized/partitioned bytes, never reads mutable global data.
    function codec.encode(body)
        if type(body)~='string' or #body>max then return nil,'invalid payload' end
        local decoded,why=decode_body(body);if not decoded then return nil,why end
        local envelope=prefix..#body..'\n'..body
        if #envelope>max then return nil,'payload capacity exceeded' end
        return envelope
    end
    function codec.decode(payload)
        if type(payload)~='string' or #payload>max or payload:sub(1,#prefix)~=prefix then
            return nil,'unsupported schema, scope or capacity'
        end
        local size,body=payload:sub(#prefix+1):match('^(%d+)\n(.*)$')
        local n=size and math.tointeger(tonumber(size))
        if not n or n<0 or tostring(n)~=size or #body~=n then return nil,'invalid length' end
        return decode_body(body)
    end
    function codec.supported(payload) return codec.decode(payload)~=nil end
    return codec -- Does not grant authority or durable status.
end
return M
