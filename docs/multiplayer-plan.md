# Running on a dedicated server

How Pal Work Priority becomes a mod a server owner and their players install
together, where everyone in a guild sees and edits the same rules.

Written after reading PalPriority's shipped source, which solves the same
problem and settles the questions that would otherwise have to be guessed at.

## What the reference already proves

PalPriority ships as **two mods**, not one:

    PalPriority       ue4ss/Mods/PalPriority/       server side, 1768 lines
    PalPriorityUI     ue4ss/Mods/PalPriorityUI/     client side, 1296 lines

That split is the whole answer. The scheduler needs authority, the interface
needs a screen, and a dedicated server has one and not the other.

### The transport

There is no custom networking. Two vanilla RPCs on
`PalNetworkBaseCampComponent` are repurposed, with the command carried in an
FName and a small number in the int32:

    -- client -> server
    comp:Request_Server_int32({ A=0, B=0, C=0, D=0 }, FName("PrioMod_Ping"), 1)

    -- server -> client, Client+Reliable, delivered to that player alone
    comp:Notify_RequestClient_int32({ A=0, B=0, C=0, D=0 }, FName(msg), 1)

Each side receives by hooking the same function it does not call:

    RegisterHook("/Script/Pal.PalNetworkBaseCampComponent:Request_Server_int32", ...)
    RegisterHook("/Script/Pal.PalNetworkBaseCampComponent:Notify_RequestClient_int32", ...)

The FName is the payload channel. PalPriority packs whole messages into it,
for example `PrioSync|<palkey>|<13 priority chars>`, and splits on the pipe.

Three constraints come with it, all learned the hard way by that mod and
worth taking on trust rather than rediscovering:

- **Never the Multicast variants.** An unmodded client must receive nothing.
- **Writes route per owner.** Each managed pal has to remember which player's
  component manages it, because guild-per-player servers silently reject a
  write sent through another player's component. Manager offline means the
  change waits rather than failing.
- **A custom message is an attestation.** Any `PrioMod_*` arriving proves that
  component belongs to a real modded player, so it becomes the push target and
  evicts anything found by a boot-time `FindFirstOf` whose writes no-op.

## Target shape

    PalWorkPriority          server: the decision and the writes
      config.lua               policy, read from disk on the server
      caps.txt                 the rules, owned by the server
      priorities.txt           per-pal priorities, owned by the server
      palapi, workdefs, demand, scheduler, store, caps, log
      net_server.lua           NEW: receive commands, push state

    PalWorkPriorityUI        client: the screens
      palapi (read-only parts), workdefs, log
      ui.lua                   the grid on the Monitoring Stand
      panel.lua                the rules panel
      items.lua                the item list for the picker
      net_client.lua           NEW: send commands, receive state

Nothing in `scheduler.lua`, `caps.lua`, `workdefs.lua` or `items.lua` changes.
They are already pure enough to move. The work is in what talks to them.

## Phase 0: prove the transport

**Nothing else is worth building until this passes.** Two throwaway mods, a
few dozen lines each: the client sends a ping every ten seconds, the server
logs it and replies, the client logs the reply.

Run it in all three places, because they fail differently:

| Where | What it proves |
| --- | --- |
| Single player | The hooks register and the calls execute locally |
| Listen server (host + friend) | The RPC crosses a real connection |
| Dedicated server | The only configuration that actually matters |

Gate: if `Request_Server_int32` does not cross on a real dedicated server, or
the server rejects it, every phase below is void and the answer is a
server-side mod with no interface at all.

## Phase 1: split Core and UI

Mechanical, and safe to do before Phase 0 pays off, because both halves still
work standalone in single player.

1. Core refuses to run a pass unless `api.has_authority()`. That check already
   exists and already gates the demand fallback.
2. UI never runs a pass, never writes a permission flag, never touches
   `caps.txt`. It renders what it is told and sends what was clicked.
3. Shared modules get copied into both packages. Two copies of `workdefs.lua`
   is worse than one, but a shared folder that only exists when both mods are
   installed is worse still.
