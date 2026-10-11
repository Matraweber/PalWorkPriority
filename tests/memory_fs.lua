-- Ordinary nil,error returns model disk failures; exceptions are tested too.
return function()
    local fs = { files = {}, fault = nil, operations = {} }
    local function fail(op, path)
        fs.operations[#fs.operations + 1] = op .. ':' .. path
        if fs.fault then return fs.fault(op, path) end
    end
    function fs.open(path, mode)
        if fail('open', path) then return nil, 'injected open failure', 13 end
        if mode:sub(1,1) == 'r' and fs.files[path] == nil then return nil, 'missing', 2 end
        if mode:sub(1,1) == 'w' then fs.files[path] = '' end
        local position = 1
        return {
            read = function(_, n)
                if fail('read', path) then return nil, 'injected read failure' end
                local text = fs.files[path]
                if n == '*a' then return text end
                if position > #text then return nil end
                local part = text:sub(position, position+n-1)
                position = position + #part
                return part
            end,
            lines = function()
                local text = fs.files[path] .. '\n'
                return function()
                    if position > #text then return nil end
                    local last = text:find('\n',position,true)
                    if not last then return nil end
                    local line = text:sub(position,last-1)
                    position = last+1
                    return line
                end
            end,
            write = function(self, text)
                if fail('write', path) then return nil, 'injected write failure' end
                fs.files[path] = (fs.files[path] or '') .. text
                return self
            end,
            flush = function()
                if fail('flush', path) then return nil, 'injected flush failure' end
                return true
            end,
            close = function()
                if fail('close', path) then return nil, 'injected close failure' end
                return true
            end,
        }
    end
    function fs.rename(from, to)
        if fail('rename', from .. '>' .. to) then return nil, 'injected rename failure' end
        if not fs.files[from] then return nil, 'missing', 2 end
        if fs.files[to] then return nil, 'destination exists', 17 end
        fs.files[to], fs.files[from] = fs.files[from], nil
        return true
    end
    function fs.remove(path)
        if fail('remove', path) then return nil, 'injected remove failure' end
        if fs.files[path] == nil then return nil, 'missing', 2 end
        fs.files[path] = nil
        return true
    end
    return fs
end
