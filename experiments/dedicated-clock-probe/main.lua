-- Isolated clock-only bootstrap. No world, guild, Pal or persistence adapters.
local root=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
    :match('^(.*)/main.lua$'))
local entry=dofile(root..'/dedicated_clock_entry.lua')
return entry.start{root=root,config=dofile(root..'/config.lua'),fs=io,
    clock_module=dofile(root..'/dedicated_parameter_clock.lua'),
    probe=dofile(root..'/dedicated_clock_probe.lua'),
    resolve=function()return StaticFindObject('/Script/Engine.Default__GameplayStatics')end,
    schedule=LoopInGameThreadWithDelay,cancel=CancelDelayedAction}
