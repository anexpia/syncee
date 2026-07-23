--!optimize 2
--!strict

local Squish = require("../luau_packages/squish")
local CreateSignal = require("./Signal")
local NodeCreator = require("./CreateNode")

local Constants = require("./Constants")

local _nilvalue = Constants.nilvalue

local vlq = Squish.vlq()
local u8, vlqser = Squish.u8(), vlq.ser

local anyTableSerdes = Constants.anyTableSerdes
local idArraySerdes = Squish.array(vlq)

local tryrealloc, pushbuf, pushstr = Squish.util.tryrealloc, Squish.util.pushbuf, Squish.util.pushstr

local Schemas = Constants.Schemas

local ksweaktable = {__mode = 'ks'}
local vsweaktable = {__mode = "vs"}

--

local __: any = nil

type anyTable = Constants.anyTable
type TableChangeSignal = Constants.TableChangeSignal
type BufferChangeSignal = Constants.BufferChangeSignal

type node = NodeCreator.node
type syncdata = {
	t: anyTable | buffer,
	node: node,
	id: number,
	
	isbuffer: boolean,
	
	destroyed: boolean?,
	cleared: boolean?,
		
	replicator: {[any]: any}?,
	ratelimited: boolean?,
	lastsend: number?,
	
	recipients: {[node]: boolean},
	changesignal: typeof( CreateSignal( __ :: (...any) -> () )) ?,
	
	partialreplicationbuffer: buffer?,
	wholereplicationbuffer: buffer?,
}

type privatedata = {
	persistent: boolean?,
	ratelimit: number?,
	schemaidx: number?,
}

--

local exposed = {}

local freeids: {number} = {}
local lastfreeid = 4

local playerdata: {[Player]: any} = {}
local storage: {[any]: privatedata} = setmetatable({}, ksweaktable) :: any
local syncdatastorage: {[any]: syncdata} = setmetatable({}, ksweaktable) :: any
local idtovalue: {anyTable | buffer} = setmetatable({}, vsweaktable) :: any
local pendingreplication: {syncdata} = {}
local ratelimitedarray: {syncdata} = {}
local replicationmaps: {[Player]: anyTable} = {}


--

local function claimid(): number
	local id = table.remove(freeids)
	
	if not id then
		id = lastfreeid
		lastfreeid += 1
	end
	
	return id :: number
end

local function releaseid(id: number)
	table.insert(freeids, id)
end

local function addreplicator(syncdata: syncdata): anyTable
	if not syncdata.replicator then
		syncdata.replicator = {}
		table.insert(pendingreplication, syncdata)
	end
	
	return syncdata.replicator :: anyTable
end

local function assignsyncdata(t: anyTable | buffer): (syncdata)
	local syncdata = syncdatastorage[t]
	
	if not syncdata then
		local id = claimid()
		local node = NodeCreator.create(t)
		
		local newdata: syncdata = {
			t = t :: any,
			node = node, 
			id = id, 
			recipients = {},
			
			isbuffer = type(t) == "buffer",
		}
		
		idtovalue[id] = t
		syncdatastorage[t] = newdata
		
		if type(t) == 'table' then
			for k, v in next, t :: any do 
				local vtype = type(v)
				
				if vtype == "table" or vtype == "buffer" then
					local othersyncdata = assignsyncdata(v)
					node:connect(othersyncdata.node, k)
				end
			end 
		end
		
		return newdata
	end
	
	return syncdata
end

local function assignprivatedata(t: anyTable | buffer): privatedata
	local data = storage[t]
	if data then return data end 
	
	data = {} :: privatedata
	storage[t] = data
	
	return data
end

local function assertRegistered(t: unknown): syncdata
	local typ = type(t)
	assert(typ == 'table' or typ == 'buffer', `Expected a table or buffer, got {typeof(t)}`)
	return assert(syncdatastorage[t], 'Provided table/buffer is not a replicated table/buffer.')
end

local function assertRegisteredTable(t: unknown): syncdata
	assert(type(t) == 'table', `Expected a table, got {typeof(t)}`)
	return assert(syncdatastorage[t], 'Provided table is not a replicated table.')
end

