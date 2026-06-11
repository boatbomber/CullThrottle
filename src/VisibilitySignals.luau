--!strict
--!optimize 2
--!native

--[[
	This module handles ObjectEnteredView/ObjectExitedView delivery, plus the
	in-view set those signals are derived from. It is the only writer of that
	set, through markVisible on ingest, the exit sweep, and forget on removal.
	Both signals are buffered while the frame's search and ingest passes run
	and fired together at the end of the frame, so a handler can freely mutate
	the tracked set without corrupting an in-progress iteration.
]]

local types = require(script.Parent.types)
local GoodSignal = require(script.Parent.Utilities.GoodSignal)

local tableCreate = table.create
local tableMove = table.move
local tableClear = table.clear

-- This sets how long an object that was visible keeps its place in the in-view
-- set after its voxels stop being visible, before ObjectExitedView fires. This
-- is signal smoothing only, so an object oscillating across the frustum
-- boundary (head bob) doesn't fire entered/exited every frame. A lingering
-- object is not ingested or updated, and re-entry fires no duplicate
-- ObjectEnteredView because its lastVisibleClock never returns to zero while
-- it lingers.
local EXIT_SIGNAL_GRACE_PERIOD = 0.2

local VisibilitySignals = {}
VisibilitySignals.__index = VisibilitySignals

type VisibilitySignalsProto = {
	-- These are the facade's public signals, injected so this module fires them
	-- without owning them.
	_enteredViewSignal: GoodSignal.Signal<Instance>,
	_exitedViewSignal: GoodSignal.Signal<Instance>,

	-- These are the objects currently in view (lastVisibleClock ~= 0), kept as a
	-- compact array so the exit scan touches only in-view objects instead of
	-- every tracked one.
	_objectsInView: { types.ObjectData },
	_objectsInViewSize: number,

	-- Visibility signals are deferred so a handler can't mutate while we're still iterating.
	_pendingEnteredView: { Instance },
	_pendingEnteredViewSize: number,
	_pendingExitedView: { Instance },
	_pendingExitedViewSize: number,
}

export type VisibilitySignals = typeof(setmetatable({} :: VisibilitySignalsProto, VisibilitySignals))

--[[
	Builds the buffers around the given entered/exited signals.
]]
function VisibilitySignals.new(
	enteredViewSignal: GoodSignal.Signal<Instance>,
	exitedViewSignal: GoodSignal.Signal<Instance>
): VisibilitySignals
	local self = setmetatable({
		_enteredViewSignal = enteredViewSignal,
		_exitedViewSignal = exitedViewSignal,
		_objectsInView = {},
		_objectsInViewSize = 0,
		_pendingEnteredView = {},
		_pendingEnteredViewSize = 0,
		_pendingExitedView = {},
		_pendingExitedViewSize = 0,
	}, VisibilitySignals)

	return self
end

