import sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from accept_save_lifecycle import inspect
A='1'*32;B='2'*32
def fixture():
    lines=[];epoch=0
    for world in [A,'title',B,'title',A]:
        for event in ['load_pre','init_pre','init_post','load_post']:
            if event.endswith('_pre'):epoch+=1
            lines.append(f'event={event} epoch={epoch}')
        suffix='World /Game/Pal/Maps/Title/PL_Title.PL_Title' if world=='title' else f'world.directory={world} identity.selected={world} identity.loaded_world=true identity.context_status=context_agrees'
        lines.append(f'SAMPLE_EDGE epoch={epoch} {suffix}')
    return '\n'.join(lines)
class Acceptance(unittest.TestCase):
    def test_route(self):self.assertTrue(inspect(fixture(),A,B)['tested_local_route_passed'])
    def test_inert(self):
        for text in ['', '\n'.join(x for x in fixture().splitlines() if 'event=' not in x),fixture().replace('event=load_pre','event=load_post'),fixture().replace(B,A),fixture()+'\nFAIL callback']:
            with self.assertRaises(ValueError):inspect(text,A,B)
    def test_epoch_did_not_advance(self):
        text=fixture().replace('epoch=6','epoch=4')
        with self.assertRaises(ValueError):inspect(text,A,B)
    def test_stale_sample(self):
        with self.assertRaises(ValueError):inspect(fixture().replace('SAMPLE_EDGE epoch=10','SAMPLE_EDGE epoch=2'),A,B)
if __name__=='__main__':unittest.main()
