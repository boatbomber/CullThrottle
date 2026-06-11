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

describe("RenderDistanceController", function()
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

	it("should adjust render distance when performance is poor", function()
		cullThrottle:SetRenderDistanceRange(NumberRange.new(200, 2500))

		-- These sit far past their budgets (the default search budget alone is
		-- 0.0008s), so the worst weighted load lands deep in shrink territory.
		cullThrottle._perfMetrics._averageObjectDeltaTime = 1
		cullThrottle._perfMetrics._searchDuration = 0.01
		cullThrottle._perfMetrics._ingestDuration = 0.01

		local originalDistance = cullThrottle._config.renderDistance
		cullThrottle._renderDistanceController:adjust()

		expect(cullThrottle._config.renderDistance).toBeLessThan(originalDistance)
	end)

	it("should increase render distance when performance is good", function()
		cullThrottle:SetRenderDistanceRange(NumberRange.new(200, 2500))

		-- These all sit under the grow headroom (60 percent of budget), and the
		-- skip buffers must read zero because any skipped frame forces a shrink
		-- no matter how light the load is.
		cullThrottle._perfMetrics._averageObjectDeltaTime = 0.01
		cullThrottle._perfMetrics._searchDuration = 0.0001
		cullThrottle._perfMetrics._ingestDuration = 0.0001
		cullThrottle._perfMetrics._skippedSearch = { 0, 0, 0, 0 }
		cullThrottle._perfMetrics._skippedIngest = { 0, 0, 0, 0 }

		local originalDistance = cullThrottle._config.renderDistance
		cullThrottle._renderDistanceController:adjust()

		expect(cullThrottle._config.renderDistance).toBeGreaterThan(originalDistance)
	end)

	it("ignores the search pass when its budget is zero", function()
		cullThrottle:SetRenderDistanceRange(NumberRange.new(200, 2500))
		local _, ingestBudget, updateBudget = cullThrottle:GetTimeBudgets()
		cullThrottle:SetTimeBudgets(0, ingestBudget, updateBudget)

		-- A zeroed-out search still measures a nonzero duration (seeding runs
		-- before the budget check) and falls back to cached verdicts for every
		-- volume, but neither signal may vote a shrink for a pass that is
		-- configured off.
		cullThrottle._perfMetrics._searchDuration = 0.01
		cullThrottle._perfMetrics._skippedSearch = { 9, 9, 9, 9 }
		cullThrottle._perfMetrics._ingestDuration = 0.0001
		cullThrottle._perfMetrics._averageObjectDeltaTime = 0.01
		cullThrottle._perfMetrics._skippedIngest = { 0, 0, 0, 0 }

		local originalDistance = cullThrottle._config.renderDistance
		cullThrottle._renderDistanceController:adjust()

		expect(cullThrottle._config.renderDistance).toBeGreaterThan(originalDistance)
	end)

	it("ignores the ingest pass when its budget is zero", function()
		cullThrottle:SetRenderDistanceRange(NumberRange.new(200, 2500))
		local searchBudget, _, updateBudget = cullThrottle:GetTimeBudgets()
		cullThrottle:SetTimeBudgets(searchBudget, 0, updateBudget)

		-- A zeroed-out ingest dumps every voxel through the fast pass, so its
		-- duration and skip tallies only describe the fallback at work.
		cullThrottle._perfMetrics._ingestDuration = 0.01
		cullThrottle._perfMetrics._skippedIngest = { 9, 9, 9, 9 }
		cullThrottle._perfMetrics._searchDuration = 0.0001
		cullThrottle._perfMetrics._averageObjectDeltaTime = 0.01
		cullThrottle._perfMetrics._skippedSearch = { 0, 0, 0, 0 }

		local originalDistance = cullThrottle._config.renderDistance
		cullThrottle._renderDistanceController:adjust()

		expect(cullThrottle._config.renderDistance).toBeGreaterThan(originalDistance)
	end)

	it("ignores the update pace when the update budget is zero", function()
		cullThrottle:SetRenderDistanceRange(NumberRange.new(200, 2500))
		local searchBudget, ingestBudget = cullThrottle:GetTimeBudgets()
		cullThrottle:SetTimeBudgets(searchBudget, ingestBudget, 0)

		-- With updates configured off nothing refreshes the per-object delta,
		-- so a stale measurement must not keep voting a shrink.
		cullThrottle._perfMetrics._averageObjectDeltaTime = 1
		cullThrottle._perfMetrics._searchDuration = 0.0001
		cullThrottle._perfMetrics._ingestDuration = 0.0001
		cullThrottle._perfMetrics._skippedSearch = { 0, 0, 0, 0 }
		cullThrottle._perfMetrics._skippedIngest = { 0, 0, 0, 0 }

		local originalDistance = cullThrottle._config.renderDistance
		cullThrottle._renderDistanceController:adjust()

		expect(cullThrottle._config.renderDistance).toBeGreaterThan(originalDistance)
	end)

	it("should respect min and max render distance limits", function()
		cullThrottle:SetRenderDistanceRange(NumberRange.new(200, 2500))

		cullThrottle._config.renderDistance = cullThrottle._config.minRenderDistance
		cullThrottle._perfMetrics._averageObjectDeltaTime = 1
		cullThrottle._renderDistanceController:adjust()

		expect(cullThrottle._config.renderDistance).toBeGreaterThanOrEqual(cullThrottle._config.minRenderDistance)

		cullThrottle._config.renderDistance = cullThrottle._config.maxRenderDistance
		cullThrottle._perfMetrics._averageObjectDeltaTime = 0.001
		cullThrottle._renderDistanceController:adjust()

		expect(cullThrottle._config.renderDistance).toBeLessThanOrEqual(cullThrottle._config.maxRenderDistance)
	end)

	it("should not adjust render distance for a zero-width range", function()
		cullThrottle:SetRenderDistanceRange(NumberRange.new(500, 500))

		cullThrottle._perfMetrics._averageObjectDeltaTime = 1
		cullThrottle._perfMetrics._searchDuration = 0.01
		cullThrottle._perfMetrics._ingestDuration = 0.01

		cullThrottle._renderDistanceController:adjust()

		expect(cullThrottle._config.renderDistance).toBe(500)
	end)

	it("starts with fresh momentum when the range changes", function()
		cullThrottle:SetRenderDistanceRange(NumberRange.new(200, 2500))

		-- Drive a shrink streak so the controller builds momentum (a pegged step
		-- and a shrink direction).
		cullThrottle._perfMetrics._averageObjectDeltaTime = 1
		cullThrottle._perfMetrics._searchDuration = 0.01
		cullThrottle._perfMetrics._ingestDuration = 0.01
		for _ = 1, 3 do
			cullThrottle._renderDistanceController:adjust()
		end

		cullThrottle:SetRenderDistanceRange(NumberRange.new(400, 3000))

		-- The new range starts under light load, so the first adjustment grows.
		cullThrottle._perfMetrics._averageObjectDeltaTime = 0.01
		cullThrottle._perfMetrics._searchDuration = 0.0001
		cullThrottle._perfMetrics._ingestDuration = 0.0001
		cullThrottle._perfMetrics._skippedSearch = { 0, 0, 0, 0 }
		cullThrottle._perfMetrics._skippedIngest = { 0, 0, 0, 0 }

		local midpoint = cullThrottle._config.renderDistanceMidpoint
		cullThrottle._renderDistanceController:adjust()

		-- A first move from rest takes a full step (which clamps to the 0.025 max
		-- step, hard-coded here), while leftover shrink momentum would read the
		-- grow as a reversal and damp the step to a fraction of that.
		expect(cullThrottle:GetRenderDistance() - midpoint).toBeCloseTo(0.025 * midpoint)
	end)
end)
