local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages, DevPackages = ReplicatedStorage:WaitForChild("Packages"), ReplicatedStorage:WaitForChild("DevPackages")

local JestGlobals = require(DevPackages:WaitForChild("JestGlobals"))

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local beforeEach = JestGlobals.beforeEach

local BandedQueue = require(Packages:WaitForChild("CullThrottle"):WaitForChild("BandedQueue"))

-- The tests stage over ten bands of width ten, so band boundaries land on
-- round numbers. Banding priorities is the owner's business under the queue's
-- contract, and this mapping plays that role for the tests, clamping
-- out-of-range values into the edge bands the way an owner must.
local BAND_COUNT = 10
local BAND_WIDTH = 10
local function bandFromPriority(priority: number): number
	return math.clamp(priority // BAND_WIDTH + 1, 1, BAND_COUNT)
end

describe("BandedQueue", function()
	local queue
	local stagedItems: { string }
	local stagedBands: { number }
	local stagedSize: number

	beforeEach(function()
		queue = BandedQueue.new(BAND_COUNT)
		stagedItems = {}
		stagedBands = {}
		stagedSize = 0
	end)

	--[[
		Appends one item to the test's staging arrays with its band computed
		from the priority, the shape an owner stages in.
	]]
	local function stage(item: string, priority: number)
		stagedSize += 1
		stagedItems[stagedSize] = item
		stagedBands[stagedSize] = bandFromPriority(priority)
	end

	--[[
		Hands the staged arrays to the queue and resets them for the next batch.
	]]
	local function fill()
		queue:enqueueBatch(stagedItems, stagedBands, stagedSize)
		table.clear(stagedItems)
		table.clear(stagedBands)
		stagedSize = 0
	end

	--[[
		Drains the queue proper, returning the items in dequeue order plus a map
		of each item's dequeued band.
	]]
	local function drainAll()
		local order = {}
		local bands = {}
		while not queue:isEmpty() do
			local item, band = queue:dequeue()
			table.insert(order, item)
			bands[item] = band
		end
		return order, bands
	end

	describe("new", function()
		it("creates an empty queue", function()
			expect(queue).toBeDefined()
			expect(queue:len()).toBe(0)
			expect(queue:isEmpty()).toBe(true)
		end)
	end)

	describe("enqueueBatch", function()
		it("lays items out in ascending band order regardless of staging order", function()
			stage("band10", 95)
			stage("band1", 5)
			stage("band6", 55)
			stage("band3", 25)
			fill()

			local order = drainAll()
			expect(order).toEqual({ "band1", "band3", "band6", "band10" })
		end)

		it("keeps items that share a band in staged order rather than priority order", function()
			-- All three land in the same band, and the middle one carries the
			-- highest priority value. Staged order winning here is the queue's
			-- defining relaxation, so this pins it directly.
			stage("first", 12)
			stage("second", 18)
			stage("third", 15)
			fill()

			local order = drainAll()
			expect(order).toEqual({ "first", "second", "third" })
		end)

		it("orders across bands while keeping staged order within each band", function()
			stage("highLate", 25)
			stage("lowEarly", 5)
			stage("highEarlier", 21)
			stage("lowLater", 8)
			fill()

			-- Band one drains before band three, and within each band the
			-- staged order holds even where it disagrees with priority order.
			local order = drainAll()
			expect(order).toEqual({ "lowEarly", "lowLater", "highLate", "highEarlier" })
		end)

		it("returns each item's band from dequeue", function()
			stage("a", 42)
			stage("b", 7)
			fill()

			local _order, bands = drainAll()
			expect(bands.a).toBe(5)
			expect(bands.b).toBe(1)
		end)

		it("only reads the caller's arrays without keeping or writing them", function()
			stage("kept", 5)
			local itemsIdentity = stagedItems
			local bandsIdentity = stagedBands
			queue:enqueueBatch(stagedItems, stagedBands, stagedSize)

			-- The caller's arrays came back untouched, and mutating them after
			-- the fill can't reach into the laid-out queue.
			expect(stagedItems[1]).toBe("kept")
			expect(stagedBands[1]).toBe(1)
			stagedItems[1] = "mutated"
			expect(stagedItems).toBe(itemsIdentity)
			expect(stagedBands).toBe(bandsIdentity)
			expect((queue:dequeue())).toBe("kept")
		end)

		it("does nothing on an empty batch", function()
			fill()
			expect(queue:isEmpty()).toBe(true)
			expect(queue:len()).toBe(0)
		end)

		it("appends a later batch behind the current layout without merging", function()
			stage("laidFirst", 50)
			fill()

			-- The second batch carries a lower band, but the queue's contract
			-- is one staged batch per drain cycle, so it lands behind whatever
			-- is already laid out.
			stage("laidSecond", 5)
			fill()

			local order = drainAll()
			expect(order).toEqual({ "laidFirst", "laidSecond" })
		end)

		it("returns the per-band tallies to zero between fills", function()
			-- A fill leaves its per-band tallies zeroed for the next one, so a
			-- second full cycle through clear and refill must come out just as
			-- ordered as the first.
			stage("firstCycleLate", 95)
			stage("firstCycleEarly", 5)
			fill()
			expect((drainAll())).toEqual({ "firstCycleEarly", "firstCycleLate" })

			queue:clear()
			stage("secondCycleLate", 75)
			stage("secondCycleEarly", 35)
			fill()
			expect((drainAll())).toEqual({ "secondCycleEarly", "secondCycleLate" })
		end)

		it("appends a fill behind a partially drained layout", function()
			-- The owner's contract is to clear between frames, so a fill landing
			-- on a partially drained layout is outside it. This documents the
			-- owner-side corner as it stands. The batch appends behind the
			-- existing layout, band order notwithstanding, and the drain's
			-- progress stands.
			stage("first", 15)
			stage("second", 25)
			fill()
			expect((queue:dequeue())).toBe("first")

			stage("appended", 5)
			fill()

			expect(queue:len()).toBe(2)
			local order = drainAll()
			expect(order).toEqual({ "second", "appended" })
		end)

		it("drains every staged item exactly once in non-decreasing band order", function()
			-- The staged priorities cycle through the bands in a scrambled
			-- order, and the drain must visit each item exactly once with the
			-- band index never decreasing.
			local stagedByItem = {}
			for i = 1, 100 do
				local priority = (i * 37) % 100
				local item = `item{i}`
				stagedByItem[item] = bandFromPriority(priority)
				stage(item, priority)
			end
			fill()

			local order, bands = drainAll()
			expect(#order).toBe(100)
			local previousBand = 1
			local seen = {}
			for _, item in order do
				expect(seen[item]).toBeNil()
				seen[item] = true
				expect(bands[item]).toBe(stagedByItem[item])
				expect(bands[item] >= previousBand).toBe(true)
				previousBand = bands[item]
			end
		end)
	end)

	describe("dequeue", function()
		it("asserts on an empty queue", function()
			expect(function()
				queue:dequeue()
			end).toThrow("Queue is empty")
		end)

		it("tracks len and isEmpty through a drain", function()
			stage("a", 5)
			stage("b", 15)
			stage("c", 25)
			fill()

			expect(queue:len()).toBe(3)
			queue:dequeue()
			expect(queue:len()).toBe(2)
			expect(queue:isEmpty()).toBe(false)
			queue:dequeue()
			queue:dequeue()
			expect(queue:len()).toBe(0)
			expect(queue:isEmpty()).toBe(true)
		end)
	end)

	describe("drainView", function()
		it("hands over the layout in the same order dequeue walks", function()
			stage("late", 95)
			stage("early", 5)
			stage("middle", 55)
			fill()

			local items, bands, cursor, size = queue:drainView()
			expect(cursor).toBe(0)
			expect(size).toBe(3)
			expect(items[1]).toBe("early")
			expect(items[2]).toBe("middle")
			expect(items[3]).toBe("late")
			expect(bands[1]).toBe(1)
			expect(bands[2]).toBe(6)
			expect(bands[3]).toBe(10)
		end)

		it("keeps a bulk drain and dequeue agreed through the cursor", function()
			stage("a", 5)
			stage("b", 15)
			stage("c", 25)
			fill()

			-- The bulk drain walks two items and stores each position back into
			-- the cursor as it goes, which is the drainView contract. A regular
			-- dequeue afterward must pick up exactly where the walk stopped.
			local items, _bands, cursor, size = queue:drainView()
			local walked = {}
			while cursor < size and #walked < 2 do
				cursor += 1
				queue._cursor = cursor
				table.insert(walked, items[cursor])
			end

			expect(walked).toEqual({ "a", "b" })
			expect(queue:len()).toBe(1)
			expect((queue:dequeue())).toBe("c")
			expect(queue:isEmpty()).toBe(true)
		end)

		it("starts a later view at the committed cursor", function()
			stage("a", 5)
			stage("b", 15)
			fill()
			queue:dequeue()

			local _items, _bands, cursor, size = queue:drainView()
			expect(cursor).toBe(1)
			expect(size).toBe(2)
		end)

		it("moves the fill epoch on clear and on resize", function()
			stage("a", 5)
			fill()

			-- Both operations invalidate any captured layout, so both must move
			-- the epoch a captured view would compare against.
			local _items, _bands, _cursor, _size, epochAtFill = queue:drainView()
			queue:clear()
			local _items2, _bands2, _cursor2, _size2, epochAfterClear = queue:drainView()
			expect(epochAfterClear).never.toBe(epochAtFill)

			queue:resize()
			local _items3, _bands3, _cursor3, _size3, epochAfterResize = queue:drainView()
			expect(epochAfterResize).never.toBe(epochAfterClear)
		end)

		it("flags a cleared layout to a stale drain through the epoch", function()
			stage("a", 5)
			stage("b", 15)
			fill()

			-- An iterator captures the layout the way the facade's update loop
			-- does, walks one item, and goes dormant holding its epoch.
			local items, _bands, cursor, size, epoch = queue:drainView()
			cursor += 1
			queue._cursor = cursor
			expect(items[cursor]).toBe("a")
			expect(cursor < size).toBe(true)

			-- The frame ends and the owner clears and refills. The captured
			-- view now describes a queue that no longer exists, and the epoch
			-- is the tell the consumer checks before touching the arrays again.
			queue:clear()
			stage("c", 25)
			fill()

			local _items2, _bands2, _cursor2, _size2, freshEpoch = queue:drainView()
			expect(freshEpoch == epoch).toBe(false)
			-- The stale drain ends at the mismatch without writing its cursor
			-- back, so the fresh layout drains in full.
			expect((drainAll())).toEqual({ "c" })
		end)
	end)

	describe("resize", function()
		it("keeps a partially drained layout and its cursor across a resize", function()
			stage("a", 5)
			stage("b", 15)
			stage("c", 25)
			fill()
			expect((queue:dequeue())).toBe("a")

			local itemsBefore, _bandsBefore, _cursorBefore, _sizeBefore, epochBefore = queue:drainView()
			queue:resize()
			local itemsAfter, _bandsAfter, cursorAfter, sizeAfter, epochAfter = queue:drainView()

			-- The layout moved into fresh arrays, so the epoch flags every
			-- captured view as stale.
			expect(itemsAfter == itemsBefore).toBe(false)
			expect(epochAfter == epochBefore).toBe(false)
			-- The rebuild preserves the contents and the drain's progress.
			expect(cursorAfter).toBe(1)
			expect(sizeAfter).toBe(3)
			expect(queue:len()).toBe(2)
			expect((queue:dequeue())).toBe("b")
			expect((queue:dequeue())).toBe("c")
			expect(queue:isEmpty()).toBe(true)
		end)
	end)

	describe("clear", function()
		it("empties the queue proper", function()
			stage("a", 5)
			stage("b", 15)
			fill()

			queue:clear()

			expect(queue:isEmpty()).toBe(true)
			expect(queue:len()).toBe(0)
			expect(function()
				queue:dequeue()
			end).toThrow("Queue is empty")
		end)

		it("clears a partially drained queue", function()
			stage("a", 5)
			stage("b", 15)
			fill()
			queue:dequeue()

			queue:clear()

			expect(queue:isEmpty()).toBe(true)
			expect(queue:len()).toBe(0)
		end)
	end)
end)
