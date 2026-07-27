--!optimize 2
--!strict

local Squish = require("../roblox_packages/squish")
local CreateSignal = require("./Signal")
local NodeCreator = require("./CreateNode")

local Constants = require("./Constants")

local _nilvalue = Constants.nilvalue

local vlq = Squish.vlq()
local u8, vlqser = Squish.u8(), vlq.ser

local anyTableSerdes = Constants.anyTableSerdes
local dataSerdes = Constants.DataSerdes
local idArraySerdes = Squish.array(vlq)

local tryrealloc, pushbuf, setpos, getbuf, getpos = Squish.util.tryrealloc, Squish.util.pushbuf, Squish.util.setpos, Squish.util.getbuf, Squish.util.getpos

local Schemas = Constants.Schemas

local ksweaktable = {__mode = 'ks'}
local vsweaktable = {__mode = "vs"}

--

local MAP_DELETIONS = 1 
local MAP_CLEARED = 2
-- keep cleared and deletions in sequence.
local MAP_NEW_BUFFERS = 3
local MAP_BUFFER_DELTAS = 4
local MAP_NEW_TABLES = 5
local MAP_TABLE_DELTAS = 6

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
	partialdata: {any}?, -- {buffer, references}
	wholedata: {any}?, -- {buffer, references}
}

type privatedata = {
	persistent: boolean?,
	ratelimit: number?,
	schemaidx: number?,

	hassubschemas: boolean?,
	subschemas: {[any]: number}?,
	subschemaid: number?,

	proxy: anyTable?,
}

--

local exposed = {}

local freeids: {number} = {}
local lastfreeid = 0

local playerdata: {[Player]: any} = {}
local storage: {[any]: privatedata} = setmetatable({}, ksweaktable) :: any
local syncdatastorage: {[any]: syncdata} = setmetatable({}, ksweaktable) :: any
local idtovalue: {anyTable | buffer} = setmetatable({}, vsweaktable) :: any
local pendingreplication: {syncdata} = {}
local ratelimitedarray: {syncdata} = {}
local replicationmaps: {[Player]: anyTable} = {}

local proxymap = setmetatable({}, ksweaktable) :: {[anyTable]: anyTable}

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

local function canApplySubschema(v: anyTable | buffer): boolean
	if type(v) ~= "table" then return false end 

	local private = storage[v]
	if private and private.schemaidx then return false end 

	return true
end

local function applySubschemaIfNeeded(childTable: anyTable, key: any, subschemas: {[any]: number}?, subschemaid: number?): boolean?
	if not canApplySubschema(childTable) then return false end
	
	local schemaid: number? = nil

	if subschemas then schemaid = subschemas[key]
	else schemaid = subschemaid end
	
	if not schemaid then return nil end
	exposed.SetSchema(childTable, schemaid)

	return true
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

		local private = storage[t :: any]
		local subschemas, subschemaid 

		if private then
			node.persistent = private.persistent
			if private.proxy then syncdatastorage[private.proxy] = newdata end 

			subschemas = private.subschemas
			subschemaid = private.subschemaid
		end

		local hassubschemas = subschemas or subschemaid

		if type(t) == 'table' then
			for k, v in t :: any do 
				local vtype = type(v)
				
				local istable = vtype == "table"

				if istable or vtype == "buffer" then
					local othersyncdata = assignsyncdata(v)
					node:connect(othersyncdata.node, k)

					if istable and hassubschemas then
						applySubschemaIfNeeded(v :: anyTable, k, subschemas, subschemaid)
					end
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

local function assertRegisteredTable(t: unknown): syncdata
	assert(type(t) == 'table', `Expected a table, got {typeof(t)}`)
	return assert(syncdatastorage[t], 'Provided table is not a replicated table.')
end

local function assertRegisteredBuffer(t: unknown): syncdata
	assert(type(t) == 'buffer', `Expected a buffer, got {typeof(t)}`)
	return assert(syncdatastorage[t], 'Provided buffer is not a replicated buffer.')
