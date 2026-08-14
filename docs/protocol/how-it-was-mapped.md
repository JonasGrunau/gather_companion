# How this was mapped

The method behind the other three documents in this directory: the rig, the
instruments, the order they were used in, what each one can and cannot prove,
and the dead ends — so the work can be resumed, re-run, or redone against a
newer app version without rediscovering any of it.

| Document | What it holds |
| --- | --- |
| [`two-instance-rig.md`](./two-instance-rig.md) | the apparatus — running isolated clients, why a user-data-dir is enough |
| [`observed-wire-protocol.md`](./observed-wire-protocol.md) | what two live clients actually said, from real frames |
| [`client-action-surface.md`](./client-action-surface.md) | the full catalogue — 261 actions, 243 endpoints, with the server's verdict |
| this file | how all of that was obtained |

Everything was done on 2026-08-14 against desktop client 0.48.4 (Electron 40.6.0,
Chromium 144) carrying web bundle 0.0.76 (commit `90c16e075`, built 2026-08-12).
The scripts live in `~/.gather-alt/`, outside this repo, because they drive a
third-party desktop app rather than build this one.

## The shape of the problem

Three different questions, and no single instrument answers more than one:

| Question | Instrument | Blind to |
| --- | --- | --- |
| What *does* the client say? | frame capture over CDP | everything the session never happened to do |
| What *can* the client say? | static extraction from the bundles | whether the server accepts any of it |
| What does the server *do* with it? | live invocation, both accounts | anything the client has no code to send |

Answering only the first is the trap, because a capture always looks complete
from the inside. The capture here ran 70 seconds and saw 8 distinct actions; the
bundles declare 277. Nothing in the capture hints at the other 269.

So the order matters: **enumerate statically first, then use traffic to confirm
shapes, then invoke to learn verdicts.** Static extraction is the only step that
yields a denominator, and without a denominator there is no way to say how much
of the surface any other method reached.

## Cold start

```sh
~/.gather-alt/gather-alt.sh status               # what is already up
~/.gather-alt/gather-alt.sh start b              # instance "b" on port 9333
~/.gather-alt/gather-alt.sh targets b            # confirm a gather.town/app page
node ~/.gather-alt/cdp.mjs 9333 eval gather.town/app 'gatherDev.Repos.gameSpace.currentSpaceUser.id'
```

The primary instance keeps the default profile and port 9222; instance `b` gets
`~/.gather-alt/profile-b` and port 9333. Ports derive from the instance name and
must not drift — every saved script attaches by port.

Two accounts were used, and the pairing is what makes permission comparison
possible at all:

| Instance | Port | Account | Role in space |
| --- | --- | --- | --- |
| A (primary) | 9222 | `grunaujonas@gmail.com` | Admin / space owner |
| B | 9333 | `grunauluca@gmail.com` | Member |

