--!strict

--[[
	This is a batched yield-safe signal implementation, based on stravant's
	original GoodSignal but heavily modified for strict typing and a better
	API surface. Behavior matches a normal RBXScriptSignal, apart from a couple
	extra stack frames at the bottom of the stack trace when an error is
	thrown. Runner coroutines are cached, so yielding in signal handlers costs
	little over a signal that either always or never spawns a thread.

	A signal is parameterized by the argument pack that Fire sends and
	connected handlers receive.

		local sig: Signal.Signal<number, string> = Signal.new()
		local connection = sig:Connect(function(count, label) end)
		sig:Fire(5, "hello")
		local count, label = sig:Wait()
		local hasConnections = sig:HasConnections()
		connection:Disconnect()
		sig:DisconnectAll()

	The original GoodSignal is by stravant (2021) and is licensed under the MIT
	licence. The strict typing and API changes are by boatbomber (2026).
]]

-- The currently idle thread to run the next handler on. This cache is shared
-- by every signal, so it lives at module level.
local freeRunnerThread: thread? = nil

--[[
	Acquires the currently idle handler runner thread, runs fn on it, and then
	releases the thread, returning it to being the currently idle one. If
	another runner thread became idle while fn ran, restoring ours on top of it
	just drops that one to be GCed, which is okay.
]]
local function acquireRunnerThreadAndCallEventHandler<T...>(fn: (T...) -> (), ...: T...)
	local acquiredRunnerThread = freeRunnerThread
	freeRunnerThread = nil
	fn(...)
	freeRunnerThread = acquiredRunnerThread
end

--[[
	The coroutine runner that we create coroutines of. The coroutine can be
	repeatedly resumed with functions to run followed by the arguments to run
	them with. We can't use the arguments the coroutine was first resumed with
	for a handler call, because those would stay on the stack for the duration
	of the thread's existence, temporarily leaking references, and without
	access to raw bytecode there's no way to clear the "..." references from
	the stack. That's why the loop leads with a bare coroutine.yield instead.
]]
local function runEventHandlerInFreeThread()
	while true do
		acquireRunnerThreadAndCallEventHandler(coroutine.yield())
	end
end

--[[
	T... is the argument pack that Fire sends and connected handlers receive.
	Signals and connections are plain tables that carry their methods directly,
	because the typechecker can't parameterize typeof(setmetatable(...)) and
	won't look through __index when matching a structural type, which rules out
	a generic metatable class. The method implementations are defined once at
	module level as functions generic in T... and shared by every signal, so
	creating a signal allocates no closures and the method values are identical
	across all signals. Property slots are invariant and won't accept the
	generic functions directly, so Signal.new pins each one to its own T...
	through an annotated local before storing it. The underscore fields are
	implementation details, present in the types so the method bodies typecheck
	through self, not for external use.
]]
export type Signal<T... = ...any> = {
	Connect: (self: Signal<T...>, fn: (T...) -> ()) -> Connection<T...>,
	Once: (self: Signal<T...>, fn: (T...) -> ()) -> Connection<T...>,
	Wait: (self: Signal<T...>) -> T...,
	Fire: (self: Signal<T...>, T...) -> (),
	DisconnectAll: (self: Signal<T...>) -> (),
	HasConnections: (self: Signal<T...>) -> boolean,
	_handlerListHead: Connection<T...>?,
	_connectionCount: number,
}

export type Connection<T... = ...any> = {
	Connected: boolean,
	Disconnect: (self: Connection<T...>) -> (),
	_signal: Signal<T...>,
	_fn: (T...) -> (),
	_next: Connection<T...>?,
}

--[[
	Disconnects the connection so its handler no longer runs when the signal
	fires. Disconnecting an already disconnected connection is a no-op.
]]
local function Disconnect<T...>(self: Connection<T...>)
	-- Without this guard a second Disconnect would decrement the count again,
	-- undercounting the remaining live handlers.
	if not self.Connected then
		return
	end

	self.Connected = false
	self._signal._connectionCount -= 1

	-- Unhook the node but don't clear it, so a fire call currently sitting on it
	-- can still iterate forward while later fires skip it.
	if self._signal._handlerListHead == self then
		self._signal._handlerListHead = self._next
	else
		local prev = self._signal._handlerListHead
		while prev and prev._next ~= self do
			prev = prev._next
		end
		if prev then
			prev._next = self._next
		end
	end
