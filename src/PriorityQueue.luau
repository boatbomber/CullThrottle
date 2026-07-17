--!strict
--!native
--[[
    This is PriorityQueue by Ilya Kolbin, from github.com/iskolbin/priorityqueue.

    It was adapted for Luau by boatbomber.

    Lowest priority values come first.

    The heap is 4-ary rather than binary. Slot i's children live at slots
    4i - 2 through 4i + 1 and its parent at (i + 2) // 4, so the tree is half
    as deep. A drained element sinks through half the levels (fewer moves,
    and the four child priorities it scans per level sit adjacent in memory),
    which is the right trade for this queue's workload of batch fills followed
    by budgeted dequeue drains.

    Priorities must be real numbers. A NaN priority fails every heap comparison
    and silently corrupts dequeue order, and the hot enqueue paths deliberately
    don't pay for a guard, so callers keep NaN out (VoxelGrid rejects non-finite
    positions before staging voxel maintenance work).
]]

local PriorityQueue = {}
PriorityQueue.__index = PriorityQueue

type PriorityQueueProto<T> = {
	_items: { T },
	_priorities: { number },
	-- This is the item-to-slot map behind contains/remove/update and the
	-- duplicate skipping.
	_indices: { [T]: number },
	_size: number,

	_incomingBatch: { items: { T }, priorities: { number }, size: number },
}

export type PriorityQueue<T> = typeof(setmetatable({} :: PriorityQueueProto<T>, PriorityQueue))

--[[
	Sinks the element at `from` down toward the leaves until the min-heap property
	holds again. This is the shared core of the bottom-up heapify and of the
	single-node restores after a remove or a dequeue, so each of those sinks only
	the one element that can be out of place rather than re-sinking valid nodes.
	Rather than swapping at every level, the out-of-place element is held aside
	while smaller children shift up into the hole, and it lands with a single
	write at its final slot, which roughly halves the writes per level.
]]
local function sinkElement<T>(items: { T }, priorities: { number }, indices: { [T]: number }, size: number, from: number)
	local index = from
	local item = items[index]
	local priority = priorities[index]
	local firstChild = index * 4 - 2
	while firstChild <= size do
		local smallest = firstChild
		local smallestPriority = priorities[firstChild]
		local lastChild = firstChild + 3
		if lastChild > size then
			lastChild = size
		end
		for child = firstChild + 1, lastChild do
			local childPriority = priorities[child]
			if childPriority < smallestPriority then
				smallest = child
				smallestPriority = childPriority
			end
		end

		if smallestPriority >= priority then
			break
		end

		local smallestItem = items[smallest]
		items[index] = smallestItem
		priorities[index] = smallestPriority
		indices[smallestItem] = index

		index = smallest
		firstChild = index * 4 - 2
	end

	if index ~= from then
		items[index] = item
		priorities[index] = priority
		indices[item] = index
	end
end

--[[
	Builds an empty queue with an empty incoming batch.
]]
function PriorityQueue.new<T>(): PriorityQueue<T>
	local self = setmetatable({
		_items = {},
		_priorities = {},
		_indices = {},
		_size = 0,
		_incomingBatch = { items = {}, priorities = {}, size = 0 },
	}, PriorityQueue)

	return self
end

--[[
	Appends one item to the incoming batch, a cheap staging array that only
	gets heapified when enqueueIncomingBatch runs.
]]
function PriorityQueue.addToIncomingBatch<T>(self: PriorityQueue<T>, item: T, priority: number): ()
	local incomingBatch = self._incomingBatch
	incomingBatch.size += 1
	incomingBatch.items[incomingBatch.size] = item
	incomingBatch.priorities[incomingBatch.size] = priority
end

--[[
	Appends parallel arrays of items and priorities to the incoming batch in
	one bulk move.
]]
function PriorityQueue.addMultipleToIncomingBatch<T>(self: PriorityQueue<T>, items: { T }, priorities: { number }): ()
	local incomingBatch = self._incomingBatch
	local itemsCount = #items
	table.move(items, 1, itemsCount, incomingBatch.size + 1, incomingBatch.items)
	table.move(priorities, 1, itemsCount, incomingBatch.size + 1, incomingBatch.priorities)
	incomingBatch.size += itemsCount
end

--[[
	Heapifies everything staged in the incoming batch into the queue proper.
	The batch is left intact, so pair this with clearIncomingBatch.
]]
function PriorityQueue.enqueueIncomingBatch<T>(self: PriorityQueue<T>): ()
	local incomingBatch = self._incomingBatch
	if incomingBatch.size > 0 then
		self:batchEnqueue(incomingBatch.items, incomingBatch.priorities)
	end
end

--[[
	Empties the incoming batch without touching the queue proper.
]]
function PriorityQueue.clearIncomingBatch<T>(self: PriorityQueue<T>): ()
	local incomingBatch = self._incomingBatch
	incomingBatch.size = 0
	table.clear(incomingBatch.items)
	table.clear(incomingBatch.priorities)
end

--[[
	Bubbles the element at `from` up toward the root until the min-heap
	property holds again, returning its final index. Like sinkElement, the
	moving element is held aside while displaced parents shift down, and it
	lands with a single write at its final slot.
]]
function PriorityQueue.siftup<T>(self: PriorityQueue<T>, from: number)
	local items, priorities, indices = self._items, self._priorities, self._indices
	local index = from
	local item = items[index]
	local priority = priorities[index]
	local parent = (index + 2) // 4
	while index > 1 and priority < priorities[parent] do
		local parentItem = items[parent]
		items[index] = parentItem
		priorities[index] = priorities[parent]
		indices[parentItem] = index
		index = parent
		parent = (index + 2) // 4
	end
	if index ~= from then
		items[index] = item
		priorities[index] = priority
		indices[item] = index
	end
	return index