Both sat in space `bfe5d402-3a4c-4988-a3e8-b2a760371c14`, **a throwaway**. That
is a precondition, not a detail — see [Safety](#safety).

The last command above is the readiness check: if `gatherDev.Repos` resolves, the
client is signed in, joined, and every instrument below will work. `gatherDev`
is the app's own debug handle and exposes `Repos` (model instances) and `tsrAPI`
(the REST client).

## The instrument chain

### 1. Capture the wire

```sh
node ~/.gather-alt/record.mjs 9333 70 cap-9333.jsonl --reload   # to JSONL
node ~/.gather-alt/sniff.mjs  9333 25 --reload                  # live summary
```

Binary frames are msgpack and are decoded with the bridge's own `msgpack.js`, so
shapes line up with what the bridge already understands. Nothing is interpreted
at capture time — the raw JSONL stays re-analysable without re-running a session.

**`--reload` is not optional.** CDP only names sockets it watched being created,
so a socket opened before you attached is reported without its URL, and the
connection handshake is simply gone. Reloading re-opens all three under watch.

Run both instances' recorders concurrently to get both ends of the same events.

### 2. Apply a known stimulus

```sh
node ~/.gather-alt/drive.mjs 9333 20000    # four held arrow keys, 1.2 s each
```

A capture of ambient traffic tells you which fields *exist*. It does not tell you
which field carries a given meaning. Driving B's avatar with real
`Input.dispatchKeyEvent` presses at a known time turns the cross-client section of
`observed-wire-protocol.md` from a guess into a correlation: the cause was chosen
in advance, so anything that moved in A's stream at that moment is attributable.

### 3. Drive the UI — and record that it fails

```sh
node ~/.gather-alt/ui-map.mjs  9333 ui-clicks.json    # every visible control, menus 1 deep
node ~/.gather-alt/ui-deep.mjs 9333 ui-deep.json      # menus 2 deep + shortcuts + canvas right-click
```

Both correlate by time: the recorder timestamps frames, these timestamp clicks,
and the join happens afterwards.

**This was the plan, and it did not work.** About 95 interactions across both
accounts reached **9 of 261 actions — 3.4 %**. Of 45 controls clicked in the first
sweep, 4 produced any traffic at all; opening panels, switching tabs and toggling
mic and camera produced no game-plane action whatsoever, because most of the
interface is local MobX state.

The scripts are kept because the negative result is worth being able to reproduce,
and because the 9 actions they did reach are a useful cross-check on the
catalogue. But the UI is not a map of the protocol: coverage is bounded by the
account's permissions, by feature flags, and by whatever state the session
happens to be in — and from the outside you cannot tell which actions you failed
to reach.

### 4. Extract the surface statically

```sh
node ~/.gather-alt/surface.mjs        9333                 # measure, list chunks
node ~/.gather-alt/extract-actions.mjs <bundleDir>         # -> actions.json
node ~/.gather-alt/rest-contract.mjs  9333                 # -> rest.json
```

Three techniques, each worth keeping:

**Enumerate all chunks, not the loaded ones.** Only 40 of the app's 80 webpack
chunks load at startup, and the chunk containing the action definitions is lazy —
it was *not* among them. The full chunk map comes out of the webpack runtime:

```js
let req; webpackChunkgather_browser.push([[Symbol()], {}, (r) => { req = r; }]);
String(req.u)          // the chunk-id -> filename function; parse it for all 80
```

Then download the bundles directly with `curl --compressed`. (`Page.getResourceContent`
returned empty here — wrong frame association — and is not worth debugging.)

**Brace-match the declarations, don't regex them.** Every action is declared as

```js
name = (0, X.MethodAction)({ target: this, id: "move",
  requiredPermission: SpaceUserPermission.Move,
  argSchema: () => z.object({ direction: z.nativeEnum(MoveDirection) }), fn: … })
```

but property order is not fixed across declarations. A rigid regex assuming the
order above parsed **152 of 277**. Matching the balanced `{…}` and then scanning it
property by property parsed 277 of 277.

**Read the REST contract out of a closure.** The generated ts-rest client closes
over its contract rather than exposing it, so verbs and paths are read from the
function's `[[Scopes]]` via `Runtime.getProperties` — the same information a
debugger shows, without calling anything.

Note that the minified bundles are ~10 MB on a single line, where `grep` is
unreliable and slow; use Node and `indexOf` with a context window instead.

### 5. Sweep the actions, both accounts

```sh
node ~/.gather-alt/sweep-run.mjs 9333 actions.json sweep-member.json
node ~/.gather-alt/sweep-run.mjs 9222 actions.json sweep-admin.json
```

Model instances expose their actions as methods — `Repos.gameSpace.currentSpaceUser`
carries 123 of them — so an action can be invoked with no UI at all, and the
returned promise settles with the server's own verdict. See
[the zero-argument oracle](#the-zero-argument-oracle) for why every call is made
with no arguments.

Two design points that were learned the hard way and are now built in: results
accumulate on `window.__sweep` and are polled from outside, so a call that wedges
or disconnects the client cannot cost the results already collected; and actions
matching a destructive-name pattern are ordered **last**, so a self-inflicted
disconnect costs the least information.

Running the identical sweep on both ports is what produces the permission map.

### 6. Sweep the REST surface, both accounts

```sh
node ~/.gather-alt/rest-direct.mjs 9333 member rest-direct-member.json
node ~/.gather-alt/rest-direct.mjs 9222 admin  rest-direct-admin.json
```

This goes straight at the API with the account's own bearer token, pulled out of
the running client, substituting real ids for path params.

The first attempt drove the app's own ts-rest client instead, and was worthless:
the client refuses to build a URL without params, so **192 of 243 routes never
left the browser**, and because it throws rather than returning on non-2xx, 29
real server responses were misclassified as client errors.

The base URL is `https://api.v2.gather.town/api/v2`. The `/api/v2` prefix is
**not** part of the contract paths, and every one of 159 requests 404s without it —
which is exactly what the first full run produced.

### 7. Regenerate the document

```sh
node ~/.gather-alt/gendoc.mjs docs/protocol/client-action-surface.md
```

`gendoc.mjs` reads `actions.json`, `rest.json`, `models.json` and the four sweep
files and assembles the catalogue. It touches nothing on the network, so the
committed document is reproducible offline and byte-for-byte — verified.

## The zero-argument oracle

The single most useful technique here, and the reason the catalogue carries
verdicts rather than just declarations.

Call every action with **no arguments**. That splits the catalogue in two, and both
halves are informative:

- An action that **takes** arguments fails validation, and the error is a
  structured zod issue list that **enumerates the valid domain**:

  ```js
  await Repos.gameSpace.currentSpaceUser.faceDirection('Sideways');
  // MethodActionError: [{ received: "Sideways", code: "invalid_enum_value",
  //                       options: ["Up","Down","Left","Right"], … }]
  ```

  The complete `MoveDirection` enum, without reading a line of source.

- An action that takes **no** arguments has nothing to fail on, so it executes,
  and the result reports whether this account was permitted to run it.

Refusals come back in two flavours, both useful: permission denials name the
permission symbol, and business-rule refusals arrive as prose — *"Cannot wave at
yourself"*, *"Cannot reset a non-webhook-object MapObject"*, *"Deprecated Method
Action."* — documenting semantics no schema captures.

**Validation runs before the permission check.** `forceMute()` returned a schema
error, not a denial, even though the Member holds no force-mute permission. Two
consequences, and both bound what this method can establish:

1. Junk arguments are a **safe** way to harvest schemas — nothing executes.
2. Junk arguments are **useless** for probing permissions — the gate is never reached.

Which is why 110 Member actions came back `validation`: their permissions remain
untested, and closing that gap means synthesising valid arguments per action.

The corollary is the safety rule: because a zero-argument action *runs*, the
zero-argument subset must be classified before it is swept, never probed blindly.

## What the sweeps produced

| Outcome | Member | Admin |
| --- | --- | --- |
| `success` | 33 | 46 |
| `refused` | 57 | 59 |
| `validation` (needs args) | 110 | 87 |
| `error` | 3 | 2 |
| `no-method` / `no-target` | 74 | 83 |

REST, 159 of 243 sent (84 withheld by the safety rules):

| Status | Member | Admin |
| --- | --- | --- |
| 2xx | 19 | 33 |
| 400 | 94 | 94 |
| 401 | 1 | 1 |
| 403 | 38 | 24 |
| 404 | 7 | 7 |

The 403 difference is the privilege boundary: 14 routes the Admin reaches and the
Member does not, 19 both reach, 24 gated for everyone including the space owner.

The headline finding came out of comparing the two: `PerformSystemAction` refuses
54 actions **identically for both roles**, space owner included, so it is a
server-only capability rather than a role a user can hold. A single-account sweep
would have read that as "not admin enough" and been wrong.

## Dead ends

Recorded so nobody spends the time twice.

| Attempt | Outcome |
| --- | --- |
| Drive the UI to reach the action surface | 95 interactions → 9 of 261 (3.4 %); most of the UI is local state |
| Sweep REST through the app's ts-rest client | 192 of 243 blocked client-side; 29 responses misclassified as client errors |
| One regex per `MethodAction` declaration | 152 of 277 — property order is not fixed |
| `Page.getResourceContent` for bundle source | returned empty; fetch the URLs with `curl --compressed` instead |
| `grep` the minified bundles | unreliable on 10 MB single-line files; use Node `indexOf` |
| REST base without `/api/v2` | 404 on all 159 routes |
| `Object.keys(action)` to group results | `action` is a string; enumerated character indices |
| Tell instances apart in `main.log` | shared across instances, no pid in the lines — use CDP per port |

## Safety

The sweeps call the real service, and the action sweep executes every
zero-argument action, several of which delete things. Rules applied by
construction rather than by care:

- **Throwaway space only.** Space `bfe5d402-…` was confirmed disposable before the
  destructive sweep ran, and its map, settings and members are no longer
  meaningful. Do not run `sweep-run.mjs` anywhere else without asking first.
- **Destructive-last ordering** in the action sweep, with results polled out
  continuously, so damage cannot also cost data.
- **REST:** every GET is sent; a non-GET is sent only when its path is scoped to
  the throwaway space; a non-GET touching billing, orgs, users or admin is never
  sent. That withheld 84 routes, which the catalogue marks `skip` — untested, not
  unavailable.
- **Outward-facing routes were withheld by name**, not by pattern: support
  requests, OTP requests, logout, space creation, recording deletion, HubSpot
  writes, user deletion, org creation and AI job submission. Several of these
  send mail or touch third parties, where "it's only a test call" is not visible
  to the recipient.
- **UI sweeps** never click a control whose label matches a deny pattern
  (`leave|delete|remove|kick|sign out|…`).

## Knowing when the map is complete

Completeness is claimable only where it was measured:

- **Parse completeness.** 277 declarations parsed against 277 occurrences of
  `MethodAction)(` in the bundles — no occurrence went unparsed. This is the check
  that caught the 152-of-277 regex.
- **Chunk completeness.** All 80 chunks enumerated and downloaded, against the 40
  the running client had loaded.
- **Cross-check against traffic.** All 8 actions observed on the wire appear in the
  statically extracted catalogue. A wire action missing from the catalogue would
  mean the extraction had a hole.

Still unmapped, and stated so it is not mistaken for absence:

- Permissions for the 110 actions that need arguments — requires synthesising
  valid arguments per action.
- The 84 REST routes withheld by the safety rules.
- The media publish path: no media was published, so `producerIdMap` stayed `{}`
  and transport-create / produce never ran.
- Clustering: no conversation was joined, so `clusterId` stayed `undefined`.
- `chat`, `screenshare`, `follow` and `teleport` were never exercised.
- Anything the server implements that no client calls. Nothing here would show it.

## Resuming

State that survives on disk in `~/.gather-alt/`:

| | |
| --- | --- |
| `profile-b/` | instance B's Chromium profile; the Firebase session lives in its IndexedDB |
| `actions.json`, `rest.json`, `models.json` | the extracted surface — 277 / 243 / 149 |
| `sweep-{member,admin}.json` | action verdicts per account |
| `rest-direct-{member,admin}.json` | HTTP status per route per account |

To rebuild the document from that, with nothing running and no network:
`node ~/.gather-alt/gendoc.mjs <repo>/docs/protocol/client-action-surface.md`.

**After a Gather update**, the extraction is stale and the verdicts may be. Re-run
in this order — steps 4 and 7 are cheap and non-destructive; step 5 is not:

1. `gather-alt.sh start b`, confirm `gatherDev.Repos` resolves on both ports.
2. `surface.mjs` → new chunk list and counts. If the totals moved, the surface moved.
3. `extract-actions.mjs` + `rest-contract.mjs` → fresh `actions.json` / `rest.json`.
4. Diff against the committed catalogue — that diff alone answers "what changed".
5. Only if verdicts are needed: `sweep-run.mjs` and `rest-direct.mjs`, in a space
   you are willing to lose, on both accounts.
6. `gendoc.mjs`, and update `observed-wire-protocol.md` by hand if frame shapes changed.

Sign-in survives restarts, so step 1 is normally the whole setup. If a *fresh*
sign-in is ever needed, quit the other instances first: the `gather-desktop://`
OAuth callback is routed by bundle id and cannot be steered while two instances
of the same bundle are running.
