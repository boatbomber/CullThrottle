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

	--[[
		Stages the search duration far over its default budget while the ingest
		duration and the update pace sit under the grow headroom, so the search
		term alone votes the shrink.
	]]
	local function stageSearchOverrun()
		cullThrottle._perfMetrics._searchDuration = 0.01
		cullThrottle._perfMetrics._ingestDuration = 0.0001
		cullThrottle._perfMetrics._averageObjectDeltaTime = 0.01
	end

	--[[
		Stages the ingest duration far over its default budget while the search
		duration and the update pace sit under the grow headroom, so the ingest
		term alone votes the shrink.
	]]
	local function stageIngestOverrun()
		cullThrottle._perfMetrics._searchDuration = 0.0001
		cullThrottle._perfMetrics._ingestDuration = 0.01
		cullThrottle._perfMetrics._averageObjectDeltaTime = 0.01
	end

	--[[
		Stages the per-object update pace far past the refresh period midpoint
		while both pass durations sit under the grow headroom, so the pace term
		alone votes the shrink.
	]]
	local function stageSlowUpdatePace()
		cullThrottle._perfMetrics._searchDuration = 0.0001
		cullThrottle._perfMetrics._ingestDuration = 0.0001
		cullThrottle._perfMetrics._averageObjectDeltaTime = 1
	end

	--[[
		Stages the perf metrics so every weighted load sits under the grow
		headroom against the default budgets.
	]]
	local function stageLightLoad()
		cullThrottle._perfMetrics._searchDuration = 0.0001
		cullThrottle._perfMetrics._ingestDuration = 0.0001
		cullThrottle._perfMetrics._averageObjectDeltaTime = 0.01
	end

	--[[
		Stages the perf metrics so the worst weighted load lands between the
		grow headroom and the budget line, inside the controller's deadband,
		against the default budgets.
	]]
	local function stageDeadbandLoad()
		cullThrottle._perfMetrics._searchDuration = 0.0005
		cullThrottle._perfMetrics._ingestDuration = 0.0001
		cullThrottle._perfMetrics._averageObjectDeltaTime = 0.01
	end

	--[[
		Runs one controller adjustment and returns the signed render distance
		move it took.
	]]
	local function adjustOnce(): number
		local before = cullThrottle:GetRenderDistance()
		cullThrottle._renderDistanceController:adjust()
		return cullThrottle:GetRenderDistance() - before
	end

	it("shrinks the render distance when the search load runs over budget", function()
		cullThrottle:SetRenderDistanceRange(NumberRange.new(200, 2500))

		-- The staged search duration sits far past the default 0.0008s search
		-- budget, so the worst weighted load lands deep in shrink territory.
		stageSearchOverrun()

		local originalDistance = cullThrottle:GetRenderDistance()
		cullThrottle._renderDistanceController:adjust()

		expect(cullThrottle:GetRenderDistance()).toBeLessThan(originalDistance)
	end)

	it("grows the render distance when every load sits under the grow headroom", function()
		cullThrottle:SetRenderDistanceRange(NumberRange.new(200, 2500))

		-- The staged durations all sit under the grow headroom (60 percent of
		-- budget). The skip rings stay at a fresh instance's zeros, which
		-- matters because any skipped frame would force a shrink no matter how
		-- light the load is.
		stageLightLoad()

		local originalDistance = cullThrottle:GetRenderDistance()
		cullThrottle._renderDistanceController:adjust()

		expect(cullThrottle:GetRenderDistance()).toBeGreaterThan(originalDistance)
	end)

	it("holds the render distance when the worst load sits inside the deadband", function()
		cullThrottle:SetRenderDistanceRange(NumberRange.new(200, 2500))

		-- The worst weighted load lands around 0.81, above the 0.6 grow headroom
		-- and below the 1.0 budget line, so the controller must hold rather than
		-- creep in either direction and reintroduce the oscillation the deadband
		-- exists to prevent.
		stageDeadbandLoad()

		local originalDistance = cullThrottle:GetRenderDistance()
		cullThrottle._renderDistanceController:adjust()

		expect(cullThrottle:GetRenderDistance()).toBe(originalDistance)
	end)

	it("forces a shrink when the search pass skipped voxels despite light load", function()
		cullThrottle:SetRenderDistanceRange(NumberRange.new(200, 2500))

		-- Every duration sits comfortably under the grow headroom, but the skip
		-- ring shows the search pass couldn't even keep up. Skipping outranks
		-- load, so the controller must shrink anyway. The ingest ring stays at
		-- zero so the search ring alone carries the vote.
		stageLightLoad()
		cullThrottle._perfMetrics._skippedSearch = { 1, 0, 0, 0 }
		cullThrottle._perfMetrics._skippedIngest = { 0, 0, 0, 0 }

		local originalDistance = cullThrottle:GetRenderDistance()
		cullThrottle._renderDistanceController:adjust()

		expect(cullThrottle:GetRenderDistance()).toBeLessThan(originalDistance)
	end)

	it("forces a shrink when the ingest pass skipped voxels even with the search budget off", function()
		cullThrottle:SetRenderDistanceRange(NumberRange.new(200, 2500))
		local _, ingestBudget, updateBudget = cullThrottle:GetTimeBudgets()
		cullThrottle:SetTimeBudgets(0, ingestBudget, updateBudget)

		-- The ingest pass has a live budget and its skip ring shows a missed
		-- frame, so it must force a shrink all by itself. The search budget is
		-- turned off to prove the shrink keys off the ingest budget, since a
		-- guard consulting the search budget by mistake would read zero, discard
		-- the skip, and grow on the light load instead.
		stageLightLoad()
		cullThrottle._perfMetrics._skippedIngest = { 1, 0, 0, 0 }
		cullThrottle._perfMetrics._skippedSearch = { 0, 0, 0, 0 }

		local originalDistance = cullThrottle:GetRenderDistance()
		cullThrottle._renderDistanceController:adjust()

		expect(cullThrottle:GetRenderDistance()).toBeLessThan(originalDistance)
	end)

	it("resumes growing once the skipped frames age out of the ring", function()
		cullThrottle:SetRenderDistanceRange(NumberRange.new(200, 2500))

		-- A recent skipped frame forces a shrink even though every load reads
		-- light.
		stageLightLoad()
		cullThrottle._perfMetrics._skippedSearch = { 1, 0, 0, 0 }
		local originalDistance = cullThrottle:GetRenderDistance()
		cullThrottle._renderDistanceController:adjust()
		local shrunkDistance = cullThrottle:GetRenderDistance()
		expect(shrunkDistance).toBeLessThan(originalDistance)

		-- The skip pressure must release once the skipped frame ages out of
		-- the lookback ring rather than latching. With the ring back at zeros
		-- and the load still light, growth resumes on the very next adjustment.
		cullThrottle._perfMetrics._skippedSearch = { 0, 0, 0, 0 }
		cullThrottle._renderDistanceController:adjust()
		expect(cullThrottle:GetRenderDistance()).toBeGreaterThan(shrunkDistance)
	end)

	it("shrinks when only one of the three loads runs over budget", function()
		cullThrottle:SetRenderDistanceRange(NumberRange.new(200, 2500))
		cullThrottle:SetTimeBudgets(0.001, 0.001, 0.001)

		-- The search load lands just over the budget line (0.0008 / 0.001 at its
		-- 1.3 weight is 1.04) while the other two stay light enough that the
		-- mean of all three sits under the grow headroom. Only the worst
		-- constraint drives the controller, so it must shrink where an
		-- implementation that averaged the loads or let the light ones outvote
		-- the heavy one would grow instead.
		cullThrottle._perfMetrics._searchDuration = 0.0008
		cullThrottle._perfMetrics._ingestDuration = 0.00005
		cullThrottle._perfMetrics._averageObjectDeltaTime = 0.005

		local originalDistance = cullThrottle:GetRenderDistance()
		cullThrottle._renderDistanceController:adjust()

		expect(cullThrottle:GetRenderDistance()).toBeLessThan(originalDistance)
	end)

	it("shrinks when the ingest load alone runs over budget", function()
		cullThrottle:SetRenderDistanceRange(NumberRange.new(200, 2500))

		-- Only the staged ingest duration runs over its budget, while the
		-- search duration and the update pace read light. The ingest term must
		-- carry the shrink on its own, so a controller missing that term would
		-- read pure headroom here and grow instead.
		stageIngestOverrun()

		local originalDistance = cullThrottle:GetRenderDistance()
		cullThrottle._renderDistanceController:adjust()

		expect(cullThrottle:GetRenderDistance()).toBeLessThan(originalDistance)
	end)

	it("shrinks when the update pace alone falls behind the refresh midpoint", function()
		cullThrottle:SetRenderDistanceRange(NumberRange.new(200, 2500))

		-- Only the per-object delta runs past the refresh period midpoint,
		-- while both pass durations read light. The pace term must carry the
		-- shrink on its own, so a controller missing that term would read pure
		-- headroom here and grow instead.
		stageSlowUpdatePace()

		local originalDistance = cullThrottle:GetRenderDistance()
		cullThrottle._renderDistanceController:adjust()

		expect(cullThrottle:GetRenderDistance()).toBeLessThan(originalDistance)
	end)

	it("recovers from a single overrun spike with one shrink and a damped reversal", function()
		cullThrottle:SetRenderDistanceRange(NumberRange.new(200, 2500))

		-- One frame's search load spikes over budget and the controller
		-- shrinks once at the full step.
		stageSearchOverrun()
		local shrinkDelta = -adjustOnce()
		expect(shrinkDelta).toBeGreaterThan(0)

		-- The load reads healthy again on the very next frame, so the recovery
		-- grow is a reversal. A reversal damps the step rather than swinging
		-- back equally, so the grow must move strictly less than the shrink it
		-- answers instead of bouncing the distance around one bad frame.
		stageLightLoad()
		local growDelta = adjustOnce()

		expect(growDelta).toBeGreaterThan(0)
		expect(growDelta).toBeLessThan(shrinkDelta)
	end)

	it("accelerates the step while the direction stays consistent", function()
		cullThrottle:SetRenderDistanceRange(NumberRange.new(200, 2500))

		-- The controller clamps its step to 0.025 of the range midpoint, so no
		-- single move may exceed this bound no matter how long a streak runs.
		local maxMove = 0.025 * cullThrottle._config.renderDistanceMidpoint

		-- The first move from rest takes the full starting step, so
		-- acceleration only becomes observable after a reversal damps the step
		-- back down. One overrun frame shrinks first, moving within the cap.
		stageSearchOverrun()
		local firstShrinkDelta = -adjustOnce()
		expect(firstShrinkDelta).toBeGreaterThan(0)
		expect(firstShrinkDelta).toBeLessThanOrEqual(maxMove + 1e-9)

		-- The load then lifts for good. The reversal damps the first grow, and
		-- every grow after it accelerates while the direction holds, so the
		-- streak's moves must take strictly increasing deltas.
		stageLightLoad()
		local deltas = {}
		for i = 1, 4 do
			deltas[i] = adjustOnce()
		end

		for i = 1, 4 do
			expect(deltas[i]).toBeGreaterThan(0)
			expect(deltas[i]).toBeLessThanOrEqual(maxMove + 1e-9)
			if i > 1 then
				expect(deltas[i]).toBeGreaterThan(deltas[i - 1])
			end
		end

		-- A long enough streak climbs the step to its cap, where consecutive
		-- moves level off instead of growing without bound.
		local previousMove = deltas[4]
		local leveledOff = false
		for _ = 1, 32 do
			local move = adjustOnce()
			expect(move).toBeLessThanOrEqual(maxMove + 1e-9)
			if move <= previousMove + 1e-9 then
				leveledOff = true
				break
			end
			previousMove = move
		end
		expect(leveledOff).toBe(true)
	end)

	it("keeps damping the step for every frame it settles in the deadband", function()
		cullThrottle:SetRenderDistanceRange(NumberRange.new(200, 2500))

		--[[
			Takes one full-step shrink under an overrun, settles in the deadband
			for the given number of frames, then returns the grow move that
			follows.
		]]
		local function growAfterSettling(deadbandFrames: number): number
			cullThrottle._renderDistanceController:reset()
			stageSearchOverrun()
			adjustOnce()
			stageDeadbandLoad()
			for _ = 1, deadbandFrames do
				-- The deadband holds the distance itself in place.
				expect(adjustOnce()).toBe(0)
			end
			stageLightLoad()
			return adjustOnce()
		end

		-- Every frame spent settled in the deadband must damp the step further,
		-- so the grow that follows two settled frames has to come out strictly
		-- smaller than the grow that follows one. A controller that only damped
		-- on the reversal into the deadband would hand both sequences the same
		-- step and move them equally.
		local growAfterOne = growAfterSettling(1)
		local growAfterTwo = growAfterSettling(2)

		expect(growAfterOne).toBeGreaterThan(0)
		expect(growAfterTwo).toBeGreaterThan(0)
		expect(growAfterTwo).toBeLessThan(growAfterOne)
	end)

	it("damps oscillating moves down to a nonzero floor instead of deadlocking", function()
		cullThrottle:SetRenderDistanceRange(NumberRange.new(200, 2500))

		-- The load flips between an overrun and light on every adjustment, so
		-- every move after the first is a reversal and the controller damps
		-- over and over. The step must converge on its floor rather than
		-- damping toward zero, because a step that damped all the way out
		-- would leave the controller unable to respond once the scene
		-- changed.
		local magnitudes = {}
		for cycle = 1, 24 do
			if cycle % 2 == 1 then
				stageSearchOverrun()
			else
				stageLightLoad()
			end
			magnitudes[cycle] = math.abs(adjustOnce())
		end

		-- The damping is real at the start and the magnitudes never grow back.
		-- The tiny allowance covers float wiggle once the moves sit at the floor.
		expect(magnitudes[2]).toBeLessThan(magnitudes[1])
		for cycle = 2, 24 do
			expect(magnitudes[cycle]).toBeLessThanOrEqual(magnitudes[cycle - 1] + 1e-9)
		end

		-- The late moves all sit on one shared nonzero floor instead of still
		-- shrinking apart from each other geometrically.
		expect(magnitudes[24]).toBeGreaterThan(0)
		for cycle = 20, 23 do
			expect(magnitudes[cycle] / magnitudes[24]).toBeCloseTo(1, 6)
		end
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

		local originalDistance = cullThrottle:GetRenderDistance()
		cullThrottle._renderDistanceController:adjust()

		expect(cullThrottle:GetRenderDistance()).toBeGreaterThan(originalDistance)
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

		local originalDistance = cullThrottle:GetRenderDistance()
		cullThrottle._renderDistanceController:adjust()

		expect(cullThrottle:GetRenderDistance()).toBeGreaterThan(originalDistance)
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

		local originalDistance = cullThrottle:GetRenderDistance()
		cullThrottle._renderDistanceController:adjust()

		expect(cullThrottle:GetRenderDistance()).toBeGreaterThan(originalDistance)
	end)

	it("grows toward the max when every budget is zero", function()
		cullThrottle:SetRenderDistanceRange(NumberRange.new(200, 2500))
		cullThrottle:SetTimeBudgets(0, 0, 0)

		-- With every pass configured off, no constraint gets a vote no matter
		-- what the metrics read, and reading no signal as full headroom is the
		-- intended choice. The distance drifts toward the configured max
		-- rather than freezing wherever it happened to sit. The staged
		-- overruns and skip rings pin that none of them can sneak a vote in.
		cullThrottle._perfMetrics._searchDuration = 0.01
		cullThrottle._perfMetrics._ingestDuration = 0.01
		cullThrottle._perfMetrics._averageObjectDeltaTime = 1
		cullThrottle._perfMetrics._skippedSearch = { 9, 9, 9, 9 }
		cullThrottle._perfMetrics._skippedIngest = { 9, 9, 9, 9 }

		local originalDistance = cullThrottle:GetRenderDistance()
		cullThrottle._renderDistanceController:adjust()

		expect(cullThrottle:GetRenderDistance()).toBeGreaterThan(originalDistance)
	end)

	it("clamps adjustments at the render distance bounds", function()
		cullThrottle:SetRenderDistanceRange(NumberRange.new(200, 2500))

		-- The distance starts barely above the floor and the staged shrink
		-- moves far more than that gap, so the clamp must catch the move
		-- exactly at the minimum rather than letting it pass below.
		cullThrottle._config.renderDistance = cullThrottle._config.minRenderDistance + 1
		stageSearchOverrun()
		cullThrottle._renderDistanceController:adjust()

		expect(cullThrottle:GetRenderDistance()).toBe(cullThrottle:GetRenderDistanceRange().Min)

		-- The same idea mirrored at the ceiling, where a light load grows
		-- across the gap and the clamp must catch the move exactly at the
		-- maximum.
		cullThrottle._config.renderDistance = cullThrottle._config.maxRenderDistance - 1
		stageLightLoad()
		cullThrottle._renderDistanceController:adjust()

		expect(cullThrottle:GetRenderDistance()).toBe(cullThrottle:GetRenderDistanceRange().Max)
	end)

	it("holds the render distance still for a zero-width range", function()
		cullThrottle:SetRenderDistanceRange(NumberRange.new(500, 500))

		stageSearchOverrun()

		cullThrottle._renderDistanceController:adjust()

		expect(cullThrottle:GetRenderDistance()).toBe(500)
	end)

	it("starts with fresh momentum when the range changes", function()
		cullThrottle:SetRenderDistanceRange(NumberRange.new(200, 2500))
		local oldMidpoint = cullThrottle._config.renderDistanceMidpoint

		-- Drive a shrink streak so the controller builds momentum (an
		-- accelerated step and a shrink direction). The first move's fraction
		-- of the midpoint is what a first move from rest takes in any range.
		stageSearchOverrun()
		local firstMoveFraction = -adjustOnce() / oldMidpoint
		for _ = 1, 2 do
			cullThrottle._renderDistanceController:adjust()
		end

		cullThrottle:SetRenderDistanceRange(NumberRange.new(400, 3000))

		-- The new range starts under light load, so the first adjustment grows.
		stageLightLoad()

		local midpoint = cullThrottle._config.renderDistanceMidpoint
		local growFraction = adjustOnce() / midpoint

		-- A first move from rest grows by no more than the step cap's 0.025 of
		-- the midpoint, and it comes out no smaller than the old range's first
		-- move (a whisker of float slack aside). Leftover shrink momentum
		-- would instead read the grow as a reversal and damp it to a fraction
		-- of that.
		expect(growFraction).toBeGreaterThan(firstMoveFraction * 0.99)
		expect(growFraction).toBeLessThanOrEqual(0.025 + 1e-9)
	end)
end)
