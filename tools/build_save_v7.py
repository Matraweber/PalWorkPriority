"""Build the editor-native V7 integration experiment; never install it.

Uses three Engine-only V7 assets and unique explicitly owned dev save slots.
The C++ coordinator/receiver is editor-only, NOT a shipping runtime artifact.
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
import uuid

ROOT = Path(__file__).resolve().parents[1]
NAMES = ('BP_RegistryEntryV7', 'BP_SaveRegistryV7', 'BP_SaveRecordV7')


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
    out = ROOT / 'test-results/save-native-v7' / stamp
    out.mkdir(parents=True, exist_ok=False)
    asset_dir = kit / 'Content/Mods/PalWorkPrioritySaveV7'
    sources = [ROOT / f'unreal/PalWidgetGen/Private/BuildSaveV7Commandlet.{ext}' for ext in ('cpp', 'h')]
    generation_file = asset_dir / 'registry-generation.json'
    generator_hashes = {str(p): sha(p) for p in sources}

    def protected():
        files = set()
        for directory in (
            kit / 'Content/Mods/PalWorkPrioritySaveScratch',
            kit / 'Content/Mods/PalWorkPrioritySaveRegistry',
            kit / 'Content/Mods/PalWorkPrioritySaveRegistryV2',
            kit / 'Saved/Cooked/Windows/Pal/Content/Mods/PalWorkPrioritySaveScratch',
        ):
            if directory.exists():
                files.update(p for p in directory.rglob('*') if p.is_file())
        for directory in (ROOT / 'test-results').glob('save-scratch-*'):
            if directory.is_dir():
                files.update(p for p in directory.rglob('*') if p.is_file())
        for name in ('save-registry-v1', 'save-registry-driver-v1', 'save-registry-v2'):
            directory = ROOT / 'test-results' / name
            if directory.exists():
                files.update(p for p in directory.rglob('*') if p.is_file())
        for directory in (ROOT / 'test-results/save-native-v7').iterdir():
            if directory.is_dir() and directory != out:
                files.update(p for p in directory.rglob('*') if p.is_file())
        for base in (ROOT / 'unreal/PalWidgetGen/Private', target):
            files.update(base / f'{name}.{ext}' for name in ('BuildSavePrototypeCommandlet', 'BuildSaveRegistryCommandlet', 'BuildSaveRegistryV2Commandlet') for ext in ('cpp', 'h'))
        files.update(ROOT / p for p in ('tools/build_save_scratch.py', 'tools/build_save_registry.py', 'tools/build_save_registry_v2.py',
                                      'experiments/ue4ss-save-registry/Scripts/main.lua', 'tests/test_save_registry_driver.lua'))
        return {str(p): sha(p) for p in sorted(files) if p.is_file()}

    before = protected()
    live_evidence = [p for p in (ROOT / 'test-results').glob('save-registry-live-*') if p.is_dir()]
    for directory in live_evidence:
        before.update({str(p): sha(p) for p in directory.rglob('*') if p.is_file()})
    (out / 'preserved-before.json').write_text(json.dumps(before, indent=2), encoding='utf-8')
    receipt = {'experimental': True, 'installed': False, 'disk_save_io': True, 'editor_native_receiver': True, 'shipping_ready': False, 'artifact_kind': 'editor-native-reference-proof', 'integrated_backend_pak': False, 'positive_absence': False, 'production_initialization': False, 'capacity': 32, 'container': 'Engine Blueprint map',
               'scope': 'Editor C++ immutable operation receiver and local gate integrated with guarded generated Engine registry; real async dev-slot save/readback only. No Engine Blueprint receiver, shipping integration, trusted active identity, positive absence, first initialization, external writer exclusion or durability proof',
               'sources': {str(p): sha(p) for p in (*sources, Path(__file__).resolve())}, 'steps': {}}

    def run(name, command, markers=()):
        log = out / f'{name}.log'
        with (out / f'{name}.stdout.log').open('w', encoding='utf-8') as stream:
            result = subprocess.run([str(x) for x in command], stdout=stream, stderr=subprocess.STDOUT, timeout=180)
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
        nonce_generate, nonce_reload = uuid.uuid4().hex, uuid.uuid4().hex
        receipt['dev_slot_authorization'] = {'basis': 'User-authorized synthetic owned editor fixture; NOT absence-based initialization',
            'nonce_generate': nonce_generate, 'nonce_reload': nonce_reload,
            'slots': [f'PWP_V7Dev_{nonce}_{side}' for nonce in (nonce_generate, nonce_reload) for side in ('A', 'B')]}
        markers = [name + ' pass=1' for name in (
            'reserve_local_registry_nested_atomicity', 'actual_write_exact_readback',
            'registry_busy_through_readback', 'registry_receiver_proxy_retained_gc',
            'stale_previous_holder_callbacks_preserve_successor',
            'same_holder_stale_callbacks_and_ack_preserve_pending',
            'ack_retry_preserves_new_terminal_bounded_tombstone',
            'actual_null_save_inline_failure_retained', 'null_load_unreadable_no_initialization',
            'exact_native_dispatch_counts_no_rejected_io', 'integrated_registry_32_retained_33_refused')]
        markers.append('fixture_pass=1')
        run('generate' if not all(present) else 'verify', base + ['-run=BuildSaveV7',
            '-Generate' if not all(present) else '-Verify', f'-Nonce={nonce_generate}',
            f'-abslog={out / ("generate.log" if not all(present) else "verify.log")}'], markers)
        pristine = {str(p): sha(p) for p in assets}
        if not all(present):
            generation_file.write_text(json.dumps({'generator_sources': generator_hashes, 'source_assets': pristine}, indent=2), encoding='utf-8')
        run('reload', base + ['-run=BuildSaveV7', '-Verify', f'-Nonce={nonce_reload}', f'-abslog={out / "reload.log"}'], markers)
        if pristine != {str(p): sha(p) for p in assets}:
            raise RuntimeError('Reload unexpectedly modified persisted registry defaults')
        slot_files = [kit / 'Saved/SaveGames' / f'{slot}.sav' for slot in receipt['dev_slot_authorization']['slots']]
        if not all(p.is_file() and p.stat().st_size for p in slot_files):
            raise RuntimeError('Owned dev slots not found at observed editor Saved/SaveGames path')
        written_slots = {str(p): sha(p) for p in slot_files}
        run('restart-readonly', base + ['-run=BuildSaveV7', '-ReadOnly', f'-Nonce={nonce_reload}',
            f'-abslog={out / "restart-readonly.log"}'], ['fresh_process_readonly_A pass=1',
            'fresh_process_readonly_B pass=1', 'readonly_zero_write_dispatches pass=1', 'readonly_pass=1'])
        if written_slots != {str(p): sha(p) for p in slot_files}:
            raise RuntimeError('Read-only restart changed owned slot bytes')
        receipt['owned_slot_hashes'] = written_slots
        receipt['readonly_restart_unchanged'] = True
        packages = '+'.join(f'/Game/Mods/PalWorkPrioritySaveV7/{name}' for name in NAMES)
        run('cook', base + ['-run=Cook', '-TargetPlatform=Windows', f'-Package={packages}',
                           f'-OutputDir={out / "Cooked/[Platform]"}', '-SkipCookingEditorContent', f'-abslog={out / "cook.log"}'])
        cooked = out / 'Cooked/Windows/Pal/Content/Mods/PalWorkPrioritySaveV7'
        files = [cooked / f'{name}{ext}' for name in NAMES for ext in ('.uasset', '.uexp')]
        for path in files:
            if not path.is_file() or not path.stat().st_size:
                raise RuntimeError(f'Missing cooked output {path}')
            data = path.read_bytes()
            for encoding in ('ascii', 'utf-16-le'):
                if '/Script/PalWidgetGen'.encode(encoding) in data:
                    raise RuntimeError(f'Editor-module reference in cooked output {path}')
        receipt.update(source_assets=pristine, cooked_dependency_assets={str(p): sha(p) for p in files}, passed=True)
        receipt['prior_dependency_only_pak'] = {'path': str(ROOT / 'test-results/save-native-v7/20261004T001846055063Z/PalWorkPrioritySaveV7.pak'), 'installable_backend': False, 'note': 'Initial wrapper packaged dependency assets only before packaging was removed; original evidence retained unchanged.'}
        receipt['runtime_route'] = ('Not implemented: generate Engine UObject coordinator and per-request receiver Blueprints, '
            'capture identity once, bind async delegates to that receiver, hold registry/local guards through transitions, '
            'then repeat nested/stale/GC/ACK tests in editor and shipping. Alternative: separately shipped runtime native module. '
            'Cooked dependencies here contain neither coordinator nor receiver and are not a backend.')
    except Exception as exc:
        receipt.update(passed=False, error=str(exc))
        raise
    finally:
        after = {p: sha(Path(p)) if Path(p).is_file() else None for p in before}
        receipt['preserved_unchanged'] = before == after
        if before != after:
            receipt.update(passed=False, error='Protected scratch inputs/evidence changed during run')
        (out / 'receipt.json').write_text(json.dumps(receipt, indent=2), encoding='utf-8')
        print(f'Receipt: {out / "receipt.json"}', flush=True)
        if before != after:
            raise RuntimeError('Protected scratch inputs/evidence changed during run; inspect receipt')
    print(f'Editor-native reference proof only; no pak: {out}', flush=True)


if __name__ == '__main__':
    main()
