"""Build and stage the isolated fixed-CDO registry fixture; never install it.

Uses only the three assets in PalWorkPrioritySaveRegistry. No save-slot IO.
Existing scratch assets, sources and evidence are hashed before/after every run.
Cook success is not proof of execution inside the shipping game.
"""
from pathlib import Path
import argparse
from datetime import datetime, timezone
import hashlib
import json
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
NAMES = ('BP_SaveRegistryV1', 'BP_RegistryBridgeA', 'BP_RegistryBridgeB')


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--engine', type=Path, default=Path('D:/Program Files (x86)/Epic Games/UE_5.1'))
    parser.add_argument('--kit', type=Path, default=Path('C:/Users/matra/Desktop/PalworldModdingKit'))
    parser.add_argument('--regenerate', action='store_true', help='Back up and replace ONLY this new fixture\'s three source assets')
    args = parser.parse_args()
    engine, kit = args.engine.resolve(), args.kit.resolve()
    editor = engine / 'Engine/Binaries/Win64/UnrealEditor-Cmd.exe'
    unrealpak = engine / 'Engine/Binaries/Win64/UnrealPak.exe'
    project = kit / 'Pal.uproject'
    target = kit / 'Source/PalWidgetGen/Private'
    for path in (editor, unrealpak, project, target):
        if not path.exists():
            parser.error(f'Missing prerequisite: {path}')
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    out = ROOT / 'test-results/save-registry-v1' / stamp
    out.mkdir(parents=True, exist_ok=False)
    asset_dir = kit / 'Content/Mods/PalWorkPrioritySaveRegistry'
    sources = [ROOT / f'unreal/PalWidgetGen/Private/BuildSaveRegistryCommandlet.{ext}' for ext in ('cpp', 'h')]
    generation_file = asset_dir / 'registry-generation.json'
    generator_hashes = {str(p): sha(p) for p in sources}

    def protected():
        files = set()
        for directory in (
            kit / 'Content/Mods/PalWorkPrioritySaveScratch',
            kit / 'Saved/Cooked/Windows/Pal/Content/Mods/PalWorkPrioritySaveScratch',
        ):
            if directory.exists():
                files.update(p for p in directory.rglob('*') if p.is_file())
        for directory in (ROOT / 'test-results').glob('save-scratch-*'):
            if directory.is_dir():
                files.update(p for p in directory.rglob('*') if p.is_file())
        for base in (ROOT / 'unreal/PalWidgetGen/Private', target):
            files.update(base / f'BuildSavePrototypeCommandlet.{ext}' for ext in ('cpp', 'h'))
        files.add(ROOT / 'tools/build_save_scratch.py')
        return {str(p): sha(p) for p in sorted(files) if p.is_file()}

    before = protected()
    (out / 'preserved-before.json').write_text(json.dumps(before, indent=2), encoding='utf-8')
    receipt = {'experimental': True, 'installed': False, 'disk_save_io': False,
               'scope': 'Two-scope fixed-CDO admission fixture; no async IO, game runtime, Lua reload or travel acceptance',
               'sources': {str(p): sha(p) for p in (*sources, Path(__file__).resolve())}, 'steps': {}}

    def run(name, command, markers=()):
        log = out / f'{name}.log'
        with (out / f'{name}.stdout.log').open('w', encoding='utf-8') as stream:
            result = subprocess.run([str(x) for x in command], stdout=stream, stderr=subprocess.STDOUT)
        receipt['steps'][name] = {'exit_code': result.returncode}
        if result.returncode:
            raise RuntimeError(f'{name} failed ({result.returncode}); see {out}')
        text = log.read_text(encoding='utf-8-sig', errors='replace') if log.exists() else ''
        if any(marker not in text for marker in markers) or 'pass=0' in text or 'fixture_pass=0' in text:
            raise RuntimeError(f'{name}: required fixture evidence missing or failed; see {log}')
        print(f'PASS {name}', flush=True)

    try:
        for source in sources:
            dest = target / source.name
            if not dest.exists() or dest.read_bytes() != source.read_bytes():
                shutil.copy2(source, dest)
        run('build', [engine / 'Engine/Build/BatchFiles/Build.bat', 'PalEditor', 'Win64', 'Development',
                      project, '-CompilerVersion=14.38.33130', '-WaitMutex', '-NoHotReloadFromIDE'])
        assets = [asset_dir / f'{name}.uasset' for name in NAMES]
        if args.regenerate:
            # Exact, nonrecursive targets; keep previous candidate bytes in this run.
            for path in assets:
                if path.resolve().parent != asset_dir.resolve():
                    raise RuntimeError('Unexpected asset target')
                if path.exists():
                    backup = out / 'previous-source-assets' / path.name
                    backup.parent.mkdir(exist_ok=True)
                    shutil.copy2(path, backup)
                    path.unlink()
            if generation_file.exists():
                backup = out / 'previous-source-assets' / generation_file.name
                backup.parent.mkdir(exist_ok=True)
                shutil.copy2(generation_file, backup)
                generation_file.unlink()
        present = [p.exists() for p in assets]
        if any(present) and not all(present):
            raise RuntimeError('Partial registry fixture exists; use --regenerate to back up and replace it')
        if all(present):
            provenance = json.loads(generation_file.read_text(encoding='utf-8')) if generation_file.exists() else {}
            if provenance.get('generator_sources') != generator_hashes or provenance.get('source_assets') != {str(p): sha(p) for p in assets}:
                raise RuntimeError('Existing assets lack matching generator provenance; use --regenerate')
        base = [editor, project, '-unattended', '-nullrhi', '-nosplash']
        markers = ['literal_mutates_actual_cdo pass=1', 'independent_class_same_cdo_refused pass=1',
                   'busy_holder_survives_gc_without_fixture_root pass=1', 'terminal_holder_survives_gc pass=1',
                   'explicit_root_anchor_targets_fixed_cdo pass=1',
                   'old_holder_cannot_bypass_registry pass=1', 'fixture_pass=1 checks=28 disk_io=0']
        run('generate' if not all(present) else 'verify', base + ['-run=BuildSaveRegistry',
            '-Generate' if not all(present) else '-Verify', f'-abslog={out / ("generate.log" if not all(present) else "verify.log")}'], markers)
        pristine = {str(p): sha(p) for p in assets}
        if not all(present):
            generation_file.write_text(json.dumps({'generator_sources': generator_hashes, 'source_assets': pristine}, indent=2), encoding='utf-8')
        run('reload', base + ['-run=BuildSaveRegistry', '-Verify', f'-abslog={out / "reload.log"}'], markers)
        if pristine != {str(p): sha(p) for p in assets}:
            raise RuntimeError('Reload unexpectedly modified persisted registry defaults')
        packages = '+'.join(f'/Game/Mods/PalWorkPrioritySaveRegistry/{name}' for name in NAMES)
        run('cook', base + ['-run=Cook', '-TargetPlatform=Windows', f'-Package={packages}',
                           f'-OutputDir={out / "Cooked/[Platform]"}', '-SkipCookingEditorContent', f'-abslog={out / "cook.log"}'])
        cooked = out / 'Cooked/Windows/Pal/Content/Mods/PalWorkPrioritySaveRegistry'
        files = [cooked / f'{name}{ext}' for name in NAMES for ext in ('.uasset', '.uexp')]
        for path in files:
            if not path.is_file() or not path.stat().st_size:
                raise RuntimeError(f'Missing cooked output {path}')
            data = path.read_bytes()
            for encoding in ('ascii', 'utf-16-le'):
                if '/Script/PalWidgetGen'.encode(encoding) in data:
                    raise RuntimeError(f'Editor-module reference in cooked output {path}')
        response = out / 'registry.response.txt'
        response.write_text('\n'.join(f'"{p}" "../../../Pal/Content/Mods/PalWorkPrioritySaveRegistry/{p.name}"' for p in files) + '\n', encoding='utf-8')
        pak = out / 'PalWorkPrioritySaveRegistryV1.pak'
        run('pak', [unrealpak, pak, f'-Create={response}', '-compress'])
        run('pak-list', [unrealpak, pak, '-List'])
        listing = (out / 'pak-list.stdout.log').read_text(encoding='utf-8', errors='replace')
        if '6 files' not in listing or any(p.name not in listing for p in files):
            raise RuntimeError('Pak contents mismatch')
        receipt.update(source_assets=pristine, cooked={str(p): sha(p) for p in files}, pak=str(pak), pak_sha256=sha(pak), passed=True)
    except Exception as exc:
        receipt.update(passed=False, error=str(exc))
        raise
    finally:
        after = protected()
        receipt['preserved_unchanged'] = before == after
        if before != after:
            receipt.update(passed=False, error='Protected scratch inputs/evidence changed during run')
        (out / 'receipt.json').write_text(json.dumps(receipt, indent=2), encoding='utf-8')
        print(f'Receipt: {out / "receipt.json"}', flush=True)
        if before != after:
            raise RuntimeError('Protected scratch inputs/evidence changed during run; inspect receipt')
    print(f'Staged only: {pak}', flush=True)


if __name__ == '__main__':
    main()
