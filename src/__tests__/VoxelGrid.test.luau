local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages, DevPackages = ReplicatedStorage:WaitForChild("Packages"), ReplicatedStorage:WaitForChild("DevPackages")

local JestGlobals = require(DevPackages:WaitForChild("JestGlobals"))

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local beforeEach = JestGlobals.beforeEach
local afterEach = JestGlobals.afterEach

local CullThrottlePackage = Packages:WaitForChild("CullThrottle")
local CullThrottle = require(CullThrottlePackage)

local TestHelpers = require(script.Parent.TestHelpers)
local createMockPart = TestHelpers.createMockPart
local stubObjectData = TestHelpers.stubObjectData
local straddlingFrustumPlanes = TestHelpers.straddlingFrustumPlanes

describe("VoxelGrid", function()
	local cullThrottle

	beforeEach(function()
		cullThrottle = CullThrottle.new()
	end)

	afterEach(function()
		if cullThrottle then
			cullThrottle:Destroy()
		end
		cullThrottle = nil
	end)

	describe("Voxel operations", function()
		it("should insert object to voxel correctly", function()
			local voxelKey = Vector3.new(1, 1, 1)
			local part = createMockPart()
			local objectData = stubObjectData(part)

			cullThrottle._grid:insertToVoxel(voxelKey, objectData)

			expect(cullThrottle._grid._voxels[voxelKey]).toBeDefined()
			expect(table.find(cullThrottle._grid._voxels[voxelKey], objectData)).toBeDefined()

			part:Destroy()
		end)

		it("should remove object from voxel correctly", function()
			local voxelKey = Vector3.new(1, 1, 1)
			local part = createMockPart()
			local objectData = stubObjectData(part)

			cullThrottle._grid:insertToVoxel(voxelKey, objectData)
			cullThrottle._grid:removeFromVoxel(voxelKey, objectData)

			if cullThrottle._grid._voxels[voxelKey] then
				expect(table.find(cullThrottle._grid._voxels[voxelKey], objectData)).toBeNil()
			else
				expect(cullThrottle._grid._voxels[voxelKey]).toBeNil()
			end

			part:Destroy()
		end)

		it("should clean up empty voxels", function()
			local voxelKey = Vector3.new(1, 1, 1)
			local part = createMockPart()
			local objectData = stubObjectData(part)

			cullThrottle._grid:insertToVoxel(voxelKey, objectData)
			cullThrottle._grid:removeFromVoxel(voxelKey, objectData)

			expect(cullThrottle._grid._voxels[voxelKey]).toBeNil()

			part:Destroy()
		end)

		it("should clear cached voxel visibility when a voxel empties", function()
			local voxelKey = Vector3.new(1, 1, 1)
			local part = createMockPart()
			local objectData = stubObjectData(part)

			cullThrottle._grid:insertToVoxel(voxelKey, objectData)
			-- Simulate the search loop having proven this voxel visible.
			cullThrottle._visibilityCache._voxelProofs[voxelKey] = Vector3.new(5, -1, 1)

			cullThrottle._grid:removeFromVoxel(voxelKey, objectData)

			-- The voxel is gone, so its cached proof must not linger. The search
			-- loops only overwrite proofs for voxels they re-test, so an emptied
			-- voxel's entry would otherwise leak forever.
			expect(cullThrottle._visibilityCache._voxelProofs[voxelKey]).toBeNil()

			part:Destroy()
		end)

		it("should keep cached voxel visibility while the voxel still holds objects", function()
			local voxelKey = Vector3.new(1, 1, 1)
			local part1 = createMockPart()
			local part2 = createMockPart()
			local objectData1 = stubObjectData(part1)
			local objectData2 = stubObjectData(part2)

			cullThrottle._grid:insertToVoxel(voxelKey, objectData1)
			cullThrottle._grid:insertToVoxel(voxelKey, objectData2)
			cullThrottle._visibilityCache._voxelProofs[voxelKey] = Vector3.new(5, -1, 1)

			-- Removing one of two objects leaves the voxel occupied, so its cached
			-- visibility proof is still valid and must be preserved.
			cullThrottle._grid:removeFromVoxel(voxelKey, objectData1)

			expect(cullThrottle._grid._voxels[voxelKey]).toBeDefined()
			expect(cullThrottle._visibilityCache._voxelProofs[voxelKey]).toBe(Vector3.new(5, -1, 1))

			part1:Destroy()
			part2:Destroy()
		end)

		it("should add a new voxel to the coarse grid", function()
			local voxelKey = Vector3.new(1, 1, 1)
			local part = createMockPart()

			cullThrottle._grid:insertToVoxel(voxelKey, stubObjectData(part))

			-- The occupied voxel is discoverable through the coarse grid query.
			local count = cullThrottle._search:seedSearchVolumes(straddlingFrustumPlanes, 0, 0, 0, 4, 4, 4)
			expect(count).toBe(1)
			expect(cullThrottle._search._searchVoxelKeys[1]).toBe(voxelKey)

			part:Destroy()
		end)

		it("should drop a voxel from the coarse grid when it empties", function()
			local voxelKey = Vector3.new(1, 1, 1)
			local part = createMockPart()
			local objectData = stubObjectData(part)

			cullThrottle._grid:insertToVoxel(voxelKey, objectData)
			cullThrottle._grid:removeFromVoxel(voxelKey, objectData)

			-- With no objects left, the grid must not report a ghost voxel.
			local count = cullThrottle._search:seedSearchVolumes(straddlingFrustumPlanes, 0, 0, 0, 4, 4, 4)
			expect(count).toBe(0)

			part:Destroy()
		end)

		it("should keep co-located voxels in the coarse grid when one empties", function()
			-- These two distinct voxels share one coarse bucket (COARSE_VOXEL_SIZE is 4).
			local voxelKeyA = Vector3.new(0, 0, 0)
			local voxelKeyB = Vector3.new(1, 0, 0)
			local partA = createMockPart()
			local partB = createMockPart()
			local objectDataA = stubObjectData(partA)

			cullThrottle._grid:insertToVoxel(voxelKeyA, objectDataA)
			cullThrottle._grid:insertToVoxel(voxelKeyB, stubObjectData(partB))

			-- Emptying one voxel must not evict the other from the shared bucket.
			cullThrottle._grid:removeFromVoxel(voxelKeyA, objectDataA)

			local count = cullThrottle._search:seedSearchVolumes(straddlingFrustumPlanes, 0, 0, 0, 4, 4, 4)
			expect(count).toBe(1)
			expect(cullThrottle._search._searchVoxelKeys[1]).toBe(voxelKeyB)

			partA:Destroy()
			partB:Destroy()
		end)

		it("should filter out edge-bucket voxels that fall outside the queried box", function()
			-- Both voxels share coarse bucket (0,0,0) but only one is inside the box.
			local insideKey = Vector3.new(1, 1, 1)
			local outsideKey = Vector3.new(3, 1, 1)
			local insidePart = createMockPart()
			local outsidePart = createMockPart()

			cullThrottle._grid:insertToVoxel(insideKey, stubObjectData(insidePart))
			cullThrottle._grid:insertToVoxel(outsideKey, stubObjectData(outsidePart))

			-- The box stops at x = 2, so the bucket is only partially covered and its
			-- keys must be filtered down to the box bounds.
			local count = cullThrottle._search:seedSearchVolumes(straddlingFrustumPlanes, 0, 0, 0, 2, 4, 4)
			expect(count).toBe(1)
			expect(cullThrottle._search._searchVoxelKeys[1]).toBe(insideKey)

			insidePart:Destroy()
			outsidePart:Destroy()
		end)

		it("should reuse the desiredVoxelKeys table in place across updates", function()
			cullThrottle:SetVoxelSize(100)

			local part = createMockPart(Vector3.new(0, 0, 0))
			cullThrottle:AddObject(part)
			local objectData = cullThrottle._lifecycle._objects[part]
			local voxelSize = cullThrottle._config.voxelSize

			-- Capture the table that already backs the object, then recompute for a
			-- moved object. The table must be reused (same identity), not realloc'd.
			local sharedTable = objectData.desiredVoxelKeys
			objectData.cframe = CFrame.new(5000, 0, 0)
			cullThrottle._grid:updateDesiredVoxelKeys(part, objectData)

			expect(objectData.desiredVoxelKeys).toBe(sharedTable)

			-- The diff was rebuilt from scratch, adding the new voxel and dropping the
			-- old one with no stale entries from before the clear.
			local newKey = objectData.cframe.Position // voxelSize
			expect(objectData.desiredVoxelKeys[newKey]).toBe(true)
			expect(objectData.desiredVoxelKeys[Vector3.new(0, 0, 0)]).toBe(false)

			part:Destroy()
		end)
	end)
end)
