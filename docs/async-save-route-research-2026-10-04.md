---
date: 2026-10-04
tags: [async-save, native, research]
status: evidence
---
# Async saving: SDK access and alternative entry route

Related: [async-enablement-2026-10-04](async-enablement-2026-10-04.md) · [reference-persistence-2026-09-29](reference-persistence-2026-09-29.md) · [save-initialization-review-2026-10-04](save-initialization-review-2026-10-04.md)

Research and live checkpoints, October 4. No reference mod executed or production
save changes. Our separate constant-entry DLL passed two launches, as recorded
below. Asynchronous production saves remain off.

## What changed

The private SDK blocks our proposed **CppUserModBase** integration, not every
native integration. UE4SS documents loading Lua C libraries from a mod's Scripts
directory. A minimal module can include the pinned public LuaMadeSimple headers
without including CppUserModBase or private Unreal headers.

`experiments/native-lua-entry-probe/entry.cpp` now compiles and links. It borrows
the passed Lua state through the exact public wrapper, pushes the integer 2281,
and returns. It does no IO, threads, callbacks or UObject access. Source confirms
the wrapper destructor does not close the borrowed state.

`check_link.py` verifies the installed runtime hash, compiles against untouched
revision 2281fa311e417b1dfddedbcd49972d764fddb244 headers, and matches the three
compiler-generated import names against the installed DLL's export table. It
generates a narrow import library from those names and links the probe. This is
normal linking metadata, not reconstructed declarations or address-based calls.
There is no second Lua runtime and no plain Lua C-API import.

Evidence: `test-results/native-lua-entry-probe-20261004/receipt.json`,
`imports.txt`, `compile.log`, `link.log`. Independent read-only review confirmed
the compiled DLL, import surface and source behavior. **Compile/link only**:
the wrapper contains STL members, so layout/compiler/runtime compatibility and
actual loader behavior remain gates. Matching symbol names alone do not prove
ABI compatibility. No callback registration or worker implementation is tested.

