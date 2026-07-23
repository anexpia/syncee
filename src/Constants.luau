--!optimize 2
--!strict

local Squish = require("../luau_packages/squish")
local CreateSignal = require("./Signal")

local __: any = nil

export type anyTable = {[any]: any}
export type TableChangeSignal = typeof(CreateSignal( __ :: (t: anyTable, k: any, v: any) -> () ))
export type BufferChangeSignal = typeof(CreateSignal( __ :: (b: buffer) -> () ))

local tokens = {
	nilvalue = newproxy(true),
}

for k, v in tokens :: any do 
	local name = `<{string.upper(k)}>`
	getmetatable(v).__tostring = function() return name end
end

local _nilvalue = tokens.nilvalue

local anySerdes 
local anyTableSerdes

local TableReferenceSerdes: Squish.SerDes<anyTable> = {
	type = "table",
	
	ser = function() error("TableReference serialization isn't available on the client.", 0) end,
	des = function() error("TableReference deserialization isn't available on the server.", 0) end
}

local BufferReferenceSerdes: Squish.SerDes<buffer> = {
	type = "buffer",

	ser = function() error("BufferReference serialization isn't available on the client.", 0) end,
	des = function() error("BufferReference deserialization isn't available on the server.", 0) end
}


do 
	local any = Squish.any()
	local multypeinfo = any.multypeinfo :: any
	local toindex, toserdes = table.clone(multypeinfo.toindex :: {[string]: number}), table.clone(multypeinfo.toserdes :: {Squish.SerDes<any>})

	toserdes[toindex.table] = TableReferenceSerdes
	toserdes[toindex.buffer] = BufferReferenceSerdes

	anySerdes = Squish.anyFrom(toindex, toserdes, {}, {}, nil, true)
	anyTableSerdes = Squish.table(anySerdes)

	Squish.addliterals(anySerdes, _nilvalue)
end

local DataSerdes = Squish.map(Squish.vlq(), Squish.buffer())

local Schemas: {Squish.SerDes<any>} = {[0] = anyTableSerdes}
local SchemaNameToIdx: {[string]: number} = {default = 0}
local PendingSchemas: {[string]: Squish.SerDes<any>} = {}

return {
	nilvalue = _nilvalue,

	anySerdes = anySerdes,
	anyTableSerdes = anyTableSerdes,
	TableReferenceSerdes = TableReferenceSerdes,
	BufferReferenceSerdes = BufferReferenceSerdes,
	DataSerdes = DataSerdes,

	Schemas = Schemas,
	SchemaNameToIdx = SchemaNameToIdx,
	PendingSchemas = PendingSchemas,
}
