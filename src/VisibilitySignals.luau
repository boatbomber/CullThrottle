--!strict
--!optimize 2
--!native

--[[
	This module handles ObjectEnteredView/ObjectExitedView delivery, plus the
	in-view bookkeeping those signals are derived from. An object is in view
	while its lastVisibleClock is nonzero. The ingest passes stamp that clock
	inline every visible frame and hand the flip from out of view to in view to
	markEnteredView, which buffers the entered event and schedules the object
	in the exit sweep's due buckets. Removal evicts through forget. Both
	signals are buffered while the frame's search and ingest passes run and
	fired together at the end of the frame, so a handler can freely mutate the
	tracked set without corrupting an in-progress iteration.

	The exit sweep is organized as due buckets rather than a walk of every
	in-view object. Each in-view object sits in exactly one bucket, the one
	covering its last known grace deadline, and a frame's sweep only opens the
	buckets whose due time has arrived. An object seen again since it was
	scheduled just gets rescheduled at its current deadline, so a steadily
	visible object is touched about once per grace period instead of every
	frame, and the sweep's cost tracks turnover instead of how much is on
	screen.
]]

local types = require(script.Parent.types)
local GoodSignal = require(script.Parent.Utilities.GoodSignal)

local tableCreate = table.create
local tableClear = table.clear

-- This sets how long an object that was visible keeps its place in the in-view
-- set after its voxels stop being visible, before ObjectExitedView fires. This
-- is signal smoothing only, so an object oscillating across the frustum
-- boundary (head bob) doesn't fire entered/exited every frame. A lingering
-- object is not ingested or updated, and re-entry fires no duplicate
-- ObjectEnteredView because its lastVisibleClock never returns to zero while
-- it lingers.
local EXIT_SIGNAL_GRACE_PERIOD = 0.2

-- The due buckets quantize grace deadlines to this period. A bucket only comes
-- due once every deadline it covers has passed, so an exit can fire at most
-- one period late, which is a frame or two against the grace period's 0.2
-- seconds of deliberate smoothing.
local EXIT_SWEEP_BUCKET_PERIOD = 1 / 30

local VisibilitySignals = {}
VisibilitySignals.__index = VisibilitySignals

type VisibilitySignalsProto = {
	-- These are the facade's public signals, injected so this module fires them
	-- without owning them.
	_enteredViewSignal: GoodSignal.Signal<Instance>,
	_exitedViewSignal: GoodSignal.Signal<Instance>,

	-- These are the exit sweep's due buckets, keyed by deadline quantum, each a
	-- compact array with its occupancy tracked alongside. Every in-view object
	-- sits in exactly one bucket (its record stores which, and where), and the
	-- sweep consumes whole buckets as they come due. Emptied bucket arrays are
	-- recycled through the pool.
	_exitSweepBuckets: { [number]: { types.ObjectData } },
	_exitSweepBucketSizes: { [number]: number },
	_nextSweepBucketIndex: number,
	_inViewCount: number,
	_bucketPool: { { types.ObjectData } },
	_bucketPoolSize: number,

	-- Visibility signals are deferred so a handler can't mutate while we're still iterating.
	_pendingEnteredView: { Instance },
	_pendingEnteredViewSize: number,
	_pendingExitedView: { Instance },
	_pendingExitedViewSize: number,
}

export type VisibilitySignals = typeof(setmetatable({} :: VisibilitySignalsProto, VisibilitySignals))

--[[
	Builds the buffers and the empty due buckets around the given
	entered/exited signals.
]]
function VisibilitySignals.new(
	enteredViewSignal: GoodSignal.Signal<Instance>,
	exitedViewSignal: GoodSignal.Signal<Instance>
): VisibilitySignals
	local self = setmetatable({
		_enteredViewSignal = enteredViewSignal,
		_exitedViewSignal = exitedViewSignal,
		_exitSweepBuckets = {},
		_exitSweepBucketSizes = {},
		_nextSweepBucketIndex = 0,
		_inViewCount = 0,
		_bucketPool = {},
		_bucketPoolSize = 0,
		_pendingEnteredView = {},
		_pendingEnteredViewSize = 0,
		_pendingExitedView = {},
		_pendingExitedViewSize = 0,
	}, VisibilitySignals)

	return self
end

