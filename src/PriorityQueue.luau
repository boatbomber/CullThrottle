--!strict
--!native
--[[
    PriorityQueue by Ilya Kolbin
    url: github.com/iskolbin/priorityqueue

    Adapted for Luau by boatbomber

    Lowest priority values come first.
--]]

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

function PriorityQueue.addToIncomingBatch<T>(self: PriorityQueue<T>, item: T, priority: number): ()
	local incomingBatch = self._incomingBatch
	incomingBatch.size += 1
	incomingBatch.items[incomingBatch.size] = item
	incomingBatch.priorities[incomingBatch.size] = priority
end

function PriorityQueue.addMultipleToIncomingBatch<T>(self: PriorityQueue<T>, items: { T }, priorities: { number }): ()
	local incomingBatch = self._incomingBatch
	local itemsCount = #items
	table.move(items, 1, itemsCount, incomingBatch.size + 1, incomingBatch.items)
	table.move(priorities, 1, itemsCount, incomingBatch.size + 1, incomingBatch.priorities)
	incomingBatch.size += itemsCount
end

function PriorityQueue.enqueueIncomingBatch<T>(self: PriorityQueue<T>): ()
	local incomingBatch = self._incomingBatch
	if incomingBatch.size > 0 then
		self:batchEnqueue(incomingBatch.items, incomingBatch.priorities)
	end
end

function PriorityQueue.clearIncomingBatch<T>(self: PriorityQueue<T>): ()
	local incomingBatch = self._incomingBatch
	incomingBatch.size = 0
	table.clear(incomingBatch.items)
	table.clear(incomingBatch.priorities)
end

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
			self:siftdown(self:siftup(index))
		end
	end
	return true
end

function PriorityQueue.update<T>(self: PriorityQueue<T>, item: T, priority: number): boolean
	local ok = self:remove(item)
	if not ok then
		return false
	end

	self:enqueue(item, priority)
	return true
end

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

function PriorityQueue.peek<T>(self: PriorityQueue<T>): (T, number)
	return self._items[1], self._priorities[1]
end

function PriorityQueue.peekPriority<T>(self: PriorityQueue<T>): number?
	return self._priorities[1]
end

function PriorityQueue.items<T>(self: PriorityQueue<T>): { T }
	return self._items
end

function PriorityQueue.clear<T>(self: PriorityQueue<T>): ()
	table.clear(self._indices)
	table.clear(self._items)
	table.clear(self._priorities)
	self._size = 0
end

function PriorityQueue.len<T>(self: PriorityQueue<T>): number
	return self._size
end

function PriorityQueue.contains<T>(self: PriorityQueue<T>, item: T): boolean
	return self._indices[item] ~= nil
end

function PriorityQueue.isEmpty<T>(self: PriorityQueue<T>): boolean
	return self._size <= 0
end

return PriorityQueue
