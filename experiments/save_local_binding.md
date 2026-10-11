# Local mod-data binding API

Isolated, opt-in experiment. `save_local_binding.lua` performs no engine access,
filesystem IO, scheduling, installation, or production changes. The installed
native-journal probe is unchanged. This adapter does not use the older
`PWP-ACTIVE-STORAGE-1` proof or claim the physical location of the game's save.

## Construction contract

`Binding.new(options)` captures these values once; changing `options` afterward
cannot redirect it. All callbacks are trusted adapters, synchronous, non-yielding,
and serialized on the game thread. They must not retain engine wrappers.

| Field | Exact contract |
| --- | --- |
| `enabled` | Must be `true`; otherwise no callbacks run. |
| `namespace` | Trusted installation/profile label, 1–64 ASCII word/underscore/colon/hyphen characters. No path. |
| `boot` | Unique label per provider/process replacement, same grammar and bound. Incarnation is `boot:serial`. |
| `stream` | Exactly `priorities` or `limits`. |
| `rootcap` | Fixed native registry capability captured privately: positive Lua integer or restricted opaque label of at most 128 characters. Tables/userdata/paths are rejected. Native must validate it. Never returned in candidates or bindings. |
| `limit` | Optional lifetime candidate cap, integer 1–256; default 256. Exhaustion permanently closes the binder. |
| `get_epoch()` | Plain `{available=true, supported=true, epoch=positive_integer, token=function}`. Epoch <= 2147483647, monotonically increasing; token is the actual immutable lifecycle token, never a newly allocated proxy. |
| `read_evidence()` | Fresh flat `Pair.read` output, from fresh engine and GameplayStatics helpers in this callback. No renamed name-only World result or cached observation. |
| `read_authority(context)` | Fresh plain `{authority_status='read', authority=true, guild_status='format_valid', guild=<canonical nonzero GUID>, world_address, state_address, instance_address}`. All three addresses must match the supplied scalar context. This callback must resolve current guild/authority from that actual context; echoing addresses does not establish ownership. |
| `bind(rootcap, request)` | Native boundary described below. Return a positive Lua integer registry ID. No Boolean/string/table success forms. |
| `binding_kind` | Default `inert` preserves the original registry-only contract. Explicit `revocable-owner` permits the native owner claim described below. Unknown values disable binding. Captured at construction. |
| `discard(binding_id)` | Idempotently revoke Lua permission and retain responsibility for cleanup; return exactly `true`. With `revocable-owner`, use `lifetime.discard`, not native command 7 directly. Success acknowledges revocation, not completed native release. Failure/throw permanently closes this binder. |

The native request has exactly these fields:

```lua
{namespace=namespace, worldguid=guid, guild=guild, stream=stream,
 epoch=epoch, incarnation=boot .. ':' .. serial}
```

No root/path can be supplied through `sample`, `bind`, or `check`. Native must
validate the root capability, configured namespace association, request fields,
capacity, and binding ID lifetime. In default `inert` mode, `bind` only allocates
a registry entry, with no owner claim. In explicit `revocable-owner` mode it may
also claim exclusive native ownership of that exact scope/incarnation/epoch.
Neither mode permits journal file access, recovery, update admission, ticket
reservation or queued work during bind. Claiming ownership does not establish
authority, grant permission to submit, activate recovered settings or ACK edits.
The complete fresh postcheck still runs before the binder returns a grant.

This reconciles the earlier inert-only requirement with the actual bridge:
command 1 calls `JournalBackend::open`, validates the scope, generates an opaque
nonce and calls `SaveOwner::claim`. The claim creates a named Win32 mutex for
cross-process exclusion, pins the helper module and retains its state in a bounded
registry. This is **not merely a Lua/memory allocation**: it holds an OS resource
and excludes another owner until release or process exit. It does not access
journal files, recover payloads, reserve a ticket or start a worker. Commands 2/3
perform operation admission separately. Command 0 root configuration is separate
and must not be hidden inside the binder callback.

The `revocable-owner` bind adapter must register every returned native ID with
`save_binding_lifetime.track(id, original_context)` before returning it to the
binder. Keep the original scalar context and reserve tracking capacity before
allocation; never return an active ID after failed tracking. Use the already
configured root and validate its namespace association. Native bind rejection,
throw, lost return or failed tracking is not an authorization fallback or retry
opportunity. A claim whose ID is unknown remains held natively; do not guess an ID
or retire another owner to obtain a new one.

An integer's shape is not proof of native validity; authenticity is the injected
native callback's responsibility. IDs must not be reused in a way that revives
stale references. The current bridge burns at most 128 IDs per configuration;
coordinate that bound across binders (the generic binder's candidate limit is
not a native allocation budget).

After a successful postcheck, attach the settings session to the lifetime before
opening it. Its fresh `authorize` callback must combine `binder.check(id)` and
`lifetime.current(id, context)` with external authority checks; neither the owner
claim nor `lifetime.current` supplies fresh authority. On failed postcheck the
binder discards the already-tracked ID and returns no grant. Poll that discarded
ID to retire/release the unused claim. No session or recovery is needed first.

