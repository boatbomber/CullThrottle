--!strict
--!optimize 2
--!native

--[[
	This is the dynamic render distance controller, an adaptive step controller
	that grows the render distance while the frame work is comfortably under
	budget and shrinks it when any budget is overrun, damping its step size as
	it settles so the distance doesn't bounce.
]]

local types = require(script.Parent.types)
local Config = require(script.Parent.Config)

-- Search pressure weighs heaviest and the per-object update pace lightest.
local DYNAMIC_RENDER_DISTANCE_SEARCH_WEIGHT = 1.3
local DYNAMIC_RENDER_DISTANCE_INGEST_WEIGHT = 1.0
local DYNAMIC_RENDER_DISTANCE_DELTA_WEIGHT = 0.8
-- Grow only when the worst weighted load is below this fraction of budget.
local DYNAMIC_RENDER_DISTANCE_GROW_HEADROOM = 0.6
-- The step is a fraction of the range midpoint, adapted within these bounds.
-- A fresh controller's first move clamps the initial step down to the max.
local DYNAMIC_RENDER_DISTANCE_INITIAL_STEP = 0.03
local DYNAMIC_RENDER_DISTANCE_MIN_STEP = 0.0002
local DYNAMIC_RENDER_DISTANCE_MAX_STEP = 0.025
-- Shrink the step on a reversal or settle, and grow it on a sustained trend.
local DYNAMIC_RENDER_DISTANCE_STEP_DAMPING = 0.35
local DYNAMIC_RENDER_DISTANCE_STEP_GAIN = 1.2

local RenderDistanceController = {}
RenderDistanceController.__index = RenderDistanceController

type RenderDistanceControllerProto = {
	_config: Config.Config,
	_perfMetrics: types.PerfMetrics,
	-- The step is a fraction of the midpoint distance, and direction holds the
	-- last move's sign (-1 shrink, 0 hold, 1 grow).
	_step: number,
	_direction: number,
}

export type RenderDistanceController = typeof(setmetatable(
	{} :: RenderDistanceControllerProto,
	RenderDistanceController
))

--[[
	Builds the controller at rest. It adjusts the live render distance on the
	config, but its working state (step size and direction) lives here.
]]
function RenderDistanceController.new(config: Config.Config, perfMetrics: types.PerfMetrics): RenderDistanceController
	local self = setmetatable({
		_config = config,
		_perfMetrics = perfMetrics,
		_step = DYNAMIC_RENDER_DISTANCE_INITIAL_STEP,
		_direction = 0,
	}, RenderDistanceController)

	return self
end

--[[
	Returns the controller to its starting step and direction. The facade calls
	this when the render distance range changes, so momentum built up in the
	old range doesn't carry into the new one.
]]
function RenderDistanceController.reset(self: RenderDistanceController)
	self._step = DYNAMIC_RENDER_DISTANCE_INITIAL_STEP
	self._direction = 0
end

--[[
	Runs one controller step per processed frame. It normalizes each budget
	constraint into a weighted load, picks a direction from the worst one (grow,
	hold, or shrink), adapts the step size, and applies the step to the render
	distance within the configured bounds.
]]
function RenderDistanceController.adjust(self: RenderDistanceController)
	local config = self._config
	if config.minRenderDistance == config.maxRenderDistance then
		return
	end

	local perfMetrics = self._perfMetrics

	-- A zero budget means that pass is configured off rather than starved, so it
	-- gets no vote in the load or the skip signal.
	local searchTimeBudget = config.searchTimeBudget
	local ingestTimeBudget = config.ingestTimeBudget
	local updateTimeBudget = config.updateTimeBudget

	local isSkipping = (ingestTimeBudget > 0 and perfMetrics._getAverage(perfMetrics._skippedIngest) ~= 0)
		or (searchTimeBudget > 0 and perfMetrics._getAverage(perfMetrics._skippedSearch) ~= 0)

	local load = math.max(
		if searchTimeBudget > 0
			then (perfMetrics._searchDuration / searchTimeBudget) * DYNAMIC_RENDER_DISTANCE_SEARCH_WEIGHT
			else 0,
		if ingestTimeBudget > 0
			then (perfMetrics._ingestDuration / ingestTimeBudget) * DYNAMIC_RENDER_DISTANCE_INGEST_WEIGHT
			else 0,
		if updateTimeBudget > 0
			then (perfMetrics._averageObjectDeltaTime / config.refreshPeriodMidpoint) * DYNAMIC_RENDER_DISTANCE_DELTA_WEIGHT
			else 0
	)

	local direction = if isSkipping or load > 1 then -1 elseif load < DYNAMIC_RENDER_DISTANCE_GROW_HEADROOM then 1 else 0

	local step = self._step
	local lastDirection = self._direction
	if direction == 0 or (lastDirection ~= 0 and direction ~= lastDirection) then
		-- Settled or reversed, so damp toward rest.
		step *= DYNAMIC_RENDER_DISTANCE_STEP_DAMPING
	else
		-- A consistent trend (or the first move from rest) accelerates to catch up.
		step *= DYNAMIC_RENDER_DISTANCE_STEP_GAIN
	end
	step = math.clamp(step, DYNAMIC_RENDER_DISTANCE_MIN_STEP, DYNAMIC_RENDER_DISTANCE_MAX_STEP)

	self._step = step
	self._direction = direction

	if direction ~= 0 then
		config.renderDistance = math.clamp(
			config.renderDistance + direction * step * config.renderDistanceMidpoint,
			config.minRenderDistance,
			config.maxRenderDistance
		)
	end
end

return RenderDistanceController
