--!strict

local Config = {}
Config.__index = Config

-- multiVoxelRadiusThreshold is this fraction of the voxel size. An object whose
-- radius exceeds it can straddle more than one voxel, so it is tracked in every
-- voxel it overlaps instead of just the one holding its center. Both Config.new
-- and CullThrottle:SetVoxelSize derive the threshold from this single ratio so
-- they can't drift apart.
Config.MULTI_VOXEL_RADIUS_RATIO = 0.25

type ConfigurationProto = {
	voxelSize: number,
	multiVoxelRadiusThreshold: number,

	computeVisibilityOnlyOnDemand: boolean,
	strictlyEnforceWorstRefreshRate: boolean,

	searchTimeBudget: number,
	updateTimeBudget: number,
	ingestTimeBudget: number,

	bestRefreshPeriod: number,
	worstRefreshPeriod: number,
	refreshPeriodRange: number,
	refreshPeriodMidpoint: number,

	minRenderDistance: number,
	maxRenderDistance: number,
	renderDistanceMidpoint: number,
	dynamicRenderDistance: boolean,
	renderDistance: number,
	renderDistanceStep: number,
	renderDistanceDirection: number,
}

export type Config = typeof(setmetatable({} :: ConfigurationProto, Config))

function Config.new(): Config
	local self = setmetatable({}, Config)

	self.voxelSize = 100
	self.multiVoxelRadiusThreshold = self.voxelSize * Config.MULTI_VOXEL_RADIUS_RATIO

	self.computeVisibilityOnlyOnDemand = false
	self.strictlyEnforceWorstRefreshRate = false

	self.searchTimeBudget = 0.8 / 1000
	self.ingestTimeBudget = 1.2 / 1000
	self.updateTimeBudget = 0.4 / 1000

	self.bestRefreshPeriod = 1 / 60
	self.worstRefreshPeriod = 1 / 15
	self.refreshPeriodRange = self.worstRefreshPeriod - self.bestRefreshPeriod
	self.refreshPeriodMidpoint = (self.bestRefreshPeriod + self.worstRefreshPeriod) / 2

	self.minRenderDistance = 150
	self.maxRenderDistance = 2000
	self.renderDistanceMidpoint = (self.minRenderDistance + self.maxRenderDistance) / 2
	self.dynamicRenderDistance = self.minRenderDistance ~= self.maxRenderDistance
	self.renderDistance = self.renderDistanceMidpoint
	self.renderDistanceStep = 0.03
	self.renderDistanceDirection = 0

	return self
end

return Config
