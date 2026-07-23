--!optimize 2
--!strict

local RunService = game:GetService("RunService")

local Squish = require("./luau_packages/squish")

local implementation = (if RunService:IsServer() then require("@self/Server") else require("@self/Client")) :: any
local Constants = require("@self/Constants") 

local _nilvalue = Constants.nilvalue

local isServer = RunService:IsServer()
local currentSchemaIdx = 0

--

local __: any = nil
local VALIDATION_ENABLED = false

type anyTable = Constants.anyTable
type TableChangeSignal = Constants.TableChangeSignal
type BufferChangeSignal = Constants.BufferChangeSignal
type Cursor = Squish.Cursor
type SerDes<T> = Squish.SerDes<T>

--

local util = Squish.util
local validation = Squish.validation

local nilSerdes = Squish.Nil()

local pushu1, popu1, tryrealloc = util.pushu1, util.popu1, util.tryrealloc
local pushvlqrealloc, popvlq = util.pushvlqrealloc, util.popvlq
local serbitarr, desbitarr = util.serbitarr, util.desbitarr

local beginValidationScope = validation.beginValidationScope
local exitValidationScope = validation.exitValidationScope
local overrideValidationScopeName = validation.overrideValidationScopeName
local assertSerializeType = validation.assertSerializeType

--

local exposed = {
	server = {},
	client = {},
}

exposed._constants = Constants
exposed.serdes = {
	table = Constants.TableReferenceSerdes,
	buffer = Constants.BufferReferenceSerdes,
	
	any = Constants.anySerdes,
	anytable = Constants.anyTableSerdes,
	
	replicationarray = Constants.DataSerdes,
}

-- server

exposed.server.SetPersistent = implementation.SetPersistent :: typeof(
	-- Sets whether the provided table or buffer is persistent in syncdata even if not replicated to anyone.
	-- This should be used for tables you know are guaranteed to be replicated. so that you have a safety guarantee that Syncee's api wont error on it.
	function(t: anyTable | buffer, state: boolean) 
		return __ end
)

exposed.server.SetSchema = implementation.SetSchema :: typeof(
	-- Registers the provided schema to be used for the given table, nil can be provided to remove the schema.
	-- This doesn't need the value to be already in Syncee's registry.
	function(t: anyTable, schema_idx: number | string) 
		return __ end
)

exposed.server.SetRatelimit = implementation.SetRatelimit :: typeof(
	-- Limits the rate of replication for the provided table to atleast 'n' seconds between each replication.
	-- This doesn't need the value to be already in syncee's registry. 
	-- -
	-- Note that this only applies to the provided table/buffer.
	function(t: anyTable | buffer, ratelimit: number?) 
		return __ end
)

exposed.server.Replicate = implementation.Replicate :: typeof(
	-- Replicates the value of the provided key, even if not changed.
	function<T>(t: T, key: keyof<T>) 
		return __ end
)

exposed.server.ReplicateBufferRegion = implementation.ReplicateBufferRegion :: typeof(
	-- Marks a region of a buffer for delta replication.
	function(buf: buffer, start: number, length: number) 
		return __ end
)

exposed.server.Set = implementation.Set :: typeof(
	-- Sets 'key' of 't' to 'value', replicates the change then fires TableChangedSignal if present.
	function<T, K>(t: T, key: K & keyof<T>, value: index<T, K>) 
		return __ end
)

exposed.server.GetDataToReplicate = implementation.GetDataToReplicate :: typeof(
	-- Returns a dictionary mapping each player to an array of buffers containing new data to replicate.
	function(): {[Player]: {[number]: buffer}}
		return __ end
)

exposed.server.MarkPlayerLoaded = implementation.MarkPlayerLoaded :: typeof(
	-- Marks the given player as loaded and begins replicating the data to them.
	function(player: Player) 
		return __ end
)

exposed.server.GetProxy = implementation.GetProxy :: typeof(
	-- Returns a proxy for the provided table that automatically runs Syncee.server.set() upon any changes.
	function(t: anyTable): anyTable
		return __ end
)

