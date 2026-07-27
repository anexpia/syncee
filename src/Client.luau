--!optimize 2
--!strict

local LogService = game:GetService("LogService")
local RS = game:GetService("RunService")

local Squish = require("../roblox_packages/squish")
local CreateSignal = require("./Signal")

local Constants = require("./Constants")

local _nilvalue = Constants.nilvalue

local vlqdes = Squish.vlq().des
local bufferSerdes = Squish.buffer()

local setpos, getpos, setbuf = Squish.util.setpos, Squish.util.getpos, Squish.util.setbuf

local anyTableSerdes = Constants.anyTableSerdes
local dataSerdes = Constants.DataSerdes
local Schemas = Constants.Schemas

local MAP_DELETIONS = 1
local MAP_CLEARED = 2
local MAP_NEW_BUFFERS = 3
local MAP_BUFFER_DELTAS = 4
local MAP_NEW_TABLES = 5
local MAP_TABLE_DELTAS = 6

local __: any = nil

type anyTable = Constants.anyTable
type TableChangeSignal = Constants.TableChangeSignal
type BufferChangeSignal = Constants.BufferChangeSignal

local exposed = {}

local debuggingEnabled = if false then RS:IsStudio() else false

local AwaitDataSignal = CreateSignal( __ )
local rootdata: anyTable
local idtovalue: {any} = {}
local valuetoid: {[any]: number} = {}
local valuetosignal: {[anyTable]: typeof( CreateSignal( __ :: (...any) -> () ) )} = {};

(Constants.TableReferenceSerdes :: any).des = function(cursor: Squish.Cursor): any 
	local id = vlqdes(cursor) 
	if id == 0 then return nil end 

	id -= 1
	
	local t = idtovalue[id]
	
	if t then return t
	else warn(`sync ( ! ): TableReference points to unknown id {id}`) end
	
	return nil
end

(Constants.BufferReferenceSerdes :: any).des = Constants.TableReferenceSerdes.des

local function assertRegisteredTable(t: unknown)
	assert(type(t) == 'table', `Expected a table, got {typeof(t)}`)
	return assert(valuetoid[t], 'Provided table is not a replicated table.')
end

local function assertRegisteredBuffer(t: unknown)
	assert(type(t) == 'buffer', `Expected a buffer, got {typeof(t)}`)
	return assert(valuetoid[t], 'Provided buffer is not a replicated buffer.')
end

local function log(text: string)
	if debuggingEnabled then LogService:Info(text) end
end

local function print(text: string)
	if debuggingEnabled then LogService:Output(text) end
end

local function warn(text: string)
	if debuggingEnabled then LogService:Warn(text) end
end


