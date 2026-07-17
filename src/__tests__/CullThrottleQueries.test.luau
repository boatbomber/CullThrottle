local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
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
local Utilities = CullThrottlePackage:WaitForChild("Utilities")
local CameraCache = require(Utilities:WaitForChild("CameraCache"))

local TestHelpers = require(script.Parent.TestHelpers)
local createMockPart = TestHelpers.createMockPart
local patchFunction = TestHelpers.patchFunction
local roomyFrustumPlanes = TestHelpers.roomyFrustumPlanes

--[[
	Spins on os.clock without yielding until the given deadline has passed.
	Yielding would hand the real frame loop a chance to process visibility and
	clear the update queue mid-test, so the budget probes burn the time in
	place instead.
]]
local function busyWaitUntil(deadline: number)
	local now = os.clock()
	while now < deadline do
		now = os.clock()
	end
end

describe("CullThrottle queries", function()
	local cullThrottle

	beforeEach(function()
		cullThrottle = CullThrottle.new()
	end)

	afterEach(function()
		-- Module tables are shared state, so any values patched onto them must
		-- be unwound before the next test.
		TestHelpers.restorePatches()
		if cullThrottle then
			cullThrottle:Destroy()
		end
		cullThrottle = nil
	end)

	describe("GetVisibleObjects", function()
		it("returns an empty array when no objects are visible", function()
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

		it("returns each object exactly once when the truncated search leans on the fallback", function()
			-- The search geometry is pinned to the shared roomy fixture (a camera
			-- at the origin facing plus Y), and the camera reads the ingest
			-- passes score against are parked at the same pose, so both halves
			-- of the pipeline agree on what is in view no matter where the live
			-- camera happens to sit.
			patchFunction(CameraCache, "getPlanesAndBounds", function()
				return roomyFrustumPlanes, Vector3.new(0, 0, 0), Vector3.new(19, 27, 3)
			end)
			patchFunction(CameraCache, "CFrame", CFrame.lookAt(Vector3.zero, Vector3.yAxis, Vector3.zAxis))
			patchFunction(CameraCache, "Position", Vector3.zero)

			-- These six voxels sit inside the fixture frustum while their coarse
			-- buckets straddle its side planes, so every one of them seeds a
			-- root volume and the budgeted volume loop has leftovers to abandon
			-- once its time is gone.
			local singleVoxelKeys = {
				Vector3.new(1, 3, 0),
				Vector3.new(1, 5, 0),
				Vector3.new(5, 11, 0),
				Vector3.new(8, 15, 0),
				Vector3.new(9, 19, 0),
				Vector3.new(12, 23, 0),
			}
			local parts = {}
			for i, voxelKey in singleVoxelKeys do
				local part = createMockPart((voxelKey + Vector3.new(0.5, 0.5, 0.5)) * 100)
				cullThrottle:AddObject(part)
				parts[i] = part
			end

			-- This part is large enough to straddle the voxel boundary at
			-- y = 800, so it occupies two voxels that resolve through different
			-- paths (one rides a straddling bucket's search volume, the other a
			-- fully inside bucket's bulk append). The README promises the
			-- visible list holds it once anyway.
			local spanningPart = createMockPart(Vector3.new(150, 800, 50), Vector3.new(10, 120, 10))
			cullThrottle:AddObject(spanningPart)

			-- The pinned distance covers every staged part from the fixture
			-- camera's origin.
			cullThrottle:SetRenderDistanceRange(NumberRange.new(4000, 4000))
			cullThrottle:SetTimeBudgets(1, 1, 1)

			-- A first, fully budgeted frame stamps a real visible proof on every
			-- staged voxel, which is what the truncated frame's fallback reuses
			-- below.
			cullThrottle:_processObjectVisibility(os.clock())

			-- Nothing the whole-frame replay watches moves between these frames,
			-- so it gets disarmed by hand to force the truncated frame to
			-- re-run the search.
			cullThrottle._search._replayReady = false

			cullThrottle:SetTimeBudgets(0, 1, 1)
			cullThrottle._processedVisibilityThisFrame = false
			local visibleObjects = cullThrottle:GetVisibleObjects()

			-- The zero budget must have pushed the search into its fallback, or
			-- this test isn't exercising the composite promise it claims to.
			expect(cullThrottle:GetPerformanceMetrics().skippedSearch).toBeGreaterThan(0)

			local seen = {}
			for _, object in visibleObjects do
				expect(seen[object]).toBeUndefined()
				seen[object] = true
			end
			for _, part in parts do
				expect(seen[part]).toBe(true)
			end
			expect(seen[spanningPart]).toBe(true)

			for _, part in parts do
				part:Destroy()
			end
			spanningPart:Destroy()
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

			-- Creating the iterator lays the queue out with all three parts, so
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

		it("ends a stale iterator held across frames instead of corrupting the fresh drain", function()
			local camera = workspace.CurrentCamera
			local partA = createMockPart((camera.CFrame * CFrame.new(-6, 0, -80)).Position)
			local partB = createMockPart((camera.CFrame * CFrame.new(6, 0, -80)).Position)
			cullThrottle:AddObject(partA)
			cullThrottle:AddObject(partB)

			cullThrottle:SetTimeBudgets(1, 1, 1)
			cullThrottle:_processObjectVisibility(os.clock())

			-- Hold an iterator across the frame boundary after yielding one
			-- object. The extra parens truncate the multiple return values.
			local staleIterator = cullThrottle:IterateObjectsToUpdate()
			expect((staleIterator())).toBeDefined()

			-- The next frame clears and restages the queue, so the held
			-- closure's captured layout no longer describes it.
			cullThrottle._processedVisibilityThisFrame = false
			cullThrottle:_processObjectVisibility(os.clock())

			-- A stale call before the refill ends quietly instead of erroring
			-- on the cleared arrays or stomping the live cursor.
			expect((staleIterator())).toBeNil()

			-- A stale call after the refill must not steal from or skip past
			-- the fresh layout either.
			local freshIterator = cullThrottle:IterateObjectsToUpdate()
			expect((staleIterator())).toBeNil()

			local yielded = 0
			for _ in freshIterator do
				yielded += 1
			end
			expect(yielded).toBe(2)

			partA:Destroy()
			partB:Destroy()
		end)

		it("keeps two interleaved live iterators from yielding the same object twice", function()
			local camera = workspace.CurrentCamera
			local partA = createMockPart((camera.CFrame * CFrame.new(-6, 0, -80)).Position)
			local partB = createMockPart((camera.CFrame * CFrame.new(6, 0, -80)).Position)
			local partC = createMockPart((camera.CFrame * CFrame.new(0, 6, -80)).Position)
			cullThrottle:AddObject(partA)
			cullThrottle:AddObject(partB)
			cullThrottle:AddObject(partC)

			cullThrottle:SetTimeBudgets(1, 1, 1)
			cullThrottle:_processObjectVisibility(os.clock())

			-- Two iterators live at once drain one shared queue, so alternating
			-- calls between them must hand each staged object to exactly one
			-- caller rather than replaying the other's progress.
			local iteratorA = cullThrottle:IterateObjectsToUpdate()
			local iteratorB = cullThrottle:IterateObjectsToUpdate()

			local yieldCounts = {}
			local function take(iterator): Instance?
				local object = iterator()
				if object then
					yieldCounts[object] = (yieldCounts[object] or 0) + 1
				end
				return object
			end

			local live = true
			while live do
				local fromA = take(iteratorA)
				local fromB = take(iteratorB)
				live = fromA ~= nil or fromB ~= nil
			end

			local distinctObjects = 0
			for _, count in yieldCounts do
				distinctObjects += 1
				expect(count).toBe(1)
			end
			expect(distinctObjects).toBe(3)

			partA:Destroy()
			partB:Destroy()
			partC:Destroy()
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

			expect(cullThrottle:GetPerformanceMetrics().averageObjectDeltaTime).toBeCloseTo(0.5, 1)

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

			expect(cullThrottle:GetPerformanceMetrics().averageObjectDeltaTime).toBeCloseTo(0.5, 1)

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

		it("holds the first band past the p0 region to the plain update budget", function()
			-- The part sits far beyond render distance so the real passes are
			-- guaranteed to cull it, leaving the queue holding exactly the
			-- handpicked entry below.
			local camera = workspace.CurrentCamera
			local part = createMockPart((camera.CFrame * CFrame.new(0, 0, 5000)).Position)
			cullThrottle:AddObject(part)

			-- Strict enforcement raises the p0 budget past anything the drain can spend,
			-- making the two budgets maximally distinguishable.
			cullThrottle:SetTimeBudgets(0, 0, 0)
			cullThrottle:SetStrictlyEnforceWorstRefreshRate(true)
			cullThrottle:_processObjectVisibility(os.clock())

			-- The batch is staged directly with a handpicked band because the
			-- boundary matters here. The p0 overrun applies to bands up to and
			-- including the p0 region's last, so the first band past it takes
			-- the plain (zero) budget, and that edge is reachable since an
			-- overdue object with zero screen size prices at exactly the p0
			-- threshold and bands just past the region. Hand staging also has
			-- to stamp the record visible the way ingest would, since the
			-- iterator reads a zeroed visibility stamp as a removed object.
			local objectData = cullThrottle._lifecycle._objects[part]
			cullThrottle._signals:markVisible(objectData, os.clock())
			local ingest = cullThrottle._ingest
			local stagedSize = ingest._stagedSize + 1
			ingest._stagedSize = stagedSize
			ingest._stagedObjects[stagedSize] = objectData
			ingest._stagedBands[stagedSize] = Ingest.P0_BAND_COUNT + 1

			local count = 0
			for _ in cullThrottle:IterateObjectsToUpdate() do
				count += 1
			end

			expect(count).toBe(0)

			part:Destroy()
		end)

		it("grants the raised p0 budget to the p0 region's last band", function()
			-- Like the exactly-at case, the part sits beyond render distance so
			-- only the handpicked entry reaches the queue.
			local camera = workspace.CurrentCamera
			local part = createMockPart((camera.CFrame * CFrame.new(0, 0, 5000)).Position)
			cullThrottle:AddObject(part)

			cullThrottle:SetTimeBudgets(0, 0, 0)
			cullThrottle:SetStrictlyEnforceWorstRefreshRate(true)
			cullThrottle:_processObjectVisibility(os.clock())

			-- This band is the last one inside the p0 region, so unlike the
			-- just-past case it counts as p0 and gets the raised budget, which
			-- is what lets it come out despite the plain budget being zero. Like
			-- the just-past case, hand staging stamps the record visible the way
			-- ingest would.
			local objectData = cullThrottle._lifecycle._objects[part]
			cullThrottle._signals:markVisible(objectData, os.clock())
			local ingest = cullThrottle._ingest
			local stagedSize = ingest._stagedSize + 1
			ingest._stagedSize = stagedSize
			ingest._stagedObjects[stagedSize] = objectData
			ingest._stagedBands[stagedSize] = Ingest.P0_BAND_COUNT

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

			expect(cullThrottle:GetPerformanceMetrics().averageObjectDeltaTime).toBeCloseTo(0.5, 1)

			stalePart:Destroy()
			freshPart:Destroy()
		end)

		it("eventually updates every visible object when the batch dwarfs the update budget", function()
			-- A dozen visible parts stage every frame while the update budget is
			-- zero, so no frame can afford the whole batch. The README promises
			-- every visible object is still reached, because an object that
			-- waits long enough crosses the worst refresh period, escalates to
			-- p0, and strict enforcement drains p0 regardless of budget.
			local camera = workspace.CurrentCamera
			local parts = {}
			for i = 1, 12 do
				local column = (i - 1) % 4
				local row = (i - 1) // 4
				local part = createMockPart((camera.CFrame * CFrame.new(column * 6 - 9, row * 6 - 6, -80)).Position)
				cullThrottle:AddObject(part)
				parts[i] = part
			end

			cullThrottle:SetTimeBudgets(1, 1, 0)
			cullThrottle:SetStrictlyEnforceWorstRefreshRate(true)
			-- A two second worst refresh period, far longer than the synthetic
			-- frames below, keeps an object that just updated from re-entering
			-- p0 within this test, so the drain schedule stays deterministic.
			cullThrottle:SetRefreshRates(NumberRange.new(0.5, 60))

			-- The staged clocks stagger when each object crosses the worst
			-- refresh period, about one synthetic frame apart, and zeroed jitter
			-- keeps the crossings exactly where they are staged.
			local frameStep = 0.05
			local startClock = os.clock()
			for i, part in parts do
				local objectData = cullThrottle._lifecycle._objects[part]
				objectData.jitterOffset = 0
				objectData.lastUpdateClock = startClock + (i - 1) * frameStep - 2.01
			end

			local counts = {}
			for _, part in parts do
				counts[part] = 0
			end
			local maxYieldedInOneFrame = 0
			for i = 1, 14 do
				cullThrottle._processedVisibilityThisFrame = false
				cullThrottle:_processObjectVisibility(startClock + i * frameStep)

				local yielded = 0
				for object in cullThrottle:IterateObjectsToUpdate() do
					counts[object] += 1
					yielded += 1
				end
				if yielded > maxYieldedInOneFrame then
					maxYieldedInOneFrame = yielded
				end
			end

			-- The zero budget held. No single frame drained anywhere
			-- near the whole staged batch.
			expect(maxYieldedInOneFrame).toBeLessThan(#parts)

			-- Yet nobody starved.
			for _, part in parts do
				expect(counts[part]).toBeGreaterThanOrEqual(1)
			end

			for _, part in parts do
				part:Destroy()
			end
		end)
	end)

	describe("IsTracking", function()
		it("reports whether an object is tracked", function()
			local part = createMockPart()

			expect(cullThrottle:IsTracking(part)).toBe(false)

			cullThrottle:AddObject(part)
			expect(cullThrottle:IsTracking(part)).toBe(true)

			cullThrottle:RemoveObject(part)
			expect(cullThrottle:IsTracking(part)).toBe(false)

			part:Destroy()
		end)
	end)

	describe("GetTrackedObjects", function()
		it("returns every tracked object", function()
			local a = createMockPart(Vector3.new(0, 0, 0))
			local b = createMockPart(Vector3.new(500, 0, 0))
			cullThrottle:AddObject(a)
			cullThrottle:AddObject(b)

			local tracked = cullThrottle:GetTrackedObjects()
			expect(#tracked).toBe(2)
			expect(table.find(tracked, a)).never.toBeNil()
			expect(table.find(tracked, b)).never.toBeNil()

			a:Destroy()
			b:Destroy()
		end)

		it("returns a snapshot that cannot mutate internal state", function()
			local part = createMockPart()
			cullThrottle:AddObject(part)

			local tracked = cullThrottle:GetTrackedObjects()
			table.clear(tracked)

			expect(cullThrottle:IsTracking(part)).toBe(true)
			expect(cullThrottle:GetTrackedObjectCount()).toBe(1)

			part:Destroy()
		end)
	end)

	describe("GetTrackedObjectCount", function()
		it("tracks the count across add and remove", function()
			expect(cullThrottle:GetTrackedObjectCount()).toBe(0)

			local a = createMockPart(Vector3.new(0, 0, 0))
			local b = createMockPart(Vector3.new(500, 0, 0))

			cullThrottle:AddObject(a)
			expect(cullThrottle:GetTrackedObjectCount()).toBe(1)

			cullThrottle:AddObject(b)
			expect(cullThrottle:GetTrackedObjectCount()).toBe(2)

			cullThrottle:RemoveObject(a)
			expect(cullThrottle:GetTrackedObjectCount()).toBe(1)

			a:Destroy()
			b:Destroy()
		end)

		it("does not double-count an idempotent re-add", function()
			local part = createMockPart()

			cullThrottle:AddObject(part)
			cullThrottle:AddObject(part)

			expect(cullThrottle:GetTrackedObjectCount()).toBe(1)

			part:Destroy()
		end)

		it("does not underflow when removing an untracked object", function()
			local part = createMockPart()

			cullThrottle:RemoveObject(part)

			expect(cullThrottle:GetTrackedObjectCount()).toBe(0)

			part:Destroy()
		end)

		it("stays correct through RemoveObjectsWithTag", function()
			local tag = "TrackedCountTag"
			local tagged = {}
			for i = 1, 4 do
				local part = createMockPart(Vector3.new(i * 10, 0, 0))
				CollectionService:AddTag(part, tag)
				cullThrottle:AddObject(part)
				tagged[i] = part
			end

			local untagged = createMockPart(Vector3.new(0, 500, 0))
			cullThrottle:AddObject(untagged)

			expect(cullThrottle:GetTrackedObjectCount()).toBe(5)

			cullThrottle:RemoveObjectsWithTag(tag)

			expect(cullThrottle:GetTrackedObjectCount()).toBe(1)

			for _, part in tagged do
				CollectionService:RemoveTag(part, tag)
				part:Destroy()
			end
			untagged:Destroy()
		end)
	end)

	describe("Performance metrics", function()
		it("seeds the average object delta time with the best refresh period", function()
			-- The seed feeds the render distance controller before any real
			-- updates have been committed, so a fresh instance starts at the
			-- default best refresh period.
			expect(cullThrottle:GetPerformanceMetrics().averageObjectDeltaTime).toBeCloseTo(1 / 60)
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

		it("keeps the previous average object delta time across a frame that updates nothing", function()
			-- Plant a recognizable committed average with no pending update
			-- samples, then process a frame. The commit is guarded on having
			-- updated something, since without the guard the frame
			-- would divide zero by zero and poison the average with NaN.
			cullThrottle._perfMetrics._averageObjectDeltaTime = 0.123
			cullThrottle:_processObjectVisibility(os.clock())

			expect(cullThrottle:GetPerformanceMetrics().averageObjectDeltaTime).toBe(0.123)
		end)

		it("returns a snapshot with the documented metric fields", function()
			local metrics = cullThrottle:GetPerformanceMetrics()

			expect(type(metrics.searchDuration)).toBe("number")
			expect(type(metrics.ingestDuration)).toBe("number")
			expect(type(metrics.skippedSearch)).toBe("number")
			expect(type(metrics.skippedIngest)).toBe("number")
			expect(type(metrics.occludedVoxelCount)).toBe("number")
			expect(type(metrics.averageObjectDeltaTime)).toBe("number")
		end)

		it("reflects the latest internal metrics", function()
			cullThrottle._perfMetrics._searchDuration = 0.00123
			cullThrottle._perfMetrics._ingestDuration = 0.00456
			cullThrottle._perfMetrics._skippedSearch[1] = 7
			cullThrottle._perfMetrics._skippedIngest[1] = 9
			cullThrottle._perfMetrics._occludedVoxelCount = 4
			cullThrottle._perfMetrics._averageObjectDeltaTime = 0.025

			local metrics = cullThrottle:GetPerformanceMetrics()
			expect(metrics.searchDuration).toBe(0.00123)
			expect(metrics.ingestDuration).toBe(0.00456)
			expect(metrics.skippedSearch).toBe(7)
			expect(metrics.skippedIngest).toBe(9)
			expect(metrics.occludedVoxelCount).toBe(4)
			expect(metrics.averageObjectDeltaTime).toBe(0.025)
		end)

		it("reports the current frame's skipped tallies after the cursor advances", function()
			-- Each visibility pass advances the ring cursor, so the snapshot must
			-- read whichever slot is current rather than a hardcoded one.
			cullThrottle:_findVisibleObjects(os.clock())
			cullThrottle:_findVisibleObjects(os.clock())

			-- Decoys fill every slot first, so a snapshot reading any slot other
			-- than the cursor's comes back wrong no matter how long the ring is.
			local perfMetrics = cullThrottle._perfMetrics
			for slot in perfMetrics._skippedSearch do
				perfMetrics._skippedSearch[slot] = 1000
				perfMetrics._skippedIngest[slot] = 1000
			end
			local cursor = perfMetrics._skippedFramesCursor
			perfMetrics._skippedSearch[cursor] = 7
			perfMetrics._skippedIngest[cursor] = 9

			local metrics = cullThrottle:GetPerformanceMetrics()
			expect(metrics.skippedSearch).toBe(7)
			expect(metrics.skippedIngest).toBe(9)
		end)

		it("returns a fresh snapshot that cannot corrupt internal metrics", function()
			local metrics = cullThrottle:GetPerformanceMetrics()
			metrics.searchDuration = 999
			metrics.skippedSearch = 999

			expect(cullThrottle._perfMetrics._searchDuration).never.toBe(999)
			expect(cullThrottle._perfMetrics._skippedSearch[1]).never.toBe(999)
		end)
	end)

	describe("Edge cases", function()
		it("keeps a zero-size object tracked and queryable", function()
			-- A zero-size part has a degenerate bounding box, and the exact
			-- radius handling for that lives with ObjectDimensions. The claim at
			-- this level is that such an object still enters tracking and flows
			-- through the queries like anything else.
			local camera = workspace.CurrentCamera
			local part = createMockPart((camera.CFrame * CFrame.new(0, 0, -80)).Position, Vector3.new(0, 0, 0))

			expect(function()
				cullThrottle:AddObject(part)
			end).never.toThrow()
			expect(cullThrottle:IsTracking(part)).toBe(true)

			cullThrottle:SetTimeBudgets(1, 1, 1)
			expect(table.find(cullThrottle:GetVisibleObjects(), part)).never.toBeNil()

			part:Destroy()
		end)

		it("handles processing with no objects", function()
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
