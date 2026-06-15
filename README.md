# ReplicatedTable

ReplicatedTable is a small Roblox table replication helper. Services register
plain server-owned tables, mutate them over time, and clients receive compact
delta updates plus local change signals.

It is intentionally not a data store, validation layer, or player-data facade.
Your services still own state, rules, persistence, and gameplay events.

## Install

Copy `src` into your project as one ModuleScript named `ReplicatedTable`, or use
the included Rojo project:

```text
ReplicatedStorage
  ReplicatedTable
    DeltaCompress
    NamedSignal
```

With Wally, this release candidate is authored as:

```toml
ReplicatedTable = "cluelessdev/replicated-table@0.1.0-rc.1"
```

## Server Example

```lua
--!strict

const ReplicatedStorage = game:GetService("ReplicatedStorage")

const ReplicatedTable = require(ReplicatedStorage.ReplicatedTable)

type PlayerData = {
    chests: {
        ownedChests: { { kind: string, UID: string } },
    },
}

const playerData = ReplicatedTable.new<PlayerData>("PlayerData")

playerData.register(player, {
    chests = {
        ownedChests = {},
    },
})

playerData.update(player, "chests.ownedChests", function(ownedChests)
    table.insert(ownedChests, {
        kind = "Common",
        UID = "example",
    })
end)
```

## Client Example

```lua
--!strict

const Players = game:GetService("Players")
const ReplicatedStorage = game:GetService("ReplicatedStorage")

const ReplicatedTable = require(ReplicatedStorage.ReplicatedTable)

const localPlayer = Players.LocalPlayer
const playerData = ReplicatedTable.new<any>("PlayerData")

const chests = playerData.get(localPlayer, "chests.ownedChests")

playerData.changed(localPlayer, "chests.ownedChests"):Connect(function(newChests, oldChests)
    print("Chest list changed", newChests, oldChests)
end)
```

## API

### `ReplicatedTable.new<T>(streamId: string): Stream<T>`

Creates or returns a named stream. Every stream shares one `RemoteEvent` and one
`RemoteFunction`; `streamId` routes messages to the right local cache.

### `Stream.register(owner: Instance, data: T): T`

Server only. Registers authoritative data for an owner and sends a baseline diff
to current recipients.

### `Stream.unregister(owner: Instance)`

Server only. Clears authoritative data and sends a final nil delta to current
recipients.

### `Stream.set(owner: Instance, accessor: string, value: any): T`

Server only. Replaces one accessor path inside the owner table.

### `Stream.update(owner: Instance, accessor: string?, updater: (currentValue: any) -> any): T`

Server only. Mutates or replaces one accessor path. If `updater` returns `nil`,
ReplicatedTable assumes the callback mutated the current value in place.

### `Stream.modify(owner: Instance, data: T): T`

Server only. Replaces the whole registered table.

### `Stream.get(owner: Instance, accessor: string?): any?`

Shared. Reads server authoritative data on the server. On the client, reads the
local cache or yields once through `Get` to request an initial snapshot.

### `Stream.changed(owner: Instance, accessor: string?): NamedSignal`

Shared. Returns a local signal that fires with `(newValue, oldValue)` when the
root table or accessor changes.

## Data Shape

Replicated data must be compatible with Roblox remotes and DeltaCompress:
strings, numbers, booleans, plain arrays/dictionaries, Vector types, and CFrame.
Prefer stable ids over runtime `Instance` references inside replicated tables.

## Bundled Dependencies

- DeltaCompress by Micah/nezuo
- NamedSignal by Nowoshire

See `THIRD_PARTY_NOTICES.md` for license notices.