After session admission, the same discard immediately fences new edits,
activation and ACKs. Poll the captured old session until all accepted/coalesced
work and native completions drain, then issue native 7/8 through the lifetime.
Do not fresh-check the retired binder as a prerequisite for draining previously
accepted data. Old-context drain can reserve the coalesced tail; it cannot ACK
into a replacement world. A same-scope replacement remains excluded natively
until the old claim is definitely released. Native 7/8 themselves are not
retry-idempotent: the lifetime memoizes confirmed success and retains uncertain
outcomes without retry. There is no automatic retry after failed drain.

## Public methods and lifecycle wiring

* `sample()` returns a plain `status='candidate', authorized=false` record with
  namespace/storage/guild/stream/epoch/incarnation, and no native ID. Only that
  exact returned table is accepted once by `bind`; its mutable fields are never
  trusted. There is at most one pending candidate.
* `bind(candidate)` rechecks the complete scalar snapshot, calls native, then
  rechecks again. Only success returns `status='bound', authorized=true,
  binding=<integer>` plus copied identity fields. Failed postchecks discard the
  tracked binding/claim and return no ID. Duplicate or forged candidates cannot call
  native. At most one binding is retained.
* `check(binding_id)` performs another complete fresh read and returns
  `status='current', authorized=true, binding=id` only while it remains current.
  It does not itself authorize or execute a journal operation. A new `sample`
  while bound also checks freshness but returns `already_bound` without the ID.
* `revoke()` clears the candidate and discards the retained binding. Wire it to
  lifecycle invalidation and shutdown, on the game thread. It performs only the
  injected permission/lifetime discard, not file IO. Reentry poisons the outer operation and
  permanently closes the binder.

Use the tested lifecycle controller as the epoch source:

```lua
get_epoch = function()
    local s = lifecycle:status()
    local token = lifecycle:candidate()
    return {available=token ~= nil, supported=supported_local_route,
            epoch=s.epoch, token=token}
end
```

`supported_local_route` is an explicit integration policy, not something this
adapter infers from map names. On pre-transition invalidation, the lifecycle
controller fences its token before its observer; the observer can then call
`binder.revoke()`. Missing registration/late attachment/nested transitions yield
no candidate. Non-hook shutdown and unsupported routes also require explicit
revocation. Native operations must retire their own admission/owner state;
discarding a binding is not cancellation of an already-started write.

A detected gap or changed evidence quarantines the highest observed epoch.
Recovery needs a strictly newer epoch, normally the next transition or an explicit
`lifecycle:revoke()` followed by fresh verification. This includes transient
initialization/read failures; no same-epoch retry silently restores a grant.
Native bind throws/invalid replies are uncertain and permanently close the
binder without retry. An unknown native allocation must remain bounded with no
journal work admitted; an owner claim may remain held until process teardown.
Lua cannot discard an ID it never received.

Call `check(id)` immediately before native operation admission, without yielding;
the native admission API must use this registered fixed-root binding, not accept
an independent root path. Admission and completion also need the lifecycle token
fence. Never pass engine wrappers or Lua token functions to workers. Only bounded
scalar identity and the opaque ID cross the native boundary.

## Supported identity policy and limits

Require Pair agreement, role 3, dedicated=false, matching valid selected/world
GUID, loaded=true, and autosave empty or matching. Require separate fresh current
guild/authority evidence. Nil/unreadable roles, missing viewport, clients,
headless/dedicated contexts, new-world first entry without selected/loaded, and
unsupported lifecycle routes stay closed. A missing loaded flag does not imply
non-authority.

Persistent identity is `namespace / world GUID / guild GUID / stream`.
Epoch/incarnation separate sessions, not persistent files. Within one namespace,
same-GUID clones with the same guild deliberately share mod data. Distinct clones
requiring isolation must use separately configured namespaces/root capabilities.
Profile changes require explicit configuration; there is no automatic profile
detection or physical game-save path claim, and no ETW requirement. Native root
binding must enforce the namespace association; different caller labels alone
cannot separate records in the current namespace-free record format.

Tests compose the actual lifecycle controller and actual Pair collectors with
disposable engine mocks, and exercise the native boundary, stale epochs, context
changes, rejection, reentry, bounded capacity and wrapper collection. They do not
establish native root-capability implementation or additional live travel coverage.
The owner-mode regressions compose the actual binder and lifetime with a synthetic
exclusive owner boundary: precheck denial allocates nothing, changed/thrown/reentrant
postchecks discard without IO, lost returns retain claims, and normal revocation
cannot release before an accepted coalesced tail drains. Native implementation
evidence above comes from source inspection, not a mocked claim of native execution.

Validation:
`python tools/test_lua.py tests/test_save_local_binding.lua tests/test_save_binding_lifetime.lua tests/test_save_lifecycle_epoch.lua tests/test_save_context_pair_probe.lua tests/test_save_active_provider.lua tests/test_save_authorization.lua`
