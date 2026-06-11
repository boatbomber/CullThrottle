local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages, DevPackages = ReplicatedStorage:WaitForChild("Packages"), ReplicatedStorage:WaitForChild("DevPackages")

local JestGlobals = require(DevPackages:WaitForChild("JestGlobals"))

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local beforeEach = JestGlobals.beforeEach
local afterEach = JestGlobals.afterEach

local CullThrottlePackage = Packages:WaitForChild("CullThrottle")
local CullThrottle = require(CullThrottlePackage)
local Ingest = require(CullThrottlePackage:WaitForChild("Ingest"))

local TestHelpers = require(script.Parent.TestHelpers)
local createMockPart = TestHelpers.createMockPart

--[[
	Spins on os.clock without yielding until the given deadline has passed.
	Yielding would hand the real frame loop a chance to process visibility and
	clear the update queue mid-test, so the budget probes burn the time in
	place instead.
]]
local function busyWaitUntil(deadline: number)
	local spins = 0
	while os.clock() < deadline do
		spins += 1
	end
end

describe("CullThrottle queries", function()
	local cullThrottle

	beforeEach(function()
		cullThrottle = CullThrottle.new()
	end)

	afterEach(function()
		if cullThrottle then
			cullThrottle:Destroy()
		end
		cullThrottle = nil
	end)

	describe("GetVisibleObjects", function()
		it("should return empty array when no objects are visible", function()
			local visibleObjects = cullThrottle:GetVisibleObjects()
			expect(#visibleObjects).toBe(0)
		end)

		it("returns objects in the frustum and excludes ones behind or beyond render distance", function()
			-- Place objects relative to the live camera so the real frustum pass,
			-- not a hand-built plane set, decides what is visible.
			local camera = workspace.CurrentCamera
			local camCFrame = camera.CFrame

			local frontPart = createMockPart((camCFrame * CFrame.new(0, 0, -80)).Position)
			local behindPart = createMockPart((camCFrame * CFrame.new(0, 0, 120)).Position)
			local farPart = createMockPart((camCFrame * CFrame.new(0, 0, -5000)).Position)

			cullThrottle:AddObject(frontPart)
			cullThrottle:AddObject(behindPart)
			cullThrottle:AddObject(farPart)

			-- Give it generous budgets so the search and precise ingest run to completion.
			cullThrottle:SetTimeBudgets(1, 1, 1)

			local visibleObjects = cullThrottle:GetVisibleObjects()

			expect(table.find(visibleObjects, frontPart)).never.toBeNil()
			expect(table.find(visibleObjects, behindPart)).toBeNil()
			expect(table.find(visibleObjects, farPart)).toBeNil()

			frontPart:Destroy()
			behindPart:Destroy()
			farPart:Destroy()
		end)

		it("does not return an object removed later in the same frame", function()
			local camera = workspace.CurrentCamera
			local keptPart = createMockPart((camera.CFrame * CFrame.new(-6, 0, -80)).Position)
			local removedPart = createMockPart((camera.CFrame * CFrame.new(6, 0, -80)).Position)
			cullThrottle:AddObject(keptPart)
			cullThrottle:AddObject(removedPart)

			cullThrottle:SetTimeBudgets(1, 1, 1)
			cullThrottle:_processObjectVisibility(os.clock())

			-- Removal never scrubs the staged visibility batch, and the same-frame
			-- short-circuit means this snapshot is served from that stale batch.
			-- The removed object must be filtered out of it anyway.
			cullThrottle:RemoveObject(removedPart)

			local visibleObjects = cullThrottle:GetVisibleObjects()
			expect(table.find(visibleObjects, keptPart)).never.toBeNil()
			expect(table.find(visibleObjects, removedPart)).toBeNil()

			keptPart:Destroy()
			removedPart:Destroy()
		end)

		it("still returns the visible snapshot after the update iterator drained the queue", function()
			local camera = workspace.CurrentCamera
			local partA = createMockPart((camera.CFrame * CFrame.new(-6, 0, -80)).Position)
			local partB = createMockPart((camera.CFrame * CFrame.new(6, 0, -80)).Position)
			cullThrottle:AddObject(partA)
			cullThrottle:AddObject(partB)

			cullThrottle:SetTimeBudgets(1, 1, 1)
			cullThrottle:_processObjectVisibility(os.clock())

			for _ in cullThrottle:IterateObjectsToUpdate() do
				local _
			end

			-- The iterator consumes the queue, but the staged batch it was built
			-- from survives until the next frame, so the snapshot must still
			-- reflect everything visible this frame.
			local visibleObjects = cullThrottle:GetVisibleObjects()
			expect(table.find(visibleObjects, partA)).never.toBeNil()
			expect(table.find(visibleObjects, partB)).never.toBeNil()

			partA:Destroy()
			partB:Destroy()
		end)
	end)

	describe("IterateObjectsToUpdate", function()
		it("yields every visible object with its update data", function()
			local camera = workspace.CurrentCamera
			local part1 = createMockPart((camera.CFrame * CFrame.new(-6, 0, -80)).Position)
			local part2 = createMockPart((camera.CFrame * CFrame.new(6, 0, -80)).Position)

			cullThrottle:AddObject(part1)
			cullThrottle:AddObject(part2)

			cullThrottle:SetTimeBudgets(1, 1, 1)
			cullThrottle:_processObjectVisibility(os.clock())

			local yielded = {}
			for object, deltaTime, distance, cframe in cullThrottle:IterateObjectsToUpdate() do
				yielded[object] = true
				expect(type(deltaTime)).toBe("number")
				expect(type(distance)).toBe("number")
				expect(typeof(cframe)).toBe("CFrame")
			end

			expect(yielded[part1]).toBe(true)
			expect(yielded[part2]).toBe(true)

			part1:Destroy()
			part2:Destroy()
		end)

		it("yields a visible object with its real distance and cframe", function()
			local camera = workspace.CurrentCamera
			local frontPart = createMockPart((camera.CFrame * CFrame.new(0, 0, -80)).Position)
			cullThrottle:AddObject(frontPart)

			-- Give it generous budgets so the search runs to completion and the update
			-- loop doesn't bail before reaching the object.
			cullThrottle:SetTimeBudgets(1, 1, 1)
			cullThrottle:_processObjectVisibility(os.clock())

			local seen
			for object, deltaTime, distance, cframe in cullThrottle:IterateObjectsToUpdate() do
				if object == frontPart then
					seen = { deltaTime = deltaTime, distance = distance, cframe = cframe }
				end
			end

			expect(seen).toBeDefined()
			expect(type(seen.deltaTime)).toBe("number")
			-- The object sits 80 studs down the camera's look vector.
			expect(seen.distance).toBeCloseTo(80)
			expect(typeof(seen.cframe)).toBe("CFrame")

			frontPart:Destroy()
		end)

		it("skips objects removed while still queued instead of ending iteration", function()
			local camera = workspace.CurrentCamera
			local nearPart = createMockPart((camera.CFrame * CFrame.new(0, 0, -20)).Position)
			local midPart = createMockPart((camera.CFrame * CFrame.new(6, 0, -60)).Position)
			local farPart = createMockPart((camera.CFrame * CFrame.new(-6, 0, -100)).Position)
			cullThrottle:AddObject(nearPart)
			cullThrottle:AddObject(midPart)
			cullThrottle:AddObject(farPart)

			cullThrottle:SetTimeBudgets(1, 1, 1)
			cullThrottle:_processObjectVisibility(os.clock())

			-- Creating the iterator heapifies the queue with all three parts, so
			-- removing the nearest one afterward leaves its stale entry at the
			-- front of the queue. The iterator must skip past it and still yield
			-- the other two.
			local iterator = cullThrottle:IterateObjectsToUpdate()
			cullThrottle:RemoveObject(nearPart)

			local yielded = {}
			for object in iterator do
				yielded[object] = true
			end

			expect(yielded[nearPart]).toBeUndefined()
			expect(yielded[midPart]).toBe(true)
			expect(yielded[farPart]).toBe(true)

			nearPart:Destroy()
			midPart:Destroy()
			farPart:Destroy()
		end)

		it("does not re-yield this frame's objects to a second iteration", function()
			local camera = workspace.CurrentCamera
			local partA = createMockPart((camera.CFrame * CFrame.new(-6, 0, -80)).Position)
			local partB = createMockPart((camera.CFrame * CFrame.new(6, 0, -80)).Position)
			cullThrottle:AddObject(partA)
			cullThrottle:AddObject(partB)

			cullThrottle:SetTimeBudgets(1, 1, 1)
			cullThrottle:_processObjectVisibility(os.clock())

			local firstCount = 0
			for _ in cullThrottle:IterateObjectsToUpdate() do
				firstCount += 1
			end

			-- The first iteration drained the queue, so a second one in the same
			-- frame must not re-enqueue the staged batch and update everything
			-- again with near-zero delta times.
			local secondCount = 0
			for _ in cullThrottle:IterateObjectsToUpdate() do
				secondCount += 1
			end

			expect(firstCount).toBe(2)
			expect(secondCount).toBe(0)

			partA:Destroy()
			partB:Destroy()
		end)

		it("commits a completed iteration's delta times into the average on the next frame", function()
			local camera = workspace.CurrentCamera
			local partA = createMockPart((camera.CFrame * CFrame.new(-6, 0, -80)).Position)
			local partB = createMockPart((camera.CFrame * CFrame.new(6, 0, -80)).Position)
			cullThrottle:AddObject(partA)
			cullThrottle:AddObject(partB)

			cullThrottle:SetTimeBudgets(1, 1, 1)
			cullThrottle:_processObjectVisibility(os.clock())

			-- Give the objects a known half-second delta so the committed average
			-- stands out from the default the metric starts at.
			cullThrottle._lifecycle._objects[partA].lastUpdateClock = os.clock() - 0.5
			cullThrottle._lifecycle._objects[partB].lastUpdateClock = os.clock() - 0.5

			for _ in cullThrottle:IterateObjectsToUpdate() do
				local _
			end

			-- The commit lands at the start of the next processed frame.
			cullThrottle._processedVisibilityThisFrame = false
			cullThrottle:_processObjectVisibility(os.clock())

			expect(cullThrottle._perfMetrics._averageObjectDeltaTime).toBeCloseTo(0.5, 1)

			partA:Destroy()
			partB:Destroy()
		end)

		it("folds an abandoned iteration's delta times into the average on the next frame", function()
			local camera = workspace.CurrentCamera
			local partA = createMockPart((camera.CFrame * CFrame.new(-6, 0, -80)).Position)
			local partB = createMockPart((camera.CFrame * CFrame.new(6, 0, -80)).Position)
			cullThrottle:AddObject(partA)
			cullThrottle:AddObject(partB)

			cullThrottle:SetTimeBudgets(1, 1, 1)
			cullThrottle:_processObjectVisibility(os.clock())

			cullThrottle._lifecycle._objects[partA].lastUpdateClock = os.clock() - 0.5
			cullThrottle._lifecycle._objects[partB].lastUpdateClock = os.clock() - 0.5

			-- Consume one object and abandon the iterator, the way a consumer
			-- breaking out of the loop partway through does. The extra parens
			-- truncate the iterator's multiple return values to just the object.
			local iterator = cullThrottle:IterateObjectsToUpdate()
			expect((iterator())).toBeDefined()

			-- Simulate the next frame. Its visibility pass must fold the abandoned
			-- iteration's pending delta times into the average instead of losing
			-- the updates that were already handed out.
			cullThrottle._processedVisibilityThisFrame = false
			cullThrottle:_processObjectVisibility(os.clock())

			expect(cullThrottle._perfMetrics._averageObjectDeltaTime).toBeCloseTo(0.5, 1)

			partA:Destroy()
			partB:Destroy()
		end)

		it("stops iterating and clears the queue when the update budget is exhausted", function()
			local camera = workspace.CurrentCamera
			local parts = {}
			for i = 1, 5 do
				local part = createMockPart((camera.CFrame * CFrame.new(i * 6, 0, -80)).Position)
				cullThrottle:AddObject(part)
				parts[i] = part
			end

			-- A zero update budget (and no strict enforcement) means even the first
			-- dequeue is already over budget, so nothing should be iterated.
			cullThrottle:SetTimeBudgets(1, 1, 0)
			cullThrottle:SetStrictlyEnforceWorstRefreshRate(false)
			cullThrottle:_processObjectVisibility(os.clock())

			local count = 0
			for _ in cullThrottle:IterateObjectsToUpdate() do
				count += 1
			end

			expect(count).toBe(0)
			-- Leftovers are cleared so they can't spill into a second iteration.
			expect(cullThrottle._ingest._visibleObjectsQueue:isEmpty()).toBe(true)

			for _, part in parts do
				part:Destroy()
			end
		end)

		it("keeps updating overdue p0 objects past the normal budget under strict enforcement", function()
			local camera = workspace.CurrentCamera
			local part = createMockPart((camera.CFrame * CFrame.new(0, 0, -80)).Position)
			cullThrottle:AddObject(part)

			-- Make the object overdue before ingest so it is enqueued in the p0
			-- priority band (the band is decided at ingest time, not at iteration).
			cullThrottle._lifecycle._objects[part].lastUpdateClock = os.clock() - 100

			-- The normal budget is exhausted immediately, but strict enforcement
			-- raises the p0 budget so worst-rate objects still update.
			cullThrottle:SetTimeBudgets(1, 1, 0)
			cullThrottle:SetStrictlyEnforceWorstRefreshRate(true)
			cullThrottle:_processObjectVisibility(os.clock())

			local seen = false
			for object in cullThrottle:IterateObjectsToUpdate() do
				if object == part then
					seen = true
				end
			end

			expect(seen).toBe(true)

			part:Destroy()
		end)

		it("holds overdue p0 objects to the scaled update budget when enforcement is lax", function()
			local camera = workspace.CurrentCamera
			local part = createMockPart((camera.CFrame * CFrame.new(0, 0, -80)).Position)
			cullThrottle:AddObject(part)

			-- The object is overdue, so ingest places it in the p0 priority band.
			cullThrottle._lifecycle._objects[part].lastUpdateClock = os.clock() - 100

			-- Without strict enforcement a p0 object only gets the normal budget
			-- scaled by the overrun factor, and zero scaled by any factor is still
			-- zero, so even the overdue object must not be yielded. This is what
			-- separates the lax overrun from the strict flag's unbounded budget.
			cullThrottle:SetTimeBudgets(1, 1, 0)
			cullThrottle:SetStrictlyEnforceWorstRefreshRate(false)
			cullThrottle:_processObjectVisibility(os.clock())

			local seenOverdue = false
			for object in cullThrottle:IterateObjectsToUpdate() do
				if object == part then
					seenOverdue = true
				end
			end

			expect(seenOverdue).toBe(false)

			part:Destroy()
		end)

		it("lets p0 objects overrun a nonzero update budget by the allowance and no further", function()
			local camera = workspace.CurrentCamera
			local parts = {}
			for i = 1, 3 do
				local part = createMockPart((camera.CFrame * CFrame.new((i - 2) * 6, 0, -80)).Position)
				cullThrottle:AddObject(part)
				parts[i] = part
			end

			-- Every object is overdue before ingest so all of them land in the p0
			-- priority band.
			for _, part in parts do
				cullThrottle._lifecycle._objects[part].lastUpdateClock = os.clock() - 100
			end

			-- A 10ms budget makes the overrun allowance (15 percent, so 11.5ms)
			-- wide enough to probe between the two cutoffs without flakes.
			local updateBudget = 0.01
			cullThrottle:SetTimeBudgets(1, 1, updateBudget)
			cullThrottle:SetStrictlyEnforceWorstRefreshRate(false)
			cullThrottle:_processObjectVisibility(os.clock())

			-- The iterator anchors its budget clock when it is created, so this
			-- reference clock is taken right beside it. The extra parens truncate
			-- the iterator's multiple return values to just the object.
			local startClock = os.clock()
			local iterator = cullThrottle:IterateObjectsToUpdate()

			-- The first object comes out well inside the base budget.
			expect((iterator())).toBeDefined()

			-- Just past the base budget but inside the overrun allowance, a p0
			-- object must still come out. Holding the budget to the base amount
			-- here would erase the documented allowance.
			busyWaitUntil(startClock + updateBudget * 1.05)
			expect((iterator())).toBeDefined()

			-- Past the overrun allowance, even p0 objects stop.
			busyWaitUntil(startClock + updateBudget * 1.3)
			expect((iterator())).toBeNil()

			for _, part in parts do
				part:Destroy()
			end
		end)

		it("holds a priority exactly at the p0 threshold to the plain update budget", function()
			-- The part sits far beyond render distance so the real passes are
			-- guaranteed to cull it, leaving the queue holding exactly the
			-- handpicked entry below.
			local camera = workspace.CurrentCamera
			local part = createMockPart((camera.CFrame * CFrame.new(0, 0, 5000)).Position)
			cullThrottle:AddObject(part)

			-- Strict enforcement raises the p0 budget to effectively unbounded,
			-- making the two budgets maximally distinguishable.
			cullThrottle:SetTimeBudgets(0, 0, 0)
			cullThrottle:SetStrictlyEnforceWorstRefreshRate(true)
			cullThrottle:_processObjectVisibility(os.clock())

			-- The queue is staged directly with a handpicked priority because the
			-- boundary matters here. The iterator's overrun comparison is strict,
			-- so a priority exactly at the threshold takes the plain (zero)
			-- budget, and the edge is reachable since an overdue object with zero
			-- screen size prices at exactly the threshold.
			cullThrottle._ingest._visibleObjectsQueue:addToIncomingBatch(part, Ingest.P0_THRESHOLD)

			local count = 0
			for _ in cullThrottle:IterateObjectsToUpdate() do
				count += 1
			end

			expect(count).toBe(0)

			part:Destroy()
		end)

		it("grants the raised p0 budget to a priority strictly under the threshold", function()
			-- Like the exactly-at case, the part sits beyond render distance so
			-- only the handpicked entry reaches the queue.
			local camera = workspace.CurrentCamera
			local part = createMockPart((camera.CFrame * CFrame.new(0, 0, 5000)).Position)
			cullThrottle:AddObject(part)

			cullThrottle:SetTimeBudgets(0, 0, 0)
			cullThrottle:SetStrictlyEnforceWorstRefreshRate(true)
			cullThrottle:_processObjectVisibility(os.clock())

			-- This priority sits a hair under the threshold, so unlike the
			-- exactly-at case it counts as p0 and gets the raised budget, which
			-- is what lets it come out despite the plain budget being zero.
			cullThrottle._ingest._visibleObjectsQueue:addToIncomingBatch(part, Ingest.P0_THRESHOLD - 0.01)

			local yielded = {}
			for object in cullThrottle:IterateObjectsToUpdate() do
				yielded[object] = true
			end

			expect(yielded[part]).toBe(true)

			part:Destroy()
		end)

		it("excludes objects unseen for over a second from the delta time average", function()
			local camera = workspace.CurrentCamera
			local stalePart = createMockPart((camera.CFrame * CFrame.new(-6, 0, -80)).Position)
			local freshPart = createMockPart((camera.CFrame * CFrame.new(6, 0, -80)).Position)
			cullThrottle:AddObject(stalePart)
			cullThrottle:AddObject(freshPart)

			cullThrottle:SetTimeBudgets(1, 1, 1)
			cullThrottle:_processObjectVisibility(os.clock())

			-- A delta over a second reflects time the object spent out of view,
			-- not its real refresh cadence, so only the fresh part's delta should
			-- reach the average. Folding the stale one in would drag the average
			-- to ~50 and mislead the render distance controller.
			cullThrottle._lifecycle._objects[stalePart].lastUpdateClock = os.clock() - 100
			cullThrottle._lifecycle._objects[freshPart].lastUpdateClock = os.clock() - 0.5

			for _ in cullThrottle:IterateObjectsToUpdate() do
				local _
			end

			-- The commit lands at the start of the next processed frame.
			cullThrottle._processedVisibilityThisFrame = false
			cullThrottle:_processObjectVisibility(os.clock())

			expect(cullThrottle._perfMetrics._averageObjectDeltaTime).toBeCloseTo(0.5, 1)

			stalePart:Destroy()
			freshPart:Destroy()
		end)
	end)

	describe("Performance metrics", function()
		it("seeds the average object delta time with the best refresh period", function()
			-- The seed feeds the render distance controller before any real
			-- updates have been committed, so a fresh instance starts at the
			-- default best refresh period.
			expect(cullThrottle._perfMetrics._averageObjectDeltaTime).toBeCloseTo(1 / 60)
		end)

		it("averages over the lookback window length, not the input length", function()
			-- The helper only ever sees the fixed-length skipped-frame ring
			-- buffers, so it divides by the lookback window length. A three-value
			-- input makes a divide-by-input-length mistake produce a different
			-- answer.
			local average = cullThrottle._perfMetrics._getAverage({ 2, 4, 6 })
			expect(average).toBe(3)
		end)

		it("records fresh search and ingest durations each visibility pass", function()
			-- Both durations get planted with an impossible value first, so the
			-- assertions can only pass if the pass overwrote them.
			cullThrottle._perfMetrics._searchDuration = -1
			cullThrottle._perfMetrics._ingestDuration = -1

			cullThrottle:_findVisibleObjects(os.clock())

			expect(cullThrottle._perfMetrics._searchDuration).toBeGreaterThanOrEqual(0)
			expect(cullThrottle._perfMetrics._ingestDuration).toBeGreaterThanOrEqual(0)
		end)
	end)

	describe("Edge cases", function()
		it("should handle objects with tiny size", function()
			local part = createMockPart(Vector3.new(0, 0, 0), Vector3.new(0, 0, 0))

			expect(function()
				cullThrottle:AddObject(part)
			end).never.toThrow()

			local objectData = cullThrottle._lifecycle._objects[part]
			expect(objectData).toBeDefined()
			expect(objectData.radius).toBeLessThanOrEqual(0.01)

			part:Destroy()
		end)

		it("should handle objects at extreme distances", function()
			local farPart = createMockPart(Vector3.new(1000000, 1000000, 1000000))
			local nearPart = createMockPart(Vector3.new(0.1, 0.1, 0.1))

			expect(function()
				cullThrottle:AddObject(farPart)
				cullThrottle:AddObject(nearPart)
			end).never.toThrow()

			farPart:Destroy()
			nearPart:Destroy()
		end)

		it("should handle rapid add/remove cycles", function()
			local part = createMockPart()

			expect(function()
				for _ = 1, 10 do
					cullThrottle:AddObject(part)
					cullThrottle:RemoveObject(part)
				end
			end).never.toThrow()

			expect(cullThrottle._lifecycle._objects[part]).toBeNil()

			part:Destroy()
		end)

		it("should handle processing with no objects", function()
			expect(function()
				cullThrottle:_processObjectVisibility(os.clock())
				cullThrottle:GetVisibleObjects()
				for _ in cullThrottle:IterateObjectsToUpdate() do
					local _
				end
			end).never.toThrow()
		end)
	end)
end)