--[[
	Stamps the object as visible at the given clock. On the flip from out of
	view to in view it also takes the object into the in-view set and buffers
	an ObjectEnteredView signal for the end-of-frame flush. Both ingest passes
	call this for every visible object.
]]
function VisibilitySignals.markVisible(self: VisibilitySignals, objectData: types.ObjectData, now: number)
	if objectData.lastVisibleClock == 0 then
		-- A lastVisibleClock of zero means this object isn't in the in-view set
		-- (it's freshly tracked or the exit sweep zeroed it), so it's entering
		-- view now.
		local pendingEnteredViewSize = self._pendingEnteredViewSize + 1
		self._pendingEnteredView[pendingEnteredViewSize] = objectData.object
		self._pendingEnteredViewSize = pendingEnteredViewSize

		local objectsInViewSize = self._objectsInViewSize + 1
		self._objectsInView[objectsInViewSize] = objectData
		self._objectsInViewSize = objectsInViewSize
		objectData.inViewIndex = objectsInViewSize
	end
	objectData.lastVisibleClock = now
end

--[[
	Drops the object from the in-view set without buffering an exit signal.
	This is the removal path's eviction, where ObjectRemoved already covers the
	announcement and a later ObjectExitedView would be spurious. The entry
	swapped into the freed slot carries its stored index along with it.
]]
function VisibilitySignals.forget(self: VisibilitySignals, objectData: types.ObjectData)
	if objectData.lastVisibleClock == 0 then
		return
	end
	objectData.lastVisibleClock = 0

	local inViewIndex = objectData.inViewIndex
	if inViewIndex == 0 then
		return
	end

	local objectsInView = self._objectsInView
	local inViewSize = self._objectsInViewSize
	local swappedData = objectsInView[inViewSize]
	objectsInView[inViewIndex] = swappedData
	objectsInView[inViewSize] = nil
	swappedData.inViewIndex = inViewIndex
	objectData.inViewIndex = 0
	self._objectsInViewSize = inViewSize - 1
end

--[[
	Sweeps the in-view set. Objects seen recently enough keep their place, and
	objects that stayed out of view past the exit grace period are swap-removed
	with an ObjectExitedView signal buffered for the end-of-frame flush.
]]
function VisibilitySignals.signalVisibilityChanges(self: VisibilitySignals, now: number)
	debug.profilebegin("signalVisibilityChanges")
	local objectsInView = self._objectsInView
	local size = self._objectsInViewSize
	local pendingExitedView = self._pendingExitedView
	local pendingExitedViewSize = self._pendingExitedViewSize

	local index = 1
	while index <= size do
		local objectData = objectsInView[index]
		if now - objectData.lastVisibleClock < EXIT_SIGNAL_GRACE_PERIOD then
			index += 1
		else
			-- The object left view and stayed out past the signal grace. We
			-- swap-remove it and leave index where it is, so the entry swapped
			-- into this slot gets checked on the next loop iteration. The swapped
			-- entry carries its stored index along with it.
			objectData.lastVisibleClock = 0
			pendingExitedViewSize += 1
			pendingExitedView[pendingExitedViewSize] = objectData.object
			local swappedData = objectsInView[size]
			objectsInView[index] = swappedData
			objectsInView[size] = nil
			swappedData.inViewIndex = index
			objectData.inViewIndex = 0
			size -= 1
		end
	end

	self._objectsInViewSize = size
	self._pendingExitedViewSize = pendingExitedViewSize

	debug.profileend()
end

--[[
	Fires the visibility signals buffered during this frame's search/ingest.
	By the time we get here all of CullThrottle's own iteration over the voxels,
	the tracked objects, and the in-view set is finished, so a handler is now
	free to mutate the tracked set (AddObject/RemoveObject) without corrupting
	an in-progress loop. Every entered signal fires before any exited signal,
	which is contract, so a consumer always hears about a replacement before
	the vacancy it fills. We null out each slot as we go so a removed/destroyed
	instance isn't pinned in the buffer until the next frame overwrites it.
]]
function VisibilitySignals.flushVisibilitySignals(self: VisibilitySignals)
	debug.profilebegin("flushVisibilitySignals")

	local enteredView = self._enteredViewSignal
	local pendingEnteredView = self._pendingEnteredView
	local enteredCount = self._pendingEnteredViewSize
	self._pendingEnteredViewSize = 0
	for i = 1, enteredCount do
		local object = pendingEnteredView[i]
		pendingEnteredView[i] = nil
		enteredView:Fire(object)
	end

	local exitedView = self._exitedViewSignal
	local pendingExitedView = self._pendingExitedView
	local exitedCount = self._pendingExitedViewSize
	self._pendingExitedViewSize = 0
	for i = 1, exitedCount do
		local object = pendingExitedView[i]
		pendingExitedView[i] = nil
		exitedView:Fire(object)
	end

	debug.profileend()
end

--[[
	Rebuilds the buffers at their current occupancy so a burst of in-view
	objects doesn't leave permanently oversized arrays behind. The in-view set
	is carried over, but the pending signal buffers are recreated empty while
	their size counters stay put, so this may only run while both pending
	buffers are empty. The driver guarantees that by resizing between frames,
	after the end-of-frame flush has drained the buffers and zeroed their
	counters.
]]
function VisibilitySignals.resizeBuffers(self: VisibilitySignals)
	local objectsInViewSize = self._objectsInViewSize
	local objectsInView = tableCreate(objectsInViewSize)
	tableMove(self._objectsInView, 1, objectsInViewSize, 1, objectsInView)
	self._objectsInView = objectsInView

	self._pendingEnteredView = tableCreate(self._pendingEnteredViewSize)
	self._pendingExitedView = tableCreate(self._pendingExitedViewSize)
end

--[[
	Clears the in-view set and both pending buffers so everything they
	referenced can be garbage collected.
]]
function VisibilitySignals.destroy(self: VisibilitySignals)
	tableClear(self._objectsInView)
	self._objectsInViewSize = 0
	tableClear(self._pendingEnteredView)
	self._pendingEnteredViewSize = 0
	tableClear(self._pendingExitedView)
	self._pendingExitedViewSize = 0
end

return VisibilitySignals
