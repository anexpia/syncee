--!optimize 2
--!strict

local LogService = game:GetService("LogService")
local RS = game:GetService("RunService")

local Squish = require("../luau_packages/squish")
local CreateSignal = require("./Signal")

local Constants = require("./Constants")

local _nilvalue = Constants.nilvalue

local u8, vlqdes = Squish.u8(), Squish.vlq().des
local bufferSerdes = Squish.buffer()

local setpos, getpos = Squish.util.setpos, Squish.util.getpos

local anyTableSerdes = Constants.anyTableSerdes
local dataSerdes = Constants.DataSerdes
local Schemas = Constants.Schemas

local __: any = nil

type anyTable = Constants.anyTable
type TableChangeSignal = Constants.TableChangeSignal
type BufferChangeSignal = Constants.BufferChangeSignal

local exposed = {}

local debuggingEnabled = if true then RS:IsStudio() else false

local AwaitDataSignal = CreateSignal( __ )
local data: anyTable
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


-- Should be provided the buffer of replicated changes the server sends.
function exposed.DataReceived(b: buffer)
	log("|:| SYNCEE -> DATA RECEIVED")

	local modifications = dataSerdes.des(Squish.frombuffer(b))
	
	-- handle special maps
	-- [0] = deletions
	-- [1] = clearing
	-- [2] = new buffers
	-- [3] = buffer deltas
	-- [4] and beyond is unreserved.
	
	local checkreplicators: {[number]: {[any]: any}}

	local removed_buf = modifications[0]
	if removed_buf then
		
		local cursor = Squish.frombuffer(removed_buf)
		local len = vlqdes(cursor)
		
		log(`Deleting {len} table(s) and/or buffer(s).`)
		
		for i = 1, len do 
			local id = vlqdes(cursor)			
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

		modifications[0] = nil
	end

	local cleared_buf = modifications[1]
	if cleared_buf then

		local cursor = Squish.frombuffer(cleared_buf)
		local len = vlqdes(cursor)
		
		log(`Clearing {len} table(s).`)
		
		for i = 1, len do 
			local id = vlqdes(cursor)
			
			local original = idtovalue[id]
			if original then table.clear(original) end
		end
		
		modifications[1] = nil
	end
	
	local newbufs_buf = modifications[2]
	if newbufs_buf then
		local cursor = Squish.frombuffer(newbufs_buf)
		local len = vlqdes(cursor)
		
		log(`Allocating {len} new buffer(s).`)
		
		for _ = 1, len do
			local id = vlqdes(cursor)
			local buf = bufferSerdes.des(cursor)
			
			idtovalue[id] = buf :: any
			valuetoid[buf :: any] = id
			
			print(`received a new buffer with id:{id}`)
		end
		
		modifications[2] = nil
	end
	
	local deltas_buf = modifications[3]
	if deltas_buf then
		local cursor = Squish.frombuffer(deltas_buf)
		local len = vlqdes(cursor)
		
		local cursorbuf = Squish.util.getbuf(cursor)
				
		log(`Applying deltas to {len} buffer(s).`)
		
		for _ = 1, len do
			local id = vlqdes(cursor)
			local regioncount = vlqdes(cursor)
						
			local original = idtovalue[id]
			if original and typeof(original) == "buffer" then
				local lastStart = 0
				
				for i = 1, regioncount do
					local rawOffset = vlqdes(cursor)
					local length = vlqdes(cursor)
					
					local start = lastStart + rawOffset
					lastStart = start
					
					local pos = getpos(cursor) - length
					buffer.copy(original, start, cursorbuf, pos, length)
					setpos(cursor, pos)
				end
				
				local signal = valuetosignal[original] :: BufferChangeSignal
				if signal then signal:FireDeferred(original) end
			else
				warn(`Couldn't find a buffer associated with id:{id}{if original then ", a table has this id." else ""}`)
				
				for _ = 1, regioncount do 
					vlqdes(cursor)
					
					local length = vlqdes(cursor)
					setpos(cursor, getpos(cursor) - length)
				end
			end
		end
		
		modifications[3] = nil
	end
	
	log("Allocating new tables.")
	
	for id, buf in modifications do 
		local flags = buffer.readu8(buf, buffer.len(buf) - 1)

		if bit32.btest(flags, 1) then
			local v = {}
			idtovalue[id] = v 
			valuetoid[v] = id
			
			if data == nil and bit32.btest(flags, 2) then
				data = v
				print(`received root table with id:{id}`)
			else 
				print(`received a new table with id:{id}`)
			end
		end
	end
	
	log("Deserializing tables.")

	for id, buf in modifications do 
		local cursor = Squish.frombuffer(buf)
		local flags = u8.des(cursor)
		
		local isnewtable = bit32.btest(flags, 1)
		local preallocated = if isnewtable then idtovalue[id] else nil
			
		local schemaidx = vlqdes(cursor)
		local v = (if schemaidx > 0 then Schemas[schemaidx] else anyTableSerdes).des(cursor, preallocated)

		if not isnewtable then
			if not checkreplicators then checkreplicators = {} end
			checkreplicators[id] = v 
			
		end
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

	if AwaitDataSignal and data then
		log("Firing AwaitDataSignal.")
		AwaitDataSignal:FireDeferred(data)
		AwaitDataSignal:Destroy()
		AwaitDataSignal = __
	end
	
	log("|:| SYNCEE -> DONE")
end

-- Waits for the root replication table of the client to be received from server.
function exposed.AwaitDataAsync(): anyTable
	return if AwaitDataSignal then AwaitDataSignal:Wait() else data
end

-- Returns the root replication table of localplayer.
function exposed.GetData(): anyTable?
	return data
end

-- Returns the table or buffer associated with the provided id if present.
function exposed.GetValueWithId(id: number): anyTable | buffer | nil
	return idtovalue[id]
end

-- Returns id associated with the table or buffer if present.
function exposed.GetIdOfValue(t: anyTable | buffer): number?
	return valuetoid[t]
end

-- Returns boolean indicating if the table is replicated.
function exposed.IsReplicatedTable(t: anyTable): boolean
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

-- Waits until 'key' of the provided table is not nil, then returns the value.



return exposed