end

local function assertPlayer(v: unknown, context: string)
	local typ = typeof(v)
	assert(typ == "Instance" and (v :: Instance):IsA("Player"), `Expected a player, got {if typ == "Instance" then (v :: Instance).ClassName else typ}`)
end

--

-- Sets whether the provided table or buffer is persistent in syncdata even if not replicated to anyone.
-- This should be used for tables you know are guaranteed to be replicated. so that you have a safety guarantee that Syncee's api wont error on it.
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
-- This doesn't need the value to be already in syncee's registry.
-- If the schema has sub-schemas, they will be automatically applied to any table present within if they don't have a schema assigned already.
function exposed.SetSchema(t: anyTable, schema: (number | string)?)
	local typ = type(t)
	assert(typ == "table", `Expected a table, got {typeof(t)}`)
	
	local schema_idx: number?
	local serdes 

	if type(schema) == "string" then
		schema_idx = Constants.SchemaNameToIdx[schema] :: number
	else schema_idx = schema end
	
	if schema ~= nil then serdes = assert(Schemas[schema_idx :: number], `No schema is registered with the id/name {schema}.`) end

	local data = if schema_idx then assignprivatedata(t) else storage[t]
	if data then
		data.schemaidx = schema_idx
		
		if serdes then
			local subschemas, subschemaidx = (serdes :: any).subschemas, (serdes :: any).subschemaIdx
			local hassubschemas = not not (subschemas or subschemaidx)

			data.subschemas = subschemas
			data.subschemaid = subschemaidx
			data.hassubschemas = hassubschemas

			local syncdata = hassubschemas and syncdatastorage[t]
			if syncdata then 
				if subschemaidx then
					for subnode in syncdata.node.ascend do
						local v = subnode.value
						if not canApplySubschema(v) then continue end 

						exposed.SetSchema(v, subschemaidx)
					end
				else 
					for key, subschema in subschemas do 
						local v = t[key]
						if v then 
							if not canApplySubschema(v) then continue end 

							exposed.SetSchema(v, subschema)
						end
					end
				end
			end
		else
			data.hassubschemas = false
			data.subschemas = nil
			data.subschemaid = nil
		end
	end
end

-- Limits the rate of replication for the provided table to atleast 'n' seconds between each replication.
-- This doesn't need the value to be already in syncee's registry. 
-- -
-- Note that this only applies to the provided table/buffer.
function exposed.SetRatelimit(t: anyTable | buffer, ratelimit: number?)
	if ratelimit ~= nil then assert(type(ratelimit) == "number", `Expected ratelimit to be a number, got {typeof(ratelimit)}`) end 
	
	local typ = type(t)
	assert(typ == "table" or typ == "buffer", `Expected a table or buffer, got {typeof(t)}`)

	local data = if ratelimit then assignprivatedata(t) else storage[t]
	if data then
		data.ratelimit = ratelimit
		
		if not ratelimit then
			local syncdata = syncdatastorage[t]
			if syncdata then syncdata.ratelimited = nil end
		end
	end
end

