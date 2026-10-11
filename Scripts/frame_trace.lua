-- Opt-in, bounded scalar events. File I/O happens only in explicit commands,
-- outside frame recordings. Anchors bracket publication to an external QPC reader.
local M = {}
function M.new(options)
    options=options or {}
    local clock=options.clock or os.clock
    local open=options.open or io.open
    local self={enabled=false,events={},anchors={},dropped=0,expired=false,used={},used_n=0,attempts=0,
        limit=options.limit or 4096,seconds=options.seconds or 180,threshold=options.threshold or .004}
    function self:start()
        self.events,self.anchors={},{}
        self.dropped,self.expired=0,false
        self.attempts=0
        self.started=clock()
        self.enabled=true
    end
    function self:stop() self.enabled=false end
    function self:record(name,first,last)
        if not self.enabled then return end
        if type(first)~='number' or type(last)~='number' or first~=first or last~=last
            or first<self.started or last<first or last==math.huge then return end
        if last-self.started>self.seconds then self.enabled=false; self.expired=true; return end
        if last-first<self.threshold then return end
        if #self.events>=self.limit then self.dropped=self.dropped+1; return end
        self.events[#self.events+1]={name=tostring(name):sub(1,160):gsub('[\t\r\n]',' '),first=first,last=last}
    end
    local function write(path,text)
        local handle,reason=open(path,'wb')
        if not handle then return false,'open: '..tostring(reason) end
        local ok,result,err=pcall(function() return handle:write(text) end)
        local closed,close_result,close_err=pcall(function() return handle:close() end)
        if not ok or not result then return false,'write: '..tostring(ok and err or result) end
        if not closed or not close_result then return false,'close: '..tostring(closed and close_err or close_result) end
        return true
    end
    function self:anchor(path,id)
        if not self.started then return false,'start frameevents first' end
        if type(id)~='string' or #id<1 or #id>64 or not id:match('^[%w_-]+$') then return false,'invalid nonce' end
        if self.used[id] then return false,'duplicate nonce' end
        if self.attempts>=16 or self.used_n>=256 then return false,'anchor attempt limit' end
        -- A failed close may still publish bytes. Never let another interval
        -- reuse that nonce, even after starting a new trace in this process.
        self.used[id]=true
        self.used_n,self.attempts=self.used_n+1,self.attempts+1
        local first=clock()
        local ok,reason=write(path,id..'\n')
        local last=clock()
        if not ok then return false,reason end
        if last<first then return false,'clock rollback' end
        self.anchors[#self.anchors+1]={id=id,first=first,last=last}
        return true
    end
    function self:export(path)
        if not self.started then return false,'no trace' end
        local lines={'#PWP_FRAME_EVENTS\t1','#clock\tLua os.clock; requires measured external alignment',
            '#inclusive\ttrue','#dropped\t'..self.dropped,'#expired\t'..tostring(self.expired),
            '#threshold_seconds\t'..self.threshold,'#limit\t'..self.limit}
        for _,a in ipairs(self.anchors) do lines[#lines+1]=string.format('anchor\t%s\t%.9f\t%.9f',a.id,a.first,a.last) end
        for _,e in ipairs(self.events) do lines[#lines+1]=string.format('event\t%s\t%.9f\t%.9f',e.name,e.first,e.last) end
        return write(path,table.concat(lines,'\n')..'\n')
    end
    return self
end
return M
