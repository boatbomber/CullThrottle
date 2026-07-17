local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages, DevPackages = ReplicatedStorage:WaitForChild("Packages"), ReplicatedStorage:WaitForChild("DevPackages")

local JestGlobals = require(DevPackages:WaitForChild("JestGlobals"))

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local CullThrottlePackage = Packages:WaitForChild("CullThrottle")
local VisibilityCache = require(CullThrottlePackage:WaitForChild("VisibilityCache"))
local Frustum = require(CullThrottlePackage:WaitForChild("Frustum"))
local types = require(CullThrottlePackage:WaitForChild("types"))

local TestHelpers = require(script.Parent.TestHelpers)
local visibleVoxelProof = TestHelpers.visibleVoxelProof
local culledVoxelProof = TestHelpers.culledVoxelProof
local hiddenOcclusionProof = TestHelpers.hiddenOcclusionProof
local clearOcclusionProof = TestHelpers.clearOcclusionProof

--[[
	Builds a fully inside bucket verdict with generous expiries, in the shape
	the search caches.
]]
local function insideBucketVerdict(): types.BucketVerdict
	return {
		state = Frustum.BUCKET_INSIDE,
		armFactor = 1,
		sideExpiry = 100,
		farExpiry = math.huge,
	}
end

describe("VisibilityCache", function()
	it("gives each instance its own independent stores", function()
		-- Several CullThrottle instances can coexist, so a record cached by one
		-- must never leak into another's visibility decisions, in any of the
		-- four stores.
		local a = VisibilityCache.new()
		local b = VisibilityCache.new()

		a._voxelProofs[Vector3.new(1, 2, 3)] = visibleVoxelProof(5, 1)
		a._bucketVerdicts[Vector3.new(0, 0, 0)] = insideBucketVerdict()
		a._bucketOcclusionProofs[Vector3.new(0, 0, 0)] = hiddenOcclusionProof(4, 1)
		a._voxelOcclusionProofs[Vector3.new(1, 2, 3)] = clearOcclusionProof(4, 1)

		expect(next(b._voxelProofs)).toBeNil()
		expect(next(b._bucketVerdicts)).toBeNil()
		expect(next(b._bucketOcclusionProofs)).toBeNil()
		expect(next(b._voxelOcclusionProofs)).toBeNil()
	end)

	it("drops every proof and verdict on clear", function()
		local cache = VisibilityCache.new()
		cache._voxelProofs[Vector3.new(1, 2, 3)] = visibleVoxelProof(5, 1)
		cache._voxelProofs[Vector3.new(4, 5, 6)] = culledVoxelProof(2, 3)
		cache._bucketVerdicts[Vector3.new(0, 0, 0)] = insideBucketVerdict()
		cache._bucketOcclusionProofs[Vector3.new(0, 0, 0)] = hiddenOcclusionProof(4, 1)
		cache._voxelOcclusionProofs[Vector3.new(1, 2, 3)] = clearOcclusionProof(4, 1)

		cache:clear()

		-- The flush that calls this re-anchors the motion odometer at zero, so
		-- any record surviving here would compare its old expiry against the
		-- restarted readings and validate long after its real motion bound
		-- passed. The occlusion proofs are the easiest to miss, since they live
		-- in their own two tables apart from the frustum records.
		expect(next(cache._voxelProofs)).toBeNil()
		expect(next(cache._bucketVerdicts)).toBeNil()
		expect(next(cache._bucketOcclusionProofs)).toBeNil()
		expect(next(cache._voxelOcclusionProofs)).toBeNil()
	end)

	it("drops only the occlusion proofs on clearOcclusionProofs", function()
		local cache = VisibilityCache.new()
		local voxelKey = Vector3.new(1, 2, 3)
		local bucketKey = Vector3.new(0, 0, 0)
		cache._voxelProofs[voxelKey] = visibleVoxelProof(5, 1)
		cache._bucketVerdicts[bucketKey] = insideBucketVerdict()
		cache._bucketOcclusionProofs[bucketKey] = hiddenOcclusionProof(4, 1)
		cache._voxelOcclusionProofs[voxelKey] = clearOcclusionProof(4, 1)

		cache:clearOcclusionProofs()

		-- A wrapped occluder generation only poisons the occlusion records, so
		-- both of their tables must empty while the frustum proof and the
		-- bucket verdict ride through untouched.
		expect(next(cache._bucketOcclusionProofs)).toBeNil()
		expect(next(cache._voxelOcclusionProofs)).toBeNil()
		expect(cache._voxelProofs[voxelKey]).toBe(visibleVoxelProof(5, 1))
		expect(cache._bucketVerdicts[bucketKey]).toBeDefined()
	end)
end)
