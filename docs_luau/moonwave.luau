--- @class Syncee
--- Listed API is shared between server and client. For server / client specific API, check their documentation.

--------------------------------------------------------------------------------
-- 1. SHARED
--------------------------------------------------------------------------------

--[=[
	@function RegisterSchema
	@within Syncee
	@param name string
	@param serdes Squish.SerDes<table>
	@return number?
	Registers a table schema for use in serializing replicated tables and returns the id of the schema.
	Same schemas should be registered on both server and client. Schemas are identified by name so order doesn't matter.
]=]

--- @function GetSchemaId
--- @within Syncee
--- @param name string
--- @return number?
--- Returns id of the schema for use in SetSchema().

--- @function GetData
--- @within Syncee
--- @param player Player?
--- @return table?
--- Returns the root replication table of the provided player.\
--- On client, only returns that of the localplayer.

--- @function GetValueWithId
--- @within Syncee
--- @param id number
--- @return (table | buffer)?
--- Returns the table or buffer associated with the provided id if present.

--- @function GetIdOfValue
--- @within Syncee
--- @param t table | buffer
--- @return number?
--- Returns id associated with the table or buffer if present.

--- @function IsReplicatedValue
--- @within Syncee
--- @param t table | buffer
--- @return boolean
--- Returns boolean indicating if the table or buffer is replicated.

--- @function GetTableChangedSignal
--- @within Syncee
--- @param t table
--- @return any -- This is properly typed in the package.
--- Returns signal that fires whenever any key of the replicated table changes.

--- @function GetBufferChangedSignal
--- @within Syncee
--- @param b buffer
--- @return any -- This is properly typed in the package.
--- Returns signal that fires whenever the content of the buffer changes.

--- @function WaitForValue
--- @within Syncee
--- @param t table
--- @param key any
--- @param timeout number?
--- @return any
--- Waits until 'key' of the provided table is not nil, then returns the value.

--- @prop buffer typeof(buffer)
--- @within Syncee
--- Wrapper table for the `buffer` library that automatically handles replication for buffers on the server\
--- You shouldn't use this unless you don't care about performance. Using [`ReplicateBufferRegion`](../api/server#ReplicateBufferRegion) is better.

--------------------------------------------------------------------------------
-- 2. SERVER NAMESPACE
--------------------------------------------------------------------------------

--[=[
	@class server
]=]

--[=[
	@function SetPersistent
	@within server
	@param t table | buffer
	@param state boolean
	Sets whether the provided table or buffer is persistent in syncdata even if not replicated to anyone.\
	This should be used for tables you know are guaranteed to be replicated. so that you have a safety guarantee that Syncee's api wont error on it.
]=]

--[=[
	@function SetSchema
	@within server
	@param t table
	@param schema (number | string)?
	Registers the provided schema to be used for the given table, nil can be provided to remove the schema.\
	This doesn't need the value to be already in Syncee's registry.

	If the schema has sub-schemas, they will be automatically applied to any table present within if they don't have a schema assigned already.
]=]

--[=[
	@function SetRatelimit
	@within server
	@param t table | buffer
	@param ratelimit number?
	Limits the rate of replication for the provided table to atleast 'n' seconds between each replication.\
	This doesn't need the value to be already in syncee's registry.\
	\
	Note that this only applies to the provided table/buffer.
]=]

--- @function Replicate
--- @within server
--- @param t table
--- @param key any
--- Replicates the value of the provided key, even if not changed.

--- @function ReplicateBufferRegion
--- @within server
--- @param buf buffer
--- @param start number
--- @param length number
--- Marks a region of a buffer for delta replication.

--- @function Set
--- @within server
--- @param t table
--- @param key any
--- @param value any
--- Sets 'key' of 't' to 'value', replicates the change then fires TableChangedSignal if present.

--- @function GetDataToReplicate
--- @within server
--- @return {[Player]: buffer}
--- Returns a dictionary mapping each player to a buffer containing the data to replicate to them.

--- @function MarkPlayerLoaded
--- @within server
--- @param player Player
--- Marks the given player as loaded and begins replicating the data to them.

--- @function GetProxy
--- @within server
--- @param t table
--- @return table
--- Returns a proxy for the provided table that automatically runs Syncee.server.Set() upon any changes.

--- @function ProxyToTable
--- @within server
--- @param proxy table
--- @return table?
--- Returns the original table that this proxy is bound to, if it exists.

--- @function Clear
--- @within server
--- @param t table
--- table.clear(), but replicates the changes if on server. Does not fire change signal.

--- @function Insert
--- @within server
--- @param t table
--- @param posOrValue any
--- @param value any?
--- table.insert(), but replicates the changes if on server and fires change signal.

--- @function Remove
--- @within server
--- @param t table
--- @param pos number?
--- @return any
--- table.remove(), but replicates the changes if on server and fires change signal.

--- @function GetRecipients
--- @within server
--- @param t table | buffer
--- @return {Player}
--- Returns the players this table/buffer is replicated to.

--------------------------------------------------------------------------------
-- 3. CLIENT NAMESPACE
--------------------------------------------------------------------------------

--[=[
	@class client
]=]

--- @function DataReceived
--- @within client
--- @param b buffer
--- Should be provided the buffer of replicated changes the server sends.

--- @function AwaitDataAsync
--- @within client
--- @return table
--- Waits for the root replication table of the client to be received from server.

--------------------------------------------------------------------------------
-- 4. SERDES NAMESPACE
--------------------------------------------------------------------------------

--[=[
	@class serdes
	Contains preconfigured serdes for handling references to tables and buffers. 
]=]

--- @prop table Squish.SerDes<table>
--- @within serdes
--- For nested tables within custom schemas.

--- @prop buffer Squish.SerDes<buffer>
--- @within serdes
--- For nested buffers within custom schemas.

--- @prop any Squish.SerDes<any>
--- @within serdes
--- Identical to Squish.any(), but overwrites buffer & table serdes with syncee's.

--- @prop anytable Squish.SerDes<table>
--- @within serdes
--- Default serdes used in syncee.