-- Replicates the value of the provided key, even if not changed.
function exposed.Replicate(t: anyTable, key: any)
	local syncdata = assertRegisteredTable(t)
	local t = syncdata.t :: anyTable

	local value = t[key]
	local rv = value

	for othernode, keys in syncdata.node.ascend do
		if keys[key] then 
			if value ~= othernode.value then
				syncdata.node:disconnect(othernode, key)
				break -- no other node can be bound to this key.
			else return end -- don't need to continue because its guaranteed that nothing changed.
		end
	end

	local t_new = type(value)
	local newistable = t_new == "table"
	
	if newistable or t_new == "buffer" then
		local othersyncdata = assignsyncdata(value)
		syncdata.node:connect(othersyncdata.node, key)
		
		if newistable then
			local private = storage[t]
			
			if private and private.hassubschemas then
				applySubschemaIfNeeded(value, key, private.subschemas, private.subschemaid)
			end
		end
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
	local old = t[key]
	if old == value then return end 

	t[key] = value

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
		local newistable = t_new == "table"
		
		if newistable or t_new == "buffer" then
			local othersyncdata = assignsyncdata(value)
			syncdata.node:connect(othersyncdata.node, key)

			if newistable then
				local private = storage[t]

				if private and private.hassubschemas then
					applySubschemaIfNeeded(value, key, private.subschemas, private.subschemaid)
				end
			end
		elseif value == nil then
			rv = _nilvalue
		end

		addreplicator(syncdata)[key] = rv

		local signal = syncdata.changesignal
		if signal then signal:Fire(t, key, value) end
	else 
		t[key] = value
	end
end

-- Returns the root replication table of the provided player.
function exposed.GetData(player: Player)
	assertPlayer(player, "calling Syncee.server.GetData()")
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
		table.clear(syncdata.t :: anyTable)
		
		local replicator = addreplicator(syncdata)
		table.clear(replicator)
		
		syncdata.cleared = true
	else
		table.clear(proxymap[t] or t)
	end
end

-- table.insert(), but replicates the changes if on server and fires change signal.
function exposed.Insert(t: anyTable, posOrValue: any, value: any?)	
	t = proxymap[t] or t 

	--TODO special instruction to avoid having to .set() everything.

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
	t = proxymap[t] or t 

	--TODO special instruction to avoid having to .set() everything.

	local len = #t	
	pos = pos or len

	if pos > len or pos == 0 then return end 
	
	local old = t[pos]
	
	for i = pos, len - 1 do exposed.Set(t, i, t[i + 1]) end
	exposed.Set(t, len, nil)

	return old
end

-- Returns the players this table/buffer is replicated to.
function exposed.GetRecipients(t: anyTable | buffer): {Player}
	local recipients = {}
	local count = 0

	local syncdata = syncdatastorage[t]
	if syncdata then
		local node = syncdata.node
		if node.awaitingupdate then node:updateorigins() end 

		if not syncdata.destroyed then 
			for origin, state in node.origins do 
				local player = origin.player
				
				if player then
					count += 1 
					recipients[count] = player
				end
			end
		end
	end 

	return recipients
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

