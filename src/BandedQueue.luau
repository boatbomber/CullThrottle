--!strict
--!optimize 2
--!native

--[[
	This is the banded priority queue behind the visible-objects stream, which
	the ingest pass stages and the update iterator drains every frame. The
	owner stages each frame's batch in its own arrays with every item's band
	already computed, hands the batch over through enqueueBatch, and a stable
	counting sort lays it out band by band. Dequeues walk that layout front to
	back. Items in different bands dequeue in exact band order, and items that
	share a band dequeue in the order they were staged, so ordering is exact at
	band granularity with staging order breaking ties within a band. Both the
	fill and the drain are straight array walks with no per-item sifting.
	PriorityQueue is the exactly-ordered sibling for workloads that need
	merging, membership checks, or removal by item, none of which this queue
	offers.

	Every band must be an integer in [1, bandCount]. The owner computes bands
	from whatever priority scheme it runs, so the queue never interprets a
	priority value itself, and a NaN anywhere in that scheme must be culled
	before it produces a band (Ingest culls non-finite distances and radii
	before banding anything).

	The queue is built for the ingest workload of one staged batch per frame
	followed by one front-to-back drain. enqueueBatch appends the staged batch
	in band order behind whatever is already laid out, without merging into it,
	so callers clear the queue between frames rather than topping it up
	mid-drain.
]]

local BandedQueue = {}
BandedQueue.__index = BandedQueue

type BandedQueueProto<T> = {
	_bandCount: number,

	-- This is the drain layout, in band order after enqueueBatch. The cursor
	-- marks how far dequeues have walked into it, and a bulk drain through
	-- drainView advances the same cursor directly.
	_items: { T },
	_bands: { number },
	_size: number,
	_cursor: number,

	-- These are the counting sort's per-band tallies, kept all zeros between
	-- fills.
	_bandCounts: { number },

	-- The fill epoch counts every clear, so a drain that captured the layout
	-- can tell when its arrays no longer describe the queue.
	_fillEpoch: number,
}

export type BandedQueue<T> = typeof(setmetatable({} :: BandedQueueProto<T>, BandedQueue))

--[[
	Builds an empty queue over the given number of bands.
]]
function BandedQueue.new<T>(bandCount: number): BandedQueue<T>
	local self = setmetatable({
		_bandCount = bandCount,
		_items = {},
		_bands = {},
		_size = 0,
		_cursor = 0,
		_bandCounts = table.create(bandCount, 0),
		_fillEpoch = 0,
	}, BandedQueue)

	return self
end

--[[
	Lays a staged batch out into the queue proper in band order, using a stable
	counting sort over the caller's precomputed bands. Walking the batch in
	staged order at each step keeps items that share a band in their staged
	(FIFO) order. The caller's arrays are only read, never kept or written, so
	the caller reuses or clears them freely afterward.
]]
function BandedQueue.enqueueBatch<T>(self: BandedQueue<T>, items: { T }, bands: { number }, size: number): ()
	if size == 0 then
		return
	end
	local bandCounts = self._bandCounts

	-- Tally how many staged items land in each band. The tallies arrive all
	-- zeros (the constructor zeroes them and the reset below restores that),
	-- so only the touched range needs re-zeroing afterward.
	local maxBand = 1
	for i = 1, size do
		local band = bands[i]
		bandCounts[band] += 1
		if band > maxBand then
			maxBand = band
		end
	end

	-- Turn the tallies into each band's starting output slot (prefix sum).
	local slot = self._size + 1
	for band = 1, maxBand do
		local bandTally = bandCounts[band]
		bandCounts[band] = slot
		slot += bandTally
	end

	-- Scatter each item into its band's slots.
	local queueItems, queueBands = self._items, self._bands
	for i = 1, size do
		local band = bands[i]
		local outputIndex = bandCounts[band]
		bandCounts[band] = outputIndex + 1
		queueItems[outputIndex] = items[i]
		queueBands[outputIndex] = band
	end
	self._size = slot - 1

	-- Restore the all-zeros invariant for the next fill.
	for band = 1, maxBand do
		bandCounts[band] = 0
	end
end

--[[
	Pops and returns (item, band) for the front of the drain layout, which is
	the lowest-banded item staged earliest. Asserts on an empty queue.
]]
function BandedQueue.dequeue<T>(self: BandedQueue<T>): (T, number)
	local cursor = self._cursor + 1
	assert(cursor <= self._size, "Queue is empty")
	self._cursor = cursor
	return self._items[cursor], self._bands[cursor]
end

--[[
	Returns the drain layout for a bulk drain: the items array, the bands
	array, the cursor (how many items are already dequeued), the size, and the
	fill epoch. The caller walks items from cursor + 1 through size in order
	and stores each new position straight into _cursor as it goes, which keeps
	dequeue, len, isEmpty, and any later drain agreed on progress. Before
	every step it must confirm the epoch still matches _fillEpoch, since a
	clear leaves the captured layout describing a queue that no longer exists.
	The arrays stay owned by the queue and must not be written. This exists so
	the per-frame drain pays no per-item method calls.
]]
function BandedQueue.drainView<T>(self: BandedQueue<T>): ({ T }, { number }, number, number, number)
	return self._items, self._bands, self._cursor, self._size, self._fillEpoch
end

--[[
	Returns how many items are left in the queue proper.
]]
function BandedQueue.len<T>(self: BandedQueue<T>): number
	return self._size - self._cursor
end

--[[
	Returns whether the queue proper is empty (fully drained counts as empty).
]]
function BandedQueue.isEmpty<T>(self: BandedQueue<T>): boolean
	return self._cursor >= self._size
end

--[[
	Empties the queue proper, releasing every item reference it holds and
	advancing the fill epoch so any outstanding drain ends instead of walking
	the cleared arrays.
]]
function BandedQueue.clear<T>(self: BandedQueue<T>): ()
	table.clear(self._items)
	table.clear(self._bands)
	self._size = 0
	self._cursor = 0
	self._fillEpoch += 1
end

--[[
	Rebuilds the cleared-without-shrinking layout arrays at their current
	occupancy, preserving contents, so a one-off burst doesn't leave
	permanently oversized arrays whose per-frame clears walk their whole peak
	capacity. The tallies stay as they are, since their size is fixed at the
	band count. The epoch advances because any outstanding drain captured the
	old arrays, which no longer back the queue.
]]
function BandedQueue.resize<T>(self: BandedQueue<T>): ()
	local size = self._size

	local items = table.create(size)
	table.move(self._items, 1, size, 1, items)
	self._items = items

	local bands = table.create(size)
	table.move(self._bands, 1, size, 1, bands)
	self._bands = bands

	self._fillEpoch += 1
end

return BandedQueue
