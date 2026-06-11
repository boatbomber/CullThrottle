--!strict
--!native
--[[
    This is PriorityQueue by Ilya Kolbin, from github.com/iskolbin/priorityqueue.

    It was adapted for Luau by boatbomber.

    Lowest priority values come first.

    Priorities must be real numbers. A NaN priority fails every heap comparison
    and silently corrupts dequeue order, and the hot enqueue paths deliberately
    don't pay for a guard, so callers keep NaN out (Ingest culls NaN distances
    before staging anything).
]]

local PriorityQueue = {}
PriorityQueue.__index = PriorityQueue

type PriorityQueueProto<T> = {
	_items: { T },
	_priorities: { number },
	_indices: { [T]: number },
	_size: number,

	_incomingBatch: { items: { T }, priorities: { number }, size: number },
}

export type PriorityQueue<T> = typeof(setmetatable({} :: PriorityQueueProto<T>, PriorityQueue))

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
	property holds again, returning its final index.
]]
function PriorityQueue.siftup<T>(self: PriorityQueue<T>, from: number)
	local items, priorities, indices = self._items, self._priorities, self._indices
	local index = from
	local parent = index // 2
	while (index > 1) and (priorities[index] < priorities[parent]) do
		priorities[index], priorities[parent] = priorities[parent], priorities[index]
		items[index], items[parent] = items[parent], items[index]
		indices[items[index]], indices[items[parent]] = index, parent
		index = parent
		parent = index // 2
	end
	return index
end

--[[
	Sinks every element from `limit` down to the root into place. Called with
	size // 2, this is the classic O(n) bottom-up heapify.
]]
function PriorityQueue.siftdown<T>(self: PriorityQueue<T>, limit: number)
	local items, priorities, indices, size = self._items, self._priorities, self._indices, self._size
	for index = limit, 1, -1 do
		local left = index + index
		local right = left + 1
		while left <= size do
			local smaller = left
			if (right <= size) and (priorities[right] < priorities[left]) then
				smaller = right
			end

			if priorities[smaller] >= priorities[index] then
				break
			end

			items[index], items[smaller] = items[smaller], items[index]
			priorities[index], priorities[smaller] = priorities[smaller], priorities[index]
			indices[items[index]], indices[items[smaller]] = index, smaller

			index = smaller
			left = index + index
			right = left + 1
		end
	end
end

--[[
	Inserts one item with the given priority. An item already in the queue is
	left untouched.
]]
function PriorityQueue.enqueue<T>(self: PriorityQueue<T>, item: T, priority: number): PriorityQueue<T>
	local items, priorities, indices = self._items, self._priorities, self._indices
	if indices[item] ~= nil then
		return self
	end
	local size = self._size + 1
	self._size = size
	items[size], priorities[size], indices[item] = item, priority, size
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
		local item, priority = itemsBatch[i], prioritiesBatch[i]
		if item == nil or indices[item] ~= nil then
			continue
		end
		size = size + 1
		items[size], priorities[size] = item, priority
		indices[item] = size
	end
	self._size = size
	if size > 1 then
		self:siftdown(size // 2)
	end
end

--[[
	Removes one item from anywhere in the queue (swapping the last element
	into its slot and re-sifting), returning whether it was present. Items
	still in the incoming batch are not consulted.
]]
function PriorityQueue.remove<T>(self: PriorityQueue<T>, item: T): boolean
	local index = self._indices[item]
	if index == nil then
		return false
	end

	local size = self._size
	local items, priorities, indices = self._items, self._priorities, self._indices
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
			-- so we bubble it up first and then sink from wherever it landed.
			self:siftdown(self:siftup(index))
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
		self:siftdown(1)
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
