--!strict

local Config = {}
Config.__index = Config

type ConfigurationProto = {
	voxelSize: number,
	renderDistanceTarget: number,
	searchTimeBudget: number,
	updateTimeBudget: number,
	ingestTimeBudget: number,
	bestRefreshRate: number,
	worstRefreshRate: number,

	computeVisibilityOnlyOnDemand: boolean,
	strictlyEnforceWorstRefreshRate: boolean,
	dynamicRenderDistance: boolean,

	_renderDistance: number,
	_minRenderDistance: number,
	_maxRenderDistance: number,
	_halfVoxelSizeVec: Vector3,
	_radiusThresholdForCorners: number,
	_refreshRateRange: number,
}

export type Config = typeof(setmetatable({} :: ConfigurationProto, Config))

function Config.new(): Config
	local self = setmetatable({}, Config)

	self.voxelSize = 110
	self.renderDistanceTarget = 600
	self.searchTimeBudget = 0.95 / 1000
	self.ingestTimeBudget = 1.5 / 1000
	self.updateTimeBudget = 0.4 / 1000
	self.bestRefreshRate = 1 / 60
	self.worstRefreshRate = 1 / 15
	self.computeVisibilityOnlyOnDemand = false
	self.strictlyEnforceWorstRefreshRate = false
	self.dynamicRenderDistance = true

	-- These are computed values, not meant to be directly set
	self._renderDistance = self.renderDistanceTarget
	self._minRenderDistance = self.renderDistanceTarget / 2
	self._maxRenderDistance = self.renderDistanceTarget * 5
	self._halfVoxelSizeVec = Vector3.one * (self.voxelSize / 2)
	self._radiusThresholdForCorners = self.voxelSize * (1 / 8)
	self._refreshRateRange = self.worstRefreshRate - self.bestRefreshRate

	return self
end

return Config