-- Returns boolean indicating if the table or buffer is replicated.
function exposed.IsReplicatedValue(t: anyTable | buffer): boolean
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
	local set = exposed.Set
	local proxy_mtbl = {
		__index = function(proxy: anyTable, key: any)
			local value = rawget(proxymap[proxy], key)
			if type(value) == "table" then return exposed.GetProxy(value) end -- proxy'ify tables. 

			return value
		end,
		
		__newindex = function(proxy: anyTable, key: any, value: any)
			return set(proxymap[proxy], key, proxymap[value] or value)
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
	
	-- Returns a proxy for the provided table that automatically runs Syncee.server.set() upon any changes.
	-- <strong>Do not use proxies with server.Set() or manually add them to replicated tables</strong>. Unexpected behaviors may occur if this is done.
	function exposed.GetProxy(t: anyTable): anyTable
		local private = storage[t]

		if private then
			local proxy = private.proxy
			if proxy then return proxy end
		end
		
		local proxy = table.freeze(setmetatable({}, proxy_mtbl)) :: any
		
		proxymap[proxy] = t 
		if private then private.proxy = proxy
		else private = {proxy = proxy} :: privatedata; storage[t] = private end

		setmetatable(private, vsweaktable) -- so proxies dont leak.

		syncdatastorage[proxy] = syncdatastorage[t]
		storage[proxy] = private

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
		
		local array = {}
		local originalcount = 0
		
		for start in replicator do 
			originalcount += 1
			array[originalcount] = start
		end
		
		if originalcount > 1 then table.sort(array) end

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

			local cursorpos = getpos(cursor)

			tryrealloc(cursor, length)
			buffer.copy(getbuf(cursor), cursorpos, buf, start, length)
			setpos(cursor, cursorpos + length)
						
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
		
		if syncdata.isbuffer then
			if whole then
				local newbufs = map[MAP_NEW_BUFFERS]
				if not newbufs then newbufs = {}; map[MAP_NEW_BUFFERS] = newbufs end

				table.insert(newbufs, syncdata)
			elseif datachanged then
				local deltas = map[MAP_BUFFER_DELTAS]
				if not deltas then deltas = {}; map[MAP_BUFFER_DELTAS] = deltas end

				table.insert(deltas, deltaBuffer(syncdata.t :: buffer, syncdata))
			end
			
			return
		end

		if not whole and syncdata.cleared then
			local cleared = map[MAP_CLEARED]
			if not cleared then cleared = {}; map[MAP_CLEARED] = cleared end
			table.insert(cleared, syncdata.id)
			
			if not datachanged then return end
		end

		local mainkey = if whole then "wholedata" else "partialdata"
		local tosend = (syncdata :: any)[mainkey]

		if not tosend then
			local t = syncdata.t :: anyTable
			local data = if whole then t else syncdata.replicator :: anyTable

			local privatedata = storage[t]
			local schemaidx = if privatedata then privatedata.schemaidx else nil
			local schema = Schemas[schemaidx :: any]

			local cursor = Squish.cursor()

			if schema then
				schema.ser(cursor, data)
			else
				schemaidx = 0
				anyTableSerdes.ser(cursor, data)
			end

			vlqser(cursor, schemaidx :: number)

			local savedbuffer = Squish.tobuffer(cursor)
			local savedrefs = cursor.refs;

			tosend = {savedbuffer, savedrefs}
			(syncdata :: any)[mainkey] = tosend
		end 

		local mapid = if whole then MAP_NEW_TABLES else MAP_TABLE_DELTAS
		local submap = map[mapid]

		if not submap then 
			submap = {} 
			map[mapid] = submap 
		end
		
		submap[syncdata.id] = tosend
	end

	local function removePlayer(player: Player, data: syncdata)
		local map = getplayermap(player)
		
		local removed = map[MAP_DELETIONS]
		if not removed then 
			removed = {} 
			map[MAP_DELETIONS] = removed 
		end
		
		table.insert(removed, data.id)
	end

	-- Returns a dictionary mapping each player to a table containing a buffer and an auxillary references array to send to them.
	function exposed.GetDataToReplicate(): {[Player]: {b: buffer, refs: {{any} | false}}}
		
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
						if not newrecipients[node] then
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
		
		local cursor = Squish.cursor()
		for player, map in replicationmaps do 

			for i = MAP_DELETIONS, MAP_CLEARED do
				local t = map[i]
				if t then 
					idArraySerdes.ser(cursor, t)
					map[i] = Squish.tobuffer(cursor)
					setpos(cursor, 0)
				end
			end
			
			local newbufs = map[MAP_NEW_BUFFERS]
			if newbufs then				
				for _, syncdata in newbufs do
					local t: buffer = syncdata.t 
					local len = buffer.len(t)
					
					tryrealloc(cursor, len)
					pushbuf(cursor, t, len)
					vlqser(cursor, len)
					vlqser(cursor, syncdata.id)
				end
				
				vlqser(cursor, #newbufs)
				
				map[MAP_NEW_BUFFERS] = Squish.tobuffer(cursor)
				setpos(cursor, 0)
			end
			
			local deltaBufs = map[MAP_BUFFER_DELTAS]
			if deltaBufs then				
				for _, buf in deltaBufs do 
					-- not writing length of buffer because that information is embedded in each region.
					
					local len = buffer.len(buf)
					tryrealloc(cursor, len)
					pushbuf(cursor, buf, len)
				end
				
				vlqser(cursor, #deltaBufs)
				
				map[MAP_BUFFER_DELTAS] = Squish.tobuffer(cursor)
				setpos(cursor, 0)
			end

			local refsarray: {{any} | false}
			local hasrefs = false 

			local refsidx = 0

			local newtables = map[MAP_NEW_TABLES]
			if newtables then
				refsarray = refsarray or {}
				local idsarray = {}

				for id, data in newtables do 
					local b, refs = data[1], data[2]

					refsidx += 1
					idsarray[refsidx] = id

					if refs then hasrefs = true end
					refsarray[refsidx] = refs or false

					local len = buffer.len(b)
					tryrealloc(cursor, len)
					pushbuf(cursor, b, len)
				end

				idArraySerdes.ser(cursor, idsarray)
				map[MAP_NEW_TABLES] = Squish.tobuffer(cursor)
				setpos(cursor, 0)
			end

			local deltatables = map[MAP_TABLE_DELTAS]
			if deltatables then
				refsarray = refsarray or {}
				local deltacount = 0

				for id, data in deltatables do 
					local b, refs = data[1], data[2]

					refsidx += 1

					if refs then hasrefs = true end
					refsarray[refsidx] = refs or false

					local len = buffer.len(b)
					tryrealloc(cursor, len)
					pushbuf(cursor, b, len)
					vlqser(cursor, id)

					deltacount += 1
				end

				vlqser(cursor, deltacount)
				
				map[MAP_TABLE_DELTAS] = Squish.tobuffer(cursor)

				setpos(cursor, 0)
			end
			
			if hasrefs then map.refs = refsarray end
		end
		
		-- cleanup
		-- buffer.writeu8(buf, len, bit32.bor(if whole then 1 else 0, if whole and syncdata.node.player == player then 2 else 0))
		
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
				
				 -- ratelimits dont stop initial full data send.
				syncdata.wholedata = nil
			else
				if syncdata.isbuffer then 
					if syncdata.replicator then
						syncdata.partialreplicationbuffer = nil	

						-- this.. isn't a good place to fire change signals for buffers. but i don't know any better location.
						local signal = syncdata.changesignal :: BufferChangeSignal
						if signal then signal:FireDeferred(syncdata.t :: buffer) end
					end
				else 
					syncdata.wholedata = nil 
					syncdata.partialdata = nil
				end
				
				syncdata.replicator = nil 
				syncdata.cleared = nil
			end
		end

		table.clear(pendingreplication)

		if limitedcount > 0 then
			table.move(ratelimitedarray, 1, limitedcount, 1, pendingreplication)
			table.clear(ratelimitedarray)
		end
		
		-- return result
		
		local toreturn = {}
		local cursor = Squish.cursor()

		for player, map in replicationmaps do 
			local refs = map.refs 
			map.refs = nil 

			local rootid = exposed.GetIdOfValue(playerdata[player]) :: number

			dataSerdes.ser(cursor, map)
			vlqser(cursor, rootid or 0)

			toreturn[player] = {b = Squish.tobuffer(cursor), refs = refs}
			setpos(cursor, 0)
		end

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
	local t = node.value
	local syncdata: syncdata? = syncdatastorage[t]
	
	if syncdata then
		syncdatastorage[t] = nil 

		local private = storage[t]
		local proxy = private and private.proxy
		if proxy then syncdatastorage[proxy] = nil end
		
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
end

(Constants.TableReferenceSerdes :: any).ser = function(cursor: Squish.Cursor, value: anyTable)
	local syncdata = syncdatastorage[value]

	if syncdata then vlqser(cursor, syncdata.id + 1)
	else u8.ser(cursor, 0) end
end

(Constants.BufferReferenceSerdes :: any).ser = Constants.TableReferenceSerdes.ser

game:GetService("Players").PlayerRemoving:Connect(DeleteData)

return exposed