-- Should be provided the buffer of replicated changes the server sends as well as references if present.
function exposed.DataReceived(b: buffer, refs: {{any}}?)
	log("|:| SYNCEE -> DATA RECEIVED")

	local maincursor = Squish.frombuffer(b)
	local rootid = vlqdes(maincursor)

	local refsmax = refs and #refs

	local modifications = dataSerdes.des(maincursor)
	local checkreplicators: {[number]: {[any]: any}}

	local removed_buf = modifications[MAP_DELETIONS]
	if removed_buf then
		
		setbuf(maincursor, removed_buf)
		setpos(maincursor, buffer.len(removed_buf))

		local len = vlqdes(maincursor)
		
		log(`Deleting {len} table(s) and/or buffer(s).`)
		
		for i = 1, len do 
			local id = vlqdes(maincursor)			
			local oldt = idtovalue[id]

			if oldt then
				idtovalue[id], valuetoid[oldt] = nil, nil

				local signal = valuetosignal[oldt]
				if signal then
					signal:Destroy()
					valuetosignal[oldt] = nil
				end
			end
		end
	end

	local cleared_buf = modifications[MAP_CLEARED]
	if cleared_buf then

		setbuf(maincursor, cleared_buf)
		setpos(maincursor, buffer.len(cleared_buf))
		
		local len = vlqdes(maincursor)
		
		log(`Clearing {len} table(s).`)
		
		for i = 1, len do 
			local id = vlqdes(maincursor)
			
			local original = idtovalue[id]
			if original then table.clear(original) end
		end
	end
	
	local newbufs_buf = modifications[MAP_NEW_BUFFERS]
	if newbufs_buf then

		setbuf(maincursor, newbufs_buf)
		setpos(maincursor, buffer.len(newbufs_buf))

		local len = vlqdes(maincursor)
		
		log(`Allocating {len} new buffer(s).`)
		
		for _ = 1, len do
			local id = vlqdes(maincursor)
			local buf = bufferSerdes.des(maincursor)
			
			idtovalue[id] = buf :: any
			valuetoid[buf :: any] = id
			
			print(`received a new buffer with id:{id}`)
		end
	end
	
	local deltas_buf = modifications[MAP_BUFFER_DELTAS]
	if deltas_buf then

		setbuf(maincursor, deltas_buf)
		setpos(maincursor, buffer.len(deltas_buf))

		local len = vlqdes(maincursor)
		
		local cursorbuf = Squish.util.getbuf(maincursor)
				
		log(`Applying deltas to {len} buffer(s).`)
		
		for _ = 1, len do
			local id = vlqdes(maincursor)
			local regioncount = vlqdes(maincursor)
						
			local original = idtovalue[id]
			if original and typeof(original) == "buffer" then
				local lastStart = 0
				
				for i = 1, regioncount do
					local rawOffset = vlqdes(maincursor)
					local length = vlqdes(maincursor)
					
					local start = lastStart + rawOffset
					lastStart = start
					
					local pos = getpos(maincursor) - length
					buffer.copy(original, start, cursorbuf, pos, length)
					setpos(maincursor, pos)
				end
				
				local signal = valuetosignal[original] :: BufferChangeSignal
				if signal then signal:FireDeferred(original) end
			else
				warn(`Couldn't find a buffer associated with id:{id}{if original then ", a table has this id." else ""}`)
				
				for _ = 1, regioncount do 
					vlqdes(maincursor)
					
					local length = vlqdes(maincursor)
					setpos(maincursor, getpos(maincursor) - length)
				end
			end
		end
	end
	
	local newtables_buf = modifications[MAP_NEW_TABLES]
	if newtables_buf then

		setbuf(maincursor, newtables_buf)
		setpos(maincursor, buffer.len(newtables_buf))

		local idscount = vlqdes(maincursor)
		local idsarray = table.create(idscount, 0)

		-- allocating new tables, backwards.
		-- allocations need to be done first so references to new tables are valid.
		for i = 1, idscount do 
			local id = vlqdes(maincursor)
			local v = {}

			idsarray[i] = id
			
			idtovalue[id] = v 
			valuetoid[v] = id
			
			print(`received a new table with id:{id}`)
		end

		-- deserializing, backwards.
		for i, id in idsarray do 
			local schemaidx = vlqdes(maincursor)
			local v = idtovalue[id]
			
			maincursor.refs = if refs then refs[idscount - (i - 1)] else nil;
			(if schemaidx > 0 then Schemas[schemaidx] else anyTableSerdes).des(maincursor, v)

			maincursor.desdeduplookup = nil
		end
	end
	
	local tabledeltas_buf = modifications[MAP_TABLE_DELTAS]
	if tabledeltas_buf then
		
		setbuf(maincursor, tabledeltas_buf)
		setpos(maincursor, buffer.len(tabledeltas_buf))
		
		checkreplicators = {}

		local count = vlqdes(maincursor)
		
		for i = 0, count - 1 do 
			local id = vlqdes(maincursor)
			local schemaidx = vlqdes(maincursor)

			maincursor.refs = if refs then refs[(refsmax :: number) - i] else nil
			local v = (if schemaidx > 0 then Schemas[schemaidx] else anyTableSerdes).des(maincursor, nil)
			checkreplicators[id] = v 

			maincursor.desdeduplookup = nil
		end
	end

	if (not rootdata) then
		rootdata = idtovalue[rootid]
		if rootdata then print(`received root table with id:{rootid}`) end
	end

	if checkreplicators then
		log("Processing changes.")
		
		for id, replicator in checkreplicators do 
			local original = idtovalue[id]
			
			if original then
				print(`Received replicator for id:{id}`)
				
				local signal = valuetosignal[original] :: TableChangeSignal

				for k, v in replicator do 
					if v == _nilvalue then v = nil end 

					if type(v) == 'table' then
						print(`-> '{k}' has been set to 'table<{valuetoid[v] or "?"}>'`)
					else
						print(`-> '{k}' has been set to '{v}'`)
					end

					rawset(original, k, v)
					if signal then signal:FireDeferred(original, k, v) end
				end
			else 
				warn(`Couldn't find a table associated with id:{id}`)
			end
		end
	end

	if AwaitDataSignal and rootdata then
		log("Firing AwaitDataSignal.")
		AwaitDataSignal:Fire(rootdata)
		AwaitDataSignal:Destroy()
		AwaitDataSignal = __
	end
	
	log("|:| SYNCEE -> DONE")
end

-- Waits for the root replication table of the client to be received from server.
function exposed.AwaitDataAsync(): anyTable
	return if AwaitDataSignal then AwaitDataSignal:Wait() else rootdata
end

-- Returns the root replication table of localplayer.
function exposed.GetData(): anyTable?
	return rootdata
end

-- Returns the table or buffer associated with the provided id if present.
function exposed.GetValueWithId(id: number): anyTable | buffer | nil
	return idtovalue[id]
end

-- Returns id associated with the table or buffer if present.
function exposed.GetIdOfValue(t: anyTable | buffer): number?
	return valuetoid[t]
end

-- Returns boolean indicating if the table or buffer is replicated.
function exposed.IsReplicatedValue(t: anyTable | buffer): boolean
	return not not valuetoid[t]
end

local function GetChangeSignal(v: any)
	if valuetosignal[v] == nil then valuetosignal[v] = CreateSignal( __ ) end 
	return valuetosignal[v]
end

-- Returns signal that fires whenever any key of the replicated table changes.
function exposed.GetTableChangedSignal(t: anyTable): TableChangeSignal
	assertRegisteredTable(t)
	return GetChangeSignal(t)
end

-- Returns signal that fires whenever the content of the buffer changes.
function exposed.GetBufferChangedSignal(b: buffer): BufferChangeSignal
	assertRegisteredBuffer(b)
	return GetChangeSignal(b)
end

return exposed
