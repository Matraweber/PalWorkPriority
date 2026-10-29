-- Pure Lua state shared by the panel's native drawing adapters.
local M = {}
-- Exact no-child contracts only; unknown classes must prove their children.
M.leaves = {TextBlock=true, RichTextBlock=true, Image=true, Spacer=true,
    EditableText=true, EditableTextBox=true, MultiLineEditableText=true,
    MultiLineEditableTextBox=true, ProgressBar=true, Slider=true, SpinBox=true,
    Throbber=true, CircularThrobber=true, BP_PalTextBlock_C=true}

function M.amount(text, maximum)
    if type(text) ~= "string" then return nil end
    text = text:match("^%s*(.-)%s*$")
    if not text:match("^%d+$") then return nil end
    local value = math.tointeger(text)
    if not value or value < 1 or value > (maximum or 9999999) then return nil end
    return value
end

-- A successful pcall alone is insufficient: mocked/native adapters may
-- explicitly return false. Void reflected setters return nil on success.
function M.write(cache, key, token, setter)
    if cache[key] == token then return true end
    local ok, result = pcall(setter)
    if ok and result ~= false then cache[key] = token return true end
    cache[key] = nil
    return false
end

function M.name(w)
    if w == nil then return nil end
    local ok, name = pcall(function() return w:GetFullName() end)
    if ok and type(name) == "string" and name ~= "" then return name end
end

-- Reparent on every layout change, including two different row canvases.
-- Attachment and anchor writes are committed together; failed writes retry.
function M.place(cache, key, w, parent, anchors, autosize, z)
    local parent_name = M.name(parent)
    if not parent_name then return nil end
    local maximum = anchors.Maximum or anchors.Minimum
    local token = parent_name .. ":" .. tostring(autosize) .. ":" .. z
        .. ":" .. anchors.Minimum.X .. ":" .. anchors.Minimum.Y
        .. ":" .. maximum.X .. ":" .. maximum.Y
    local slot
    local ok = pcall(function()
        if cache[key] ~= token then
            local old = w:GetParent()
            if M.name(old) ~= parent_name then
                w:RemoveFromParent()
                slot = parent:AddChildToCanvas(w)
            else
                slot = w.Slot
            end
            if not slot then error("no canvas slot") end
            if slot:SetAnchors(anchors) == false then error("anchors refused") end
            if slot:SetAutoSize(autosize) == false then error("size mode refused") end
            if slot:SetZOrder(z) == false then error("z order refused") end
        else
            slot = w.Slot
        end
    end)
    if not ok or not slot then cache[key] = nil return nil end
    local changed = cache[key] ~= token
    cache[key] = token
    return slot, changed
end

function M.new()
    local state = { epoch = 0, phase = "closed", objects = {}, refs = {}, pending = 0 }

    function state:invalidate()
        self.epoch = self.epoch + 1
        self.objects, self.refs = {}, {}
        self.pending = 0
    end

    function state:remember(w)
        local name = M.name(w)
        if name then self.objects[name] = w end
        return name
    end

    -- Maps retain only names between callbacks. A caller must refresh the
    -- snapshot from a freshly resolved root before reading them again.
    function state:cache()
        local names = {}
        return setmetatable({}, {
            __index = function(_, key) return self.objects[names[key]] end,
            __newindex = function(_, key, w) names[key] = self:remember(w) end,
            __pairs = function()
                local key
                return function()
                    while true do
                        key = next(names, key)
                        if key == nil then return nil end
                        local w = self.objects[names[key]]
                        if w then return key, w end
                    end
                end
            end,
        })
    end

    -- skip: names of containers recorded but not descended into (the icon
    -- pin shelf, whose children only the draw that needs one reads).
    function state:snapshot(root, limit, skip)
        self.objects = {}
        local seen, count, complete = {}, 0, true
        local function visit(w, depth)
            if w == nil then complete = false return end
            local name = M.name(w)
            -- Missing advertised children/names mean the snapshot is partial,
            -- not that a control is absent and safe to reconstruct.
            if not name then complete = false return end
            if seen[name] then return end
            if depth > 64 or count >= (limit or 4096) then complete = false return end
            seen[name], count = true, count + 1
            self.objects[name] = w
            if skip and skip[name] then return end
            if M.leaves[name:match("^([%a_][%w_]*) [^%s%c]+$")] then return end
            local ok, n = pcall(function() return w:GetChildrenCount() end)
            if ok and type(n) == "number" then
                if math.tointeger(n) == nil or n < 0 or n > (limit or 4096) then
                    complete = false
                    return
                end
                for i = 0, n - 1 do
                    local got, child = pcall(function() return w:GetChildAt(i) end)
                    if got then visit(child, depth + 1) else complete = false end
                end
            else
                complete = false
            end
        end
        visit(root, 0)
        -- Widgets this rescan named, for the panel's perf line.
        self.last_count = count
        if not complete then self.objects = {} end
        return complete and count > 0
    end

    function state:dispatch(fn, ...)
        local args, epoch = table.pack(...), self.epoch
        local session_epoch = self.session and self.session.epoch
        local ui_epoch = self.session and self.session.ui_epoch
        if self.in_action then
            return fn(table.unpack(args, 1, args.n))
        end
        if type(ExecuteInGameThread) ~= "function" then
            self.in_action = true
            local result = table.pack(pcall(fn, table.unpack(args, 1, args.n)))
            self.in_action = false
            if not result[1] then error(result[2], 0) end
            return table.unpack(result, 2, result.n)
        end
        if self.pending >= 128 then return false end
        self.pending = self.pending + 1
        local queued, result = pcall(ExecuteInGameThread, function()
            if epoch ~= self.epoch then return end
            self.pending = self.pending - 1
            if self.session and (session_epoch ~= self.session.epoch
                or ui_epoch ~= self.session.ui_epoch) then return end
            self.in_action = true
            local ok, why = pcall(fn, table.unpack(args, 1, args.n))
            self.in_action = false
            if not ok and self.on_error then self.on_error(why) end
        end)
        if not queued or result == false then
            if epoch == self.epoch then self.pending = math.max(0, self.pending - 1) end
            if self.on_error then self.on_error("game-thread action could not be queued") end
            return false
        end
        return true
    end

    return state
end

return M
