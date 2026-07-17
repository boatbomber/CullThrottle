--!strict

--[[
	This is the mutable runtime configuration a CullThrottle instance reads
	each frame. It's built with the library defaults and mutated in place by
	the Set* methods on CullThrottle. Fields with derived companions (the
	multi-voxel threshold, the refresh period range and midpoint, and the
	render distance midpoint and live baseline) are only ever written through
	the set methods below, which both Config.new and the facade setters call,
	so each derivation lives in one place.
]]

local Config = {}
Config.__index = Config

-- The multiVoxelRadiusThreshold is this fraction of the voxel size. An object whose
-- radius exceeds it can straddle more than one voxel, so it is tracked in every
-- voxel it overlaps instead of just the one holding its center.
Config.MULTI_VOXEL_RADIUS_RATIO = 0.25

type ConfigurationProto = {
	voxelSize: number,
	multiVoxelRadiusThreshold: number,

	computeVisibilityOnlyOnDemand: boolean,
	strictlyEnforceWorstRefreshRate: boolean,

	searchTimeBudget: number,
	updateTimeBudget: number,
	ingestTimeBudget: number,

	maxOccluders: number,

	bestRefreshPeriod: number,
	worstRefreshPeriod: number,
	refreshPeriodRange: number,
	refreshPeriodMidpoint: number,

	minRenderDistance: number,
	maxRenderDistance: number,
	renderDistanceMidpoint: number,
	renderDistance: number,
}

export type Config = typeof(setmetatable({} :: ConfigurationProto, Config))

--[[
	Builds a config holding the library defaults. The fields with derived
	companions go through the same set methods the facade setters use.
]]
function Config.new(): Config
	local self: Config = setmetatable({}, Config) :: any

	self.computeVisibilityOnlyOnDemand = false
	self.strictlyEnforceWorstRefreshRate = false

	self.searchTimeBudget = 0.8 / 1000
	self.ingestTimeBudget = 1.2 / 1000
	self.updateTimeBudget = 0.4 / 1000

	self.maxOccluders = 8

	self:setVoxelSize(100)
	self:setRefreshPeriods(1 / 60, 1 / 15)
	self:setRenderDistanceRange(150, 2000)

	return self
end

--[[
	Sets the voxel grid cell size and derives the multi-voxel radius threshold
	from it.
]]
function Config.setVoxelSize(self: Config, voxelSize: number)
	self.voxelSize = voxelSize
	self.multiVoxelRadiusThreshold = voxelSize * Config.MULTI_VOXEL_RADIUS_RATIO
end

--[[
	Sets the best (most frequent) and worst refresh periods, in seconds between
	refreshes, and derives their range and midpoint.
]]
function Config.setRefreshPeriods(self: Config, bestRefreshPeriod: number, worstRefreshPeriod: number)
	self.bestRefreshPeriod = bestRefreshPeriod
	self.worstRefreshPeriod = worstRefreshPeriod
	self.refreshPeriodRange = worstRefreshPeriod - bestRefreshPeriod
	self.refreshPeriodMidpoint = (bestRefreshPeriod + worstRefreshPeriod) / 2
end

--[[
	Sets the [min, max] render distance bounds, derives their midpoint, and
	resets the live distance to that baseline.
]]
function Config.setRenderDistanceRange(self: Config, minRenderDistance: number, maxRenderDistance: number)
	self.minRenderDistance = minRenderDistance
	self.maxRenderDistance = maxRenderDistance
	self.renderDistanceMidpoint = (minRenderDistance + maxRenderDistance) / 2
	self.renderDistance = self.renderDistanceMidpoint
end

return Config
