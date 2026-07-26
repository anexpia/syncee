---
sidebar_position: 2
---

# Setup

Syncee requires a simple networking bridge between server and client using `RemoteEvent`s or whatever other method you use to transmit network data.

To set up replication:
* **Server**: Call [`server.MarkPlayerLoaded`](../api/server#MarkPlayerLoaded) when a player is ready, and collect replication payloads via [`server.GetDataToReplicate`](../api/server#GetDataToReplicate) in a loop (e.g. `RunService.Heartbeat`), then send each client's buffer to them.
* **Client**: Pass incoming buffers directly to [`client.DataReceived`](../api/client#DataReceived).

---

## Server Setup Example

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
    for player, data in payloads do 
        SyncEvent:FireClient(player, data.b, data.refs) 
    end
end)
```

---

## Client Setup Example

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

## [<u>Usage Guide</u>](./usage.md)