--[[
	Schedules the object in the due bucket covering the given grace deadline,
	the first bucket whose due time is at or past it, and records the bucket
	and slot on the object so forget can evict it directly.
]]
function VisibilitySignals.scheduleExitSweep(self: VisibilitySignals, objectData: types.ObjectData, deadline: number)
	local bucketIndex = deadline // EXIT_SWEEP_BUCKET_PERIOD + 1
	local bucket = self._exitSweepBuckets[bucketIndex]
	local slot
	if bucket then
		slot = self._exitSweepBucketSizes[bucketIndex] + 1
	else
		local poolSize = self._bucketPoolSize
		if poolSize > 0 then
			bucket = self._bucketPool[poolSize]
			self._bucketPool[poolSize] = nil
			self._bucketPoolSize = poolSize - 1
		else
			bucket = {}
		end
		self._exitSweepBuckets[bucketIndex] = bucket
		slot = 1
	end
	bucket[slot] = objectData
	self._exitSweepBucketSizes[bucketIndex] = slot
	objectData.exitSweepBucketIndex = bucketIndex
	objectData.exitSweepSlot = slot

	-- The sweep's resume point must never sit past a scheduled entry, or that
	-- entry's bucket would be skipped and its exit lost. Live clocks only move
	-- forward, so this only pulls the resume point back when a caller schedules
	-- against a clock older than one the sweep already advanced past.
	if bucketIndex < self._nextSweepBucketIndex then
		self._nextSweepBucketIndex = bucketIndex
	end
end

--[[
	Records the flip from out of view to in view. It buffers an
	ObjectEnteredView signal for the end-of-frame flush and schedules the
	object in the due bucket covering its grace deadline. The caller stamps
	lastVisibleClock itself, which is what lets the ingest passes inline the
	steady-state stamp and only pay this call on the flip.
]]
function VisibilitySignals.markEnteredView(self: VisibilitySignals, objectData: types.ObjectData, now: number)
	local pendingEnteredViewSize = self._pendingEnteredViewSize + 1
	self._pendingEnteredView[pendingEnteredViewSize] = objectData.object
	self._pendingEnteredViewSize = pendingEnteredViewSize

	local inViewCount = self._inViewCount
	if inViewCount == 0 then
		-- Nothing was scheduled anywhere, and the sweep may not have run for a
		-- long stretch (on-demand mode can idle for minutes), so re-anchor the
		-- sweep at the present rather than letting it walk every empty bucket
		-- index since the last time something was in view.
		local currentBucketIndex = now // EXIT_SWEEP_BUCKET_PERIOD
		if self._nextSweepBucketIndex <= currentBucketIndex then
			self._nextSweepBucketIndex = currentBucketIndex + 1
		end
	end
	self._inViewCount = inViewCount + 1
	self:scheduleExitSweep(objectData, now + EXIT_SIGNAL_GRACE_PERIOD)
end

--[[
	Stamps the object as visible at the given clock, handling the flip from out
	of view to in view through markEnteredView. This is the one-call version of
	what the ingest passes inline on their per-object hot path.
]]
function VisibilitySignals.markVisible(self: VisibilitySignals, objectData: types.ObjectData, now: number)
	if objectData.lastVisibleClock == 0 then
		-- A lastVisibleClock of zero means this object isn't in view (it's
		-- freshly tracked or the exit sweep gave up on it), so it's entering
		-- view now.
		self:markEnteredView(objectData, now)
	end
	objectData.lastVisibleClock = now
end

--[[
	Drops the object from the in-view set without buffering an exit signal.
	This is the removal path's eviction, where ObjectRemoved already covers the
	announcement and a later ObjectExitedView would be spurious. The entry
	swapped into the freed bucket slot carries its stored position along with
	it, and a bucket this empties is recycled through the pool.
]]
function VisibilitySignals.forget(self: VisibilitySignals, objectData: types.ObjectData)
	if objectData.lastVisibleClock == 0 then
		return
	end
	objectData.lastVisibleClock = 0

	local bucketIndex = objectData.exitSweepBucketIndex
	if bucketIndex == 0 then
		return
	end

	local bucket = self._exitSweepBuckets[bucketIndex]
	local bucketSize = self._exitSweepBucketSizes[bucketIndex]
	local slot = objectData.exitSweepSlot
	local swappedData = bucket[bucketSize]
	bucket[slot] = swappedData
	bucket[bucketSize] = nil
	swappedData.exitSweepSlot = slot
	objectData.exitSweepBucketIndex = 0
	objectData.exitSweepSlot = 0
	self._inViewCount -= 1

	if bucketSize == 1 then
		self._exitSweepBuckets[bucketIndex] = nil
		self._exitSweepBucketSizes[bucketIndex] = nil
		local poolSize = self._bucketPoolSize + 1
		self._bucketPool[poolSize] = bucket
		self._bucketPoolSize = poolSize
	else
		self._exitSweepBucketSizes[bucketIndex] = bucketSize - 1
	end
end