exposed.server.ProxyToTable = implementation.ProxyToTable :: typeof(
	-- Returns the original table that this proxy is bound to, if it exists.
	function(proxy: anyTable): anyTable?
		return __ end
)

exposed.server.Clear = implementation.Clear :: typeof(
	-- table.clear(), but replicates the changes if on server. Does not fire change signal.
	function(t: anyTable): anyTable?
		return __ end
)

exposed.server.Insert = implementation.Insert :: typeof(
	-- table.insert(), but replicates the changes if on server and fires change signal.
	function(t: anyTable, posOrValue: any, value: any?): ()
		return __ end
)

exposed.server.Remove = implementation.Remove :: typeof(
	-- table.remove(), but replicates the changes if on server and fires change signal.
	function(t: anyTable, posOrValue: any, value: any?): ()
		return __ end
)

exposed.server.GetRecipients = implementation.GetRecipients :: typeof(
	-- Returns the players this table/buffer is replicated to.
	function(t: anyTable | buffer): {Player}
		return __ end
)

-- client

exposed.client.DataReceived = implementation.DataReceived :: typeof(
	-- Should be provided the dictionary of replicated changes the server sends.
	function(modifications: {[number]: buffer}) 
		return __ end
)

exposed.client.AwaitDataAsync = implementation.AwaitDataAsync :: typeof(
	-- Waits for the root replication table of the client to be received from server.
	function(): anyTable
		return __ end
)

-- shared

exposed.GetData = implementation.GetData :: typeof(
	-- Returns the root replication table of the provided player.
	-- On client, only returns that of the localplayer.
	function(player: Player?): anyTable?
		return __ end
)

exposed.GetValueWithId = implementation.GetValueWithId :: typeof(
	-- Returns the table or buffer associated with the provided id if present.
	function(id: number): anyTable | buffer | nil
		return __ end
)

exposed.GetIdOfValue = implementation.GetIdOfValue :: typeof(
	-- Returns id associated with the table or buffer if present.
	function(t: anyTable | buffer): number?
		return __ end
)

exposed.IsReplicatedTable = implementation.IsReplicatedTable :: typeof(
	-- Returns boolean indicating if the table is replicated.
	function(t: anyTable): boolean 
		return __ end
)

exposed.GetTableChangedSignal = implementation.GetTableChangedSignal :: typeof(
	-- Returns signal that fires whenever any key of the replicated table changes.
	function(t: anyTable): TableChangeSignal
		return __ end
)

exposed.GetBufferChangedSignal = implementation.GetBufferChangedSignal :: typeof(
	-- Returns signal that fires whenever the content of the buffer changes.
	function(t: anyTable): BufferChangeSignal
		return __ end
)


-- Waits until 'key' of the provided table is not nil, then returns the value. 
function exposed.WaitForValue<T, K>(t: T, key: K & keyof<T>, timeout: number?): index<T, K>? 
	local t: anyTable = t
	
	if t[key] ~= nil then return t[key] end

	local s = exposed.GetTableChangedSignal(t)
	local thread = coroutine.running()
	local yieldthread

	local c: any c = s:Connect(function(_, changedkey, value)
		if changedkey == key and value ~= nil then
			(c :: any):Disconnect()
			task.spawn(thread, value)
		end
	end)

	if timeout then
		yieldthread = task.delay(timeout, function()
			yieldthread = nil 
			c:Disconnect()

			task.spawn(thread)
		end)
	end

	local result = coroutine.yield()
	if yieldthread then task.cancel(yieldthread) end
	return result
end

local function processSchemaAttribute(name: string, idx: number)
	Constants.SchemaNameToIdx[name] = idx

	local pending = Constants.PendingSchemas[name] 
	if pending then 
		Constants.Schemas[idx] = pending 
		Constants.PendingSchemas[name] = nil
	end
end

if not isServer then
	for name, idx in script.Constants:GetAttributes() do
		processSchemaAttribute(name, idx :: number)
	end

	script.Constants.AttributeChanged:Connect(function(name)
		local idx = tonumber(script.Constants:GetAttribute(name))
		if idx then processSchemaAttribute(name, idx) end
	end)
