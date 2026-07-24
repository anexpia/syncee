---
sidebar_position: 2
---

# Usage Guide

This covers the core APIs and features of **Syncee**.

---

## 1. Setup

Syncee requires a simple networking bridge between server and client using `RemoteEvent`s or whatever other way you have of transmitting data.

To set up replication:
* **Server**: Call [`Syncee.server.MarkPlayerLoaded`](../api/server#MarkPlayerLoaded) when a player is ready, and collect replication payloads via [`Syncee.server.GetDataToReplicate`](../api/server#GetDataToReplicate) in a loop (e.g. `RunService.Heartbeat`) then send each client's buffer to them.
* **Client**: Pass incoming buffers directly to [`Syncee.client.DataReceived`](../api/client#DataReceived).

### Server Setup Example
```lua
local Players = game:GetService("Players")
local RS = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Syncee = require(ReplicatedStorage.Packages.Syncee)
local SyncEvent = ReplicatedStorage:WaitForChild("SyncEvent")

Players.PlayerAdded:Connect(function(player)
    local playerData = Syncee.GetData(player)
    Syncee.server.Set(playerData, "Coins", 100)
    Syncee.server.Set(playerData, "Inventory", { "Sword", "Shield" })
end)

SyncEvent.OnServerEvent:Connect(function(player)
    -- mark player as loaded so Syncee replicates their root data table
    -- you should wait until the player's client has loaded first. Having the client signal this is the best way.
    Syncee.server.MarkPlayerLoaded(player)
end)

RS.Heartbeat:Connect(function()
    -- replicate changes to clients.
    local payloads = Syncee.server.GetDataToReplicate()
    for player, buff in payloads do SyncEvent:FireClient(player, buff) end
end)
```

### Client Setup Example
```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Syncee = require(ReplicatedStorage.Packages.Syncee)
local SyncEvent = ReplicatedStorage:WaitForChild("SyncEvent")

-- passing received buffer directly to DataReceived().
SyncEvent.OnClientEvent:Connect(Syncee.client.DataReceived)

task.spawn(function()
    local rootData = Syncee.client.AwaitDataAsync()
    print("Received initial player data:", rootData)
end)

SyncEvent:FireServer() -- marking to server that we are loaded.
```

---


## 2. Table Mutations

:::info Things to keep in mind
- Tables and buffers used as keys in a replicated table won't work properly. Syncee only handles values.
- Syncee does not modify original table in any way at all and it's not aware of changes you directly apply to the tables.\
    Which is why proxies or [`Syncee.server.Set`](../api/server#Set) should be used. Both are listed below.
:::

### Explicit Mutation ([`Syncee.server.Set`](../api/server#Set))

Assign values to table keys using [`Syncee.server.Set`](../api/server#Set). It updates the table, queues the key for replication, and fires connected change listeners.

```lua
Syncee.server.Set(playerData, "Coins", 500)
Syncee.server.Set(playerData, "Gems", 25)
```

You can also use [`Syncee.server.Replicate`](../api/server#Replicate) to force a table's key to be replicated even if it hasn't changed.

### Table Wrappers
Syncee provides wrappers for [`Syncee.server.Insert`](../api/server#Insert), [`Syncee.server.Remove`](../api/server#Remove), and [`Syncee.server.Clear`](../api/server#Clear) that automatically queue for replication.

```lua
local inventory = playerData.Items

Syncee.server.Insert(inventory, { Name = "Cat", Level = 1000 }) -- (table.insert)
local removedItem = Syncee.server.Remove(inventory, 1) -- (table.remove)
Syncee.server.Clear(inventory) -- (table.clear)
```

### Proxy Tables ([`Syncee.server.GetProxy`](../api/server#GetProxy))
Proxy tables wrap a target table so that any property assignment (`proxy.key = value`) automatically runs [`Syncee.server.Set`](../api/server#Set) for convenience.

```lua
local playerData = Syncee.GetData(player)
local proxy = Syncee.server.GetProxy(playerData)

-- assignments automatically queue for replication with proxies.
proxy.Coins += 50
proxy.Level = 10

-- returns original table linked to the proxy.
local rawTable = Syncee.server.ProxyToTable(proxy)
```

Proxies can be used in-place of the originals in any situation, and Syncee will treat it as the original table.

---

## 3. Registering Schemas
Syncee uses **[Squish](https://github.com/anexpia/squish)** for schemas. Defining schemas significantly reduces network bandwidth as it allows Syncee to serialize the tables in a more compact form.

By default, Syncee serializes everything in the table, however you can change it.
Ideally you should have only one copy of Squish existing in your project.

Schemas should be defined on both client and server for the client to be able to deserialize them.

You can structure your schemas in two ways:

#### Monolithic Schemas
Define a single schema with sub-schemas for all the nested tables. Syncee will automatically extract sub-schemas for tables & buffers, replace them with reference serdes, and automatically apply the sub-schemas for the nested tables.

```lua
local Syncee = require(path.to.syncee)
local Squish = require(path.to.squish)

Syncee.RegisterSchema("PlayerData", Squish.record({
    Coins = Squish.u32(),
    Gems = Squish.u16(),
    Items = Squish.array(Squish.record({
        Name = Squish.string(),
        Level = Squish.u16(),
    })),
    Settings = Squish.record({
        Sensitivity = Squish.f32(),
        Volume = Squish.f32(),
    })
}))
```

:::info
If a table already has an schema applied, either through [`SetSchema`](../api/server#SetSchema) or because it was nested in a monolithic schema, it will not apply again through this method even if the subschema should be different.
:::


#### Manual Schema Applying
Alternatively, you can register individual schemas for each table and use reference serdes (`Syncee.serdes.table` / `Syncee.serdes.buffer`) inside schemas, then manually call [`SetSchema`](../api/server#SetSchema) on each table.

```lua
local Syncee = require(path.to.syncee)
local Squish = require(path.to.squish)

local TableRef = Syncee.serdes.table

Syncee.RegisterSchema("Item", Squish.record({
    Name = Squish.string(),
    Level = Squish.u16(),
}))

Syncee.RegisterSchema("Settings", Squish.record({
    Sensitivity = Squish.f32(),
    Volume = Squish.f32(),
}))

Syncee.RegisterSchema("PlayerData", Squish.record({
    Coins = Squish.u32(),
    Gems = Squish.u16(),
    Items = TableRef,
    Settings = TableRef,
}))
```

:::info
Do note that while Syncee does use the schemas, it's not actually aware of how they're structured for performance reasons.\
So if there's something not serialized by the schema inside a table, Syncee will still process it as if it is replicated.
:::

### Binding Schemas to Tables
Bind registered schemas to each table instance on the server using [`Syncee.server.SetSchema`](../api/server#SetSchema):

```lua
local playerData = Syncee.GetData(player)
local settingsTable = { Sensitivity = 1.0, Volume = 0.8 }

-- If you used a monolithic schema, you only need to apply it once and all the subtables will be given the sub-schemas.
Syncee.server.SetSchema(playerData, "PlayerData")
Syncee.server.Set(playerData, "Settings", settingsTable)

-- Otherwise, you'll need to apply it to each table.
Syncee.server.SetSchema(settingsTable, "Settings")
```

---

## 4. Buffer Replication
As with tables, Syncee is unaware of changes on its own.\
Syncee supports delta replication by using the 2 following methods.

### Manual Region Replication ([`Syncee.server.ReplicateBufferRegion`](../api/server#ReplicateBufferRegion))
This is the ideal way to replicate regions, as you can define the length of the region.\
Regions are merged when they're overlapping or nearby when replicating.

```lua
buffer.writef32(buf, 0, v.X)
buffer.writef32(buf, 4, v.Y)
buffer.writef32(buf, 8, v.Z)
Syncee.server.ReplicateBufferRegion(buf, 0, 12) -- replicate region from 0 to 11
```

---

### Auto-Replicating Buffer Wrapper ([`Syncee.buffer`](../api/Syncee#buffer))
Syncee provides a wrapper for buffer library that automatically marks the written regions for replication for convenience.\
Ideally you should use [`Syncee.server.ReplicateBufferRegion`](../api/server#ReplicateBufferRegion) to reduce the number of regions to merge.

```lua
Syncee.buffer.writef32(buf, 0, 100)
Syncee.buffer.writef32(buf, 4, 100)
-- this will replicate regions from 0 to 3, 4 to 7
-- both regions will be merged later, though this can be avoided by using ReplicateBufferRegion().
```

## 5. Change Signals & Yielding

### Table Change Signal

```lua
local signal = Syncee.GetTableChangedSignal(playerData)

signal:Connect(function(t, key, newValue)
    print(`Property '{key}' updated to:`, newValue)
end)
```

### Buffer Change Signal
This doesn't provide the changed regions due to overhead of doing so. Behavior may change in the future.

```lua
local signal = Syncee.GetBufferChangedSignal(healthBuf)

signal:Connect(function(buf)
    local value = buffer.readf32(buf, 0)
    print("Buffer updated! Current value:", value)
end)
```

### Waiting for Values ([`Syncee.WaitForValue`](../api/Syncee#WaitForValue))
Yields current thread until the value of `key` in the table is non-nil.

```lua
local inventory = Syncee.WaitForValue(playerData, "Inventory", 5) -- timeout after 5s
if inventory then print("Inventory is ready!") end
```

---

## 6. Others

### Rate Limiting ([`Syncee.server.SetRatelimit`](../api/server#SetRatelimit))
```lua
Syncee.server.SetRatelimit(something, 0.1) -- ratelimited to update at least every 0.1 seconds.
```

### Persistence ([`Syncee.server.SetPersistent`](../api/server#SetPersistent))

Keep a table or buffer tracked in Syncee even when it has no active client recipients attached.
This is useful for tables or buffers you know will be replicated, so that you have a safety guarantee that Syncee's api wont error on it.
```lua
Syncee.server.SetPersistent(something, true)
```

### Getting Recipients ([`Syncee.server.GetRecipients`](../api/server#GetRecipients))

If you ever need to know which clients the table **is currently** replicated to. You can use this for it.
```lua
local players = Syncee.server.GetRecipients(yourtable)
-- do something i guess
```