local function assertRegisteredBuffer(t: unknown): syncdata
	assert(type(t) == 'buffer', `Expected a buffer, got {typeof(t)}`)
	return assert(syncdatastorage[t], 'Provided buffer is not a replicated buffer.')
end

local function assertPlayer(v: unknown, context: string)
	assert(typeof(v) == "Instance" and v:IsA("Player"), `Expected a player when {context}`)
end

--

-- Sets whether the provided table or buffer is persistent in syncdata even if not replicated to anyone.
-- This should be used for tables you know are guaranteed to be replicated. so that you have a safety guarantee that SyncTable's api wont error on it.
function exposed.SetPersistent(t: anyTable | buffer, state: boolean)
	state = not not state 
	
	local typ = type(t)
	assert(typ == "table" or typ == "buffer", `Expected a table or buffer, got {typeof(t)}`)
		
	local data = if state then assignprivatedata(t) else storage[t]
	if data then
		data.persistent = state 
	
		local syncdata = if state then assignsyncdata(t) else syncdatastorage[t]
		if syncdata then
			local node = syncdata.node
			
			node.persistent = state
			
			if not (state) then
				node.awaitingupdate = true
				node:updateorigins()
			end
		end
	end
end

-- Registers the provided schema to be used for the given table, nil can be provided to remove the schema.
-- This doesn't need the value to be already in synctable's regisstry.
function exposed.SetSchema(t: anyTable, schema: (number | string)?)
	local typ = type(t)
	assert(typ == "table", `Expected a table, got {typeof(t)}`)
	
	local schema_idx: number?
	
	if type(schema) == "string" then
		schema_idx = Constants.SchemaNameToIdx[schema] :: number
	else schema_idx = schema end
	
	if schema ~= nil then assert(Schemas[schema_idx :: number], `No schema is registered with the id/name {schema}.`) end

	local data = if schema_idx then assignprivatedata(t) else storage[t]
	if data then data.schemaidx = schema_idx end
end

-- Limits the rate of replication for the provided table to atleast 'n' seconds between each replication.
-- This doesn't need the value to be already in synctable's registry. 
-- -
-- Note that this only applies to the provided table/buffer.
function exposed.SetRatelimit(t: anyTable | buffer, ratelimit: number?)
	if ratelimit ~= nil then assert(type(ratelimit) == "number", `Expected ratelimit to be a number, got {typeof(ratelimit)}`) end 
	
	local typ = type(t)
	assert(typ == "table" or typ == "buffer", `Expected a table or buffer, got {typeof(t)}`)

	local data = if ratelimit then assignprivatedata(t) else storage[t]
	if data then data.ratelimit = ratelimit end
end

-- Replicates the value of the provided key, even if not changed.
function exposed.Replicate(t: anyTable, key: any)
	local syncdata = assertRegistered(t)

	for othernode, keys in syncdata.node.ascend do
		if keys[key] then 
			if t[key] ~= othernode.value then
				syncdata.node:disconnect(othernode, key)
				break -- no other node can be bound to this key.
			else return end -- don't need to continue because its guaranteed that nothing changed.
		end
	end

	local value = rawget(t, key) :: any
	local rv = value
	
	local t_new = type(value)
	if t_new == "table" or t_new == "buffer" then
		local othersyncdata = assignsyncdata(value)
		syncdata.node:connect(othersyncdata.node, key)
	elseif value == nil then
		rv = _nilvalue
	end

	addreplicator(syncdata)[key] = rv
end

-- Replicates a region of a buffer.
function exposed.ReplicateBufferRegion(buf: buffer, start: number, length: number)
	local syncdata = syncdatastorage[buf]
	
	if syncdata and syncdata.isbuffer then
		local replicator = addreplicator(syncdata)
		
		local new_end = start + (length - 1)
		replicator[start] = math.max(new_end, replicator[start] or 0, start)
	end
end

