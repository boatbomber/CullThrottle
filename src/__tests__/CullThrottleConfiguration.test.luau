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
		it("updates the voxel size configuration", function()
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

		it("flushes every cached visibility verdict and re-anchors the motion accumulators", function()
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
		end)

		it("reassigns objects to new voxels", function()
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

		it("rejects a non-positive voxel size", function()
			expect(function()
				cullThrottle:SetVoxelSize(0)
			end).toThrow()
			expect(function()
				cullThrottle:SetVoxelSize(-50)
			end).toThrow()
		end)

		it("rejects a NaN voxel size", function()
			-- Every ordered comparison against NaN is false, so a plain `<= 0` gate
			-- lets it through to poison every voxel key derived from it.
			expect(function()
				cullThrottle:SetVoxelSize(0 / 0)
			end).toThrow()
		end)

		it("rejects an infinite voxel size", function()
			-- An infinite size passes a plain `> 0` gate, but every voxel key it
			-- derives is then infinite, so the gate must reject it too.
			expect(function()
				cullThrottle:SetVoxelSize(math.huge)
			end).toThrow()
		end)

		it("keeps objects whose voxel key is unchanged by the resize", function()
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
		it("updates the render distance configuration", function()
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

		it("disables dynamic adjustment for a zero-width range", function()
			cullThrottle:SetRenderDistanceRange(NumberRange.new(500, 500))

			local range = cullThrottle:GetRenderDistanceRange()
			expect(range.Min).toBe(500)
			expect(range.Max).toBe(500)
			expect(cullThrottle:GetRenderDistance()).toBe(500)
			expect(cullThrottle:GetDynamicRenderDistance()).toBe(false)
		end)

		it("resets the dynamic controller's momentum along with the range", function()
			-- Drive the controller into a damped-down streak first. A load inside
			-- the hold deadband damps the step on every adjustment without moving
			-- the distance, so a handful of adjustments leaves the step a tiny
			-- fraction of its starting size.
			local config = cullThrottle._config
			cullThrottle._perfMetrics._averageObjectDeltaTime = config.refreshPeriodMidpoint
			for _ = 1, 6 do
				cullThrottle._renderDistanceController:adjust()
			end

			cullThrottle:SetRenderDistanceRange(NumberRange.new(300, 900))

			-- Stage clear headroom so the first post-reset adjustment grows. A
			-- reset controller moves from its full starting step, several studs
			-- here, while a damped streak carried across the range change could
			-- only nudge the distance by a fraction of a stud, so the size of
			-- this first move is the observable that separates the two.
			cullThrottle._perfMetrics._averageObjectDeltaTime = config.bestRefreshPeriod
			cullThrottle._renderDistanceController:adjust()

			expect(math.abs(cullThrottle:GetRenderDistance() - 600)).toBeGreaterThan(1)
		end)

		it("rejects a non-positive render distance", function()
			expect(function()
				cullThrottle:SetRenderDistanceRange(NumberRange.new(0, 100))
			end).toThrow()
			expect(function()
				cullThrottle:SetRenderDistanceRange(NumberRange.new(-100))
			end).toThrow()
		end)

		it("rejects a render distance range that is NaN at both ends", function()
			-- The render distance is a divisor in the priority math, so a NaN
			-- slipping through the gate would poison every priority downstream.
			expect(function()
				cullThrottle:SetRenderDistanceRange(NumberRange.new(0 / 0, 0 / 0))
			end).toThrow()
		end)

		it("rejects a NaN hiding in the range's Max", function()
			-- NumberRange's own ordering check compares Min against Max, and
			-- every comparison against NaN is false, so a NaN Max slips through
			-- construction alongside a perfectly valid Min. The setter gates Max
			-- on its own to catch it.
			expect(function()
				cullThrottle:SetRenderDistanceRange(NumberRange.new(100, 0 / 0))
			end).toThrow()
		end)

		it("rejects an infinite render distance", function()
			-- An infinite render distance yields an infinite midpoint and live
			-- distance, which poisons the controller's step and the priority
			-- divisor, so the gate must reject it.
			expect(function()
				cullThrottle:SetRenderDistanceRange(NumberRange.new(1, math.huge))
			end).toThrow()
		end)
	end)

	describe("SetTimeBudgets", function()
		it("updates the time budget configuration", function()
			local searchBudget = 0.002
			local ingestBudget = 0.003
			local updateBudget = 0.004

			cullThrottle:SetTimeBudgets(searchBudget, ingestBudget, updateBudget)

			local search, ingest, update = cullThrottle:GetTimeBudgets()
			expect(search).toBe(searchBudget)
			expect(ingest).toBe(ingestBudget)
			expect(update).toBe(updateBudget)
		end)

		it("rejects a negative time budget", function()
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

		it("rejects a NaN time budget", function()
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

		it("allows zero time budgets", function()
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
		it("converts Hz rates to seconds-between-refreshes periods", function()
			cullThrottle:SetRefreshRates(NumberRange.new(5, 25))

			-- 25 Hz is a 0.04 second period and 5 Hz is a 0.2 second period.
			expect(cullThrottle._config.bestRefreshPeriod).toBeCloseTo(0.04, 5)
			expect(cullThrottle._config.worstRefreshPeriod).toBeCloseTo(0.2, 5)
		end)

		it("derives the refresh period range and midpoint from the rates", function()
			cullThrottle:SetRefreshRates(NumberRange.new(10, 50))

			-- 50 Hz is a 0.02 second period and 10 Hz is a 0.1 second period, so
			-- the range spans 0.08 and the midpoint sits at 0.06.
			expect(cullThrottle._config.refreshPeriodRange).toBeCloseTo(0.08, 5)
			expect(cullThrottle._config.refreshPeriodMidpoint).toBeCloseTo(0.06, 5)
		end)

		it("accepts equal best and worst rates", function()
			cullThrottle:SetRefreshRates(NumberRange.new(20, 20))

			-- 20 Hz both ways is a 0.05 second period on both ends, collapsing
			-- the range to zero.
			expect(cullThrottle._config.bestRefreshPeriod).toBeCloseTo(0.05, 5)
			expect(cullThrottle._config.worstRefreshPeriod).toBeCloseTo(0.05, 5)
			expect(cullThrottle._config.refreshPeriodRange).toBeCloseTo(0, 5)
		end)

		it("rejects non-positive rates", function()
			expect(function()
				cullThrottle:SetRefreshRates(NumberRange.new(0, 15))
			end).toThrow()
			expect(function()
				cullThrottle:SetRefreshRates(NumberRange.new(-1, 60))
			end).toThrow()
		end)

		it("rejects rates that are NaN at both ends", function()
			-- The rates invert into refresh periods, and a NaN period breaks every
			-- band comparison in the ingest pass.
			expect(function()
				cullThrottle:SetRefreshRates(NumberRange.new(0 / 0, 0 / 0))
			end).toThrow()
		end)

		it("rejects a NaN hiding in the rates' Max", function()
			-- NumberRange's ordering check passes NaN (every comparison against
			-- NaN is false), so a NaN best rate can ride in next to a valid
			-- worst rate. The setter gates Max on its own to catch it.
			expect(function()
				cullThrottle:SetRefreshRates(NumberRange.new(15, 0 / 0))
			end).toThrow()
		end)

		it("rejects infinite rates", function()
			-- An infinite Hz inverts to a zero-second period. A zero best period
			-- shoves every object out of the over-refresh region, and a zero
			-- worst period zeroes the refresh period midpoint that the render
			-- distance controller divides by, so non-finite rates error at the
			-- boundary like the other setters.
			expect(function()
				cullThrottle:SetRefreshRates(NumberRange.new(15, math.huge))
			end).toThrow()
			expect(function()
				cullThrottle:SetRefreshRates(NumberRange.new(math.huge, math.huge))
			end).toThrow()
		end)
	end)

	describe("SetMaxOccluders", function()
		it("accepts the boundary caps of zero and thirty-two", function()
			-- Each umbra claims one bit of a 32-bit mask, so 32 is the highest
			-- legal cap, and zero is the documented way to disable occlusion
			-- culling entirely.
			cullThrottle:SetMaxOccluders(0)
			expect(cullThrottle:GetMaxOccluders()).toBe(0)

			cullThrottle:SetMaxOccluders(32)
			expect(cullThrottle:GetMaxOccluders()).toBe(32)
		end)

		it("rejects a fractional occluder cap", function()
			-- A fractional count has no meaning as a table size, so the setter
			-- refuses it instead of truncating silently.
			expect(function()
				cullThrottle:SetMaxOccluders(2.5)
			end).toThrow()
		end)

		it("rejects a negative occluder cap", function()
			expect(function()
				cullThrottle:SetMaxOccluders(-1)
			end).toThrow()
		end)

		it("rejects a cap above thirty-two", function()
			-- The 33rd occluder would have no umbra mask bit to claim.
			expect(function()
				cullThrottle:SetMaxOccluders(33)
			end).toThrow()
		end)

		it("rejects a NaN occluder cap", function()
			-- Every comparison against NaN is false, so the bounds are phrased to
			-- fail it into the error rather than let it through.
			expect(function()
				cullThrottle:SetMaxOccluders(0 / 0)
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
		it("reads back the voxel size", function()
			cullThrottle:SetVoxelSize(50)
			expect(cullThrottle:GetVoxelSize()).toBe(50)
		end)

		it("reads back the render distance range", function()
			cullThrottle:SetRenderDistanceRange(NumberRange.new(250, 750))

			local range = cullThrottle:GetRenderDistanceRange()
			expect(range.Min).toBe(250)
			expect(range.Max).toBe(750)
		end)

		it("reads back the time budgets in seconds", function()
			cullThrottle:SetTimeBudgets(0.002, 0.003, 0.004)

			local search, ingest, update = cullThrottle:GetTimeBudgets()
			expect(search).toBe(0.002)
			expect(ingest).toBe(0.003)
			expect(update).toBe(0.004)
		end)

		it("reads back the refresh rates in Hz, symmetric with the setter", function()
			cullThrottle:SetRefreshRates(NumberRange.new(15, 60))

			local refreshRates = cullThrottle:GetRefreshRates()
			expect(refreshRates.Max).toBeCloseTo(60)
			expect(refreshRates.Min).toBeCloseTo(15)
		end)

		it("reads back the max occluders", function()
			-- The probe value is distinct from the default 8 so the getter can't
			-- pass by never reading the stored cap.
			cullThrottle:SetMaxOccluders(5)
			expect(cullThrottle:GetMaxOccluders()).toBe(5)
		end)

		it("reads back the boolean flags", function()
			cullThrottle:SetComputeVisibilityOnlyOnDemand(true)
			cullThrottle:SetStrictlyEnforceWorstRefreshRate(true)

			expect(cullThrottle:GetComputeVisibilityOnlyOnDemand()).toBe(true)
			expect(cullThrottle:GetStrictlyEnforceWorstRefreshRate()).toBe(true)

			cullThrottle:SetComputeVisibilityOnlyOnDemand(false)
			cullThrottle:SetStrictlyEnforceWorstRefreshRate(false)

			expect(cullThrottle:GetComputeVisibilityOnlyOnDemand()).toBe(false)
			expect(cullThrottle:GetStrictlyEnforceWorstRefreshRate()).toBe(false)
		end)

		it("derives dynamic render distance from the range width", function()
			cullThrottle:SetRenderDistanceRange(NumberRange.new(200, 800))
			expect(cullThrottle:GetDynamicRenderDistance()).toBe(true)

			cullThrottle:SetRenderDistanceRange(NumberRange.new(500, 500))
			expect(cullThrottle:GetDynamicRenderDistance()).toBe(false)
		end)

		it("exposes the live render distance, distinct from the configured range", function()
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
end)
