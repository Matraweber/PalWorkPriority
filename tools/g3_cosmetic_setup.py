"""Install or remove the G3 Search/Add test setup (PalSchema + Cosmetic Outfits).

Usage (game closed):
  python -B tools/g3_cosmetic_setup.py install <palschema-extract> <cosmetic-extract>
  python -B tools/g3_cosmetic_setup.py remove <backup-folder>
install: backs up SaveGames, moves the four existing PalSchema data mods aside
(they would otherwise go live with the loader), adds PalSchema 0.6.71's dll,
enabled.txt and LICENSE, and Cosmetic Outfits v10.1 under PalSchema/mods.
remove: deletes only what install added (checked against its manifest), puts
the four data mods back and verifies them. The save backup is kept.
"""
import hashlib, json, shutil, subprocess, sys, time
from pathlib import Path

UE4SS_MODS = Path('D:/Steam/steamapps/common/Palworld/Mods/NativeMods/UE4SS/Mods')
PS = UE4SS_MODS / 'PalSchema'
SAVES = Path.home() / 'AppData/Local/Pal/Saved/SaveGames'
DATA_MODS = ['KeyItems', 'SmallerPlantations', 'SuperStacksNoLag', 'TrueMonsterRancher']


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def tree(root):
    return {str(p.relative_to(root)).replace('\\', '/'): sha(p) for p in Path(root).rglob('*') if p.is_file()}


def game_running():
    out = subprocess.run(['tasklist', '/FI', 'IMAGENAME eq Palworld-Win64-Shipping.exe'], capture_output=True, text=True).stdout
    return 'Palworld-Win64-Shipping.exe' in out


def install(ps_src, co_src):
    ps_src, co_src = Path(ps_src) / 'PalSchema', Path(co_src) / 'Mods/PalSchema/mods/CosmeticOutfits'
    assert (ps_src / 'dlls/main.dll').is_file() and co_src.is_dir()
    assert not (PS / 'dlls').exists() and not (PS / 'mods/CosmeticOutfits').exists(), 'already installed'
    b = Path('D:/PalWorkPriority-backups') / time.strftime('g3-cosmetic-%Y%m%d-%H%M%S')
    b.mkdir(parents=True)
    shutil.copytree(SAVES, b / 'SaveGames')
    record = {'data_mods': {}, 'added': []}
    (b / 'datamods').mkdir()
    for name in DATA_MODS:
        src = PS / 'mods' / name
        if src.exists():
            record['data_mods'][name] = tree(src)
            shutil.move(str(src), str(b / 'datamods' / name))
    for rel in ['dlls/main.dll', 'enabled.txt', 'LICENSE']:
        assert not (PS / rel).exists(), rel
        (PS / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ps_src / rel, PS / rel)
        record['added'].append(rel)
    shutil.copytree(co_src, PS / 'mods/CosmeticOutfits')
    record['added'] += ['mods/CosmeticOutfits/' + k for k in tree(PS / 'mods/CosmeticOutfits')]
    record['hashes'] = {rel: sha(PS / rel) for rel in record['added']}
    (b / 'setup.json').write_text(json.dumps(record, indent=1))
    print(b)
    print('saves backed up; moved aside: %s; added %d files' % (', '.join(record['data_mods']), len(record['added'])))


def remove(b):
    b = Path(b)
    record = json.loads((b / 'setup.json').read_text())
    for rel in record['added']:
        p = PS / rel
        assert sha(p) == record['hashes'][rel], 'changed since install: ' + rel
        p.unlink()
    shutil.rmtree(PS / 'mods/CosmeticOutfits')
    (PS / 'dlls').rmdir()
    for name, files in record['data_mods'].items():
        shutil.move(str(b / 'datamods' / name), str(PS / 'mods' / name))
        assert tree(PS / 'mods' / name) == files, 'data mod differs after restore: ' + name
    print('removed %d added files; restored %s (hashes equal)' % (len(record['added']), ', '.join(record['data_mods'])))


if __name__ == '__main__':
    assert not game_running(), 'close the game first'
    if sys.argv[1] == 'install':
        install(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == 'remove':
        remove(sys.argv[2])
    else:
        sys.exit(__doc__)
