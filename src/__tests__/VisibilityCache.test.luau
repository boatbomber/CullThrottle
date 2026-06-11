local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages, DevPackages = ReplicatedStorage:WaitForChild("Packages"), ReplicatedStorage:WaitForChild("DevPackages")

local JestGlobals = require(DevPackages:WaitForChild("JestGlobals"))

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local CullThrottlePackage = Packages:WaitForChild("CullThrottle")
local VisibilityCache = require(CullThrottlePackage:WaitForChild("VisibilityCache"))
local Frustum = require(CullThrottlePackage:WaitForChild("Frustum"))

local TestHelpers = require(script.Parent.TestHelpers)
local visibleVoxelProof = TestHelpers.visibleVoxelProof

--[[
	Builds a bucket verdict in the shape the search caches, defaulting to a
	fully inside verdict with generous expiries.
]]
local function insideBucketVerdict(): any
	return {
		state = Frustum.BUCKET_INSIDE,
		armFactor = 1,
		sideExpiry = 100,
		farExpiry = math.huge,
	}
end

describe("VisibilityCache", function()
	it("gives each instance its own independent stores", function()
		-- Several CullThrottle instances can coexist, so a proof cached by one
		-- must never leak into another's visibility decisions.
		local a = VisibilityCache.new()
		local b = VisibilityCache.new()

		a._voxelProofs[Vector3.new(1, 2, 3)] = visibleVoxelProof(5, 1)
		a._bucketVerdicts[Vector3.new(0, 0, 0)] = insideBucketVerdict()

		expect(next(b._voxelProofs)).toBeNil()
		expect(next(b._bucketVerdicts)).toBeNil()
	end)

	it("drops every proof and verdict on clear", function()
		local cache = VisibilityCache.new()
		cache._voxelProofs[Vector3.new(1, 2, 3)] = visibleVoxelProof(5, 1)
		cache._voxelProofs[Vector3.new(4, 5, 6)] = visibleVoxelProof(2, 3)
		cache._bucketVerdicts[Vector3.new(0, 0, 0)] = insideBucketVerdict()

		cache:clear()

		expect(next(cache._voxelProofs)).toBeNil()
		expect(next(cache._bucketVerdicts)).toBeNil()
	end)
end)
