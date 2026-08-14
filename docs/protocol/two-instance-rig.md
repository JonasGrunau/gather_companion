# The two-instance rig

Runs extra GatherV2 desktop clients beside the primary one, each signed into a
different Google account, each with its own debug port. Two clients on one
machine means the protocol can be exercised from both ends without a second
person — which is what proximity, allow-lists and media plane work needs.

This is the apparatus. What it found is written up alongside it:
[`observed-wire-protocol.md`](./observed-wire-protocol.md) for message shape and
timing taken from real frames, and
[`client-action-surface.md`](./client-action-surface.md) for the full catalogue of
actions and endpoints with the server's verdict on each.

The scripts themselves live outside this repo, in `~/.gather-alt/`, because they
drive a third-party desktop app rather than build this one.

## Why a user-data-dir is enough

The app calls `app.requestSingleInstanceLock()`. Electron keeps that lock
*inside* the user-data-dir, as `SingletonLock`. So a separate `--user-data-dir`
gets a separate lock and the second instance starts normally — no patched asar,
no duplicated `.app` bundle. Everything that matters is scoped to that directory
too: cookies, Local Storage, and the `IndexedDB/https_app.v2.gather.town_0.…`
store where Firebase persists the signed-in user.

## Use

```sh
~/.gather-alt/gather-alt.sh start b      # launch instance "b" on port 9333
~/.gather-alt/gather-alt.sh status       # every instance, its port and pid
~/.gather-alt/gather-alt.sh targets b    # its CDP page targets
~/.gather-alt/gather-alt.sh stop b       # quit just that instance
~/.gather-alt/gather-alt.sh idb b        # its Firebase auth IndexedDB path
```

Names map to stable ports from the first letter — `b` is 9333, `c` is 9334. The
port is what every debugging tool attaches to, so it must not drift between
restarts. The primary keeps the default profile and port 9222 and is never
touched.

Sign in once per instance, in its own window. The session then persists in that
instance's own profile like any normal install.

## Reading the wire

```sh
node ~/.gather-alt/sniff.mjs 9333 25 --reload    # capture the full handshake
node ~/.gather-alt/cdp.mjs   9333 eval gather.town/app '<expression>'
```

`sniff.mjs` decodes binary frames with the bridge's own `msgpack.js`, so shapes
line up with what the bridge already understands. `--reload` matters: a socket
opened before you attach is reported without its URL, because CDP only names
sockets it saw being created. Reloading re-opens them under watch and is the
only way to catch the connection handshake.

Three sockets carry everything:

| Socket | Carries |
| --- | --- |
| `wss://game-router.v2.gather.town/gather-game-v2` | game plane, msgpack binary frames |
| `wss://router.v2.gather.town/socket.io/` | routing / signalling, text |
| `wss://sfu-v2.<region>.prod.aws.gather.town/…` | SFU media signalling, text |

Observed game-plane shapes, in connection order:

```
→ {type, credential}                     auth
→ {type, spaceId, connectionData}        join
← {type, warmInGatewayServer, warmInLogicServer}
← {type, fullStatePatches, actionReturns, events,
     optimisticAckTxnIds, chunkConfig, sequenceNumber}
→ {type, txnId, action, args}            client action
```

## Two things that are not isolated

**Logs.** Electron derives `app.getPath('logs')` from the app name, not the
user-data-dir, so every instance appends to `~/Library/Logs/GatherV2/main.log`
and the lines carry no pid. They interleave and cannot be told apart after the
fact. Use CDP per port instead — it is per-instance and exact.

**The `gather-desktop://` URL scheme.** Sign-in goes out to the system browser
via `shell.openExternal` and comes back through that scheme, which macOS routes
by bundle id. With two instances of the same bundle running, which one receives
the callback is not controllable. It does not matter once each instance is
signed in, since sessions persist. If a *fresh* sign-in ever misbehaves, quit
the other instances first so only the one being signed into is running.

## Adopting an instance's session

`desktopRefreshTokens(dir)` in the bridge already takes a directory, so it can
adopt this instance's identity rather than the primary's:

```js
import { desktopRefreshTokens } from '~/.gather-app-bridge/bridge/lib/gather-auth.js';
desktopRefreshTokens(
  `${process.env.HOME}/.gather-alt/profile-b/IndexedDB/https_app.v2.gather.town_0.indexeddb.leveldb`,
);
```

## Removing one

`gather-alt.sh stop b` then `rm -rf ~/.gather-alt/profile-b`. That deletes that
account's saved session and nothing else.
