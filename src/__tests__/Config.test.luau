local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages, DevPackages = ReplicatedStorage:WaitForChild("Packages"), ReplicatedStorage:WaitForChild("DevPackages")

local JestGlobals = require(DevPackages:WaitForChild("JestGlobals"))

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local beforeEach = JestGlobals.beforeEach

local Config = require(Packages:WaitForChild("CullThrottle"):WaitForChild("Config"))

describe("Config", function()
	describe("new", function()
		local config

		beforeEach(function()
			config = Config.new()
		end)

		it("uses the documented public defaults", function()
			-- These defaults are the library's out-of-the-box contract, so pin them
			-- directly rather than only through Set/Get round-trips that overwrite them.
			expect(config.voxelSize).toBe(100)
			expect(config.renderDistanceTarget).toBe(600)
			expect(config.searchTimeBudget).toBeCloseTo(0.8 / 1000)
			expect(config.ingestTimeBudget).toBeCloseTo(1.2 / 1000)
			expect(config.updateTimeBudget).toBeCloseTo(0.4 / 1000)
			expect(config.bestRefreshRate).toBeCloseTo(1 / 60)
			expect(config.worstRefreshRate).toBeCloseTo(1 / 15)
			expect(config.computeVisibilityOnlyOnDemand).toBe(false)
			expect(config.strictlyEnforceWorstRefreshRate).toBe(false)
			expect(config.dynamicRenderDistance).toBe(true)
		end)

		it("derives the computed fields from the public defaults", function()
			expect(config._renderDistance).toBe(600)
			expect(config._renderDistanceStep).toBeCloseTo(0.03)
			expect(config._renderDistanceDirection).toBe(0)
			expect(config._minRenderDistance).toBeCloseTo(600 / 3)
			expect(config._maxRenderDistance).toBe(600 * 5)
			-- Drives multi-voxel registration (voxelSize * 1/8); never asserted elsewhere.
			expect(config._multiVoxelRadiusThreshold).toBeCloseTo(100 * (1 / 8))
			expect(config._refreshRateRange).toBeCloseTo(1 / 15 - 1 / 60)
			expect(config._refreshRateMidpoint).toBeCloseTo((1 / 60 + 1 / 15) / 2)
		end)

		it("returns independent instances", function()
			local a = Config.new()
			local b = Config.new()

			a.voxelSize = 999
			a._renderDistance = 12345

			-- Mutating one config must not bleed into another.
			expect(b.voxelSize).toBe(100)
			expect(b._renderDistance).toBe(600)
		end)
	end)
end)