4. `tools/deploy.ps1` learns to deploy both, and `tools/luacheck.py` runs over
   both trees.

At the end of this phase the mod behaves exactly as it does today in single
player, with the code in its final shape.

## Phase 2: authority-routed writes

The part that will silently do nothing if it is skipped.

- Hook `Request_Server_int32` on the Core. Every message received records
  `{ component, os.clock() }` against the component's full name.
- Expire entries past a TTL, and drop any whose component fails `alive()`.
- Each pal the mod manages records which component's attested click adopted
  it. Writes for that pal go through that component.
- No live owner means defer, log once, and try next pass. Never fall back to
  an arbitrary component: on a guild-per-player server that write is dropped
  on the floor and the mod looks broken.

## Phase 3: the sync protocol

Ours needs more than PalPriority's, because a rule names an item and an item
id is a long string. The FName carries it fine.

    client -> server
      PWP_Hello                                  announce, request everything
      PWP_Rule|<work>|<item>|<amount>            set, amount 0 clears
      PWP_Prio|<palkey>|<workvalue>|<prio>       set one cell, X sends 0

    server -> client
      PWP_Reset                                  clear, a full batch follows
      PWP_Rule|<work>|<item>|<amount>|<have>     one rule and current stock
      PWP_Prio|<palkey>|<13 chars>               that pal's whole row
      PWP_Drop|<palkey>                          pal released

`<have>` rides along because the panel shows `1964 / 5000` and the client
cannot read another base's chests. Sending it with the rule is one number
against a whole storage scan the client cannot do anyway.

On `PWP_Hello` the server sends `PWP_Reset` then the full state, so a client
that was away while a rule was deleted stops showing it.

## Phase 4: rules the guild shares

The actual goal, and it needs one data model change.

Rules today are global: `work -> item -> amount`, applied to every camp. On a
server that is wrong. Two guilds would fight over one wood ceiling.

**Key rules by base camp id.** A camp already belongs to a guild, so camp
scoping gives guild scoping for free with no guild lookup at all. It also
matches how ceilings are already measured, which is per camp.

    caps.txt   <campkey>|<work>|<item>|<amount>

The client only ever sees rules for camps it can see, which is the same set
its player can walk into. Edits are requests; the server decides and pushes
the result back, so two players editing at once converge rather than
diverging.

## Phase 5: packaging

Two Workshop items, following the reference:

- **Pal Work Priority** (Core). The server owner installs this. On its own it
  works headlessly from `config.lua`.
- **Pal Work Priority UI**. Every player installs this, including the host.

Single player needs both, which is worth saying plainly on both store pages
because it is the one thing people will get wrong.

`Info.json` gains a `Dependencies` entry on the UI side pointing at the Core's
`PackageName`, so Palworld's own loader enforces the pairing.

## Risks, in the order they are likely to bite

**The server may reject or throttle `Request_Server_int32`.** PalPriority
ships on it, which is strong evidence, but not evidence about your server's
configuration. Phase 0 answers this and nothing else does.

**FName churn.** Every distinct string becomes a permanent entry in the global
name table. Rule edits are rare and bounded; per-pal priority syncs are not,
so those should be batched per pal rather than sent per cell.

**Reentrancy on a listen server.** The Core's own write re-enters its own
toggle hook synchronously. PalPriority carries an explicit guard flag for
this. Ours will need the same.

**Version skew.** A Core and UI from different releases will disagree about
the protocol. Send a version in `PWP_Hello` and have the server say so once
rather than behaving strangely.

**Two mods, one folder.** Palworld's installer writes the Workshop copy over
`Scripts/`, which has already bitten this project once. Two packages doubles
the surface for that.

## What does not change

The crash rules stay exactly as they are: every game-object access wrapped,
every received object `alive()`-gated before a member call, never read a row's
`bindedSlot`, never trust a non-nil property read. Those are what keep this
mod from taking the game down, and networking makes them matter more rather
than less, because a hook now fires on messages from another machine.

`tools/luacheck.py` and the deploy refusing to ship a file that fails it stay
in place, across both packages.
