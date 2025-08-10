local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages, DevPackages = ReplicatedStorage:WaitForChild("Packages"), ReplicatedStorage:WaitForChild("DevPackages")

local JestGlobals = require(DevPackages:WaitForChild("JestGlobals"))

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local beforeEach = JestGlobals.beforeEach

local PriorityQueue = require(Packages:WaitForChild("CullThrottle"):WaitForChild("PriorityQueue"))

describe("PriorityQueue", function()
	local queue

	beforeEach(function()
		queue = PriorityQueue.new()
	end)

	describe("new", function()
		it("should create an empty priority queue", function()
			expect(queue).toBeDefined()
			expect(queue:len()).toBe(0)
			expect(queue:isEmpty()).toBe(true)
		end)

		it("should initialize with correct internal structure", function()
			expect(queue._size).toBe(0)
			expect(queue._items).toEqual({})
			expect(queue._priorities).toEqual({})
			expect(queue._indices).toEqual({})
			expect(queue._incomingBatch).toBeDefined()
			expect(queue._incomingBatch.size).toBe(0)
		end)
	end)

	describe("enqueue", function()
		it("should add a single item with priority", function()
			queue:enqueue("item1", 5)
			expect(queue:len()).toBe(1)
			expect(queue:isEmpty()).toBe(false)
			expect(queue:contains("item1")).toBe(true)
		end)

		it("should maintain min-heap property (lowest priority first)", function()
			queue:enqueue("high", 10)
			queue:enqueue("low", 1)
			queue:enqueue("medium", 5)

			local item, priority = queue:peek()
			expect(item).toBe("low")
			expect(priority).toBe(1)
		end)

		it("should prevent duplicate items", function()
			queue:enqueue("item1", 5)
			queue:enqueue("item1", 3)

			expect(queue:len()).toBe(1)
			local item, priority = queue:peek()
			expect(priority).toBe(5)
			expect(item).toBe("item1")
		end)

		it("should handle multiple items with same priority", function()
			queue:enqueue("item1", 5)
			queue:enqueue("item2", 5)
			queue:enqueue("item3", 5)

			expect(queue:len()).toBe(3)
			local _, priority = queue:peek()
			expect(priority).toBe(5)
		end)

		it("should return self for chaining", function()
			local result = queue:enqueue("item1", 5)
			expect(result).toBe(queue)
		end)
	end)

	describe("dequeue", function()
		it("should remove and return the item with lowest priority", function()
			queue:enqueue("high", 10)
			queue:enqueue("low", 1)
			queue:enqueue("medium", 5)

			local item, priority = queue:dequeue()
			expect(item).toBe("low")
			expect(priority).toBe(1)
			expect(queue:len()).toBe(2)
			expect(queue:contains("low")).toBe(false)
		end)

		it("should maintain heap property after dequeue", function()
			queue:enqueue("item3", 3)
			queue:enqueue("item1", 1)
			queue:enqueue("item7", 7)
			queue:enqueue("item2", 2)
			queue:enqueue("item5", 5)

			local item1, priority1 = queue:dequeue()
			expect(priority1).toBe(1)
			expect(item1).toBe("item1")

			local item2, priority2 = queue:dequeue()
			expect(priority2).toBe(2)
			expect(item2).toBe("item2")

			local item3, priority3 = queue:dequeue()
			expect(priority3).toBe(3)
			expect(item3).toBe("item3")

			expect(queue:len()).toBe(2)
		end)

		it("should error when dequeuing from empty queue", function()
			expect(function()
				queue:dequeue()
			end).toThrow("Heap is empty")
		end)

		it("should handle single item dequeue", function()
			queue:enqueue("only", 5)
			local item, priority = queue:dequeue()

			expect(item).toBe("only")
			expect(priority).toBe(5)
			expect(queue:isEmpty()).toBe(true)
		end)
	end)

	describe("peek", function()
		it("should return the item with lowest priority without removing it", function()
			queue:enqueue("high", 10)
			queue:enqueue("low", 1)
			queue:enqueue("medium", 5)

			local item, priority = queue:peek()
			expect(item).toBe("low")
			expect(priority).toBe(1)
			expect(queue:len()).toBe(3)
			expect(queue:contains("low")).toBe(true)
		end)

		it("should return nil for empty queue", function()
			local item, priority = queue:peek()
			expect(item).toBeNil()
			expect(priority).toBeNil()
		end)
	end)

	describe("peekPriority", function()
		it("should return only the priority of the top item", function()
			queue:enqueue("item1", 3)
			queue:enqueue("item2", 1)

			local priority = queue:peekPriority()
			expect(priority).toBe(1)
		end)

		it("should return nil for empty queue", function()
			local priority = queue:peekPriority()
			expect(priority).toBeNil()
		end)
	end)

	describe("remove", function()
		it("should remove a specific item from the queue", function()
			queue:enqueue("item5", 5)
			queue:enqueue("item3", 3)
			queue:enqueue("item7", 7)

			local success = queue:remove("item3")
			expect(success).toBe(true)
			expect(queue:len()).toBe(2)
			expect(queue:contains("item3")).toBe(false)
		end)

		it("should maintain heap property after removal", function()
			queue:enqueue("item1", 1)
			queue:enqueue("item3", 3)
			queue:enqueue("item2", 2)
			queue:enqueue("item5", 5)
			queue:enqueue("item4", 4)

			queue:remove("item2")

			local item1, priority1 = queue:dequeue()
			expect(priority1).toBe(1)
			expect(item1).toBe("item1")

			local item3, priority3 = queue:dequeue()
			expect(priority3).toBe(3)
			expect(item3).toBe("item3")
		end)

		it("should return false when removing non-existent item", function()
			queue:enqueue("item1", 5)

			local success = queue:remove("nonexistent")
			expect(success).toBe(false)
			expect(queue:len()).toBe(1)
		end)

		it("should handle removing the last item", function()
			queue:enqueue("item1", 1)
			queue:enqueue("item2", 2)
			queue:enqueue("item3", 3)

			local success = queue:remove("item3")
			expect(success).toBe(true)
			expect(queue:len()).toBe(2)
		end)

		it("should handle removing the root item", function()
			queue:enqueue("item1", 1)
			queue:enqueue("item2", 2)
			queue:enqueue("item3", 3)

			local success = queue:remove("item1")
			expect(success).toBe(true)
			expect(queue:len()).toBe(2)

			local item, priority = queue:peek()
			expect(priority).toBe(2)
			expect(item).toBe("item2")
		end)
	end)

	describe("update", function()
		it("should update the priority of an existing item", function()
			queue:enqueue("item1", 5)
			queue:enqueue("item2", 3)

			local success = queue:update("item1", 1)
			expect(success).toBe(true)

			local item, priority = queue:peek()
			expect(item).toBe("item1")
			expect(priority).toBe(1)
		end)

		it("should return false when updating non-existent item", function()
			queue:enqueue("item1", 5)

			local success = queue:update("nonexistent", 1)
			expect(success).toBe(false)
			expect(queue:len()).toBe(1)
		end)

		it("should maintain heap property after update", function()
			queue:enqueue("item1", 2)
			queue:enqueue("item2", 3)
			queue:enqueue("item3", 4)

			queue:update("item3", 1)

			local item, priority = queue:peek()
			expect(item).toBe("item3")
			expect(priority).toBe(1)
		end)
	end)

	describe("batchEnqueue", function()
		it("should enqueue multiple items at once", function()
			local items = { "item1", "item2", "item3" }
			local priorities = { 5, 2, 8 }

			queue:batchEnqueue(items, priorities)

			expect(queue:len()).toBe(3)
			expect(queue:contains("item1")).toBe(true)
			expect(queue:contains("item2")).toBe(true)
			expect(queue:contains("item3")).toBe(true)
		end)

		it("should maintain heap property after batch enqueue", function()
			local items = { "item1", "item2", "item3", "item4" }
			local priorities = { 7, 2, 5, 1 }

			queue:batchEnqueue(items, priorities)

			local item, priority = queue:peek()
			expect(item).toBe("item4")
			expect(priority).toBe(1)
		end)

		it("should skip duplicate items in batch", function()
			queue:enqueue("existing", 5)

			local items = { "item1", "existing", "item2" }
			local priorities = { 3, 1, 4 }

			queue:batchEnqueue(items, priorities)

			expect(queue:len()).toBe(3)
			local item, priority = queue:peek()
			expect(priority).toBe(3)
			expect(item).toBe("item1")
		end)

		it("should skip nil items in batch", function()
			local items = { "item1", nil, "item2" }
			local priorities = { 3, 1, 4 }

			queue:batchEnqueue(items, priorities)

			expect(queue:len()).toBe(2)
			expect(queue:contains("item1")).toBe(true)
			expect(queue:contains("item2")).toBe(true)
		end)
	end)

	describe("incoming batch operations", function()
		it("should add items to incoming batch", function()
			queue:addToIncomingBatch("item1", 5)
			queue:addToIncomingBatch("item2", 3)

			expect(queue._incomingBatch.size).toBe(2)
			expect(queue:len()).toBe(0)
		end)

		it("should enqueue incoming batch", function()
			queue:addToIncomingBatch("item1", 5)
			queue:addToIncomingBatch("item2", 3)
			queue:enqueueIncomingBatch()

			expect(queue:len()).toBe(2)
			local item, priority = queue:peek()
			expect(priority).toBe(3)
			expect(item).toBe("item2")
		end)

		it("should clear incoming batch", function()
			queue:addToIncomingBatch("item1", 5)
			queue:addToIncomingBatch("item2", 3)
			queue:clearIncomingBatch()

			expect(queue._incomingBatch.size).toBe(0)
			expect(#queue._incomingBatch.items).toBe(0)
			expect(#queue._incomingBatch.priorities).toBe(0)
		end)

		it("should add multiple items to incoming batch at once", function()
			local items = { "item1", "item2", "item3" }
			local priorities = { 5, 2, 8 }

			queue:addMultipleToIncomingBatch(items, priorities)

			expect(queue._incomingBatch.size).toBe(3)
			expect(queue:len()).toBe(0)
		end)

		it("should handle mixed batch operations", function()
			queue:addToIncomingBatch("item1", 5)

			local items = { "item2", "item3" }
			local priorities = { 2, 8 }
			queue:addMultipleToIncomingBatch(items, priorities)

			queue:addToIncomingBatch("item4", 1)
			queue:enqueueIncomingBatch()

			expect(queue:len()).toBe(4)
			local item, priority = queue:peek()
			expect(priority).toBe(1)
			expect(item).toBe("item4")
		end)

		it("should handle empty incoming batch enqueue", function()
			queue:enqueueIncomingBatch()
			expect(queue:len()).toBe(0)
		end)
	end)

	describe("utility methods", function()
		it("should return all items", function()
			queue:enqueue("item1", 5)
			queue:enqueue("item2", 3)
			queue:enqueue("item3", 7)

			local items = queue:items()
			expect(#items).toBe(3)
			expect(items).toContain("item1")
			expect(items).toContain("item2")
			expect(items).toContain("item3")
		end)

		it("should clear the queue", function()
			queue:enqueue("item1", 5)
			queue:enqueue("item2", 3)
			queue:enqueue("item3", 7)

			queue:clear()

			expect(queue:len()).toBe(0)
			expect(queue:isEmpty()).toBe(true)
			expect(queue._items).toEqual({})
			expect(queue._priorities).toEqual({})
			expect(queue._indices).toEqual({})
		end)

		it("should correctly report length", function()
			expect(queue:len()).toBe(0)

			queue:enqueue("item1", 5)
			expect(queue:len()).toBe(1)

			queue:enqueue("item2", 3)
			expect(queue:len()).toBe(2)

			queue:dequeue()
			expect(queue:len()).toBe(1)
		end)

		it("should correctly check if queue contains an item", function()
			queue:enqueue("item1", 5)
			queue:enqueue("item2", 3)

			expect(queue:contains("item1")).toBe(true)
			expect(queue:contains("item2")).toBe(true)
			expect(queue:contains("item3")).toBe(false)

			queue:remove("item1")
			expect(queue:contains("item1")).toBe(false)
		end)

		it("should correctly check if queue is empty", function()
			expect(queue:isEmpty()).toBe(true)

			queue:enqueue("item1", 5)
			expect(queue:isEmpty()).toBe(false)

			queue:dequeue()
			expect(queue:isEmpty()).toBe(true)
		end)
	end)

	describe("edge cases and stress tests", function()
		it("should handle large numbers of items", function()
			for i = 1, 1000 do
				queue:enqueue("item" .. i, math.random() * 1000)
			end

			expect(queue:len()).toBe(1000)

			local lastPriority = -math.huge
			for _ = 1, 1000 do
				local _, priority = queue:dequeue()
				expect(priority).toBeGreaterThanOrEqual(lastPriority)
				lastPriority = priority
			end

			expect(queue:isEmpty()).toBe(true)
		end)

		it("should handle negative priorities", function()
			queue:enqueue("item5", -5)
			queue:enqueue("item10", -10)
			queue:enqueue("item0", 0)

			local item1, priority1 = queue:dequeue()
			expect(priority1).toBe(-10)
			expect(item1).toBe("item10")

			local item2, priority2 = queue:dequeue()
			expect(priority2).toBe(-5)
			expect(item2).toBe("item5")

			local item3, priority3 = queue:dequeue()
			expect(priority3).toBe(0)
			expect(item3).toBe("item0")
		end)

		it("should handle decimal priorities", function()
			queue:enqueue("item1", 1.5)
			queue:enqueue("item2", 1.2)
			queue:enqueue("item3", 1.8)

			local item, priority = queue:peek()
			expect(priority).toBe(1.2)
			expect(item).toBe("item2")
		end)

		it("should handle various data types as items", function()
			local table1 = { key = "value" }
			local function1 = function() end

			queue:enqueue(table1, 5)
			queue:enqueue(function1, 3)
			queue:enqueue(123, 7)
			queue:enqueue(true, 1)

			expect(queue:len()).toBe(4)
			expect(queue:contains(table1)).toBe(true)
			expect(queue:contains(function1)).toBe(true)
			expect(queue:contains(123)).toBe(true)
			expect(queue:contains(true)).toBe(true)
		end)

		it("should maintain correct indices after complex operations", function()
			queue:enqueue("item1", 5)
			queue:enqueue("item2", 2)
			queue:enqueue("item3", 8)
			queue:enqueue("item4", 1)
			queue:enqueue("item5", 6)

			queue:remove("item2")
			queue:update("item3", 3)
			queue:dequeue()

			expect(queue:len()).toBe(3)
			expect(queue:contains("item1")).toBe(true)
			expect(queue:contains("item3")).toBe(true)
			expect(queue:contains("item5")).toBe(true)

			local item, priority = queue:peek()
			expect(priority).toBe(3)
			expect(item).toBe("item3")
		end)
	end)
end)