-- Sets 'key' of 't' to 'value', replicates the change then fires TableChangedSignal if present.
function exposed.Set(t: anyTable, key: any, value: any)
	local old = rawget(t, key)
	if old == value then return end 

	rawset(t, key, value)
	local syncdata = syncdatastorage[t]

	if syncdata then
		local t_old = type(old)
		local t_new = type(value)

		if t_old == "table" or t_old == "buffer" then
			local othersyncdata = syncdatastorage[old]
			local othernode = othersyncdata and othersyncdata.node
			
			if othernode then syncdata.node:disconnect(othernode, key) end
		end

		local rv = value
		if t_new == "table" or t_new == "buffer" then
			local othersyncdata = assignsyncdata(value)
			syncdata.node:connect(othersyncdata.node, key)
			
		elseif value == nil then
			rv = _nilvalue
		end

		addreplicator(syncdata)[key] = rv

		local signal = syncdata.changesignal
		if signal then signal:Fire(t, key, value) end
	end
end

-- Returns the root replication table of the provided player.
function exposed.GetData(player: Player)
	assertPlayer(player, "calling SyncTable.GetData()")
	if playerdata[player] then return playerdata[player] end 

	local t = {}
	local syncdata = assignsyncdata(t)

	playerdata[player] = t 
	syncdata.recipients[syncdata.node] = false
	syncdata.node.isorigin = true
	syncdata.node.persistent = true

	return t
end

-- Clears the content of the table and schedules the clearing for replication.
function exposed.Clear(t: anyTable)
	assert(type(t) == "table", `Expected to be provided a table, got {typeof(t)}.`)
	local syncdata = syncdatastorage[t]
	
	if syncdata then
		syncdata.node:disconnectall()
		table.clear(t)
		
		local replicator = addreplicator(syncdata)
		table.clear(replicator)
		
		syncdata.cleared = true
	else
		table.clear(t)
	end
end