end

do 
	-- array
	-- essentially copy of squish.array() with extra bitarray.
	
	local function deltaarray<T>(underlyingSerDes: SerDes<T>): SerDes<{T}>
		underlyingSerDes = Squish.unopt(underlyingSerDes)
		
		local push, pop = underlyingSerDes.ser, underlyingSerDes.des
		
		if underlyingSerDes.type == "boolean" then
			return {
				type = "table",
				
				-- 2 bits: 00 = nil, 01 = true, 10 = false, 11 = nilvalue

				ser = function(cursor: Cursor, xs: { any }): ()
					if VALIDATION_ENABLED then beginValidationScope(cursor, "deltaboolarray") assertSerializeType(cursor, xs, "table") end

					local n = table.maxn(xs)

					local bit1array = table.create(n, false) :: {boolean}
					local bit2array = table.create(n, false) :: {boolean}

					for i = 1, n do
						local x = xs[i]

						if VALIDATION_ENABLED then overrideValidationScopeName(cursor, `deltaboolarray i:{i} | val:{x}`) end

						if x ~= nil then
							
							if x == _nilvalue then
								bit1array[i] = true
								bit2array[i] = true
							elseif x then
								bit1array[i] = true
							else
								bit2array[i] = true
							end
						end
					end

					local flagBytes = (n + 7) // 8

					tryrealloc(cursor, flagBytes * 2)

					serbitarr(cursor, bit2array)
					serbitarr(cursor, bit1array)

					pushvlqrealloc(cursor, n)

					if VALIDATION_ENABLED then exitValidationScope(cursor) end
				end,
				des = function(cursor, result: anyTable?): {T?}
					local n = popvlq(cursor)

					local bit1array = desbitarr(cursor, n)
					local bit2array = desbitarr(cursor, n)

					local xs = result or table.create(n, false)
					for i = n, 1, -1 do
						local v1, v2 = bit1array[i], bit2array[i]
						
						if v1 and v2 then xs[i] = _nilvalue
						elseif v1 then xs[i] = true
						elseif not v2 then xs[i] = nil end
					end

					return xs :: any
				end,
			}
		else 
			return {
				type = "table",
				
				-- 2 bits: 00 = nil, 10 = exists, 11 = nilvalue

				ser = function(cursor: Cursor, xs: { any }): ()
					if VALIDATION_ENABLED then beginValidationScope(cursor, "deltaarray") assertSerializeType(cursor, xs, "table") end

					local n = table.maxn(xs)
					
					local existingflags = table.create(n, false) :: {boolean}
					local tokenflags = table.create(n, false) :: {boolean}
					
					for i = 1, n do
						local x = xs[i]

						if VALIDATION_ENABLED then overrideValidationScopeName(cursor, `deltaarray i:{i} | val:{x}`) end
						
						if x ~= nil then
							existingflags[i] = true

							if x == _nilvalue then tokenflags[i] = true
							else push(cursor, x :: any) end
						end
					end
					
					local flagBytes = (n + 7) // 8
					
					tryrealloc(cursor, flagBytes * 2)
					
					serbitarr(cursor, tokenflags)
					serbitarr(cursor, existingflags)

					pushvlqrealloc(cursor, n)

					if VALIDATION_ENABLED then exitValidationScope(cursor) end
				end,
				des = function(cursor, result: anyTable?): {T?}
					local n = popvlq(cursor)
					
					local existingflags = desbitarr(cursor, n)
					local tokenflags = desbitarr(cursor, n)
					
					local xs = result or table.create(n)
					for i = n, 1, -1 do
						if existingflags[i] then
							xs[i] = if tokenflags[i] then _nilvalue else  pop(cursor)
						end
					end
					
					return xs :: any
				end,
			}
		end
	end
	
	-- records
	-- simpler impl of squish.record.

	type anyRecordTable = {[string]: any}

	type StructProperty = {
		name: string,
		ser: index<SerDes<any>, "ser">,
		des: index<SerDes<any>, "des">
	}

	local function reverseArray<T>(t: {T}): {T}
		local len = #t
		local result = table.create(len) 

		for i, v in t do 
			result[len - (i - 1)] = v
		end

		return result
	end

	local function sortPropertyHandler(a1: StructProperty, a2: StructProperty)
		return a1.name < a2.name 
	end

	local function deltarecord(schema: {[string]: SerDes<any>}): SerDes<any>
		local properties: {StructProperty} = {}
		local boolProperties: {any} = {}
		
