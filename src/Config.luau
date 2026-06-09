--!strict

local Config = {}
Config.__index = Config

type ConfigurationProto = {
	voxelSize: number,
	multiVoxelRadiusThreshold: number,

	computeVisibilityOnlyOnDemand: boolean,
	strictlyEnforceWorstRefreshRate: boolean,

	searchTimeBudget: number,
	updateTimeBudget: number,
	ingestTimeBudget: number,

	bestRefreshRate: number,
	worstRefreshRate: number,
	refreshRateRange: number,
	refreshRateMidpoint: number,

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
	self.multiVoxelRadiusThreshold = self.voxelSize * 0.25

	self.computeVisibilityOnlyOnDemand = false
	self.strictlyEnforceWorstRefreshRate = false

	self.searchTimeBudget = 0.8 / 1000
	self.ingestTimeBudget = 1.2 / 1000
	self.updateTimeBudget = 0.4 / 1000

	self.bestRefreshRate = 1 / 60
	self.worstRefreshRate = 1 / 15
	self.refreshRateRange = self.worstRefreshRate - self.bestRefreshRate
	self.refreshRateMidpoint = (self.bestRefreshRate + self.worstRefreshRate) / 2

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