end

--[[
	Connects fn to run on every Fire with the fired arguments. The new
	connection is prepended to the handler list. Its _next picks up the old
	head (or nil for an empty list), so no branching is needed.
]]
local function Connect<T...>(self: Signal<T...>, fn: (T...) -> ()): Connection<T...>
	-- The connection's Disconnect slot is invariant at this signal's T..., so
	-- the shared generic implementation gets pinned through an annotated local
	-- first. This copies a reference, it does not create a function.
	local disconnect: (self: Connection<T...>) -> () = Disconnect

	self._connectionCount += 1
	local connection: Connection<T...> = {
		Connected = true,
		Disconnect = disconnect,
		_signal = self,
		_fn = fn,
		_next = self._handlerListHead,
	}
	self._handlerListHead = connection
	return connection
end

--[[
	Returns whether any handler is currently connected. Connect, Disconnect,
	and DisconnectAll maintain the count this reads.
]]
local function HasConnections<T...>(self: Signal<T...>): boolean
	return self._connectionCount > 0
end

--[[
	Disconnects all handlers. Since we use a linked list it suffices to clear
	the reference to the head handler, but each node is also marked
	disconnected so a Disconnect call on one of them later doesn't drive the
	count negative.
]]
local function DisconnectAll<T...>(self: Signal<T...>)
	local item = self._handlerListHead
	while item do
		item.Connected = false
		item = item._next
	end
	self._connectionCount = 0
	self._handlerListHead = nil
end

--[[
	Fires the signal, running every connected handler with the given arguments
	on the cached runner thread. Whenever that thread yields without returning
	to us it has been taken over by the Roblox scheduler, so the next handler
	gets a freshly made runner.
]]
local function Fire<T...>(self: Signal<T...>, ...: T...)
	local item = self._handlerListHead
	while item do
		if item.Connected then
			local currentThread: thread
			if freeRunnerThread then
				currentThread = freeRunnerThread
			else
				-- A fresh runner gets resumed to its first yield, ready for work.
				currentThread = coroutine.create(runEventHandlerInFreeThread)
				freeRunnerThread = currentThread
				coroutine.resume(currentThread)
			end
			task.spawn(currentThread, item._fn, ...)
		end
		item = item._next
	end
end

--[[
	Yields the calling thread until the signal next fires, then returns the
	fired arguments. This works through a temporary connection that
	disconnects itself and resumes the waiting thread.
]]
local function Wait<T...>(self: Signal<T...>): T...
	local waitingCoroutine = coroutine.running()
	local cn
	cn = Connect(self, function(...)
		cn:Disconnect()
		task.spawn(waitingCoroutine, ...)
	end)
	return coroutine.yield()
end

--[[
	Connects fn to run on the next Fire only. The connection disconnects
	itself before running the handler, and it can also be disconnected
	manually before it ever runs.
]]
local function Once<T...>(self: Signal<T...>, fn: (T...) -> ()): Connection<T...>
	local cn
	cn = Connect(self, function(...)
		if cn.Connected then
			cn:Disconnect()
		end
		fn(...)
	end)
	return cn
end

local Signal = {}

--[[
	Builds a new signal carrying the shared method implementations. The method
	slots are invariant at this signal's T... and won't accept the generic
	functions directly, so each one is pinned through an annotated local. The
	locals copy references, no functions are created here.
]]
function Signal.new<T...>(): Signal<T...>
	local connect: (self: Signal<T...>, fn: (T...) -> ()) -> Connection<T...> = Connect
	local once: (self: Signal<T...>, fn: (T...) -> ()) -> Connection<T...> = Once
	local wait: (self: Signal<T...>) -> T... = Wait
	local fire: (self: Signal<T...>, T...) -> () = Fire
	local disconnectAll: (self: Signal<T...>) -> () = DisconnectAll
	local hasConnections: (self: Signal<T...>) -> boolean = HasConnections

	return {
		Connect = connect,
		Once = once,
		Wait = wait,
		Fire = fire,
		DisconnectAll = disconnectAll,
		HasConnections = hasConnections,
		_handlerListHead = nil,
		_connectionCount = 0,
	}
end

return Signal
