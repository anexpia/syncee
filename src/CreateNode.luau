--!optimize 2
--!strict

local __: any = nil

local exposed = {	
	Delinked = __ :: (node) -> (),
	AncestryChanged = __ :: ({node}) -> ()
}

local api = {}
api.__index = api

local ksweaktable = {__mode = 'ks'}

export type node = {
	isorigin: boolean?,
	persistent: boolean?,
	
	value: any,
	player: Player?,
	
	origins: {[node]: true},
	
	hasancestrychanged: boolean?,
	awaitingupdate: boolean?,
	
	descend: { [node]: true };
	ascend: { [node]: {[string]: true} };
	
	updateorigins: (node) -> {[node]: true};
	connect: (node, othernode: node, key: any) -> boolean;
	disconnect: (node, othernode: node, key: any) -> boolean;
	disconnectall: (node) -> ();
	destroy: (node) -> ();
}

local function onAncestryChanged(node: node, changed: {node}?)
	node.awaitingupdate = true
	-- needs to be here since updateorigins() may run before ancestry changes are processed
	-- which will cause updateorigins() in main loop
	
	if node.hasancestrychanged then return end 
	node.hasancestrychanged = true

	local isstart = changed == nil 
	changed = changed or {}
	
	table.insert(changed, node)

	for othernode in node.ascend do 
		onAncestryChanged(othernode, changed)
	end
	
	if isstart then exposed.AncestryChanged(changed) end
end

local function recursivegetfrontier(node: node, frontiers: {node}, checked: {[node]: any})
	if checked[node] ~= nil then return end 
	
	local awaiting = node.awaitingupdate
	local isfrontier = (not awaiting) or node.isorigin
	
	checked[node] = if awaiting then (if isfrontier then 0 else false) else true
	
	if isfrontier then
		table.insert(frontiers, node)
	end
	
	if awaiting then
		table.clear(node.origins)
		if isfrontier then node.origins[node] = true end
		
		for parent in node.descend do 
			recursivegetfrontier(parent, frontiers, checked)
		end
	end
end

local function recursiveaddorigins(frontier: node, node: node, checked: {[node]: any})
	local origins = frontier.origins
	
	for subnode in node.ascend do 
		local s = checked[subnode]
		if s == nil or s == true or s == frontier then continue end 
		
		checked[subnode] = frontier
		local subnodeorigins = subnode.origins
		
		for origin in origins do 
			subnodeorigins[origin] = true
		end
		
		recursiveaddorigins(frontier, subnode, checked)
	end
end

local frontiers: {node}, checked: {[node]: any} = {}, {}
local function findallorigins(node: node): {[node]: true}
	
	recursivegetfrontier(node, frontiers, checked)
	for _, node in frontiers do recursiveaddorigins(node, node, checked) end
	
	for node, state in checked do 
		node.awaitingupdate = false
		if not (state or node.persistent) then exposed.Delinked(node) end
	end
	
	table.clear(frontiers)
	table.clear(checked)
	
	return node.origins
end

function api.updateorigins(node: node): {[node]: true}	
	local origins = node.origins

	if node.awaitingupdate then
		findallorigins(node)
	end 
	
	return origins
end

function api.connect(node: node, othernode: node, key: any): boolean?
	if node == othernode then return nil end
	
	local ascend = node.ascend[othernode]
	
	if ascend then
		ascend[key] = true
		return false
	else
		node.ascend[othernode] = {[key] = true}
		othernode.descend[node] = true
		
	    onAncestryChanged(othernode)
		return true
	end
end

function api.disconnect(node: node, othernode: node, key: any): boolean?
	if node == othernode then return nil end
	
	local ascend = node.ascend[othernode]

	if ascend then
		if ascend[key] then
			ascend[key] = nil
			
			if (not next(ascend)) then
				node.ascend[othernode] = nil
				othernode.descend[node] = nil
				
				onAncestryChanged(othernode)
				return true
			end
		end
	end
	
	return false
end

function api.disconnectall(node: node)
	for othernode: node in node.ascend do 
		othernode.descend[node] = nil
		onAncestryChanged(othernode)
	end
	
	table.clear(node.ascend)
end

function api.destroy(node: node)
	for othernode in node.descend do 
		othernode.ascend[node] = nil
	end
	
	for othernode: node in node.ascend do 
		othernode.descend[node] = nil
		onAncestryChanged(othernode)
	end

	table.clear(node.ascend)
	table.clear(node.descend)
	
	node.isorigin = nil :: any
	node.persistent = nil
	node.value = nil
	node.player = nil
end

function exposed.create(value): node
	local node = setmetatable({
		isorigin = nil;
		
		awaitingupdate = true;
		origins = {},
		
		value = value;

		descend = setmetatable({}, ksweaktable);
		ascend = setmetatable({}, ksweaktable);
	}, api) :: any

	return node
end

return exposed