local Writer=require('settings_writer')
local G=string.rep('b',32)
local function fixture()
    local c={scope='PWP-SCOPE-1:'..string.rep('a',32)..':'..G..':priorities',guild=G,
        stream='priorities',session='boot',incarnation='inc',epoch=1,camp='A',authority=true}
    local f={revision=0,durable=0,state='saved',stages=0,submits=0,closes=0}
    local s={}
    function s:status(ctx)
        assert(ctx.guild==G and ctx.epoch==1);ctx.guild='mutated copy'
        return {state=f.state,recovered=true,activation_taken=true,blocked_commit=f.blocked,
            barrier={stream_required=f.revision,durable=f.durable,stream_unsubmitted=0}}
    end
    function s:ready() return f.state=='saved' and f.revision==f.durable end
    function s:stage() f.stages=f.stages+1;if f.on_stage then return f.on_stage() end;return f.stages end
    function s:submit(ctx,ticket,body)
        f.submits=f.submits+1;f.body=body
        if f.on_submit then return f.on_submit() end
        f.revision=f.revision+1;f.state='saving'
        return {scope=c.scope,session=c.session,revision=f.revision}
    end
    function s:poll() if f.on_poll then f.on_poll() end end
    function s:close() f.closes=f.closes+1;if f.on_close then f.on_close() end;return true end
    f.options={enabled=true,session=s,context=c,body='old',recovery_body='old',
        recovery={scope=c.scope,session=c.session,revision=0}}
    f.writer=assert(Writer.new(f.options));return f
end
do
    local f=fixture();f.options.context.guild='changed';f.options.context.epoch=9
    local r=f.writer:submit('new');assert(r.state=='pending' and r.receipt.epoch==1)
    assert(f.writer:poll().state=='saving')
    f.state='saved';f.durable=1;assert(f.writer:poll().state=='saved')
    local identity=f.writer:identity();identity.guild='bad';assert(f.writer:identity().guild==G)
end
for _,mode in ipairs({'nil','throw','malformed'}) do
    local f=fixture();f.on_submit=function()
        if mode=='throw' then error('lost return') end
        if mode=='malformed' then return {} end
    end
    assert(f.writer:submit('retained').state=='uncertain')
    assert(f.writer:status().candidate_retained and f.writer:poll().state=='uncertain')
    assert(f.writer:submit('later').state=='uncertain' and f.submits==1)
end
do
    local f=fixture();f.on_stage=function() return nil end
    assert(f.writer:submit('no').state=='rejected' and f.submits==0)
    assert(not f.writer:status().candidate_retained)
    f=fixture();f.on_submit=function() return false end
    assert(f.writer:submit('no').state~='pending' and f.writer:status().closed)
    assert(not f.writer:status().candidate_retained and f.writer:poll().state~='saved')
end
for _,where in ipairs({'stage','submit','poll'}) do
    local f=fixture()
    f['on_'..where]=function() assert(f.writer:close()==false);return 1 end
    local r=where=='poll' and f.writer:poll() or f.writer:submit('candidate')
    assert(r.state=='stale' and f.writer:status().closed and f.closes==1,where)
    assert(f.writer:poll().state~='saved')
end
do
    local f=fixture();f.on_submit=function()
        assert(f.writer:submit('nested').state=='uncertain')
        return {scope=f.options.context.scope,session='boot',revision=1}
    end
    assert(f.writer:submit('outer').state=='uncertain')
    assert(f.writer:poll().state=='uncertain' and f.submits==1 and f.writer:status().candidate_retained)
end
do
    local f=fixture();f.on_close=function() assert(f.writer:close()==false) end
    assert(f.writer:close() and f.closes==1 and f.writer:drain())
end
for _,state in ipairs({'error','uncertain'}) do
    for _,blocked in ipairs({false,true}) do
        local f=fixture();assert(f.writer:submit('candidate').state=='pending')
        f.state=state;f.blocked=blocked
        assert(f.writer:poll().state==state,state)
        assert(f.writer:submit('later').state~='pending')
    end
end
do
    local f=fixture()
    for i=1,256 do assert(f.writer:submit(tostring(i)).state=='pending') end
    assert(f.writer:submit('overflow').state=='rejected' and f.submits==256)
end
print('settings_writer: immutable context, uncertainty, reentry, close, bounded admission passed')