--		local basicstructure = {}

		for name, serdes in schema do
			local unopt = Squish.unopt(serdes)
			if unopt.type == "boolean" then
				table.insert(boolProperties, name)
			else
				table.insert(properties, {
					name = name,
					ser = unopt.ser,
					des = unopt.des
				})
			end
			
--			basicstructure[name] = false
		end

		table.sort(properties, sortPropertyHandler)
		table.sort(boolProperties)
		
		local reverseproperties = reverseArray(properties)

		local propCount = #properties
		local hasProp = propCount > 0

		local boolCount = #boolProperties
		local hasbool = boolCount > 0
		
		local totalCount = boolCount + propCount
		local flagBytes = (totalCount + 7) // 8

		return {
			type = "table",
			name = "record",
			structure = schema,
			
			-- booleans: 2 bits: 00 = nil, 01 = true, 10 = false, 11 = nilvalue
			-- non-boolean: 2 bits: 00 = nil, 01 = value, 11 = nilvalue

			ser = function(cursor: Cursor, record: anyRecordTable)
				if VALIDATION_ENABLED then beginValidationScope(cursor, "deltarecord") assertSerializeType(cursor, record, "table") end

				local bit1array = table.create(totalCount, false) :: {boolean}
				local bit2array = table.create(totalCount, false) :: {boolean}
		
				if hasProp then
					for i, prop in properties do 
						local v = record[prop.name]
											
						if v ~= nil then
							bit1array[i] = true
							
							if v == _nilvalue then
								bit2array[i] = true
							else 
								prop.ser(cursor, v)
							end
						end
					end
				end
				
				if hasbool then
					for i, prop in boolProperties do 
						local val = record[prop]
						
						local idx = propCount + i
						
						if val == _nilvalue then
							bit1array[idx] = true
							bit2array[idx] = true
						elseif val then
							bit1array[idx] = true
						else
							bit2array[idx] = true
						end
					end
				end

				tryrealloc(cursor, flagBytes * 2)
				serbitarr(cursor, bit2array)
				serbitarr(cursor, bit1array)

				if VALIDATION_ENABLED then exitValidationScope(cursor) end
			end,

			des = function(cursor: Cursor, result: anyTable?): anyTable
				local result = result :: anyTable -- or table.clone(basicstructure)

				local bit1array = desbitarr(cursor, totalCount)
				local bit2array = desbitarr(cursor, totalCount)
				
				for i, name in boolProperties do 
					local idx = propCount + i 
					local v1, v2 = bit1array[idx], bit2array[idx]
					
					if v1 and v2 then result[name] = _nilvalue
					elseif v1 then result[name] = true
					elseif v2 then result[name] = false 
					else result[name] = nil end
				end
				
				for j, prop in reverseproperties do 
					local i = (propCount - j) + 1					
					local value 
					
					if bit1array[i] then
						if bit2array[i] then value = _nilvalue
						else value = prop.des(cursor) end
					end
					
					result[prop.name] = value
				end
				
				return result :: any
			end,
		}
	end
	
	-- map
	-- no need for 3 or 4 states. nil can't be serialized here.
	-- 1 bit: 0 = value, 1 = nilvalue
	
	local function deltamap(keySerDes: SerDes<any>, valueSerDes: SerDes<any>): SerDes<any>
		keySerDes = Squish.unopt(keySerDes)
		valueSerDes = Squish.unopt(valueSerDes)

		return {
			type = "table",

			ser = function(cursor: Cursor, x: {[any]: any})
				if VALIDATION_ENABLED then beginValidationScope(cursor, "deltamap") assertSerializeType(cursor, x, "table") end
				
				local flags = {}
				local n = 0
				
				for k, v in x do 
					if k == _nilvalue then continue end -- why???
					
					n += 1
					
					local v = x[k]
					local isnil = v == _nilvalue
					
					flags[n] = isnil
						
					if not isnil then valueSerDes.ser(cursor, v) end
					
					keySerDes.ser(cursor, k)
				end
				
				local flagBytes = (n + 7) // 8
				
				tryrealloc(cursor, flagBytes)
				serbitarr(cursor, flags, n) 
				pushvlqrealloc(cursor, n)

				if VALIDATION_ENABLED then exitValidationScope(cursor) end
			end,

			des = function(cursor: Cursor, result: anyTable?): {[any]: any}
				
				local n = popvlq(cursor)
				local flags = desbitarr(cursor, n)
				
				local map = result or {}
				
				for i = n, 1, -1 do 
					local key = keySerDes.des(cursor)
					local value
					
					if flags[i] then value = _nilvalue
					else value = valueSerDes.des(cursor) end
					
					if key ~= nil then
						map[key] = value
					end
				end

				return map
			end,
		}
	end
	
	-- general
	-- deltavalueserdes is used with squish.table() atm. squish.table() can't be recreated safely.
	
	local deltaCache: {[SerDes<any>]: SerDes<any>} = setmetatable({}, {__mode = "vk"}) :: any

	local function deltavalueserdes(serdes: SerDes<any>): SerDes<any>
		serdes = Squish.unopt(serdes)
		
		local result = deltaCache[serdes]
		
		if result then return result
		elseif serdes.type == "boolean" then
			-- 4 states
			
			result = {
				ser = function(cursor: Cursor, x: any)
					if VALIDATION_ENABLED then beginValidationScope(cursor, "deltaboolean") end
					
					local num = if x == nil then 0
						elseif x == _nilvalue then 1
						elseif x then 2 
						else 3
					
					tryrealloc(cursor, 1)
					pushu1(cursor, num)
					
					if VALIDATION_ENABLED then exitValidationScope(cursor) end
				end,
				des = function(cursor: Cursor): any
					local val = popu1(cursor)
					
					if val == 0 then return nil
					elseif val == 1 then return _nilvalue
					elseif val == 2 then return true
					else return false end
				end
			} :: SerDes<any>
		elseif serdes.multypeinfo then
			-- insert nil and nilvalue into the variant/literal serdes.
			
			if serdes.name == "literal" then
				result = serdes
				
				Squish.addliterals(result, nil, _nilvalue)
			else
				if not serdes.multypeinfo.literals then
					local info = serdes.multypeinfo
					result = Squish.anyFrom(table.clone(info.toindex :: any), table.clone(info.toserdes :: any), {}, {}, info.hassubtypes, info.numberfastpath)
				else result = serdes end

				Squish.addliterals(result, _nilvalue)
				Squish.addserdes(result, nilSerdes)
			end
		else 
			-- wrap around it
			
			result =  {
				ser = function(cursor: Cursor, x: any)
					if VALIDATION_ENABLED then beginValidationScope(cursor, "deltavalue") end
					
					local num

					if x == nil then num = 0
					elseif x == _nilvalue then num = 1
					else 
						num = 2
						serdes.ser(cursor, x)
					end
					
					tryrealloc(cursor, 1)
					pushu1(cursor, num)


					if VALIDATION_ENABLED then exitValidationScope(cursor) end
				end,
				des = function(cursor: Cursor): any
					local num = popu1(cursor)

					if num == 0 then return nil
					elseif num == 1 then return _nilvalue
					else return serdes.des(cursor) end
				end
			} :: SerDes<any>
		end	
		
		deltaCache[serdes] = result
		
		return result
	end

	local function deltaify(serdes: SerDes<any>): SerDes<any>
		serdes = Squish.unopt(serdes)
		
		local name = serdes.name
		if name == "array" then
			return deltaarray(serdes.structure[1])
			
		elseif name == "map" then
			local a, b = serdes.structure[1], serdes.structure[2]
			return deltamap(a, b)
			
		elseif name == "table" then
			return Squish.table(deltavalueserdes(serdes.structure))
			
		elseif name == "record" then
			return deltarecord(serdes.structure)
		else return serdes end
	end
		
	-- Registers a table schema for use in serializing replicated tables and returns the id of the schema.
	-- Same schemas should be registered on both server and client. Schemas are identified by name so order doesn't matter.
	-- -
	-- <strong>Do not use Squish.any(), Squish.buffer(), or any table serdes (array, map, ...) as a sub-serdes, Syncee.serdes.any/anytable/table/buffer should be used instead.</strong>
	-- -
	-- example: <code>Squish.array(Syncee.serdes.table)</code>
	function exposed.RegisterSchema(name: string, serdes: Squish.SerDes<anyTable>): number?
		Squish.validation.assertIsSerdes(serdes, 2, "Syncee.RegisterSchema()")
		Squish.validation.assertSerdesType(serdes, "table", 2, "Syncee.RegisterSchema()")
		
		serdes = deltaify(serdes)
		
		local id 

		if isServer then
			local id = Constants.SchemaNameToIdx[name]

			if not id then
				currentSchemaIdx += 1
				id = currentSchemaIdx

				Constants.SchemaNameToIdx[name] = id
				script.Constants:SetAttribute(name, id)
			end

			Constants.Schemas[id] = serdes
		else
			id = Constants.SchemaNameToIdx[name]

			if id then Constants.Schemas[id] = serdes
			else Constants.PendingSchemas[name] = serdes end -- cant really insert it until the server provides the id.
		end

		return id
	end
		
