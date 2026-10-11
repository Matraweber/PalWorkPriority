"""Accept one observed local A/title/B/title/A route, not all lifecycle paths."""
import re
def inspect(text, first, second):
    if first==second:raise ValueError('distinct save IDs required')
    expected=['load_pre','init_pre','init_post','load_post']
    position=0;epoch=0;completed=set();events=0;hosts=[];worlds=[];last_world_epoch=-1
    for line in text.splitlines():
        if 'FAIL' in line or 'terminal=true' in line:raise ValueError('observer failure')
        event=re.search(r'event=(\w+) epoch=(\d+)',line)
        if event:
            name,value=event.group(1),int(event.group(2))
            if name!=expected[position]:raise ValueError('unpaired event sequence')
            wanted=epoch+1 if name.endswith('_pre') else epoch
            if value!=wanted:raise ValueError('epoch did not follow transition')
            epoch=value;position=(position+1)%4;events+=1
            if name=='load_post':completed.add(epoch)
        if 'SAMPLE_EDGE' not in line:continue
        e=re.search(r'epoch=(\d+)',line)
        if not e or int(e.group(1))!=epoch or epoch not in completed:raise ValueError('sample without completed event boundary')
        if 'PL_Title.PL_Title' in line:
            world='title'
        elif 'identity.loaded_world=true' in line:
            directory=re.search(r'world.directory=([a-f0-9]{32})',line)
            if not directory:raise ValueError('host directory unavailable')
            world=directory.group(1)
            if f'identity.selected={world}' not in line or 'identity.context_status=context_agrees' not in line:
                raise ValueError('host identity disagreement')
            hosts.append({'storage':world,'epoch':int(e.group(1))})
        else:continue
        if not worlds or worlds[-1]!=world:
            if epoch<=last_world_epoch:raise ValueError('world changed without new lifecycle epoch')
            worlds.append(world);last_world_epoch=epoch
    route=[first,'title',second,'title',first]
    if position:raise ValueError('incomplete final callback sequence')
    if not any(worlds[n:n+5]==route for n in range(max(0,len(worlds)-4))):raise ValueError('distinct return route incomplete')
    return {'tested_local_route_passed':True,'events':events,'hosts':hosts,
            'all_lifecycle_paths_verified':False,'storage_grant':False,'async_enabled':False}
if __name__=='__main__':
    import sys,json
    from pathlib import Path
    print(json.dumps(inspect(Path(sys.argv[1]).read_text(),sys.argv[2],sys.argv[3]),indent=2))