end

--[[
	Sinks every element from `limit` down to the root into place. Called with
	(size + 2) // 4, the last slot with any children, this is the classic
	O(n) bottom-up heapify.
]]
function PriorityQueue.siftdown<T>(self: PriorityQueue<T>, limit: number)
	local items, priorities, indices, size = self._items, self._priorities, self._indices, self._size
	for index = limit, 1, -1 do
		sinkElement(items, priorities, indices, size, index)
	end
end

--[[
	Inserts one item with the given priority. An item already present is left
	untouched.
]]
function PriorityQueue.enqueue<T>(self: PriorityQueue<T>, item: T, priority: number): PriorityQueue<T>
	local items, priorities, indices = self._items, self._priorities, self._indices
	if indices[item] ~= nil then
		return self
	end
	local size = self._size + 1
	self._size = size
	items[size], priorities[size] = item, priority
	indices[item] = size
	self:siftup(size)
	return self
end

--[[
	Inserts a whole batch (parallel item/priority arrays, skipping nils and
	duplicates) and restores the heap with one bottom-up siftdown, which beats
	per-item siftup for large batches.
]]
function PriorityQueue.batchEnqueue<T>(self: PriorityQueue<T>, itemsBatch: { T }, prioritiesBatch: { number }): ()
	local items, priorities, indices = self._items, self._priorities, self._indices
	local size = self._size
	for i = 1, #itemsBatch do
		local item = itemsBatch[i]
		if item == nil or indices[item] ~= nil then
			continue
		end
		size += 1
		items[size], priorities[size] = item, prioritiesBatch[i]
		indices[item] = size
	end
	self._size = size
	if size > 1 then
		self:siftdown((size + 2) // 4)
	end
end

--[[
	Removes one item from anywhere in the queue (swapping the last element
	into its slot and re-sifting), returning whether it was present. Items
	still in the incoming batch are not consulted.
]]
function PriorityQueue.remove<T>(self: PriorityQueue<T>, item: T): boolean
	local indices = self._indices
	local index = indices[item]
	if index == nil then
		return false
	end

	local size = self._size
	local items, priorities = self._items, self._priorities
	indices[item] = nil
	if size == index then
		items[size], priorities[size] = nil, nil
		self._size = size - 1
	else
		local lastitem = items[size]
		items[index], priorities[index] = items[size], priorities[size]
		items[size], priorities[size] = nil, nil
		indices[lastitem] = index
		size = size - 1
		self._size = size
		if size > 1 then
			-- The swapped-in element can violate the heap in either direction,
			-- so we bubble it up first and then sink that one element from
			-- wherever it landed. Sinking only it keeps this O(log n) instead of
			-- re-sinking every node below its slot.
			sinkElement(items, priorities, indices, size, self:siftup(index))
		end
	end
	return true
end

--[[
	Re-prioritizes an item already in the queue (a remove and then an enqueue),
	returning false when it wasn't present.
]]
function PriorityQueue.update<T>(self: PriorityQueue<T>, item: T, priority: number): boolean
	local ok = self:remove(item)
	if not ok then
		return false
	end

	self:enqueue(item, priority)
	return true
end

--[[
	Pops and returns (item, priority) for the lowest-priority-value item.
	Asserts on an empty queue.
]]
function PriorityQueue.dequeue<T>(self: PriorityQueue<T>): (T, number)
	local size = self._size

	assert(size > 0, "Heap is empty")

	local items, priorities, indices = self._items, self._priorities, self._indices
	local item, priority = items[1], priorities[1]
	indices[item] = nil

	if size > 1 then
		local newitem = items[size]
		items[1], priorities[1] = newitem, priorities[size]
		items[size], priorities[size] = nil, nil
		indices[newitem] = 1
		size = size - 1
		self._size = size
		sinkElement(items, priorities, indices, size, 1)
	else
		items[1], priorities[1] = nil, nil
		self._size = 0
	end

	return item, priority
end

--[[
	Returns (item, priority) for the queue front without removing it.
]]
function PriorityQueue.peek<T>(self: PriorityQueue<T>): (T, number)
	return self._items[1], self._priorities[1]
end

--[[
	Returns the priority at the queue front, or nil when empty.
]]
function PriorityQueue.peekPriority<T>(self: PriorityQueue<T>): number?
	return self._priorities[1]
end

--[[
	Returns the live backing array of queued items, in heap (not priority) order.
]]
function PriorityQueue.items<T>(self: PriorityQueue<T>): { T }
	return self._items
end

--[[
	Empties the queue proper. The incoming batch is untouched.
]]
function PriorityQueue.clear<T>(self: PriorityQueue<T>): ()
	table.clear(self._indices)
	table.clear(self._items)
	table.clear(self._priorities)
	self._size = 0
end

--[[
	Returns how many items are in the queue proper.
]]
function PriorityQueue.len<T>(self: PriorityQueue<T>): number
	return self._size
end

--[[
	Returns whether the item is in the queue proper (not the incoming batch).
]]
function PriorityQueue.contains<T>(self: PriorityQueue<T>, item: T): boolean
	return self._indices[item] ~= nil
end

--[[
	Returns whether the queue proper is empty.
]]
function PriorityQueue.isEmpty<T>(self: PriorityQueue<T>): boolean
	return self._size <= 0
end

return PriorityQueue
