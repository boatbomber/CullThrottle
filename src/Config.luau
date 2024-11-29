--!strict

local Config = {}
Config.__index = Config

type ConfigurationProto = {
	bestRefreshRate: number,
	worstRefreshRate: number,
	refreshRateRange: number,
	strictlyEnforceWorstRefreshRate: boolean,
	renderDistance: number,
	searchTimeBudget: number,
	updateTimeBudget: number,
	voxelSize: number,
	halfVoxelSizeVec: Vector3,
	radiusThresholdForCorners: number,
}

export type Config = typeof(setmetatable({} :: ConfigurationProto, Config))

function Config.new(): Config
	local self = setmetatable({}, Config)

	self.voxelSize = 90
	self.renderDistance = 450
	self.searchTimeBudget = 1.25 / 1000
	self.updateTimeBudget = 0.35 / 1000
	self.bestRefreshRate = 1 / 60
	self.worstRefreshRate = 1 / 15
	self.strictlyEnforceWorstRefreshRate = false

	-- These are computed values, not meant to be directly set
	self.halfVoxelSizeVec = Vector3.one * (self.voxelSize / 2)
	self.radiusThresholdForCorners = self.voxelSize * (1 / 8)
	self.refreshRateRange = self.worstRefreshRate - self.bestRefreshRate

	return self
end

return Config