--[[
	Sweeps the due buckets up to the given clock. An object seen recently
	enough is rescheduled in the bucket covering its current grace deadline,
	which is the once-per-grace-period touch a steadily visible object pays,
	and an object that stayed out of view past the grace is dropped with an
	ObjectExitedView signal buffered for the end-of-frame flush. A bucket only
	comes due after every deadline it covers has passed, and rescheduling
	always lands past the swept range, so exits fire at most one bucket period
	after their grace expires and the sweep can't chase its own reinsertions.
]]
function VisibilitySignals.signalVisibilityChanges(self: VisibilitySignals, now: number)
	debug.profilebegin("signalVisibilityChanges")

	local currentBucketIndex = now // EXIT_SWEEP_BUCKET_PERIOD
	local nextSweepBucketIndex = self._nextSweepBucketIndex
	if nextSweepBucketIndex > currentBucketIndex then
		debug.profileend()
		return
	end
	local inViewCount = self._inViewCount
	if inViewCount == 0 then
		-- Nothing is scheduled anywhere, so skip straight past the due range
		-- instead of walking empty bucket indices one by one.
		self._nextSweepBucketIndex = currentBucketIndex + 1
		debug.profileend()
		return
	end

	local buckets = self._exitSweepBuckets
	local bucketSizes = self._exitSweepBucketSizes
	local bucketPool = self._bucketPool
	local pendingExitedView = self._pendingExitedView
	local pendingExitedViewSize = self._pendingExitedViewSize

	for bucketIndex = nextSweepBucketIndex, currentBucketIndex do
		local bucket = buckets[bucketIndex]
		if not bucket then
			continue
		end
		local size = bucketSizes[bucketIndex]
		buckets[bucketIndex] = nil
		bucketSizes[bucketIndex] = nil

		for slot = 1, size do
			local objectData = bucket[slot]
			bucket[slot] = nil
			local lastVisibleClock = objectData.lastVisibleClock
			if now - lastVisibleClock < EXIT_SIGNAL_GRACE_PERIOD then
				-- It was seen again after this bucket was scheduled, so its
				-- real deadline moved. Reschedule it there.
				self:scheduleExitSweep(objectData, lastVisibleClock + EXIT_SIGNAL_GRACE_PERIOD)
			else
				-- The object left view and stayed out past the signal grace.
				objectData.lastVisibleClock = 0
				objectData.exitSweepBucketIndex = 0
				objectData.exitSweepSlot = 0
				inViewCount -= 1
				pendingExitedViewSize += 1
				pendingExitedView[pendingExitedViewSize] = objectData.object
			end
		end

		local poolSize = self._bucketPoolSize + 1
		bucketPool[poolSize] = bucket
		self._bucketPoolSize = poolSize
	end

	self._nextSweepBucketIndex = currentBucketIndex + 1
	self._inViewCount = inViewCount
	self._pendingExitedViewSize = pendingExitedViewSize

	debug.profileend()
end

--[[
	Fires the visibility signals buffered during this frame's search/ingest.
	By the time we get here all of CullThrottle's own iteration over the voxels,
	the tracked objects, and the due buckets is finished, so a handler is now
	free to mutate the tracked set (AddObject/RemoveObject) without corrupting
	an in-progress loop. Every entered signal fires before any exited signal,
	which is contract, so a consumer always hears about a replacement before
	the vacancy it fills. We null out each slot as we go so a removed/destroyed
	instance isn't pinned in the buffer until the next frame overwrites it.

	Unlike the visible-objects snapshot and the update iterator, which drop
	instances no longer tracked because they hand back objects for the consumer
	to act on, the flush trusts its buffer and fires every slot. So an entered
	handler that removes another instance still buffered this frame will still
	see that instance's entered event fire, which is intended. The event records
	that the object was visible this frame, and refiltering here would let one
	handler silently cancel a peer's buffered notification.
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
	Rebuilds the pending buffers at their current occupancy and empties the
	bucket pool, so a burst of in-view objects doesn't leave permanently
	oversized arrays behind (a recycled bucket keeps the capacity of the
	biggest batch it ever held until the pool is dropped here). The pending
	signal buffers are recreated empty while their size counters stay put, so
	this may only run while both pending buffers are empty. The driver
	guarantees that by resizing between frames, after the end-of-frame flush
	has drained the buffers and zeroed their counters.
]]
function VisibilitySignals.resizeBuffers(self: VisibilitySignals)
	self._pendingEnteredView = tableCreate(self._pendingEnteredViewSize)
	self._pendingExitedView = tableCreate(self._pendingExitedViewSize)
	tableClear(self._bucketPool)
	self._bucketPoolSize = 0
end

--[[
	Clears the due buckets, the pool, and both pending buffers so everything
	they referenced can be garbage collected.
]]
function VisibilitySignals.destroy(self: VisibilitySignals)
	for _, bucket in self._exitSweepBuckets do
		tableClear(bucket)
	end
	tableClear(self._exitSweepBuckets)
	tableClear(self._exitSweepBucketSizes)
	tableClear(self._bucketPool)
	self._bucketPoolSize = 0
	self._inViewCount = 0
	tableClear(self._pendingEnteredView)
	self._pendingEnteredViewSize = 0
	tableClear(self._pendingExitedView)
	self._pendingExitedViewSize = 0
end

return VisibilitySignals
