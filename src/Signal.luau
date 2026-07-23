--!optimize 2
--!strict

--[[
	## edited by anexpia •…• ##                                                                                     

	forked ver: v2.9.1

	An insanely fast, lightweight, fully typed and documented
	open-source signal module for Roblox, with custom types.

	GitHub:
	https://github.com/anexpia/SignalPlus
]]--

-- Types

export type Connection = {
	Disconnect: (Connection) -> (),
	Connected: boolean,
}

export type Signal<func, T...> = {
	Connect: (signal: Signal<func, T...>, callback: func) -> Connection,
	Once: (signal: Signal<func, T...>, callback: func) -> Connection,

	Wait: (signal: Signal<func, T...>) -> ...any,

	Fire: (signal: Signal<func, T...>, T...) -> (),
	FireDeferred: (signal: Signal<func, T...>, T...) -> (),

	DisconnectAll: (signal: Signal<func, T...>) -> (),
	Destroy: (signal: Signal<func, T...>) -> (),
}

type anyFunction = (...any) -> ()
export type anySignal = Signal<anyFunction, ...any>
export type IntersectedConnectionTypes = RBXScriptConnection | Connection

type LinkedListNode = {
	Previous: LinkedListNode?,
	Next: LinkedListNode?,
	Tail: LinkedListNode?,
	Id: number
}

type internalSignal = anySignal & LinkedListNode

type internalConnection = Connection & LinkedListNode & {
	Callback: anyFunction?,
	Thread: thread?,
	Signal: internalSignal,
}

-- GetThread

local freethreads: {thread} = {}
local threadcount = 0 

local identityDelinkThread = task.spawn(function()
	local f: (...any) -> ...any, v1, v2, v3, v4, v5 = function() end, nil, nil, nil, nil, nil

	while true do 
		local r1, r2, r3, r4, r5 = f(v1, v2, v3, v4, v5)
		f, v1, v2, v3, v4, v5 = coroutine.yield(r1, r2, r3, r4, r5)
	end
end)

-- to prevent the signal getting deleted before it can actually run when the script stops
local function callWithDelinkedIdentity(func, ...)
	local success, r1, r2, r3, r4, r5 = coroutine.resume(identityDelinkThread, func, ...)
	if not success then error(r1, 0) end

	return r1, r2, r3, r4, r5
end

local callfunc = function(func, ...) 
	func(...) 
end

local threadfunc = function()
	local t = coroutine.running()

	while true do
		callfunc(coroutine.yield())

		threadcount += 1
		freethreads[threadcount] = t
	end
end

-- Returns a recyclable thread
local function GetThread(): thread
	local free = freethreads[1]

	if free then 
		if threadcount > 1 then
			freethreads[1] = freethreads[threadcount]
			freethreads[threadcount] = nil
		else 
			freethreads[1] = nil
		end

		threadcount -= 1

		return free
	end

	return callWithDelinkedIdentity(task.spawn, threadfunc) :: thread
end

-- Connection class.
local ConnectionImpl = {}
local WeakConnectionMtbl = {__mode = "v", __index = ConnectionImpl}

local SignalImpl = {}

ConnectionImpl.__index = ConnectionImpl
SignalImpl.__index = SignalImpl

ConnectionImpl.Disconnect = function(connection: internalConnection)
	if not connection.Connected then return end

	local previous, next = connection.Previous, connection.Next
	if previous then previous.Next = next end

	if next then next.Previous = previous 
	else
		local signal = connection.Signal
		signal.Tail = if previous == signal then nil else previous
	end

	setmetatable(connection :: any, WeakConnectionMtbl)	
	connection.Connected = false
end

SignalImpl.Connect = function(signal: internalSignal, callback: anyFunction)
	assert(typeof(callback) == "function", "Function should be provided for connection.")

	local tail = signal.Tail or signal
	local id = signal.Id
	signal.Id = id + 1

	local con = {
		Previous = tail,
		Callback = callback,
		Signal = signal,
		Id = id,

		Connected = true
	} :: internalConnection

	signal.Tail = con
	if tail then tail.Next = con end

	return setmetatable(con, ConnectionImpl)
end

SignalImpl.Once = function(signal: internalSignal, callback: anyFunction)
	assert(typeof(callback) == "function", "Function should be provided for connection.")

	local tail = signal.Tail or signal
	local id = signal.Id
	signal.Id = id + 1

	local con = {
		Previous = tail,
		Thread = coroutine.create(callback),
		Signal = signal,
		Id = id,

		Connected = true,
	} :: internalConnection

	signal.Tail = con
	if tail then tail.Next = con end

	return setmetatable(con, ConnectionImpl)
end

SignalImpl.Wait = function(signal: internalSignal)
	local tail = signal.Tail or signal
	local id = signal.Id
	signal.Id = id + 1

	local thread = coroutine.running()

	local con = {
		Previous = tail,
		Thread = thread,
		Signal = signal,
		Id = id,

		Connected = true,
	} :: internalConnection

	signal.Tail = con
	if tail then tail.Next = con end

	return coroutine.yield()
end

SignalImpl.Fire = function(signal: internalSignal, ...)
	local connection = signal.Next :: internalConnection?
	local maxId = signal.Id

	while connection do
		if connection.Id >= maxId then break end

		if connection.Connected then
			local thread = connection.Thread

			if thread then 
				-- this is either a 'Once' connection or a waiting thread, in both cases, we resume it and remove connection
				ConnectionImpl.Disconnect(connection)

				if coroutine.status(thread) == "suspended" then
					task.spawn(thread, ...)
				end
			else
				task.spawn(GetThread(), connection.Callback, ...)
			end
		end

		connection = connection.Next
	end
end

SignalImpl.FireDeferred = function(signal: internalSignal, ...)
	local connection = signal.Next :: internalConnection?

	while connection do
		local thread = connection.Thread

		if thread then 
			-- this is either a 'Once' connection or a waiting thread, in both cases, we resume it and remove connection
			ConnectionImpl.Disconnect(connection)

			if coroutine.status(thread) == "suspended" then
				task.defer(thread, ...)
			end
		else
			task.defer(GetThread(), connection.Callback, ...)
		end

		connection = connection.Next
	end
end

SignalImpl.DisconnectAll = function(signal: internalSignal)
	local n = signal.Next :: internalConnection? 
	signal.Next = nil
	signal.Tail = nil

	while n do 
		n.Connected = false
		setmetatable(n :: any, WeakConnectionMtbl)

		n = n.Next
	end
end

SignalImpl.Destroy = function(signal: internalSignal)
	SignalImpl.DisconnectAll(signal)
	setmetatable(signal, nil)
end

--[[ 
To define type information correctly for the signal, do like the example below.
-<code>
local __: any = nil
local signal = Signal( __ :: (param1: string, param2: number) -> () )</code>]]
return function<func, T...>(f: func & (T...) -> ())
	return (setmetatable({Id = 0}, SignalImpl) :: any) :: Signal<func, T...>
end 