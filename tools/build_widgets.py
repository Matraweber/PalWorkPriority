"""Rebuild the mod's two cooked widgets and stage a new PalWorkPriority.pak.

    python tools/build_widgets.py [--engine DIR] [--kit DIR]

Steps, each logged under test-results/widgets-<time>/ with a receipt.json:
copy unreal/PalWidgetGen into the modding kit, compile PalEditor, back up the
kit's WBP_WorkRules/WBP_StandInput assets, run both generator commandlets
(they build the graphs and execute the compiled handlers against fixtures),
re-verify each in a fresh process (-VerifyInputOnly), cook both packages,
pak them with the existing verified ModActor, and list the pak.

Stages only: build/PalWorkPriority.pak. Installing it in the game and updating
docs/asset-contract.json are separate, deliberate steps (see widget-spec.md).
"""
import argparse
import hashlib
import json
import shutil
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WIDGETS = ('WBP_WorkRules', 'WBP_StandInput')
COMMANDLETS = {'WBP_StandInput': 'BuildStandInputWidget', 'WBP_WorkRules': 'BuildWorkRulesWidget'}
# The ModActor shipped since 2026-09-16; asset-contract.json pins its hashes.
MOD_ACTOR = ROOT / 'test-results/escape-oldpak-20260916'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--engine', type=Path, default=Path('D:/Program Files (x86)/Epic Games/UE_5.1'))
    parser.add_argument('--kit', type=Path, default=Path('C:/Users/matra/Desktop/PalworldModdingKit'))
    args = parser.parse_args()
    engine, kit = args.engine.resolve(), args.kit.resolve()
    editor = engine / 'Engine/Binaries/Win64/UnrealEditor-Cmd.exe'
    unrealpak = engine / 'Engine/Binaries/Win64/UnrealPak.exe'
    build_bat = engine / 'Engine/Build/BatchFiles/Build.bat'
    project = kit / 'Pal.uproject'
    module = kit / 'Source/PalWidgetGen'
    assets = kit / 'Content/Mods/PalWorkPriority/UI'
    for path in (editor, unrealpak, build_bat, project, module, assets, MOD_ACTOR):
        if not path.exists():
            parser.error(f'Missing prerequisite: {path}')

    out = ROOT / 'test-results' / time.strftime('widgets-%Y%m%d-%H%M%S')
    out.mkdir(parents=True)
    receipt = {'steps': {}, 'sources': {}, 'passed': False}

    def run(name, command, must=()):
        log = out / f'{name}.log'
        with log.open('w', encoding='utf-8') as stream:
            result = subprocess.run([str(x) for x in command], stdout=stream, stderr=subprocess.STDOUT)
        text = log.read_text(encoding='utf-8', errors='replace')
        receipt['steps'][name] = {'exit_code': result.returncode}
        if result.returncode:
            raise RuntimeError(f'{name} failed ({result.returncode}); see {log}')
        missing = [m for m in must if m not in text]
        if missing or 'FAILED' in text:
            raise RuntimeError(f'{name}: FAILED marker or missing evidence {missing}; see {log}')
        print(f'PASS {name}', flush=True)
        return text

    try:
        # Sources: the repo copy is the reviewed one; the kit gets it verbatim.
        source = ROOT / 'unreal/PalWidgetGen'
        for path in source.rglob('*'):
            if path.is_file():
                dest = module / path.relative_to(source)
                dest.parent.mkdir(parents=True, exist_ok=True)
                if not dest.exists() or dest.read_bytes() != path.read_bytes():
                    shutil.copy2(path, dest)
                receipt['sources'][str(path.relative_to(ROOT))] = sha(path)
        run('compile', [build_bat, 'PalEditor', 'Win64', 'Development', project,
                        '-CompilerVersion=14.38.33130', '-WaitMutex', '-NoHotReloadFromIDE'])

        backup = out / 'kit-assets-before'
        backup.mkdir()
        for name in WIDGETS:
            shutil.copy2(assets / f'{name}.uasset', backup / f'{name}.uasset')
        receipt['kit_assets_before'] = {n: sha(backup / f'{n}.uasset') for n in WIDGETS}

        base = [editor, project, '-unattended', '-nullrhi', '-nosplash']
        for name in ('WBP_StandInput', 'WBP_WorkRules'):
            commandlet = COMMANDLETS[name]
            run(f'generate-{name}', base + [f'-run={commandlet}', f'-abslog={out / ("generate-" + name + ".abslog")}'])
            run(f'verify-{name}', base + [f'-run={commandlet}', '-VerifyInputOnly',
                                          f'-abslog={out / ("verify-" + name + ".abslog")}'])
        receipt['kit_assets_after'] = {n: sha(assets / f'{n}.uasset') for n in WIDGETS}

        packages = '+'.join(f'/Game/Mods/PalWorkPriority/UI/{n}' for n in WIDGETS)
        run('cook', base + ['-run=Cook', '-TargetPlatform=Windows', f'-Package={packages}',
                            f'-OutputDir={out / "Cooked/[Platform]"}', '-SkipCookingEditorContent'])
        cooked = out / 'Cooked/Windows/Pal/Content/Mods/PalWorkPriority/UI'
        members = [(MOD_ACTOR / f'ModActor.{e}', f'ModActor.{e}') for e in ('uasset', 'uexp')]
        members += [(cooked / f'{n}.{e}', f'UI/{n}.{e}') for n in WIDGETS for e in ('uasset', 'uexp')]
        for path, _ in members:
            if not path.is_file() or not path.stat().st_size:
                raise RuntimeError(f'Missing cooked output {path}')
            data = path.read_bytes()
            for encoding in ('ascii', 'utf-16-le'):
                if '/Script/PalWidgetGen'.encode(encoding) in data:
                    raise RuntimeError(f'Editor-module reference in cooked output {path}')
        response = out / 'pak.response.txt'
        response.write_text('\n'.join(f'"{p}" "../../../Pal/Content/Mods/PalWorkPriority/{rel}"'
                                      for p, rel in members) + '\n', encoding='utf-8')
        (ROOT / 'build').mkdir(exist_ok=True)
        pak = ROOT / 'build/PalWorkPriority.pak'
        run('pak', [unrealpak, pak, f'-Create={response}', '-compress'])
        listing = run('pak-list', [unrealpak, pak, '-List'], must=('6 files',))
        receipt.update(pak=str(pak), pak_sha256=sha(pak), pak_bytes=pak.stat().st_size,
                       members=[{'path': rel, 'sha256': sha(p)} for p, rel in members], passed=True)
        print(json.dumps({'pak_sha256': receipt['pak_sha256'], 'bytes': receipt['pak_bytes']}, indent=1))
    except Exception as exc:
        receipt['error'] = str(exc)
        raise
    finally:
        (out / 'receipt.json').write_text(json.dumps(receipt, indent=2), encoding='utf-8')
        print(f'Receipt: {out / "receipt.json"}', flush=True)


if __name__ == '__main__':
    main()
