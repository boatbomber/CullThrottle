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
		it("creates an empty queue", function()
			expect(queue).toBeDefined()
			expect(queue:len()).toBe(0)
			expect(queue:isEmpty()).toBe(true)
		end)
	end)

	describe("enqueue", function()
		it("adds a single item with a priority", function()
			queue:enqueue("item1", 5)
			expect(queue:len()).toBe(1)
			expect(queue:isEmpty()).toBe(false)
			expect(queue:contains("item1")).toBe(true)
		end)

		it("puts the lowest priority item at the front", function()
			queue:enqueue("high", 10)
			queue:enqueue("low", 1)
			queue:enqueue("medium", 5)

			local item, priority = queue:peek()
			expect(item).toBe("low")
			expect(priority).toBe(1)
		end)

		it("ignores a re-enqueue of an item already present", function()
			queue:enqueue("item1", 5)
			queue:enqueue("item1", 3)

			expect(queue:len()).toBe(1)
			local item, priority = queue:peek()
			expect(priority).toBe(5)
			expect(item).toBe("item1")
		end)

		it("returns self for chaining", function()
			local result = queue:enqueue("item1", 5)
			expect(result).toBe(queue)
		end)
	end)

	describe("dequeue", function()
		it("removes and returns the lowest priority item", function()
			queue:enqueue("high", 10)
			queue:enqueue("low", 1)
			queue:enqueue("medium", 5)

			local item, priority = queue:dequeue()
			expect(item).toBe("low")
			expect(priority).toBe(1)
			expect(queue:len()).toBe(2)
			expect(queue:contains("low")).toBe(false)
		end)

		it("dequeues in ascending priority order", function()
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

		it("errors when dequeuing from an empty queue", function()
			expect(function()
				queue:dequeue()
			end).toThrow("Heap is empty")
		end)

		it("dequeues the only item and leaves the queue empty", function()
			queue:enqueue("only", 5)
			local item, priority = queue:dequeue()

			expect(item).toBe("only")
			expect(priority).toBe(5)
			expect(queue:isEmpty()).toBe(true)
		end)

		it("accepts fresh items after being drained to empty", function()
			queue:enqueue("only", 5)
			queue:dequeue()
			expect(queue:isEmpty()).toBe(true)

			-- Re-enqueueing after a full drain must not surface a stale top element.
			queue:enqueue("fresh1", 3)
			queue:enqueue("fresh2", 1)
			expect(queue:len()).toBe(2)

			expect((queue:dequeue())).toBe("fresh2")
			expect((queue:dequeue())).toBe("fresh1")
		end)
	end)

	describe("peek", function()
		it("returns the lowest priority item without removing it", function()
			queue:enqueue("high", 10)
			queue:enqueue("low", 1)
			queue:enqueue("medium", 5)

			local item, priority = queue:peek()
			expect(item).toBe("low")
			expect(priority).toBe(1)
			expect(queue:len()).toBe(3)
			expect(queue:contains("low")).toBe(true)
		end)

		it("returns nils for an empty queue", function()
			local item, priority = queue:peek()
			expect(item).toBeNil()
			expect(priority).toBeNil()
		end)
	end)

	describe("peekPriority", function()
		it("returns only the priority of the front item", function()
			queue:enqueue("item1", 3)
			queue:enqueue("item2", 1)

			local priority = queue:peekPriority()
			expect(priority).toBe(1)
		end)

		it("returns nil for an empty queue", function()
			local priority = queue:peekPriority()
			expect(priority).toBeNil()
		end)
	end)

	describe("remove", function()
		it("removes a specific item", function()
			queue:enqueue("item5", 5)
			queue:enqueue("item3", 3)
			queue:enqueue("item7", 7)

			local success = queue:remove("item3")
			expect(success).toBe(true)
			expect(queue:len()).toBe(2)
			expect(queue:contains("item3")).toBe(false)
		end)

		it("drains in priority order after a removal", function()
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

		it("returns false when removing an item that is not present", function()
			queue:enqueue("item1", 5)

			local success = queue:remove("nonexistent")
			expect(success).toBe(false)
			expect(queue:len()).toBe(1)
		end)

		it("does not remove an item that is only staged in the incoming batch", function()
			queue:addToIncomingBatch("staged", 5)

			-- The remove method only consults the queue proper, never the
			-- incoming batch, so a batch-only item survives the call and still
			-- enqueues later.
			expect(queue:remove("staged")).toBe(false)

			queue:enqueueIncomingBatch()
			expect(queue:contains("staged")).toBe(true)
			local item, priority = queue:dequeue()
			expect(item).toBe("staged")
			expect(priority).toBe(5)
		end)

		it("removes an item sitting in the final heap slot", function()
			queue:enqueue("item1", 1)
			queue:enqueue("item2", 2)
			queue:enqueue("item3", 3)

			-- Enqueued in increasing priority order, item3 lands in the final heap
			-- slot, so this removal takes the no-replacement fast path. The index
			-- check proves that layout assumption still holds before we rely on it.
			expect(queue._indices["item3"]).toBe(queue._size)
			local success = queue:remove("item3")
			expect(success).toBe(true)
			expect(queue:len()).toBe(2)
			expect(queue:contains("item3")).toBe(false)

			local drained = {}
			while not queue:isEmpty() do
				table.insert(drained, (queue:dequeue()))
			end
			expect(drained).toEqual({ "item1", "item2" })
		end)

		it("removes the root and promotes the next lowest", function()
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

		it("bubbles the replacement up when removing an interior node", function()
			-- Insertion order produces the 4-ary heap array
			-- [1, 10, 2, 3, 4, 11, 12, 13, 14, 2.5].
			local order = {
				{ "p1", 1 },
				{ "p10", 10 },
				{ "p2", 2 },
				{ "p3", 3 },
				{ "p4", 4 },
				{ "p11", 11 },
				{ "p12", 12 },
				{ "p13", 13 },
				{ "p14", 14 },
				{ "p2.5", 2.5 },
			}
			for _, pair in order do
				queue:enqueue(pair[1], pair[2])
			end

			-- Removing p11 (an interior node) replaces it with the last element
			-- p2.5, which is smaller than p11's parent p10, so the replacement
			-- must sift up toward the root rather than sink. Every other remove
			-- test sinks instead. These checks prove the assumed layout still
			-- holds (p11 sits mid-heap and its parent outranks the element that
			-- will replace it), so the sift-up path can't silently stop being
			-- exercised if heap construction ever changes.
			local removeIndex = queue._indices["p11"]
			expect(removeIndex).toBeGreaterThan(1)
			expect(queue._size).toBeGreaterThan(removeIndex)
			expect(queue._priorities[(removeIndex + 2) // 4]).toBeGreaterThan(queue._priorities[queue._size])
			expect(queue:remove("p11")).toBe(true)

			local drained = {}
			while not queue:isEmpty() do
				table.insert(drained, (queue:dequeue()))
			end
			expect(drained).toEqual({ "p1", "p2", "p2.5", "p3", "p4", "p10", "p12", "p13", "p14" })
		end)

		it("returns false when removing from an empty queue", function()
			expect(queue:remove("missing")).toBe(false)
		end)
	end)

	describe("update", function()
		it("updates the priority of an existing item", function()
			queue:enqueue("item1", 5)
			queue:enqueue("item2", 3)

			local success = queue:update("item1", 1)
			expect(success).toBe(true)

			local item, priority = queue:peek()
			expect(item).toBe("item1")
			expect(priority).toBe(1)
		end)

		it("returns false when updating an item that is not present", function()
			queue:enqueue("item1", 5)

			local success = queue:update("nonexistent", 1)
			expect(success).toBe(false)
			expect(queue:len()).toBe(1)
		end)

		it("surfaces an item whose update makes it the new lowest", function()
			queue:enqueue("item1", 2)
			queue:enqueue("item2", 3)
			queue:enqueue("item3", 4)

			queue:update("item3", 1)

			local item, priority = queue:peek()
			expect(item).toBe("item3")
			expect(priority).toBe(1)
		end)

		it("re-sinks an item when its priority increases", function()
			queue:enqueue("a", 1)
			queue:enqueue("b", 2)
			queue:enqueue("c", 3)

			-- Raising a's priority should move it to the back. The other update tests
			-- only decrease priority (bubbling toward the root), so this one exercises
			-- the opposite sink direction.
			queue:update("a", 10)

			expect((queue:peek())).toBe("b")

			local drained = {}
			while not queue:isEmpty() do
				table.insert(drained, (queue:dequeue()))
			end
			expect(drained).toEqual({ "b", "c", "a" })
		end)

		it("returns false when updating an empty queue", function()
			expect(queue:update("missing", 1)).toBe(false)
		end)
	end)

	describe("batchEnqueue", function()
		it("enqueues multiple items at once", function()
			local items = { "item1", "item2", "item3" }
			local priorities = { 5, 2, 8 }

			queue:batchEnqueue(items, priorities)

			expect(queue:len()).toBe(3)
			expect(queue:contains("item1")).toBe(true)
			expect(queue:contains("item2")).toBe(true)
			expect(queue:contains("item3")).toBe(true)
		end)

		it("surfaces the lowest priority of the batch", function()
			local items = { "item1", "item2", "item3", "item4" }
			local priorities = { 7, 2, 5, 1 }

			queue:batchEnqueue(items, priorities)

			local item, priority = queue:peek()
			expect(item).toBe("item4")
			expect(priority).toBe(1)
		end)

		it("skips duplicate items in a batch", function()
			queue:enqueue("existing", 5)

			local items = { "item1", "existing", "item2" }
			local priorities = { 3, 1, 4 }

			queue:batchEnqueue(items, priorities)

			expect(queue:len()).toBe(3)
			local item, priority = queue:peek()
			expect(priority).toBe(3)
			expect(item).toBe("item1")
		end)

		it("skips nil items in a batch", function()
			local items = { "item1", nil, "item2" }
			local priorities = { 3, 1, 4 }

			queue:batchEnqueue(items, priorities)

			expect(queue:len()).toBe(2)
			expect(queue:contains("item1")).toBe(true)
			expect(queue:contains("item2")).toBe(true)
		end)

		it("drains a large unsorted batch in priority order", function()
			local items, priorities = {}, {}
			for i = 1, 500 do
				items[i] = "batch" .. i
				priorities[i] = math.random() * 1000
			end

			queue:batchEnqueue(items, priorities)
			expect(queue:len()).toBe(500)

			-- A correct bulk heapify still drains in non-decreasing priority order.
			local lastPriority = -math.huge
			while not queue:isEmpty() do
				local _, priority = queue:dequeue()
				expect(priority).toBeGreaterThanOrEqual(lastPriority)
				lastPriority = priority
			end
		end)

		it("merges a batch into an already populated heap", function()
			queue:enqueue("seed1", 100)
			queue:enqueue("seed2", 1)

			queue:batchEnqueue({ "x", "y", "z" }, { 50, 0, 200 })

			expect(queue:len()).toBe(5)

			-- The bulk heapify has to restore the invariant across the whole array,
			-- not just the appended region, so the merged queue must drain fully
			-- sorted rather than merely surface the right root.
			local drained = {}
			while not queue:isEmpty() do
				table.insert(drained, (queue:dequeue()))
			end
			expect(drained).toEqual({ "y", "seed2", "x", "seed1", "z" })
		end)

		it("keeps the heap valid for a batch of all-equal priorities", function()
			-- All-equal priorities make every comparison in the bulk bottom-up
			-- heapify a tie, so any strictness slip in its child scan shows up
			-- here rather than in the per-item enqueue path.
			local items, priorities = {}, {}
			for i = 1, 64 do
				items[i] = "equal" .. i
				priorities[i] = 5
			end

			queue:batchEnqueue(items, priorities)
			expect(queue:len()).toBe(64)

			-- Draining must return every item exactly once, all at the staged
			-- priority.
			local seen = {}
			local drainedCount = 0
			while not queue:isEmpty() do
				local item, priority = queue:dequeue()
				expect(priority).toBe(5)
				expect(seen[item]).toBeNil()
				seen[item] = true
				drainedCount += 1
			end
			expect(drainedCount).toBe(64)
		end)
	end)

	describe("incoming batch operations", function()
		it("enqueues the staged incoming batch", function()
			queue:addToIncomingBatch("item1", 5)
			queue:addToIncomingBatch("item2", 3)
			queue:enqueueIncomingBatch()

			expect(queue:len()).toBe(2)
			local item, priority = queue:peek()
			expect(priority).toBe(3)
			expect(item).toBe("item2")
		end)

		it("leaves the incoming batch intact after enqueueing it", function()
			queue:addToIncomingBatch("item1", 5)
			queue:addToIncomingBatch("item2", 3)
			queue:enqueueIncomingBatch()

			-- Enqueueing heapifies the staged items without consuming them. That
			-- intact snapshot is load-bearing for the facade, which answers
			-- GetVisibleObjects by reading the batch's items array directly even
			-- after the update iterator drains the queue proper (it never
			-- re-enqueues within a frame). Clearing the queue proper and
			-- re-enqueueing below proves the snapshot survived in full.
			queue:clear()
			expect(queue:len()).toBe(0)

			queue:enqueueIncomingBatch()
			expect(queue:len()).toBe(2)
			expect(queue:contains("item1")).toBe(true)
			expect(queue:contains("item2")).toBe(true)
		end)

		it("enqueues an intra-batch duplicate only once", function()
			queue:addToIncomingBatch("dup", 5)
			queue:addToIncomingBatch("dup", 2)
			queue:addToIncomingBatch("other", 9)
			queue:enqueueIncomingBatch()

			expect(queue:len()).toBe(2)
			local item, priority = queue:peek()
			expect(item).toBe("dup")
			-- The surviving priority must be one the caller actually staged, but
			-- which of the duplicates wins is unspecified.
			expect(priority == 5 or priority == 2).toBe(true)
		end)

		it("clears the incoming batch", function()
			queue:addToIncomingBatch("item1", 5)
			queue:addToIncomingBatch("item2", 3)
			queue:clearIncomingBatch()

			expect(queue._incomingBatch.size).toBe(0)
			expect(#queue._incomingBatch.items).toBe(0)
			expect(#queue._incomingBatch.priorities).toBe(0)
		end)

		it("reuses the incoming batch across clear cycles", function()
			-- clearIncomingBatch clears in place (keeping capacity) rather than
			-- reassigning fresh tables, so a fresh batch after a clear must still
			-- enqueue correctly off the contiguous 1..size keys.
			queue:addToIncomingBatch("stale1", 1)
			queue:addToIncomingBatch("stale2", 2)
			queue:enqueueIncomingBatch()
			queue:clearIncomingBatch()

			queue:addToIncomingBatch("fresh", 3)
			expect(queue._incomingBatch.size).toBe(1)
			expect(#queue._incomingBatch.items).toBe(1)
			expect(queue._incomingBatch.items[1]).toBe("fresh")

			queue:enqueueIncomingBatch()

			-- Both the originally-enqueued items and the post-clear item are present,
			-- with no duplicates or leftovers from the cleared arrays.
			expect(queue:len()).toBe(3)
			expect(queue:contains("fresh")).toBe(true)
		end)

		it("stages single and bulk adds into one batch", function()
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

		it("enqueues nothing from an empty incoming batch", function()
			queue:enqueueIncomingBatch()
			expect(queue:len()).toBe(0)
		end)
	end)

	describe("utility methods", function()
		it("returns every queued item", function()
			queue:enqueue("item1", 5)
			queue:enqueue("item2", 3)
			queue:enqueue("item3", 7)

			local items = queue:items()
			expect(#items).toBe(3)
			expect(items).toContain("item1")
			expect(items).toContain("item2")
			expect(items).toContain("item3")
		end)

		it("returns an empty array for an empty queue", function()
			expect(queue:items()).toEqual({})
		end)

		it("reflects the queue's current contents after a dequeue", function()
			queue:enqueue("a", 2)
			queue:enqueue("b", 1)
			expect(#queue:items()).toBe(2)

			queue:dequeue()

			local remaining = queue:items()
			expect(#remaining).toBe(1)
			expect(remaining).toContain("a")
			expect(remaining).never.toContain("b")
		end)

		it("clears the queue proper and leaves the staged batch", function()
			queue:enqueue("item1", 5)
			queue:enqueue("item2", 3)
			queue:enqueue("item3", 7)
			queue:addToIncomingBatch("staged", 1)

			queue:clear()

			expect(queue:len()).toBe(0)
			expect(queue:isEmpty()).toBe(true)
			expect(queue:contains("item1")).toBe(false)
			expect(queue:contains("item2")).toBe(false)
			expect(queue:contains("item3")).toBe(false)

			-- Clearing empties the queue proper only, so anything staged in the
			-- incoming batch still enqueues afterwards.
			queue:enqueueIncomingBatch()
			expect(queue:len()).toBe(1)
			expect(queue:contains("staged")).toBe(true)
		end)

		it("reports the length across enqueues and dequeues", function()
			expect(queue:len()).toBe(0)

			queue:enqueue("item1", 5)
			expect(queue:len()).toBe(1)

			queue:enqueue("item2", 3)
			expect(queue:len()).toBe(2)

			queue:dequeue()
			expect(queue:len()).toBe(1)
		end)

		it("reports whether an item is present", function()
			queue:enqueue("item1", 5)
			queue:enqueue("item2", 3)

			expect(queue:contains("item1")).toBe(true)
			expect(queue:contains("item2")).toBe(true)
			expect(queue:contains("item3")).toBe(false)

			queue:remove("item1")
			expect(queue:contains("item1")).toBe(false)
		end)

		it("reports whether the queue is empty", function()
			expect(queue:isEmpty()).toBe(true)

			queue:enqueue("item1", 5)
			expect(queue:isEmpty()).toBe(false)

			queue:dequeue()
			expect(queue:isEmpty()).toBe(true)
		end)
	end)

	describe("item data types", function()
		it("accepts tables, functions, numbers, and booleans as items", function()
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
	end)

	describe("priority ranges", function()
		it("dequeues negative priorities in ascending order", function()
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

		it("orders a math.huge priority after every finite one", function()
			-- Unlike NaN, math.huge is a real comparable number, so the heap
			-- must order it after every finite priority, including ones enqueued
			-- while it sat at the root.
			queue:enqueue("infinite", math.huge)
			queue:enqueue("small", 1)
			queue:enqueue("large", 1000)
			queue:enqueue("negative", -50)

			expect((queue:dequeue())).toBe("negative")
			expect((queue:dequeue())).toBe("small")
			expect((queue:dequeue())).toBe("large")

			local item, priority = queue:dequeue()
			expect(item).toBe("infinite")
			expect(priority).toBe(math.huge)
			expect(queue:isEmpty()).toBe(true)
		end)

		it("surfaces the lowest decimal priority", function()
			queue:enqueue("item1", 1.5)
			queue:enqueue("item2", 1.2)
			queue:enqueue("item3", 1.8)

			local item, priority = queue:peek()
			expect(priority).toBe(1.2)
			expect(item).toBe("item2")
		end)

		it("keeps the queue valid with many equal priorities", function()
			for i = 1, 50 do
				queue:enqueue("equal" .. i, 5)
			end

			expect(queue:len()).toBe(50)

			local count = 0
			while not queue:isEmpty() do
				local _, priority = queue:dequeue()
				expect(priority).toBe(5)
				count += 1
			end
			expect(count).toBe(50)
		end)
	end)

	describe("stress and property tests", function()
		it("drains a thousand random priorities in sorted order", function()
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

		it("keeps indices consistent across mixed remove, update, and dequeue", function()
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

		it("maintains the heap and index map across random insert/batch/remove/update/dequeue", function()
			-- This is a property test that brute-forces the heap with thousands of
			-- random ops and checks two invariants after every one. Parents must
			-- never outrank their children, and every live heap slot must round-trip
			-- through the index map with no stray entries, because a corrupted map
			-- keeps the heap draining correctly while later removes evict the wrong
			-- item. It exercises the mutation paths the targeted tests can't
			-- fully cover.
			local function queueIsValid(): boolean
				local items, priorities, indices = queue._items, queue._priorities, queue._indices
				for index = 2, queue._size do
					if priorities[(index + 2) // 4] > priorities[index] then
						return false
					end
				end
				for index = 1, queue._size do
					if indices[items[index]] ~= index then
						return false
					end
				end
				local mappedCount = 0
				for _ in indices do
					mappedCount += 1
				end
				return mappedCount == queue._size
			end

			-- Track present items in an array plus an index map for O(1) random pick/remove.
			local presentList, presentIndex = {}, {}
			local function addPresent(item)
				table.insert(presentList, item)
				presentIndex[item] = #presentList
			end
			local function removePresent(item)
				local index = presentIndex[item]
				if not index then
					return
				end
				local n = #presentList
				local last = presentList[n]
				presentList[index] = last
				presentIndex[last] = index
				presentList[n] = nil
				presentIndex[item] = nil
			end
			local function randomPresent()
				return presentList[math.random(1, #presentList)]
			end

			local nextId = 0
			local valid = true
			for _ = 1, 2000 do
				local operation = math.random(1, 5)
				if operation == 1 then
					nextId += 1
					local item = "rng" .. nextId
					queue:enqueue(item, math.random() * 100)
					addPresent(item)
				elseif operation == 2 and #presentList > 0 then
					local item = randomPresent()
					queue:remove(item)
					removePresent(item)
				elseif operation == 3 and #presentList > 0 then
					queue:update(randomPresent(), math.random() * 100)
				elseif operation == 4 then
					-- Bulk insertion merges into whatever heap the prior ops built,
					-- exercising the bottom-up heapify against arbitrary contents.
					local batchItems, batchPriorities = {}, {}
					for i = 1, math.random(2, 6) do
						nextId += 1
						local item = "rng" .. nextId
						batchItems[i] = item
						batchPriorities[i] = math.random() * 100
						addPresent(item)
					end
					queue:batchEnqueue(batchItems, batchPriorities)
				elseif not queue:isEmpty() then
					local item = queue:dequeue()
					removePresent(item)
				end

				if not queueIsValid() then
					valid = false
					break
				end
			end

			expect(valid).toBe(true)
			expect(queue:len()).toBe(#presentList)

			-- Whatever survived must still drain in non-decreasing priority order.
			local lastPriority = -math.huge
			while not queue:isEmpty() do
				local _, priority = queue:dequeue()
				expect(priority).toBeGreaterThanOrEqual(lastPriority)
				lastPriority = priority
			end
		end)
	end)
end)