Compiler compatibility is a configuration/toolchain question, not a demand for
an identical patch number in every case. Microsoft's supported MSVC compatibility
rules require an appropriately recent linker/runtime; the local 14.50 toolchain
and installed DLL's 14.51 PE linker marker require investigation before a load.
The successful minimal link does not settle that rule or STL layout settings.
[Microsoft compatibility rules](https://learn.microsoft.com/en-us/cpp/porting/binary-compat-2015-2017?view=msvc-170).

Primary sources:
- [Documented Lua C-library loading](https://docs.ue4ss.com/guides/creating-a-lua-mod.html#using-lua-c-libraries)
- [Exact public wrapper declaration](https://github.com/UE4SS-RE/RE-UE4SS/blob/2281fa311e417b1dfddedbcd49972d764fddb244/deps/first/LuaMadeSimple/include/LuaMadeSimple/LuaMadeSimple.hpp)
- [Exact wrapper implementation](https://github.com/UE4SS-RE/RE-UE4SS/blob/2281fa311e417b1dfddedbcd49972d764fddb244/deps/first/LuaMadeSimple/src/LuaMadeSimple.cpp)

## Supported access route remains available

The full C++ guide requires an Epic-linked GitHub account with its organization
invitation accepted. Epic documents linking under Apps & Accounts, authorizing
the integration and accepting the invitation. No account authorization or license
acceptance was performed in this research. No private mirrors were pursued.
With authorized access, obtain the pinned UEPseudo commit, not a moving branch.

- [UE4SS C++ guide](https://docs.ue4ss.com/guides/creating-a-c%2B%2B-mod.html)
- [Epic's account-linking instructions](https://www.unrealengine.com/ue-on-github?lang=en-US)
- [Upstream UEPseudo access discussion](https://github.com/UE4SS-RE/RE-UE4SS/discussions/1267)

## ExecuteAsync: corrected evidence boundary

Previously missing Lua implementations are now available in the pinned source.
`LuaRaw/src/luauser.c` implements a global critical section; `luaconf.h` installs
its lock/unlock macros. `ldo.c:528` releases the lock before invoking a C function
and reacquires it afterward. Therefore it is **incorrect to assume the Lua lock
necessarily stays held throughout C file IO**. `LuaMadeSimple::new_thread` uses
`lua_newthread`, so the async coroutine still shares globals and heap. Lua work
contends, shared file handles/multi-step state changes remain unsafe without an
ownership protocol, and Unreal operations must stay on the appropriate thread.

The async loop genuinely invokes callbacks on its worker. Shutdown joins that
worker, so a blocked write can delay unload. This supports a bounded experiment
with immutable bytes and worker-owned IO, not an automatic production wrapper.
The documented game-thread delayed replacement for deprecated ExecuteAsync
would not move blocking IO off the game thread.

- [Pinned native Lua lock](https://github.com/UE4SS-RE/RE-UE4SS/blob/2281fa311e417b1dfddedbcd49972d764fddb244/deps/first/LuaRaw/src/luauser.c)
- [Pinned C-call lock boundary](https://github.com/UE4SS-RE/RE-UE4SS/blob/2281fa311e417b1dfddedbcd49972d764fddb244/deps/first/LuaRaw/src/ldo.c#L528)
- [Pinned async dispatch](https://github.com/UE4SS-RE/RE-UE4SS/blob/2281fa311e417b1dfddedbcd49972d764fddb244/UE4SS/src/Mod/LuaMod.cpp#L7218)

## Reference mods inspected

The earlier `docs/reference-persistence-2026-09-29.md` still applies to its
specific local copies: PalPriority batches synchronous game-thread saves;
CreativeMenu's inspected assets reference synchronous SaveGameToSlot. Neither
establishes a background writer. A fresh local Workshop Lua/C++ search found
ExecuteAsync in Auto Hatch's initialization and our own clock, not a new writer.

New read-only source checkouts live under
`test-results/reference-async-research-20261004/`. They were not executed.

### PalLLM: actual background persistence in a companion process

Pinned revision f2cfcba91572f372553c4a62369187c89d91d860. A registered background
service invokes a checked temporary-write/replacement writer in the sidecar.
Useful ideas are dirty-version tracking, serialized IO and backup retention.
It saves conversation/relationship data, not priorities. Its Lua file bridge
still writes synchronously; copying that bridge would retain an IO boundary on
the game side. Snapshot capture precedes the IO lock, so serialized file access
alone is not proof of concurrent generation ordering.

- [Worker](https://github.com/mzzmuaa/PalLLM/blob/f2cfcba91572f372553c4a62369187c89d91d860/src/PalLLM.Sidecar/SessionAutosaveWorker.cs#L14-L79)
- [Writer](https://github.com/mzzmuaa/PalLLM/blob/f2cfcba91572f372553c4a62369187c89d91d860/src/PalLLM.Domain/Runtime/SessionPersistence.cs#L73-L138)
- [Lua file bridge](https://github.com/mzzmuaa/PalLLM/blob/f2cfcba91572f372553c4a62369187c89d91d860/mod/ue4ss/Mods/PalLLM/Scripts/main.lua#L318-L337)

### PalMiniMap V2: delayed, but still synchronous

Pinned revision 5245b515150966f83bdc7a54fd797dc1e8ea5ca1. LoopAsync schedules
ExecuteInGameThread(pump); pump flushes config synchronously. The initial save
deadline is not repeatedly postponed by edits, a useful coalescing property.
Clearing pending state before verified success and deleting the primary before
rename are not appropriate to copy into our reliability writer.

- [Dispatch](https://github.com/jeankassio/PalMiniMap/blob/5245b515150966f83bdc7a54fd797dc1e8ea5ca1/PalMiniMap_V2/Scripts/guard.lua#L119-L130)
- [Writer](https://github.com/jeankassio/PalMiniMap/blob/5245b515150966f83bdc7a54fd797dc1e8ea5ca1/PalMiniMap_V2/Scripts/config.lua#L317-L345)

### Half Sword Enhancer: actual in-process background settings writer

The experimental release points to 1d650967feb61a4c98526884b9d7730c519e40de.
Its native worker wakes every 500 ms and flushes settings directly, outside the
game-thread dispatcher. This is the closest concrete reference found. Shutdown
signals/wakes/joins the worker and attempts final saves; stalled IO can delay it.
[Worker/lifecycle](https://github.com/lambor590/Half-Sword-Enhancer/blob/1d650967feb61a4c98526884b9d7730c519e40de/Mod/src/Core/ModRuntimeLifecycle.cpp#L130-L181).

Config changes carry a revision. Flush serializes writers, copies serialized
state under a separate state lock, releases that lock for disk IO, and clears
dirty only when the completed revision still matches. Failed writes stay dirty.
Those ownership/revision ideas fit our design. Its temporary-file replacement
has no backup generation, checksum/readback or explicit FlushFileBuffers in this
path, so it is not a substitute for our recovery requirements.
[Writer](https://github.com/lambor590/Half-Sword-Enhancer/blob/1d650967feb61a4c98526884b9d7730c519e40de/Mod/src/ConfigManager.cpp#L37-L88).

Its tiny Windows-only UE4SS bridge returns null from start_mod after starting a
separate DLL; that DLL uses a generated Half Sword SDK. This shows another
architecture, not a proven Palworld-compatible loader. The bridge frees its DLL
after a void shutdown call, with no success acknowledgement; do not copy that
unload boundary. Our Lua entry has a clearer direct scalar handoff candidate.
[Bridge](https://github.com/lambor590/Half-Sword-Enhancer/blob/1d650967feb61a4c98526884b9d7730c519e40de/UE4SSBridge/src/DllMain.cpp).
Treat it as a design reference, not freely reusable source; its license has
redistribution restrictions. No reference implementation was copied or executed.
[License](https://github.com/lambor590/Half-Sword-Enhancer/blob/1d650967feb61a4c98526884b9d7730c519e40de/LICENSE).

The bounded search found real examples; it does not establish that no other
implementation exists or that these implementations satisfy our test gates.

## Next gate

### Live checkpoint: first native entry launch, 10:39 UTC

The constant-only Lua library is now installed as the separate, one-shot
`PWPEntryProbe` diagnostic. On UE4SS 2281fa31 it returned exactly the integer
2281 in 1,000 direct calls, followed by successful garbage collection and
ordinary Lua execution. The game then loaded the world; the Monitoring Stand
displayed priority numbers and status reported authority plus saved priorities
and limits. Production Scripts match their pre-install hashes. No background
worker or save path was connected; production async remains disabled.

The compiler/headers/libraries are coherent MSVC 14.50 release `/MD` inputs,
linked with an official portable Microsoft 14.51 linker. Actual loaded CRT
libraries are System32 version 14.51.36247.0. This is a bounded test of the three
imported LuaMadeSimple operations, not proof of the entire C++ ABI surface.

Evidence: `test-results/native-lua-entry-live-20261004/first-launch-receipt.json`,
`first-launch-entry.log`, `first-launch-priority.log`, `loaded-modules.json` and
`installation.json`. The earlier build-only receipt intentionally remains a
record of its pre-install phase.

Clean shutdown/restart and same-process reload remain untested at this checkpoint.
A Windows Security prompt for Python blocks further UI automation until the
user handles it. The diagnostic disarmed itself before loading; it will not
repeat automatically on another launch.

Prefer the small public-header Lua entry experiment before requiring a full
CppUserModBase build: verify ABI settings and controlled constant-return load,
then state usability/reload/lifetime, then scalar submit/poll and a bounded
native worker. No game pointers, Lua references or callbacks cross to the worker.
Retain the existing identity, generation, ownership and durability requirements.
Our standalone native file-publication tests remain reusable whichever entry
route succeeds. Native entry feasibility does not establish active storage,
first initialization, migration, durable acknowledgements or runtime performance.

### Clean-restart checkpoint: 10:46–10:48 UTC

After the user dismissed the Windows prompt, the existing stand macro saved and
quit normally. PID 13192 exited at 12:46:49 local; fresh PID 35736 loaded the
same probe and passed another 1,000 exact-return calls plus Lua/GC checks. The
stand reopened with numbers visible. Status reported saved priorities and limits,
authority yes, and two camps. The deployed production Scripts still match the
pre-install hashes; the captured second-session priority log contains no WARN or
ERROR lines. One probe DLL instance appears in the loaded-module snapshot.

Evidence: `second-launch-receipt.json`, `second-launch-entry.log`,
`second-launch-macro.log`, `second-launch-priority.log` and
`second-loaded-modules.json` in the live evidence directory above.
The diagnostic remains disarmed and its enabled marker was renamed to
`enabled.completed`; the currently loaded library is left for normal teardown.
This proves one normal shutdown and two successful process launches, not
same-process reload, duplicate-path isolation, worker lifetime or file durability.

The next isolated experiment will call a bounded native byte-copy/checksum
operation through UE4SS's own ExecuteAsync worker and verify delivery on the game
thread. It must demonstrate a game-thread heartbeat inside the native work
interval, distinct thread identities and exact copied-data results. No production
settings are inputs and no save destination is connected.