-- table.insert(), but replicates the changes if on server and fires change signal.
function exposed.Insert(t: anyTable, posOrValue: any, value: any?)	
	if value == nil then
		exposed.Set(t, #t + 1, posOrValue)
	else
		local pos, val = posOrValue, value

		for i = #t, pos, -1 do exposed.Set(t, i + 1, t[i]) end
		exposed.Set(t, pos, val)
	end
end

-- table.remove(), but replicates the changes if on server and fires change signal.
function exposed.Remove(t: anyTable, pos: number?)
	pos = pos or #t

	local old = t[pos]

	for i = pos, #t - 1 do exposed.Set(t, i, t[i + 1]) end
	exposed.Set(t, #t, nil)

	return old
end

-- Returns the table or buffer associated with the provided id if present.
function exposed.GetValueWithId(id: number): anyTable | buffer | nil
	return idtovalue[id]
end

-- Returns id associated with the table or buffer if present.
function exposed.GetIdOfValue(t: anyTable | buffer): number?
	local syncdata = syncdatastorage[t]
	if syncdata then return syncdata.id end
	
	return nil
end

-- Returns boolean indicating if the table is replicated.
function exposed.IsReplicatedTable(t: anyTable | buffer): boolean
	return not not syncdatastorage[t]
end

local function GetChangeSignal(syncdata: syncdata)
	local signal = syncdata.changesignal

	if not signal then 
		signal = CreateSignal( __ )
		syncdata.changesignal = signal
	end

	return signal
end

-- Returns signal that fires whenever any key of the replicated table changes.
function exposed.GetTableChangedSignal(t: anyTable): TableChangeSignal
	return GetChangeSignal(assertRegisteredTable(t)) :: TableChangeSignal
end

-- Returns signal that fires whenever the content of the buffer changes.
function exposed.GetBufferChangedSignal(b: buffer): BufferChangeSignal
	return GetChangeSignal(assertRegisteredBuffer(b)) :: BufferChangeSignal
end

-- proxies

do 
	-- reference to proxy keeps original alive, reference to original does not keep proxy alive.
	local proxymap = setmetatable({}, ksweaktable) :: {[anyTable]: anyTable}
	local toProxy = setmetatable({}, vsweaktable) :: {[anyTable]: anyTable}
	
	local set = exposed.Set
	local proxy_mtbl = {
		__index = function(proxy: anyTable, key: any)
			return rawget(proxymap[proxy], key)
		end,
		
		__newindex = function(proxy: anyTable, key: any, value: any)
			return set(proxymap[proxy], key, value)
		end,
		
		__len = function(proxy: anyTable)
			return #proxymap[proxy]
		end,
		
		__tostring = function(proxy: anyTable)
			return `proxy<{tostring(proxymap[proxy])}>`
		end,
		
		__iter = function(proxy: anyTable)
			return next, proxymap[proxy]
		end,
	}
	
	-- Returns a proxy for the provided table that automatically runs SyncTable.set() upon any changes.
	function exposed.GetProxy(t: anyTable): anyTable
		local proxy = toProxy[t]
		
		if proxy then return proxy end
		if proxymap[t] then return t end
		
		proxy = table.freeze(setmetatable({}, proxy_mtbl)) :: any
		
		proxymap[proxy] = t 
		toProxy[t] = proxy
		
		return proxy
	end
	
	-- Returns the original table that this proxy is bound to, if it exists.
	function exposed.ProxyToTable(proxy: anyTable): anyTable?
		return proxymap[proxy]
	end
end

-- replication

do 
	
	local function getplayermap(player: Player)
		local map = replicationmaps[player]
		
		if not map then
			map = {}
			replicationmaps[player] = map 
		end
		
		return map
	end
		
	local function deltaBuffer(buf: buffer, syncdata: syncdata): buffer
		local deltabuf = syncdata.partialreplicationbuffer
		if deltabuf then return deltabuf end
		
		local cursor = Squish.cursor()
		local replicator = syncdata.replicator :: {number}
		local strBuf = buffer.tostring(buf)
		
		local array = {}
		local originalcount = 0
		
		for start in replicator do 
			originalcount += 1
			array[originalcount] = start
		end
		
		table.sort(array)

		local coalesced: {number} = {}
		local regioncount = 0
		
		local currentstart: number, currentend: number

		for _, regionstart in array do
			local regionend = replicator[regionstart]
			
			if currentstart and regionstart <= (currentend + 4) then
				currentend = math.max(currentend, regionend)
				replicator[currentstart] = currentend
			else
				currentstart, currentend = regionstart, regionend
				regioncount += 1

				coalesced[regioncount] = regionstart
			end
		end
		
		-- write each region into the cursor backwards so that the client can correctly read offsets between each region
		-- since squish reads backwards.
		
		for i = regioncount, 1, -1 do 
			local start = coalesced[i]
			local length = (replicator[start] - start) + 1

			tryrealloc(cursor, length)
			pushstr(cursor, string.sub(strBuf, start + 1, start + length), length)
			
			vlqser(cursor, length)
			vlqser(cursor, start - (coalesced[i - 1] or 0))
		end

		vlqser(cursor, regioncount)
		vlqser(cursor, syncdata.id)
		
		deltabuf = Squish.tobuffer(cursor)
		syncdata.partialreplicationbuffer = deltabuf
		
		return deltabuf
	end

	local function addPlayer(player: Player, syncdata: syncdata, whole: boolean?, datachanged: boolean?)
		local map = getplayermap(player)
		if map[syncdata.id] then return end
		
		if syncdata.isbuffer then
			if whole then
				local newbufs = map[2]
				if not newbufs then newbufs = {}; map[2] = newbufs end

				table.insert(newbufs, syncdata)
			elseif datachanged then
				local deltas = map[3]
				if not deltas then deltas = {}; map[3] = deltas end

				table.insert(deltas, deltaBuffer(syncdata.t :: buffer, syncdata))
			end
			
			return
		end

		if not whole and syncdata.cleared then
			local cleared = map[1]
			if not cleared then cleared = {}; map[1] = cleared end
			table.insert(cleared, syncdata.id)
			
			if not datachanged then return end
		end

		local bufferkey = if whole then "wholereplicationbuffer" else "partialreplicationbuffer"
		local savedbuffer = (syncdata :: any)[bufferkey] :: buffer

		if savedbuffer == nil then
			local t = syncdata.t :: anyTable
			local data = if whole then t else syncdata.replicator :: anyTable
			
			local privatedata = storage[t]
			local schemaidx = if privatedata then privatedata.schemaidx else nil
			local schema = Schemas[schemaidx :: any]
			
			local cursor = Squish.cursor()
			
			if schema then schema.ser(cursor, data)
			else 
				schemaidx = 0
				anyTableSerdes.ser(cursor, data) 
			end
			
			vlqser(cursor, schemaidx :: number)
			
			savedbuffer = Squish.tobuffer(cursor);
			(syncdata :: any)[bufferkey] = savedbuffer
		end 
		
		local len = buffer.len(savedbuffer)
		local buf = buffer.create(len + 1)
		buffer.copy(buf, 0, savedbuffer, 0, len)
		buffer.writeu8(buf, len, bit32.bor(if whole then 1 else 0, if whole and syncdata.node.player == player then 2 else 0))

		map[syncdata.id] = buf
	end

	local function removePlayer(player: Player, data: syncdata)
		local map = getplayermap(player)
		
		local removed = map[0]
		if not removed then 
			removed = {} 
			map[0] = removed 
		end
		
		table.insert(removed, data.id)
	end

	-- =Returns a dictionary mapping each player to an array of buffers containing new data to replicate.
	function exposed.GetDataToReplicate(): {[Player]: {[number]: buffer}}
		
		local now = tick()
		
		for _, syncdata in pendingreplication do 
			local ancestrychanged = if syncdata.destroyed then false else syncdata.node.hasancestrychanged
			if ancestrychanged then syncdata.node:updateorigins() end
			
			if syncdata.destroyed then
				-- note: usually syncdata.destroyed is assigned midexecution of this loop by delinked which gets fired by updateorigins()
				-- there's few other spots like deletedata() and setpersistent() which may do this too.
				
				for node, state in syncdata.recipients do 
					local player = if state then node.player else nil
					if player then removePlayer(player, syncdata) end
				end
			else
				local privatedata = storage[syncdata.t]
				local ratelimited = false

				if privatedata then
					local limit = privatedata.ratelimit
					if limit then
						local lastsend = syncdata.lastsend or 0 

						ratelimited = (now - lastsend) < limit
						syncdata.ratelimited = ratelimited
						
						if not ratelimited then syncdata.lastsend = now end
					end
				end
				
				local hasnewdata = false
				
				if not ratelimited then
					if syncdata.cleared then hasnewdata = true
					elseif syncdata.replicator then
						for _ in (syncdata.replicator :: anyTable) do 
							hasnewdata = true
							break
						end
					end
				end
				
				if ancestrychanged then
					syncdata.node.hasancestrychanged = false
					
					local newrecipients = syncdata.node.origins
					local currentrecipients = syncdata.recipients

					for node, state in currentrecipients do 
						if newrecipients[node] then
							local player = if state then node.player else nil 
							if player then removePlayer(player, syncdata) end
							
							currentrecipients[node] = nil
						end
					end

					for node in newrecipients do 
						local player = node.player
						
						if player then 
							local unreplicated = not currentrecipients[node]
							
							if hasnewdata or unreplicated then
								addPlayer(player, syncdata, unreplicated, hasnewdata)
							end
							
							currentrecipients[node] = true
						else
							currentrecipients[node] = false
						end
					end
				else 
					for node, state in syncdata.recipients do 
						local unreplicated = not state
						
						if hasnewdata or unreplicated then
							if node.player then
								addPlayer(node.player, syncdata, unreplicated, hasnewdata)
								syncdata.recipients[node] = true
							end
						end
					end
				end
			end
		end
		
		-- handle special maps
		-- [0] = deletions
		-- [1] = clearing
		-- [2] = new buffers
		-- [3] = buffer deltas
		-- [4] and beyond is unreserved.
		
		for player, map in replicationmaps do 
			for i = 0, 1 do 
				local t = map[i]
				if t then 
					local cursor = Squish.cursor()
					idArraySerdes.ser(cursor, t)
					map[i] = Squish.tobuffer(cursor)
				end
			end
			
			local newbufs = map[2]
			if newbufs then
				local cursor = Squish.cursor()
				
				for _, syncdata in newbufs do
					local t: buffer = syncdata.t 
					local len = buffer.len(t)
					
					tryrealloc(cursor, len)
					pushbuf(cursor, t, len)
					vlqser(cursor, len)
					vlqser(cursor, syncdata.id)
				end
				
				vlqser(cursor, #newbufs)
				
				map[2] = Squish.tobuffer(cursor)
			end
			
			local deltaBufs = map[3]
			if deltaBufs then
				local cursor = Squish.cursor()
				
				for _, buf in deltaBufs do 
					-- not writing length of buffer because that information is embedded in each region.
					
					local len = buffer.len(buf)
					tryrealloc(cursor, len)
					pushbuf(cursor, buf, len)
				end
				
				vlqser(cursor, #deltaBufs)
				
				map[3] = Squish.tobuffer(cursor)
			end
		end
		
		-- cleanup
		
		local limitedcount = 0
		
		for _, syncdata in pendingreplication do 
			if syncdata.destroyed then
				local id = syncdata.id 
				
				releaseid(id)
				idtovalue[id] = nil

				table.clear(syncdata)
			elseif syncdata.ratelimited then
				limitedcount += 1
				ratelimitedarray[limitedcount] = syncdata
				
				syncdata.wholereplicationbuffer = nil -- ratelimits dont stop initial full data send.
			else
				if syncdata.isbuffer and syncdata.replicator then
					-- this.. isn't a good place to fire change signals for buffers. but i don't know any better location.
					local signal = syncdata.changesignal :: BufferChangeSignal
					if signal then signal:FireDeferred(syncdata.t :: buffer) end
				end
				
				syncdata.replicator = nil 
				syncdata.cleared = nil
				
				syncdata.wholereplicationbuffer = nil 
				syncdata.partialreplicationbuffer = nil
			end
		end

		table.clear(pendingreplication)

		if limitedcount > 0 then
			table.move(ratelimitedarray, 1, limitedcount, 1, pendingreplication)
			table.clear(ratelimitedarray)
		end
		
		-- return result
		
		local toreturn = table.clone(replicationmaps)
		table.clear(replicationmaps)
		
		return toreturn
	end
	
end

-- mark loading

do 
	local function recursive_playerdatarequested(syncdata: syncdata, iterated: anyTable)
		if iterated[syncdata] then return end  
		iterated[syncdata] = true

		addreplicator(syncdata)

		for subnode in syncdata.node.ascend do 
			local v = subnode.value
			local subsyncdata = syncdatastorage[v]

			if subsyncdata then
				recursive_playerdatarequested(subsyncdata, iterated)
			end
		end
	end

	-- Marks the given player as loaded and begins replicating the data to them.
	function exposed.MarkPlayerLoaded(player: Player)
		local data = exposed.GetData(player)
		local syncdata = syncdatastorage[data]
		
		if syncdata.node.player then return end
		syncdata.node.player = player
		
		recursive_playerdatarequested(syncdata, {})
	end
end

-- 

local function DeleteData(player: Player)
	local t = playerdata[player]

	if t then
		local syncdata = syncdatastorage[t]
		if syncdata then NodeCreator.Delinked(syncdata.node) end

		playerdata[player] = nil
	end
end


NodeCreator.Delinked = function(node: node)
	local t = node.value;
	local syncdata: syncdata? = syncdatastorage[t]
	
	if syncdata then
		syncdatastorage[t] = nil 
		
		if syncdata.changesignal then
			syncdata.changesignal:Destroy()
		end
		
		syncdata.destroyed = true
		addreplicator(syncdata)
	end
	
	node:destroy()
end

NodeCreator.AncestryChanged = function(nodes: {node})
	for _, node in nodes do 
		local syncdata = syncdatastorage[node.value]
		if syncdata then addreplicator(syncdata) end
	end
end;

(Constants.TableReferenceSerdes :: any).ser = function(cursor: Squish.Cursor, value: anyTable)
	local syncdata = syncdatastorage[value]

	if syncdata then vlqser(cursor, syncdata.id + 1)
	else u8.ser(cursor, 0) end
end

(Constants.BufferReferenceSerdes :: any).ser = Constants.TableReferenceSerdes.ser

game:GetService("Players").PlayerRemoving:Connect(DeleteData)

return exposed
