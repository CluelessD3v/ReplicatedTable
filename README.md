# ReplicatedTable

ReplicatedTable is a small Roblox server-to-client table replication helper.

In plain terms: it is a wrapper around
[DeltaCompress](https://github.com/nezuo/delta-compress) with batteries included.
The server keeps normal Lua tables, mutates normal Lua tables, and the client
reads normal Lua tables. ReplicatedTable handles the annoying middle part:
diffing, buffering, remotes, initial sync, local cache updates, and change
signals.

It exists for people who want their game code to keep speaking in tables instead
of passing compressed buffers around.

ReplicatedTable is intentionally not:

- a DataStore wrapper
- a validation layer
- a player-data framework
- a replacement for gameplay events

It does not save data or validate gameplay rules. ReplicatedTable only mirrors
selected tables from the server to allowed clients.

## Why Not Just DeltaCompress?

You absolutely can use DeltaCompress directly. That is a perfectly good choice.

DeltaCompress gives you the core primitive:

```lua
local data = {
    coins = 320,
    completedTutorial = true,
}

local diff, old = DeltaCompress.diffMutable(nil, data)

data.coins += 100

local diff, updatedOld = DeltaCompress.diffMutable(old, data)
```

That is clean and powerful. The downside is that every feature has to decide how
to store previous snapshots, when to create remotes, how to request initial state,
how to apply incoming buffers on the client, and how to notify UI that one nested
path changed.

ReplicatedTable wraps that repeated work so your code can stay closer to:

```lua
playerData.update(player, "chests.unopened", function(unopened)
    table.insert(unopened, chest)
end)
```

Under the hood, ReplicatedTable still uses DeltaCompress. It just keeps the
buffers at the transport boundary instead of forcing the rest of your game to
care about them.

## Install

Copy `src` into your project as one ModuleScript named `ReplicatedTable`:

```text
ReplicatedStorage
  ReplicatedTable
    DeltaCompress
    NamedSignal
```

Or use the included Rojo project.

With Wally, this release candidate is authored as:

```toml
ReplicatedTable = "cluelessdev/replicated-table@0.1.0-rc.1"
```

## Example Usage: Player Chests

Imagine your player earns unopened chests by doing anything in your game:
cutting trees, clearing an area, finishing a quest, opening a reward node, or
whatever else fits your loop.

The goal is simple: the server adds a chest to a table, and the client UI updates
from that same table shape.

When the player earns a chest, you want this flow:

1. Server adds `{ kind = "Common", UID = "..." }` to the player's data table.
2. ReplicatedTable sends only the delta to that player.
3. Client receives the delta and updates its local table cache.
4. The chest UI rerenders from a normal Lua table.

There are two common ways to organize the code.

### Option A: Shared Replicas Module

This is useful when multiple scripts need the same replicated table. Create it
once in a shared module and require that module from both the server and the
client.

```lua
-- ReplicatedStorage/Replicas.luau
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ReplicatedTable = require(ReplicatedStorage.ReplicatedTable)

export type Chest = {
    kind: string,
    UID: string,
}

export type PlayerData = {
    chests: {
        unopened: { Chest },
    },
}

local Replicas = {
    playerData = ReplicatedTable.new<PlayerData>("PlayerData"),
}

return Replicas
```

Server registration can happen when the player enters:

```lua
-- ServerScriptService/PlayersHandler.server.luau
--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Replicas = require(ReplicatedStorage.Replicas)

Players.PlayerAdded:Connect(function(player)
    Replicas.playerData.register(player, {
        chests = {
            unopened = {},
        },
    })
end)

Players.PlayerRemoving:Connect(function(player)
    Replicas.playerData.unregister(player)
end)
```

Any server script can add a chest:

```lua
-- Server-side give chest snippet
--!strict

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Replicas = require(ReplicatedStorage.Replicas)

local function giveChest(player: Player, kind: string)
    local chest = {
        kind = kind,
        UID = HttpService:GenerateGUID(false),
    }

    Replicas.playerData.update(player, "chests.unopened", function(unopened)
        table.insert(unopened, chest)
    end)

    return chest
end
```

The client UI reads and observes normal tables:

```lua
-- Client-side UnopenedChestsView snippet
--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Replicas = require(ReplicatedStorage.Replicas)

local localPlayer = Players.LocalPlayer

local function renderChests(chests)
    for _, chest in chests do
        print(chest.kind, chest.UID)
    end
end

local initialChests = Replicas.playerData.get(localPlayer, "chests.unopened") or {}
renderChests(initialChests)

Replicas.playerData.changed(localPlayer, "chests.unopened"):Connect(function(newChests, oldChests)
    renderChests(newChests or {})
end)
```

### Option B: Direct ReplicatedTable Creation

You can also create the same named ReplicatedTable handle in separate server and
client files. This is fine for small projects or isolated tests.

The important part is that the name matches.

```lua
-- Server
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ReplicatedTable = require(ReplicatedStorage.ReplicatedTable)

type PlayerData = {
    chests: {
        unopened: { { kind: string, UID: string } },
    },
}

local playerData = ReplicatedTable.new<PlayerData>("PlayerData")

playerData.register(player, {
    chests = {
        unopened = {},
    },
})

playerData.update(player, "chests.unopened", function(unopened)
    table.insert(unopened, {
        kind = "Common",
        UID = "example-uid",
    })
end)
```

```lua
-- Client
--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ReplicatedTable = require(ReplicatedStorage.ReplicatedTable)

local localPlayer = Players.LocalPlayer
local playerData = ReplicatedTable.new<any>("PlayerData")

local chests = playerData.get(localPlayer, "chests.unopened") or {}

playerData.changed(localPlayer, "chests.unopened"):Connect(function(newChests, oldChests)
    print("Chest list changed", newChests, oldChests)
end)
```

Both files call `ReplicatedTable.new("PlayerData")`, but they are not creating
two network systems. The server handle owns authoritative data. The client
handle owns mirrored data and local signals.

## API

### API Overview: Tables And Streams

A stream is a named route for one replicated data shape.

For example, `"PlayerData"` can be one stream. Each player is an owner inside
that stream, and each owner has one root table:

```lua
{
    chests = {
        unopened = {},
    },
    coins = 0,
}
```

The stream is not the table itself. It is the utility that manages the server's
authoritative table, the client's mirrored table, and the delta messages between
them.

That naming is deliberate: a table is the data; a stream is the flow of updates
for that data.

### `ReplicatedTable.new<T>(streamId: string): Stream<T>`

Creates or returns a named stream.

Use one stable id per replicated data shape:

```lua
local playerData = ReplicatedTable.new<PlayerData>("PlayerData")
local worldState = ReplicatedTable.new<WorldState>("WorldState")
```

The stream id is included in every internal remote payload so all streams can
share one `RemoteEvent` and one `RemoteFunction`.

### `stream.setRecipients(resolver: (owner: Instance) -> { Player })`

Server only.

Controls which players can receive each owner's data. By default, if the owner
is a `Player`, only that player receives that owner's table.

Use this for shared state or spectator-style visibility:

```lua
worldState.setRecipients(function(owner)
    return Players:GetPlayers()
end)
```

### `stream.register(owner: Instance, data: T): T`

Server only.

Registers the authoritative root table for one owner and sends the first diff to
current recipients.

```lua
playerData.register(player, {
    coins = 0,
    chests = {
        unopened = {},
    },
})
```

Use this at player join, entity spawn, or whenever an owner lifecycle begins.

### `stream.unregister(owner: Instance)`

Server only.

Clears an owner from the stream and sends a final nil update to recipients.

```lua
Players.PlayerRemoving:Connect(function(player)
    playerData.unregister(player)
end)
```

Use this at player leave or entity despawn.

### `stream.get(owner: Instance, accessor: string?): any?`

Shared.

Reads the server's authoritative table on the server. Reads the client's mirrored
table on the client.

On the client, if the table is not cached yet, `get` invokes the server once and
yields until it receives the initial snapshot.

```lua
local root = playerData.get(player, nil)
local coins = playerData.get(player, "coins")
local unopened = playerData.get(player, "chests.unopened")
```

Accessors are dot paths. Numeric segments are treated as numbers, so
`"items.1.name"` reads `items[1].name`.

### `stream.changed(owner: Instance, accessor: string?): NamedSignal`

Shared.

Returns a local signal for the whole table or one accessor path. The signal fires
with `(newValue, oldValue)` when that value changes locally.

```lua
playerData.changed(player, "coins"):Connect(function(newCoins, oldCoins)
    print(`Coins changed from {oldCoins} to {newCoins}`)
end)
```

This is a local signal, not a separate remote. Server-side changes fire
server-side listeners immediately. Client-side listeners fire when a delta is
received and applied.

### `stream.set(owner: Instance, accessor: string, value: any): T`

Server only.

Replaces one accessor path.

```lua
playerData.set(player, "coins", 500)
playerData.set(player, "settings.musicEnabled", false)
```

Intermediate tables must already exist. ReplicatedTable does not create missing
paths for you.

### `stream.update(owner: Instance, accessor: string?, updater: (currentValue: any) -> any): T`

Server only.

Updates one accessor path. The callback can either mutate the current value in
place and return nil, or return a replacement value.

Mutate in place:

```lua
playerData.update(player, "chests.unopened", function(unopened)
    table.insert(unopened, chest)
end)
```

Return a replacement:

```lua
playerData.update(player, "coins", function(coins)
    return (coins or 0) + 100
end)
```

Update the root table by passing nil for the accessor:

```lua
playerData.update(player, nil, function(data)
    data.coins += 100
    data.lastReward = os.time()
end)
```

### `stream.modify(owner: Instance, data: T): T`

Server only.

Replaces the whole root table for a registered owner.

```lua
playerData.modify(player, loadedSaveData)
```

Use `modify` when the whole root table changes. Prefer `set` or `update` for
normal smaller changes.

## Data Shape

Replicated data must be compatible with Roblox remotes and DeltaCompress:

- strings
- numbers
- booleans
- plain arrays and dictionaries
- Roblox datatypes supported by DeltaCompress, such as vectors and CFrames

Use nil through `set`, `update`, or `unregister` when you want to clear a field
or owner. As usual in Lua tables, nil means absence rather than a stored value.

Prefer stable ids over runtime `Instance` references inside replicated tables.
Keep Instances as owners or deliberately registered runtime entities, not as
arbitrary values deep inside your data.

## Practical Notes

- Register data on the server before expecting client UI to read it.
- Keep gameplay events for actions, fanfare, and third-party reactions.
- Use ReplicatedTable for self-state hydration, such as UI reading the local
  player's chest list.
- Keep configs, validation, reward rolls, and persistence outside this module.
- Use one shared `Replicas` module when several systems need the same stream.

## Bundled Dependencies

- DeltaCompress by Micah/nezuo
- NamedSignal by Nowoshire

See `THIRD_PARTY_NOTICES.md` for license notices.
