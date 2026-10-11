local status=require('panel_status')
local calls={}
local remote={epoch=5,request_stock=function(guild,selected)
    calls[#calls+1]={guild,selected}
end,storage_view=function(guild,selected)
    return {verified=true,guild=guild,camp=selected,choices={selected},
        scope='camp',label='Base a',totals={Stone=23},epoch=5,expires_at=os.clock()+10}
end}
local view=status.stock({}, {}, 'g','a',true,remote)
assert(view.verified and view.totals.Stone==23 and calls[1][1]=='g' and calls[1][2]=='a')
view=status.stock({}, {}, 'g','a',true,nil)
assert(not view.verified and next(view.totals)==nil,'older hot-loaded transport must stay unavailable')
view=status.stock({}, {}, nil,'a',true,remote)
assert(not view.verified and #calls==1,'unknown guild must not request stock')
view=status.stock({}, {}, 'g','a',false,remote)
assert(not view.verified and #calls==1,'authority must not use client transport')
remote.storage_view=function()return nil end
view=status.stock({}, {}, 'g','a',true,remote)
assert(not view.verified and next(view.totals)==nil,'missing response is not empty verified storage')
local candidate={verified=true,guild='g',camp='a',scope='camp',choices={'a'},
    totals={Stone=23},label='base',epoch=5,expires_at=os.clock()+10}
remote.storage_view=function()return candidate end
for _,pair in ipairs({{'guild','foreign'},{'camp','foreign'},{'epoch',4},{'expires_at',-1}}) do
    local old=candidate[pair[1]];candidate[pair[1]]=pair[2]
    assert(not status.stock({}, {}, 'g','a',true,remote).verified,'invalid provider view')
    candidate[pair[1]]=old
end
remote.request_stock=function()error('unavailable transport')end
assert(not status.stock({}, {}, 'g','a',true,remote).verified,'provider error escaped')
remote.request_stock=function()end;candidate.verified=false
assert(next(status.stock({}, {}, 'g','a',true,remote).totals)==nil,'unknown provider leaked old totals')
local clock=os.clock;os.clock=function()return 131 end
local scheduler={pass_id=1,last_storage_by_camp={a={guild='g',pass=1,scope='camp',verified=true,
    sampled_at=100,ttl=30}},last_totals_by_camp={a={Stone=23}}}
assert(not status.stock({},scheduler,'g','a',false).verified,'authority stale stock remained verified')
os.clock=function()return 105 end
assert(status.stock({},scheduler,'g','a',false).verified)
os.clock=clock
print('panel storage routes only through scoped transport on clients')
