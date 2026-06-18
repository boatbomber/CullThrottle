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
local Frustum = require(CullThrottlePackage:WaitForChild("Frustum"))

local TestHelpers = require(script.Parent.TestHelpers)
local createMockPart = TestHelpers.createMockPart
local visibleVoxelProof = TestHelpers.visibleVoxelProof

describe("CullThrottle configuration", function()
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

	describe("SetVoxelSize", function()
		it("should update voxel size configuration", function()
			-- This must differ from the default 100 so the assertions can't pass
			-- on an untouched config.
			local newVoxelSize = 50
			cullThrottle:SetVoxelSize(newVoxelSize)

			expect(cullThrottle:GetVoxelSize()).toBe(newVoxelSize)
			-- The multi-voxel radius threshold is a quarter of the voxel size, so
			-- it must follow the change. It has no public getter, so the private
			-- read is the only window into it.
			expect(cullThrottle._config.multiVoxelRadiusThreshold).toBe(newVoxelSize / 4)
		end)

		it("should flush every cached visibility verdict and re-anchor the motion accumulators", function()
			-- Every cached proof, verdict, and accumulator reading is in voxel
			-- units, so a new voxel size invalidates all of them at once. A stale
			-- proof surviving here would be interpreted at the wrong scale and
			-- hand out wrong visibility verdicts.
			local visibilityCache = cullThrottle._visibilityCache
			visibilityCache._voxelProofs[Vector3.new(1, 1, 1)] = visibleVoxelProof(100, 1)
			visibilityCache._bucketVerdicts[Vector3.new(0, 0, 0)] = {
				state = Frustum.BUCKET_INSIDE,
				armFactor = 1,
				sideExpiry = 100,
				farExpiry = math.huge,
			}
			local motion = cullThrottle._motion
			motion._accumT = 3
			motion._accumR = 0.5
			motion._accumF = 2

			cullThrottle:SetVoxelSize(50)

			expect(next(visibilityCache._voxelProofs)).toBeNil()
			expect(next(visibilityCache._bucketVerdicts)).toBeNil()
			expect(motion._accumT).toBe(0)
			expect(motion._accumR).toBe(0)
			expect(motion._accumF).toBe(0)
			-- The flush also re-anchors the far-plane reading in the new voxel
			-- unit, so the next accumulate sees no phantom render distance motion.
			expect(motion._lastRenderDistanceVoxels).toBe(cullThrottle:GetRenderDistance() / 50)
		end)

		it("should reassign objects to new voxels", function()
			local part = createMockPart(Vector3.new(150, 150, 150))
			cullThrottle:AddObject(part)

			local oldVoxelSize = cullThrottle:GetVoxelSize()
			local newVoxelSize = oldVoxelSize * 2

			-- SetVoxelSize promises the full reslot happens before the next frame,
			-- so the assertions run against exactly the state it leaves behind.
			cullThrottle:SetVoxelSize(newVoxelSize)

			local newVoxelKey = Vector3.new(150, 150, 150) // newVoxelSize
			local found = false
			for voxelKey, voxel in cullThrottle._grid._voxels do
				if voxelKey == newVoxelKey then
					found = table.find(voxel, cullThrottle._lifecycle._objects[part]) ~= nil
					break
				end
			end

			expect(found).toBe(true)

			part:Destroy()
		end)

		it("should reject a non-positive voxel size", function()
			expect(function()
				cullThrottle:SetVoxelSize(0)
			end).toThrow()
			expect(function()
				cullThrottle:SetVoxelSize(-50)
			end).toThrow()
		end)

		it("should reject a NaN voxel size", function()
			-- Every ordered comparison against NaN is false, so a plain `<= 0` gate
			-- lets it through to poison every voxel key derived from it.
			expect(function()
				cullThrottle:SetVoxelSize(0 / 0)
			end).toThrow()
		end)

		it("should reject an infinite voxel size", function()
			-- An infinite size passes a plain `> 0` gate, but every voxel key it
			-- derives is then infinite, so the gate must reject it too.
			expect(function()
				cullThrottle:SetVoxelSize(math.huge)
			end).toThrow()
		end)

		it("should keep objects whose voxel key is unchanged by the resize", function()
			-- This part's center voxel key is (0, 0, 0) under both the old and new
			-- sizes, so the reslot must reinsert it into the rebuilt grid rather
			-- than treating it as already slotted.
			local part = createMockPart(Vector3.new(40, 20, 30))
			cullThrottle:AddObject(part)

			-- The reslot is SetVoxelSize's own responsibility, so nothing drains
			-- the apply queue for it here.
			cullThrottle:SetVoxelSize(cullThrottle:GetVoxelSize() / 2)

			local voxelKey = Vector3.new(0, 0, 0)
			local voxel = cullThrottle._grid._voxels[voxelKey]
			local found = voxel ~= nil and table.find(voxel, cullThrottle._lifecycle._objects[part]) ~= nil

			expect(found).toBe(true)

			part:Destroy()
		end)
	end)

	describe("SetRenderDistanceRange", function()
		it("should update render distance configuration", function()
			cullThrottle:SetRenderDistanceRange(NumberRange.new(300, 900))

			local range = cullThrottle:GetRenderDistanceRange()
			expect(range.Min).toBe(300)
			expect(range.Max).toBe(900)
			-- The midpoint is derived with no public getter, so the private read
			-- is the only window into it.
			expect(cullThrottle._config.renderDistanceMidpoint).toBe(600)
			-- The live distance resets to the range's midpoint baseline.
			expect(cullThrottle:GetRenderDistance()).toBe(600)
			expect(cullThrottle:GetDynamicRenderDistance()).toBe(true)
		end)

		it("should disable dynamic adjustment for a zero-width range", function()
			cullThrottle:SetRenderDistanceRange(NumberRange.new(500, 500))

			local range = cullThrottle:GetRenderDistanceRange()
			expect(range.Min).toBe(500)
			expect(range.Max).toBe(500)
			expect(cullThrottle:GetRenderDistance()).toBe(500)
			expect(cullThrottle:GetDynamicRenderDistance()).toBe(false)
		end)

		it("should reset the dynamic controller's momentum along with the range", function()
			local controller = cullThrottle._renderDistanceController
			local baselineStep = controller._step

			-- Stage the working state a run of over-budget frames leaves behind,
			-- a damped step partway through a shrink streak.
			controller._step = baselineStep * 0.5
			controller._direction = -1

			cullThrottle:SetRenderDistanceRange(NumberRange.new(300, 900))

			-- The controller floats from the new range's midpoint with fresh
			-- momentum, so the old streak's step and direction must not carry over.
			expect(controller._step).toBe(baselineStep)
			expect(controller._direction).toBe(0)
		end)

		it("should reject a non-positive render distance", function()
			expect(function()
				cullThrottle:SetRenderDistanceRange(NumberRange.new(0, 100))
			end).toThrow()
			expect(function()
				cullThrottle:SetRenderDistanceRange(NumberRange.new(-100))
			end).toThrow()
		end)

		it("should reject a NaN render distance", function()
			-- The render distance is a divisor in the priority math, so a NaN
			-- slipping through the gate would poison every priority downstream.
			expect(function()
				cullThrottle:SetRenderDistanceRange(NumberRange.new(0 / 0, 0 / 0))
			end).toThrow()
		end)

		it("should reject an infinite render distance", function()
			-- An infinite render distance yields an infinite midpoint and live
			-- distance, which poisons the controller's step and the priority
			-- divisor, so the gate must reject it.
			expect(function()
				cullThrottle:SetRenderDistanceRange(NumberRange.new(1, math.huge))
			end).toThrow()
		end)
	end)

	describe("SetTimeBudgets", function()
		it("should update time budget configurations", function()
			local searchBudget = 0.002
			local ingestBudget = 0.003
			local updateBudget = 0.004

			cullThrottle:SetTimeBudgets(searchBudget, ingestBudget, updateBudget)

			local search, ingest, update = cullThrottle:GetTimeBudgets()
			expect(search).toBe(searchBudget)
			expect(ingest).toBe(ingestBudget)
			expect(update).toBe(updateBudget)
		end)

		it("should reject a negative time budget", function()
			expect(function()
				cullThrottle:SetTimeBudgets(-0.001, 0.003, 0.004)
			end).toThrow()
			expect(function()
				cullThrottle:SetTimeBudgets(0.002, -0.003, 0.004)
			end).toThrow()
			expect(function()
				cullThrottle:SetTimeBudgets(0.002, 0.003, -0.004)
			end).toThrow()
		end)

		it("should reject a NaN time budget", function()
			-- A NaN budget passes a plain `< 0` rejection and then defeats every
			-- budget comparison in the passes it feeds.
			expect(function()
				cullThrottle:SetTimeBudgets(0 / 0, 0.003, 0.004)
			end).toThrow()
			expect(function()
				cullThrottle:SetTimeBudgets(0.002, 0 / 0, 0.004)
			end).toThrow()
			expect(function()
				cullThrottle:SetTimeBudgets(0.002, 0.003, 0 / 0)
			end).toThrow()
		end)

		it("should allow zero time budgets", function()
			expect(function()
				cullThrottle:SetTimeBudgets(0, 0, 0)
			end).never.toThrow()

			local search, ingest, update = cullThrottle:GetTimeBudgets()
			expect(search).toBe(0)
			expect(ingest).toBe(0)
			expect(update).toBe(0)
		end)
	end)

	describe("SetRefreshRates", function()
		-- The range's Max is the best (most frequent) rate and Min is the worst
		-- (least frequent). The stored fields are periods in seconds, an internal
		-- unit only reachable through these private reads, so these tests pin the
		-- inversion itself rather than the getter's round-trip, and the expected
		-- values are literal numbers so a wrong inversion can't satisfy a
		-- restatement of itself.
		it("should convert Hz rates to seconds-between-refreshes periods", function()
			cullThrottle:SetRefreshRates(NumberRange.new(5, 25))

			-- 25 Hz is a 0.04 second period and 5 Hz is a 0.2 second period.
			expect(cullThrottle._config.bestRefreshPeriod).toBeCloseTo(0.04, 5)
			expect(cullThrottle._config.worstRefreshPeriod).toBeCloseTo(0.2, 5)
		end)

		it("should derive the refresh period range and midpoint from the rates", function()
			cullThrottle:SetRefreshRates(NumberRange.new(10, 50))

			-- 50 Hz is a 0.02 second period and 10 Hz is a 0.1 second period, so
			-- the range spans 0.08 and the midpoint sits at 0.06.
			expect(cullThrottle._config.refreshPeriodRange).toBeCloseTo(0.08, 5)
			expect(cullThrottle._config.refreshPeriodMidpoint).toBeCloseTo(0.06, 5)
		end)

		it("should accept equal best and worst rates", function()
			cullThrottle:SetRefreshRates(NumberRange.new(20, 20))

			-- 20 Hz both ways is a 0.05 second period on both ends, collapsing
			-- the range to zero.
			expect(cullThrottle._config.bestRefreshPeriod).toBeCloseTo(0.05, 5)
			expect(cullThrottle._config.worstRefreshPeriod).toBeCloseTo(0.05, 5)
			expect(cullThrottle._config.refreshPeriodRange).toBeCloseTo(0, 5)
		end)

		it("should reject non-positive rates", function()
			expect(function()
				cullThrottle:SetRefreshRates(NumberRange.new(0, 15))
			end).toThrow()
			expect(function()
				cullThrottle:SetRefreshRates(NumberRange.new(-1, 60))
			end).toThrow()
		end)

		it("should reject NaN rates", function()
			-- The rates invert into refresh periods, and a NaN period breaks every
			-- band comparison in the ingest pass.
			expect(function()
				cullThrottle:SetRefreshRates(NumberRange.new(0 / 0, 0 / 0))
			end).toThrow()
		end)
	end)

	describe("SetComputeVisibilityOnlyOnDemand", function()
		it("still resolves visibility when queried directly in on-demand mode", function()
			cullThrottle:SetComputeVisibilityOnlyOnDemand(true)

			local camera = workspace.CurrentCamera
			local part = createMockPart((camera.CFrame * CFrame.new(0, 0, -80)).Position)
			cullThrottle:AddObject(part)

			-- Give it generous budgets so the on-demand query runs the full precise pass.
			cullThrottle:SetTimeBudgets(1, 1, 1)

			-- In on-demand mode the render loop never computes visibility, but an
			-- explicit query must still process it on the spot.
			local visibleObjects = cullThrottle:GetVisibleObjects()
			expect(table.find(visibleObjects, part)).never.toBeNil()

			part:Destroy()
		end)

		it("computes visibility on demand when the update iterator runs", function()
			cullThrottle:SetComputeVisibilityOnlyOnDemand(true)

			local camera = workspace.CurrentCamera
			local part = createMockPart((camera.CFrame * CFrame.new(0, 0, -80)).Position)
			cullThrottle:AddObject(part)

			cullThrottle:SetTimeBudgets(1, 1, 1)

			-- Nothing has processed visibility this frame, so the iterator itself
			-- must compute it on the spot and still hand out the visible object.
			local yielded = {}
			for object in cullThrottle:IterateObjectsToUpdate() do
				yielded[object] = true
			end
			expect(yielded[part]).toBe(true)

			part:Destroy()
		end)
	end)

	describe("Configuration getters", function()
		it("should read back the voxel size", function()
			cullThrottle:SetVoxelSize(50)
			expect(cullThrottle:GetVoxelSize()).toBe(50)
		end)

		it("should read back the render distance range", function()
			cullThrottle:SetRenderDistanceRange(NumberRange.new(250, 750))

			local range = cullThrottle:GetRenderDistanceRange()
			expect(range.Min).toBe(250)
			expect(range.Max).toBe(750)
		end)

		it("should read back the time budgets in seconds", function()
			cullThrottle:SetTimeBudgets(0.002, 0.003, 0.004)

			local search, ingest, update = cullThrottle:GetTimeBudgets()
			expect(search).toBe(0.002)
			expect(ingest).toBe(0.003)
			expect(update).toBe(0.004)
		end)

		it("should read back the refresh rates in Hz, symmetric with the setter", function()
			cullThrottle:SetRefreshRates(NumberRange.new(15, 60))

			local refreshRates = cullThrottle:GetRefreshRates()
			expect(refreshRates.Max).toBeCloseTo(60)
			expect(refreshRates.Min).toBeCloseTo(15)
		end)

		it("should read back the boolean flags", function()
			cullThrottle:SetComputeVisibilityOnlyOnDemand(true)
			cullThrottle:SetStrictlyEnforceWorstRefreshRate(true)

			expect(cullThrottle:GetComputeVisibilityOnlyOnDemand()).toBe(true)
			expect(cullThrottle:GetStrictlyEnforceWorstRefreshRate()).toBe(true)

			cullThrottle:SetComputeVisibilityOnlyOnDemand(false)
			cullThrottle:SetStrictlyEnforceWorstRefreshRate(false)

			expect(cullThrottle:GetComputeVisibilityOnlyOnDemand()).toBe(false)
			expect(cullThrottle:GetStrictlyEnforceWorstRefreshRate()).toBe(false)
		end)

		it("should derive dynamic render distance from the range width", function()
			cullThrottle:SetRenderDistanceRange(NumberRange.new(200, 800))
			expect(cullThrottle:GetDynamicRenderDistance()).toBe(true)

			cullThrottle:SetRenderDistanceRange(NumberRange.new(500, 500))
			expect(cullThrottle:GetDynamicRenderDistance()).toBe(false)
		end)

		it("should expose the live render distance, distinct from the configured range", function()
			cullThrottle:SetRenderDistanceRange(NumberRange.new(200, 1000))
			-- The live distance starts at the range's midpoint baseline.
			expect(cullThrottle:GetRenderDistance()).toBe(600)

			-- Simulate the dynamic controller having adjusted the effective distance
			-- down. The getter reports the live value, not the configured range.
			cullThrottle._config.renderDistance = 450
			expect(cullThrottle:GetRenderDistance()).toBe(450)

			local range = cullThrottle:GetRenderDistanceRange()
			expect(range.Min).toBe(200)
			expect(range.Max).toBe(1000)
		end)
	end)

	describe("IsTracking", function()
		it("should report whether an object is tracked", function()
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
		it("should return every tracked object", function()
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

		it("should return a snapshot that cannot mutate internal state", function()
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
		it("should track the count across add and remove", function()
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

		it("should not double-count an idempotent re-add", function()
			local part = createMockPart()

			cullThrottle:AddObject(part)
			cullThrottle:AddObject(part)

			expect(cullThrottle:GetTrackedObjectCount()).toBe(1)

			part:Destroy()
		end)

		it("should not underflow when removing an untracked object", function()
			local part = createMockPart()

			cullThrottle:RemoveObject(part)

			expect(cullThrottle:GetTrackedObjectCount()).toBe(0)

			part:Destroy()
		end)

		it("should stay correct through RemoveObjectsWithTag", function()
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

	describe("GetPerformanceMetrics", function()
		it("should return a snapshot with the documented metric fields", function()
			local metrics = cullThrottle:GetPerformanceMetrics()

			expect(type(metrics.searchDuration)).toBe("number")
			expect(type(metrics.ingestDuration)).toBe("number")
			expect(type(metrics.skippedSearch)).toBe("number")
			expect(type(metrics.skippedIngest)).toBe("number")
			expect(type(metrics.averageObjectDeltaTime)).toBe("number")
		end)

		it("should reflect the latest internal metrics", function()
			cullThrottle._perfMetrics._searchDuration = 0.00123
			cullThrottle._perfMetrics._ingestDuration = 0.00456
			cullThrottle._perfMetrics._skippedSearch[1] = 7
			cullThrottle._perfMetrics._skippedIngest[1] = 9
			cullThrottle._perfMetrics._averageObjectDeltaTime = 0.025

			local metrics = cullThrottle:GetPerformanceMetrics()
			expect(metrics.searchDuration).toBe(0.00123)
			expect(metrics.ingestDuration).toBe(0.00456)
			expect(metrics.skippedSearch).toBe(7)
			expect(metrics.skippedIngest).toBe(9)
			expect(metrics.averageObjectDeltaTime).toBe(0.025)
		end)

		it("should report the current frame's skipped tallies after the cursor advances", function()
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

		it("should return a fresh snapshot that cannot corrupt internal metrics", function()
			local metrics = cullThrottle:GetPerformanceMetrics()
			metrics.searchDuration = 999
			metrics.skippedSearch = 999

			expect(cullThrottle._perfMetrics._searchDuration).never.toBe(999)
			expect(cullThrottle._perfMetrics._skippedSearch[1]).never.toBe(999)
		end)
	end)
end)
