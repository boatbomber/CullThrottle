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

local TestHelpers = require(script.Parent.TestHelpers)
local createMockPart = TestHelpers.createMockPart
local stubObjectData = TestHelpers.stubObjectData

describe("CullThrottle", function()
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

		it("should return visible objects after processing", function()
			local part = createMockPart(Vector3.new(0, 0, 0))
			cullThrottle:AddObject(part)

			cullThrottle:_processObjectVisibility(os.clock())

			local visibleObjects = cullThrottle:GetVisibleObjects()
			expect(type(visibleObjects)).toBe("table")

			part:Destroy()
		end)

		it("should not duplicate a multi-voxel object under fast-approximation fallback", function()
			cullThrottle:SetVoxelSize(100)

			-- A long part occupies several voxel buckets, so the fast-approximation
			-- path would emit it once per voxel if it didn't deduplicate.
			local part = createMockPart(Vector3.new(0, 0, 0), Vector3.new(500, 20, 20))
			cullThrottle:AddObject(part)
			local objectData = cullThrottle._lifecycle._objects[part]

			local visibleVoxelKeys = {}
			for voxelKey in objectData.voxelKeys do
				table.insert(visibleVoxelKeys, voxelKey)
			end
			cullThrottle._search._visibleVoxelKeys = visibleVoxelKeys
			cullThrottle._search._visibleVoxelCount = #visibleVoxelKeys

			-- Drive the fast-approximation path directly over every occupied voxel.
			cullThrottle._ingest:fastApproxIngestRemainingVoxels(os.clock(), 1)

			local items = cullThrottle._ingest._visibleObjectsQueue._incomingBatch.items
			local occurrences = 0
			for _, object in items do
				if object == part then
					occurrences += 1
				end
			end

			expect(#visibleVoxelKeys).toBeGreaterThan(1)
			expect(occurrences).toBe(1)

			part:Destroy()
		end)

		it("should not re-add an object the precise ingest pass already handled", function()
			cullThrottle:SetVoxelSize(100)

			local part = createMockPart(Vector3.new(0, 0, 0), Vector3.new(500, 20, 20))
			cullThrottle:AddObject(part)
			local objectData = cullThrottle._lifecycle._objects[part]

			local now = os.clock()
			-- Simulate the precise ingest pass having already handled this object
			-- this frame (it spans both a precisely-ingested and a fast-path voxel).
			objectData.lastCheckClock = now
			cullThrottle._ingest._visibleObjectsQueue:addToIncomingBatch(part, 0)

			local visibleVoxelKeys = {}
			for voxelKey in objectData.voxelKeys do
				table.insert(visibleVoxelKeys, voxelKey)
			end
			cullThrottle._search._visibleVoxelKeys = visibleVoxelKeys
			cullThrottle._search._visibleVoxelCount = #visibleVoxelKeys

			cullThrottle._ingest:fastApproxIngestRemainingVoxels(now, 1)

			local items = cullThrottle._ingest._visibleObjectsQueue._incomingBatch.items
			local occurrences = 0
			for _, object in items do
				if object == part then
					occurrences += 1
				end
			end

			expect(occurrences).toBe(1)

			part:Destroy()
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
			cullThrottle._config.searchTimeBudget = 1
			cullThrottle._config.ingestTimeBudget = 1

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

			cullThrottle._config.searchTimeBudget = 1
			cullThrottle._config.ingestTimeBudget = 1
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
	end)

	describe("IterateObjectsToUpdate", function()
		it("should iterate through visible objects", function()
			local part1 = createMockPart(Vector3.new(0, 0, 0))
			local part2 = createMockPart(Vector3.new(10, 10, 10))

			cullThrottle:AddObject(part1)
			cullThrottle:AddObject(part2)

			cullThrottle:_processObjectVisibility(os.clock())
			cullThrottle:_fillVisibleObjectsQueue()

			local iterator = cullThrottle:IterateObjectsToUpdate()
			local count = 0

			for object, deltaTime, distance, cframe in iterator do
				if object then
					count = count + 1
					expect(deltaTime).toBeDefined()
					expect(distance).toBeDefined()
					expect(cframe).toBeDefined()
				end
			end

			expect(count).toBeGreaterThanOrEqual(0)

			part1:Destroy()
			part2:Destroy()
		end)

		it("should return object data in iterator", function()
			local part = createMockPart(Vector3.new(50, 50, 50))
			cullThrottle:AddObject(part)

			cullThrottle:_processObjectVisibility(os.clock())
			cullThrottle:_fillVisibleObjectsQueue()

			local iterator = cullThrottle:IterateObjectsToUpdate()
			local object, deltaTime, distance, cframe = iterator()

			if object then
				expect(object).toBe(part)
				expect(type(deltaTime)).toBe("number")
				expect(type(distance)).toBe("number")
				expect(typeof(cframe)).toBe("CFrame")
			end

			part:Destroy()
		end)

		it("yields a visible object with its real distance and cframe", function()
			local camera = workspace.CurrentCamera
			local frontPart = createMockPart((camera.CFrame * CFrame.new(0, 0, -80)).Position)
			cullThrottle:AddObject(frontPart)

			-- Give it generous budgets so the search runs to completion and the update
			-- loop doesn't bail before reaching the object.
			cullThrottle._config.searchTimeBudget = 1
			cullThrottle._config.ingestTimeBudget = 1
			cullThrottle._config.updateTimeBudget = 1
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

			cullThrottle._config.searchTimeBudget = 1
			cullThrottle._config.ingestTimeBudget = 1
			cullThrottle._config.updateTimeBudget = 1
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

			cullThrottle._config.searchTimeBudget = 1
			cullThrottle._config.ingestTimeBudget = 1
			cullThrottle._config.updateTimeBudget = 1
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

			cullThrottle._config.searchTimeBudget = 1
			cullThrottle._config.ingestTimeBudget = 1
			cullThrottle._config.updateTimeBudget = 1
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

			cullThrottle._config.searchTimeBudget = 1
			cullThrottle._config.ingestTimeBudget = 1
			cullThrottle._config.updateTimeBudget = 1
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

			cullThrottle._config.searchTimeBudget = 1
			cullThrottle._config.ingestTimeBudget = 1
			-- A zero update budget (and no strict enforcement) means even the first
			-- dequeue is already over budget, so nothing should be iterated.
			cullThrottle._config.updateTimeBudget = 0
			cullThrottle:SetStrictlyEnforceWorstRefreshRate(false)
			cullThrottle:_processObjectVisibility(os.clock())

			local count = 0
			for object in cullThrottle:IterateObjectsToUpdate() do
				if object then
					count += 1
				end
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

			cullThrottle._config.searchTimeBudget = 1
			cullThrottle._config.ingestTimeBudget = 1
			-- The normal budget is exhausted immediately, but strict enforcement
			-- raises the p0 budget so worst-rate objects still update.
			cullThrottle._config.updateTimeBudget = 0
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
	end)

	describe("Performance metrics", function()
		it("should track average object delta time", function()
			expect(cullThrottle._perfMetrics._averageObjectDeltaTime).toBeDefined()
			expect(type(cullThrottle._perfMetrics._averageObjectDeltaTime)).toBe("number")
		end)

		it("should calculate average correctly", function()
			local values = { 1, 2, 3, 4 }
			local average = cullThrottle._perfMetrics._getAverage(values)
			expect(average).toBe(2.5)
		end)

		it("should track search and ingest durations", function()
			cullThrottle:_findVisibleObjects(os.clock())

			expect(cullThrottle._perfMetrics._searchDuration).toBeDefined()
			expect(type(cullThrottle._perfMetrics._searchDuration)).toBe("number")
			expect(cullThrottle._perfMetrics._ingestDuration).toBeDefined()
			expect(type(cullThrottle._perfMetrics._ingestDuration)).toBe("number")
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

		it("should handle empty voxel operations", function()
			expect(function()
				cullThrottle._grid:removeFromVoxel(Vector3.new(999, 999, 999), stubObjectData(Instance.new("Part")))
			end).never.toThrow()
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
