--!strict
--[[
    PriorityQueue by Ilya Kolbin
    url: github.com/iskolbin/priorityqueue

    Adapted for Luau by boatbomber

    Lowest priority values come first.
--]]

local PriorityQueue = {}
PriorityQueue.__index = PriorityQueue

type PriorityQueueProto = {
	_items: { any },
	_priorities: { number },
	_indices: { [any]: number },
	_size: number,
}

export type PriorityQueue = typeof(setmetatable({} :: PriorityQueueProto, PriorityQueue))

function PriorityQueue.new(): PriorityQueue
	local self = setmetatable({
		_items = {},
		_priorities = {},
		_indices = {},
		_size = 0,
	}, PriorityQueue)

	return self
end

function PriorityQueue.siftup(self: PriorityQueue, from: number)
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

function PriorityQueue.siftdown(self: PriorityQueue, limit: number)
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

function PriorityQueue.enqueue(self: PriorityQueue, item: any, priority: number): PriorityQueue
	local items, priorities, indices = self._items, self._priorities, self._indices
	if indices[item] ~= nil then
		-- It's already in the queue, so we need to remove it first
		self:remove(item)
	end
	local size = self._size + 1
	self._size = size
	items[size], priorities[size], indices[item] = item, priority, size
	self:siftup(size)
	return self
end

function PriorityQueue.remove(self: PriorityQueue, item: any): boolean
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

function PriorityQueue.contains(self: PriorityQueue, item: any): boolean
	return self._indices[item] ~= nil
end

function PriorityQueue.update(self: PriorityQueue, item: any, priority: number): boolean
	local ok = self:remove(item)
	if not ok then
		return false
	end

	self:enqueue(item, priority)
	return true
end

function PriorityQueue.dequeue(self: PriorityQueue): (any, number)
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

function PriorityQueue.peek(self: PriorityQueue): (any, number)
	return self._items[1], self._priorities[1]
end

function PriorityQueue.len(self: PriorityQueue): number
	return self._size
end

function PriorityQueue.empty(self: PriorityQueue): boolean
	return self._size <= 0
end

function PriorityQueue.batchEnqueue(self: PriorityQueue, iparray: {}): ()
	local items, priorities, indices = self._items, self._priorities, self._indices
	local size = self._size
	for i = 1, #iparray, 2 do
		local item, priority = iparray[i], iparray[i + 1]
		if indices[item] ~= nil then
			error("Item " .. tostring(indices[item]) .. " is already in the heap")
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

return PriorityQueue