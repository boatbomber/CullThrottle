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
			expect(config.searchTimeBudget).toBeCloseTo(0.8 / 1000)
			expect(config.ingestTimeBudget).toBeCloseTo(1.2 / 1000)
			expect(config.updateTimeBudget).toBeCloseTo(0.4 / 1000)
			expect(config.bestRefreshRate).toBeCloseTo(1 / 60)
			expect(config.worstRefreshRate).toBeCloseTo(1 / 15)
			expect(config.computeVisibilityOnlyOnDemand).toBe(false)
			expect(config.strictlyEnforceWorstRefreshRate).toBe(false)
		end)

		it("derives the computed fields from the public defaults", function()
			-- The default render distance range is [150, 2000], so its midpoint is the
			-- live distance's starting baseline and dynamic adjustment is active.
			expect(config.minRenderDistance).toBe(150)
			expect(config.maxRenderDistance).toBe(2000)
			expect(config.renderDistanceMidpoint).toBe((150 + 2000) / 2)
			expect(config.renderDistance).toBe((150 + 2000) / 2)
			expect(config.dynamicRenderDistance).toBe(true)
			expect(config.renderDistanceStep).toBeCloseTo(0.03)
			expect(config.renderDistanceDirection).toBe(0)
			-- Drives multi-voxel registration (voxelSize * 1/4); never asserted elsewhere.
			expect(config.multiVoxelRadiusThreshold).toBeCloseTo(100 * (1 / 4))
			expect(config.refreshRateRange).toBeCloseTo(1 / 15 - 1 / 60)
			expect(config.refreshRateMidpoint).toBeCloseTo((1 / 60 + 1 / 15) / 2)
		end)

		it("returns independent instances", function()
			local a = Config.new()
			local b = Config.new()

			a.voxelSize = 999
			a.renderDistance = 12345

			-- Mutating one config must not bleed into another.
			expect(b.voxelSize).never.toBe(a.voxelSize)
			expect(b.renderDistance).never.toBe(a.renderDistance)
		end)
	end)
end)
