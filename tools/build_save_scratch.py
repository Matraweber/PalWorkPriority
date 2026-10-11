"""Build/verify/stage the isolated async-save experiment. Never installs it.

Requires the existing Pal editor kit and UE 5.1.1 toolchain. Generated assets
contain Engine classes only. All writes target the kit's dedicated scratch
asset directory, its PWP_SaveScratch_v1_A/B slots, or versioned test-results.
--v3 selects a separate bridge, cook directory and pak, preserving V2 evidence.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--engine', type=Path, default=os.environ.get('PWP_UE'))
    p.add_argument('--kit', type=Path, default=os.environ.get('PWP_MODDING_KIT'))
    p.add_argument('--skip-build', action='store_true', help='Use an already compiled commandlet')
    p.add_argument('--v3', action='store_true', help='Build the separate callable-completion V3 bridge')
    p.add_argument('--v4', action='store_true', help='Build rooted lifetime probe; NOT scoped production backend')
    p.add_argument('--v5', action='store_true', help='Build fixed-slot native ownership/mailbox probe; NOT production backend')
    p.add_argument('--v6', action='store_true', help='Build scoped storage and epoch handover probe; NOT production backend')
    args = p.parse_args()
    if not args.engine or not args.kit:
        p.error('Supply --engine and --kit (or PWP_UE/PWP_MODDING_KIT)')
    engine, kit = args.engine.resolve(), args.kit.resolve()
    project = kit / 'Pal.uproject'
    editor = engine / 'Engine/Binaries/Win64/UnrealEditor-Cmd.exe'
    unrealpak = engine / 'Engine/Binaries/Win64/UnrealPak.exe'
    for file in (project, editor, unrealpak):
        if not file.is_file(): raise RuntimeError(f'Missing tool/project: {file}')
    if sum((args.v3,args.v4,args.v5,args.v6)) > 1: p.error('Choose only one bridge version')
    events = args.v3 or args.v4 or args.v5 or args.v6
    lifetime = args.v4 or args.v5 or args.v6
    version = 'V6' if args.v6 else 'V5' if args.v5 else 'V4' if args.v4 else 'V3' if args.v3 else 'V2'
    bridge = f'BP_ScratchBridge{version}'
    out = ROOT / f'test-results/save-scratch-{version.lower()}'
    out.mkdir(parents=True, exist_ok=True)
    sha = lambda f: hashlib.sha256(f.read_bytes()).hexdigest()
    asset_dir = kit / 'Content/Mods/PalWorkPrioritySaveScratch'
    # V3 never rewrites existing record/V2 assets or the previous cooked output
    # and evidence. Check the complete V2 evidence directory, not just its pak.
    preserved = {}
    if events:
        candidates = [asset_dir / 'BP_ScratchRecord.uasset', asset_dir / 'BP_ScratchBridgeV2.uasset']
        if lifetime:
            candidates.append(asset_dir / 'BP_ScratchBridgeV3.uasset')
            candidates.extend(f for f in (ROOT / 'test-results/save-scratch-v3').rglob('*') if f.is_file())
        if args.v5 or args.v6:
            candidates.append(asset_dir / 'BP_ScratchBridgeV4.uasset')
            candidates.extend(f for f in (ROOT / 'test-results/save-scratch-v4').rglob('*') if f.is_file())
        if args.v6:
            candidates.append(asset_dir / 'BP_ScratchBridgeV5.uasset')
            candidates.extend(f for f in (ROOT / 'test-results/save-scratch-v5').rglob('*') if f.is_file())
        for directory in (ROOT / 'test-results/save-scratch-v2',
                          kit / 'Saved/Cooked/Windows/Pal/Content/Mods/PalWorkPrioritySaveScratch'):
            if directory.exists(): candidates.extend(f for f in directory.rglob('*') if f.is_file())
        preserved = {str(f): sha(f) for f in candidates if f.is_file()}
    def run(name, command, markers=()):
        with (out / f'{name}.stdout.log').open('w', encoding='utf-8') as stream:
            result = subprocess.run([str(x) for x in command], stdout=stream, stderr=subprocess.STDOUT)
        if result.returncode:
            raise RuntimeError(f'{name} failed: {result.returncode}; see {out}')
        log = out / f'{name}.log'
        text = log.read_text(encoding='utf-8-sig', errors='replace') if log.exists() else ''
        for marker in markers:
            if marker not in text: raise RuntimeError(f'{name}: missing evidence {marker}')
        print(f'PASS {name}', flush=True)
    if not args.skip_build:
        target = kit / 'Source/PalWidgetGen/Private'
        if not target.is_dir(): raise RuntimeError('PalWidgetGen must already be configured in the editor kit')
        for suffix in ('cpp', 'h'):
            source = ROOT / f'unreal/PalWidgetGen/Private/BuildSavePrototypeCommandlet.{suffix}'
            destination = target / source.name
            if not destination.exists() or destination.read_bytes() != source.read_bytes():
                shutil.copy2(source, destination)
        run('build', [engine / 'Engine/Build/BatchFiles/Build.bat', 'PalEditor', 'Win64',
                      'Development', project, '-CompilerVersion=14.38.33130', '-WaitMutex', '-NoHotReloadFromIDE'])
    mode = ['-Verify'] if (asset_dir / f'{bridge}.uasset').exists() else []
    selection = ['-V6'] if args.v6 else ['-V5'] if args.v5 else ['-V4'] if args.v4 else ['-V3'] if args.v3 else []
    base = [editor, project, '-unattended', '-nullrhi', '-nosplash']
    markers = ['blueprint_gc_busy_readback=1', 'blueprint_null_failure=1', 'blueprint_async_recovery=1', 'readback=1 fresh_process=0']
    if events:
        markers += ['V3 callable=1', 'V3 busy_rejection_no_completion=1',
                    'V3 completion_order=1 serial=1 count=1 generation=2 success=1',
                    'V3 completion_order=1 serial=2 count=2 generation=3 success=0',
                    'V3 completion_order=1 serial=3 count=3 generation=4 success=1',
                    'V3 exactly_once_accepted=1']
    if lifetime:
        markers += ['V4 rooted_teardown_pending=1', 'V4 teardown_completion=1',
                    'V4 old_world_and_instance_released=1', 'V4 readback_gc=1',
                    'V4 inline_failure_cleared_proxy=1']
    if args.v5:
        markers += ['V5 bind_and_invalid_admission=1', 'V5 retained_exact_idempotent_consume=1',
                    'V5 stale_ack_preserves_newer_result=1', 'V5 read_consume_and_pending_ack=1',
                    'V5 completion_reentry=1']
    if args.v6:
        markers = ['V6 canonical_scope_separation=1 slots=16', 'V6 drained_handover_and_epoch_fence=1 fresh_process=0',
                   'V6 retire_during_save_readback=1', 'V6 completion_reentry=1']
    run('verify', base + ['-run=BuildSavePrototype', *selection, *mode, f'-abslog={out / "verify.log"}'], markers)
    if events:
        # Verify the serialized UFunction in a fresh process, not only the
        # generated in-memory graph used by the first native probe.
        run('reload', base + ['-run=BuildSavePrototype', *selection, '-Verify', f'-abslog={out / "reload.log"}'], markers)
    run('restart', base + ['-run=BuildSavePrototype', *selection, '-ReadOnly', f'-abslog={out / "restart.log"}'],
        ['V6 canonical_scope_separation=1 slots=16', 'V6 drained_handover_and_epoch_fence=1 fresh_process=1']
        if args.v6 else ['fresh_process_blueprint_slot=1', 'readback=1 fresh_process=1'])
    cook_selection = [f'-CookDir={asset_dir}']
    cooked = kit / 'Saved/Cooked/Windows/Pal/Content/Mods/PalWorkPrioritySaveScratch'
    if events:
        cook_selection = [f'-Package=/Game/Mods/PalWorkPrioritySaveScratch/{bridge}+/Game/Mods/PalWorkPrioritySaveScratch/BP_ScratchRecord',
                          f'-OutputDir={out / "Cooked/[Platform]"}']
        cooked = out / 'Cooked/Windows/Pal/Content/Mods/PalWorkPrioritySaveScratch'
    run('cook', base + ['-run=Cook', '-TargetPlatform=Windows', *cook_selection,
                       '-SkipCookingEditorContent', f'-abslog={out / "cook.log"}'])
    files = []
    for asset in ('BP_ScratchRecord', bridge):
        for ext in ('.uasset', '.uexp'):
            source = cooked / (asset + ext)
            if not source.is_file() or not source.stat().st_size:
                raise RuntimeError(f'Missing cooked asset: {source}')
            files.append(source)
    response = out / 'scratch.response.txt'
    response.write_text('\n'.join(f'"{f}" "../../../Pal/Content/Mods/PalWorkPrioritySaveScratch/{f.name}"'
                                  for f in files) + '\n', encoding='utf-8')
    pak = out / f'PalWorkPrioritySaveScratch{version}.pak'
    run('pak', [unrealpak, pak, f'-Create={response}', '-compress'])
    run('pak-list', [unrealpak, pak, '-List'])
    listing = (out / 'pak-list.stdout.log').read_text(encoding='utf-8', errors='replace')
    if '4 files' not in listing: raise RuntimeError('Pak list must contain exactly four scratch files')
    for file, expected in preserved.items():
        if not Path(file).is_file() or sha(Path(file)) != expected:
            raise RuntimeError(f'Preserved V2 evidence changed: {file}')
    manifest = {'experimental': True, 'installed': False, 'platform': 'Windows',
                'version': version,
                'pak': str(pak), 'sha256': sha(pak),
                'files': [{'file': str(f), 'sha256': sha(f)} for f in files],
                'source_assets': [{'file': str(asset_dir / f'{asset}.uasset'),
                                   'sha256': sha(asset_dir / f'{asset}.uasset')}
                                  for asset in ('BP_ScratchRecord', bridge)],
                'generator_sources': [{'file': str(f), 'sha256': sha(f)} for f in
                                      [ROOT / 'unreal/PalWidgetGen/Private/BuildSavePrototypeCommandlet.cpp',
                                       ROOT / 'unreal/PalWidgetGen/Private/BuildSavePrototypeCommandlet.h', Path(__file__).resolve()]],
                'preserved_v2': preserved,
                'scope': 'Editor scratch fixture only; not RAM server performance or release acceptance'}
    if events:
        manifest['completion'] = {
            'path': f'/Game/Mods/PalWorkPrioritySaveScratch/{bridge}.{bridge}_C:ScratchCompleted',
            'signature': 'void ScratchCompleted()',
            'ordering': 'Completion fields, Done=true, Busy=false, increment CompletionSerial, call ScratchCompleted; body increments CompletionCount',
            'hook_pre': 'CompletionSerial and completed fields ready; CompletionCount still previous value',
            'hook_post': 'CompletionSerial == CompletionCount; observer snapshots updated',
        }
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    print(f'Staged only: {pak}', flush=True)


if __name__ == '__main__':
    main()
