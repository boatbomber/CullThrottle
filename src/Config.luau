--!strict

local Config = {}
Config.__index = Config

type ConfigurationProto = {
	bestRefreshRate: number,
	worstRefreshRate: number,
	refreshRateRange: number,
	renderDistance: number,
	searchTimeBudget: number,
	updateTimeBudget: number,
	performanceFalloffFactor: number,
	voxelSize: number,
	halfVoxelSizeVec: Vector3,
	radiusThresholdForCorners: number,
}

export type Config = typeof(setmetatable({} :: ConfigurationProto, Config))

function Config.new(): Config
	local self = setmetatable({}, Config)

	self.voxelSize = 90
	self.halfVoxelSizeVec = Vector3.one * (self.voxelSize / 2)
	self.radiusThresholdForCorners = self.voxelSize * (1 / 8)
	self.renderDistance = 450
	self.searchTimeBudget = 1.25 / 1000
	self.updateTimeBudget = 0.35 / 1000
	self.bestRefreshRate = 1 / 60
	self.worstRefreshRate = 1 / 15
	self.refreshRateRange = self.worstRefreshRate - self.bestRefreshRate
	self.performanceFalloffFactor = 1

	return self
end

return Config
