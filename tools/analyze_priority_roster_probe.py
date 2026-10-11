"""Validate a completed diagnostic log. Never grants migration or Pal ownership."""
import argparse
import json
from pathlib import Path

def analyze(text,nonce,keys,route='camp'):
    assert route in ('camp','guild','parameter','world','direct')
    expected=set(keys)
    assert len(expected)==len(keys) and expected,'invalid expected key set'
    events=[]
    for line in text.splitlines():
        parts=line.split('\t')
        assert len(parts)>=3 and parts[1]==nonce,'wrong/malformed run'
        fields={}
        for value in parts[3:]:
            k,sep,v=value.partition('=');assert sep and k not in fields,'duplicate/malformed field'
            fields[k]=v
        events.append((parts[2],fields))
    assert events and events[0][0]=='armed' and events[-1][0]=='done','incomplete run'
    assert sum(e=='armed' for e,_ in events)==1 and sum(e=='done' for e,_ in events)==1,'duplicate run boundary'
    assert events[0][1].get('read_only')=='true'
    assert events[-1][1].get('samples')=='3'
    seen_samples=[];rows={};saved={};parameters={};ownership={};results=[];identity=None
    for event,f in events:
        assert event in ('armed','pal','guild_key','parameter','ownership','saved_key','sample','done'),'failed/unknown event'
        if event in ('armed','sample','done'):assert f.get('activation_allowed')=='false'
        if event not in ('pal','guild_key','parameter','ownership','saved_key','sample'):continue
        sample=int(f['sample']);assert sample==len(seen_samples)+1 and sample<=3,'out of order'
        if event=='ownership':
            assert route=='direct' and f['key'] in expected and f['key'] not in ownership
            assert f['accepted']=='true','direct ownership rejected'
            ownership[f['key']]=True
        elif event=='parameter':
            assert route in ('parameter','world') and f['key'] in expected and f['key'] not in parameters
            if route=='world':assert f.get('world_resolved')=='true'
            assert int(f['address'])>0 and len(f['group'])==32 and all(c in '0123456789abcdef' for c in f['group'])
            assert f['matches'] in ('true','false')
            parameters[f['key']]=f
        elif event=='pal':
            assert route=='camp'
            assert f['key'] not in rows,'duplicate Pal'
            values=f['capable'].split(',') if f['capable'] else []
            assert len(values)==len(set(values)) and all(v.isdecimal() and 1<=int(v)<=64 for v in values)
            rows[f['key']]=f['camp']
        elif event=='guild_key':
            assert route in ('guild','parameter','world','direct') and f['key'] not in rows,'duplicate/wrong-route guild key'
            rows[f['key']]='guild-roster'
        elif event=='saved_key':
            assert f['key'] in expected and f['key'] not in saved,'unexpected/duplicate saved key'
            saved[f['key']]=f
        else:
            assert f.get('complete')=='true' and f.get('second_complete')=='true' and f.get('stable')=='true','partial/unstable observation'
            assert f.get('world_membership_proven')=='false' and f.get('route', 'camp')==route
            assert int(f['pals'])==len(rows)
            if route=='camp':
                assert f.get('expected_camps_observed')=='true' and int(f['camps'])==2 and int(f['target_camps'])==2
            elif route=='direct':
                assert int(f['array_address'])==0 and int(f['camps'])==0 and set(ownership)==expected
            else:
                assert int(f['array_address'])>0 and int(f['camps'])==0
            current=(f['storage'],f['guild'])
            assert identity is None or identity==current,'scope changed';identity=current
            assert set(saved)==expected and int(f['saved'])==len(expected)
            found=expected.intersection(rows);missing=expected-found
            if route=='direct':assert set(rows)==expected and found==expected and not missing
            if route in ('parameter','world'):
                for k,r in parameters.items():
                    assert r['matches']==('true' if r['group']==f['guild'] else 'false')
                assert all(k in parameters and parameters[k]['matches']=='true' for k in rows)
            else:assert not parameters
            for k,r in saved.items():
                assert r['observed']==('true' if k in found else 'false')
                assert r['camp']==(rows[k] if k in found else 'unknown')
            assert int(f['matched'])==len(found) and int(f['unknown'])==len(missing)
            results.append({'sample':sample,'observed_pals':len(rows),'matched':len(found),'unknown_keys':sorted(missing)})
            seen_samples.append(sample);rows={};saved={};parameters={};ownership={}
    assert seen_samples==[1,2,3] and not rows and not saved,'missing samples'
    return {'diagnostic_complete':True,'route':route,'activation_allowed':False,'world_membership_proven':False,
            'storage':identity[0],'guild':identity[1],'samples':results}

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('evidence',type=Path);a=p.parse_args()
    install=json.loads((a.evidence/'install.json').read_text())
    log=Path(install['probe'])/'Scripts/roster.log'
    print(json.dumps(analyze(log.read_text(),install['nonce'],install['saved_keys'],install.get('route','camp')),indent=2))