end 

-- Returns id of the schema for use in SetSchema().
function exposed.GetSchemaId(name: string): number?
	return Constants.SchemaNameToIdx[name]
end

do
	-- wrapper for buffer library so that people who dont wanna use ReplicateBufferRegion() dont have to use it
	-- buffer regions get coalesced when processed. so we're ok
	
	-- this really shouldn't be used unless you don't care about performance.
	
	local ReplicateBufferRegion = exposed.server.ReplicateBufferRegion
	
	exposed.Buffer = (if isServer then setmetatable({}, {
		__index = function(self, key): any
			local builtinfunc: (buffer, ...any) -> any = (buffer :: anyTable)[key]
			
			if type(builtinfunc) == "function" then
				local wrapper
				
				local fixedLen = tonumber(string.match(key, "%d+$"))
				if fixedLen then
					if string.sub(key, 1, 5) == "write" then
						fixedLen /= 8

						wrapper = function(buf: buffer, offset: number, value: any)
							builtinfunc(buf, offset, value)
							ReplicateBufferRegion(buf, offset, fixedLen)
						end
					else wrapper = builtinfunc end
				elseif key == "writestring" then
					wrapper = function(buf: buffer, offset: number, value: string, count: number?)
						builtinfunc(buf, offset, value, count)
						ReplicateBufferRegion(buf, offset, count or #value)
					end
					
				elseif key == "copy" then
					wrapper = function(target: buffer, targetOffset: number, source: buffer, sourceOffset: number?, count: number?)
						builtinfunc(target, targetOffset, source, sourceOffset, count)
						ReplicateBufferRegion(target, targetOffset, count or (buffer.len(source) - (sourceOffset or 0)))
					end
					
				elseif key == "fill" then
					wrapper = function(buf: buffer, offset: number, value: number, count: number?)
						builtinfunc(buf, offset, value, count)
						ReplicateBufferRegion(buf, offset, count or (buffer.len(buf) - offset))
					end
					
				else
					wrapper = builtinfunc
				end
				
				rawset(self, key, wrapper)
				return wrapper
			end
			
			return nil
		end
	}) else buffer) :: typeof(buffer)
end

-- 

if isServer then
	setmetatable(exposed.client, {__index = function()
		error("Cannot index anything from the client api as this is running on the server.", 0)
	end,})
else 
	setmetatable(exposed.server, {__index = function()
		error("Cannot index anything from the server api as this is running on the client.", 0)
	end,})
end

return exposed