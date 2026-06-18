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
local Frustum = require(CullThrottlePackage:WaitForChild("Frustum"))
local Utilities = CullThrottlePackage:WaitForChild("Utilities")
local CameraCache = require(Utilities:WaitForChild("CameraCache"))

local TestHelpers = require(script.Parent.TestHelpers)
local createMockPart = TestHelpers.createMockPart
local stubObjectData = TestHelpers.stubObjectData
local visibleVoxelProof = TestHelpers.visibleVoxelProof
local straddlingFrustumPlanes = TestHelpers.straddlingFrustumPlanes
local roomyFrustumPlanes = TestHelpers.roomyFrustumPlanes

--[[
	Sweeps every voxel in the oriented box's world AABB and asserts the fill
	left empty each candidate whose center sits provably outside the box,
	meaning farther past one of the box's face planes than the face extent plus
	the half-voxel-diagonal inflation the fill may legitimately keep. Returns
	how many such clearly outside candidates it checked, so callers can require
	the sweep exercised real rejections.
]]
local function expectNoFillBeyondReach(objectData, cframe: CFrame, size: Vector3, voxelSize: number): number
	local halfSize = size / 2
	local minCorner, maxCorner
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				local corner = cframe * Vector3.new(sx * halfSize.X, sy * halfSize.Y, sz * halfSize.Z)
				minCorner = if minCorner then minCorner:Min(corner) else corner
				maxCorner = if maxCorner then maxCorner:Max(corner) else corner
			end
		end
	end
	local minKey = minCorner // voxelSize
	local maxKey = maxCorner // voxelSize
	local axisInflation = (voxelSize / 2) * math.sqrt(3)

	local clearlyOutsideCount = 0
	for x = minKey.X, maxKey.X do
		for y = minKey.Y, maxKey.Y do
			for z = minKey.Z, maxKey.Z do
				local center = (Vector3.new(x, y, z) + Vector3.new(0.5, 0.5, 0.5)) * voxelSize
				local localPoint = cframe:PointToObjectSpace(center)
				if
					math.abs(localPoint.X) > halfSize.X + axisInflation
					or math.abs(localPoint.Y) > halfSize.Y + axisInflation
					or math.abs(localPoint.Z) > halfSize.Z + axisInflation
				then
					clearlyOutsideCount += 1
					expect(objectData.voxelKeys[Vector3.new(x, y, z)]).toBeUndefined()
				end
			end
		end
	end
	return clearlyOutsideCount
end

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

		it("should remove the requested object and keep the others in the voxel", function()
			local voxelKey = Vector3.new(1, 1, 1)
			local partA = createMockPart()
			local partB = createMockPart()
			local partC = createMockPart()
			local dataA = stubObjectData(partA)
			local dataB = stubObjectData(partB)
			local dataC = stubObjectData(partC)

			cullThrottle._grid:insertToVoxel(voxelKey, dataA)
			cullThrottle._grid:insertToVoxel(voxelKey, dataB)
			cullThrottle._grid:insertToVoxel(voxelKey, dataC)

			-- Removing the middle entry swap-removes, so exactly the other two
			-- must survive. Evicting the wrong object would pass a length check.
			cullThrottle._grid:removeFromVoxel(voxelKey, dataB)

			local voxel = cullThrottle._grid._voxels[voxelKey]
			expect(#voxel).toBe(2)
			expect(table.find(voxel, dataA)).toBeDefined()
			expect(table.find(voxel, dataC)).toBeDefined()
			expect(table.find(voxel, dataB)).toBeNil()

			-- Removing the entry that now sits last takes the tail fast path.
			cullThrottle._grid:removeFromVoxel(voxelKey, dataC)
			expect(#voxel).toBe(1)
			expect(voxel[1]).toBe(dataA)

			partA:Destroy()
			partB:Destroy()
			partC:Destroy()
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
			cullThrottle._visibilityCache._voxelProofs[voxelKey] = visibleVoxelProof(5, 1)

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

			local proof = visibleVoxelProof(5, 1)
			cullThrottle._grid:insertToVoxel(voxelKey, objectData1)
			cullThrottle._grid:insertToVoxel(voxelKey, objectData2)
			cullThrottle._visibilityCache._voxelProofs[voxelKey] = proof

			-- Removing one of two objects leaves the voxel occupied, so its cached
			-- visibility proof is still valid and must be preserved.
			cullThrottle._grid:removeFromVoxel(voxelKey, objectData1)

			expect(cullThrottle._grid._voxels[voxelKey]).toBeDefined()
			expect(cullThrottle._visibilityCache._voxelProofs[voxelKey]).toBe(proof)

			part1:Destroy()
			part2:Destroy()
		end)

		it("should clear a cached bucket verdict when its coarse bucket empties", function()
			local voxelKey = Vector3.new(1, 1, 1)
			local coarseKey = Vector3.new(0, 0, 0)
			local part = createMockPart()
			local objectData = stubObjectData(part)

			cullThrottle._grid:insertToVoxel(voxelKey, objectData)
			-- Simulate the seed having cached a verdict for this bucket.
			cullThrottle._visibilityCache._bucketVerdicts[coarseKey] =
				{ state = Frustum.BUCKET_CULLED, armFactor = 1, sideExpiry = 1, farExpiry = 1 }

			cullThrottle._grid:removeFromVoxel(voxelKey, objectData)

			-- The bucket is gone, so a lingering verdict would leak forever
			-- (the seed only touches buckets that still hold voxels).
			expect(cullThrottle._visibilityCache._bucketVerdicts[coarseKey]).toBeNil()

			part:Destroy()
		end)

		it("should keep a cached bucket verdict while the bucket still holds voxels", function()
			local coarseKey = Vector3.new(0, 0, 0)
			local partA = createMockPart()
			local partB = createMockPart()
			local dataA = stubObjectData(partA)

			cullThrottle._grid:insertToVoxel(Vector3.new(0, 0, 0), dataA)
			cullThrottle._grid:insertToVoxel(Vector3.new(1, 0, 0), stubObjectData(partB))
			local verdict = { state = Frustum.BUCKET_CULLED, armFactor = 1, sideExpiry = 1, farExpiry = 1 }
			cullThrottle._visibilityCache._bucketVerdicts[coarseKey] = verdict

			-- Emptying one voxel leaves the bucket occupied, and the verdict
			-- describes the bucket's box, so it stays valid.
			cullThrottle._grid:removeFromVoxel(Vector3.new(0, 0, 0), dataA)

			expect(cullThrottle._visibilityCache._bucketVerdicts[coarseKey]).toBe(verdict)

			partA:Destroy()
			partB:Destroy()
		end)

		it("should add a new voxel to the coarse grid", function()
			local voxelKey = Vector3.new(1, 1, 1)
			local part = createMockPart()

			cullThrottle._grid:insertToVoxel(voxelKey, stubObjectData(part))

			-- The coarse index has no query surface of its own, so this test and
			-- the bucket tests around it observe it through the search's seed
			-- scan, the index's one real consumer.
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

		it("should seed occupied voxels at negative coordinates", function()
			-- Bucket keys floor-divide voxel coordinates, so both voxels here land
			-- in bucket (-1, 0, -1) rather than wrapping toward bucket zero, and
			-- the scan range must reach them when the query box crosses the origin.
			local part = createMockPart()
			local keyA = Vector3.new(-1, 1, -1)
			local keyB = Vector3.new(-4, 2, -3)
			cullThrottle._grid:insertToVoxel(keyA, stubObjectData(part))
			cullThrottle._grid:insertToVoxel(keyB, stubObjectData(part))

			local search = cullThrottle._search
			local count = search:seedSearchVolumes(roomyFrustumPlanes, -8, 0, -8, 8, 8, 8)

			expect(count).toBe(2)
			for _, key in { keyA, keyB } do
				local found = false
				for i = 1, count do
					if search._searchVoxelKeys[i] == key then
						found = true
						break
					end
				end
				expect(found).toBe(true)
			end

			part:Destroy()
		end)

		it("should grow the coarse bounds when an insert lands outside them", function()
			-- The first insert anchors the occupied bounds around its own bucket.
			-- A later insert in a far bucket must grow them, or the seed scan's
			-- clamp would silently cut the new bucket out of every search.
			local partA = createMockPart()
			local partB = createMockPart()
			cullThrottle._grid:insertToVoxel(Vector3.new(1, 1, 1), stubObjectData(partA))
			cullThrottle._grid:insertToVoxel(Vector3.new(1, 41, 1), stubObjectData(partB))

			-- The query box covers only the far bucket, which sits fully inside
			-- the roomy frustum, so its voxel arrives through the bucket verdict's
			-- bulk append.
			local search = cullThrottle._search
			search:seedSearchVolumes(roomyFrustumPlanes, 0, 40, 0, 4, 44, 4)

			expect(search._visibleVoxelCount).toBe(1)
			expect(search._pendingVoxelKeys[1]).toBe(Vector3.new(1, 41, 1))

			partA:Destroy()
			partB:Destroy()
		end)

		it("should re-anchor the coarse bounds at the first insert after the grid empties", function()
			-- clearAll empties the grid for a voxel size change and leaves the old
			-- bounds behind with the dirty flag down, so the first insert
			-- afterwards must re-anchor the bounds at its own bucket. Growing the
			-- stale box instead would leave the clamp able to cut the new bucket
			-- out of the scan.
			local partA = createMockPart()
			local partB = createMockPart()
			cullThrottle._grid:insertToVoxel(Vector3.new(1, 1, 1), stubObjectData(partA))
			cullThrottle._grid:clearAll()
			expect(cullThrottle._grid._coarseBucketCount).toBe(0)

			cullThrottle._grid:insertToVoxel(Vector3.new(1, 41, 1), stubObjectData(partB))

			-- The bounds hug the lone occupied bucket on both sides, which proves
			-- a re-anchor rather than a union with the stale box.
			expect(cullThrottle._grid._coarseMinY).toBe(10)
			expect(cullThrottle._grid._coarseMaxY).toBe(10)

			local search = cullThrottle._search
			search:seedSearchVolumes(roomyFrustumPlanes, 0, 40, 0, 4, 44, 4)

			expect(search._visibleVoxelCount).toBe(1)
			expect(search._pendingVoxelKeys[1]).toBe(Vector3.new(1, 41, 1))

			partA:Destroy()
			partB:Destroy()
		end)

		it("should stage a clean enter and leave diff when the object moves", function()
			cullThrottle:SetVoxelSize(100)

			local part = createMockPart(Vector3.new(0, 0, 0))
			cullThrottle:AddObject(part)
			local objectData = cullThrottle._lifecycle._objects[part]
			local voxelSize = cullThrottle._config.voxelSize

			objectData.cframe = CFrame.new(5000, 0, 0)
			cullThrottle._grid:updateDesiredVoxelKeys(part, objectData)

			-- The diff was rebuilt from scratch, adding the new voxel and dropping the
			-- old one with no stale entries from before the recompute.
			local newKey = objectData.cframe.Position // voxelSize
			expect(objectData.desiredVoxelKeys[newKey]).toBe(true)
			expect(objectData.desiredVoxelKeys[Vector3.new(0, 0, 0)]).toBe(false)

			part:Destroy()
		end)

		it("drops kept voxels from the diff and never re-inserts the object into them", function()
			-- This part spans voxels -1 through 2 on the x axis. Shifting it one
			-- voxel right keeps voxels 0 through 2, so the diff must hold only
			-- the entered voxel and the left one. A kept voxel surviving in the
			-- diff as an enter would insert a duplicate entry, and a later
			-- removal would leave a ghost copy behind.
			local part = createMockPart(Vector3.new(100, 50, 50), Vector3.new(250, 20, 20))
			cullThrottle:AddObject(part)
			local objectData = cullThrottle._lifecycle._objects[part]

			objectData.cframe = CFrame.new(200, 50, 50)
			local diff = cullThrottle._grid:updateDesiredVoxelKeys(part, objectData)

			expect(diff[Vector3.new(3, 0, 0)]).toBe(true)
			expect(diff[Vector3.new(-1, 0, 0)]).toBe(false)
			expect(diff[Vector3.new(0, 0, 0)]).toBeUndefined()
			expect(diff[Vector3.new(1, 0, 0)]).toBeUndefined()
			expect(diff[Vector3.new(2, 0, 0)]).toBeUndefined()

			cullThrottle._grid:updateObjectVoxels(1, os.clock())

			-- Each overlap voxel holds the object exactly once, the left voxel
			-- emptied, and the entered one is occupied.
			for _, key in { Vector3.new(0, 0, 0), Vector3.new(1, 0, 0), Vector3.new(2, 0, 0), Vector3.new(3, 0, 0) } do
				local voxel = cullThrottle._grid._voxels[key]
				expect(voxel).toBeDefined()
				local occurrences = 0
				for _, entry in voxel do
					if entry == objectData then
						occurrences += 1
					end
				end
				expect(occurrences).toBe(1)
			end
			expect(cullThrottle._grid._voxels[Vector3.new(-1, 0, 0)]).toBeNil()

			part:Destroy()
		end)
	end)

	describe("updateObjectVoxels", function()
		it("applies queued moves closest to the camera first", function()
			local camPos = CameraCache.Position
			local nearPart = createMockPart(camPos + Vector3.new(150, 300, 0))
			local farPart = createMockPart(camPos + Vector3.new(5000, 300, 0))
			cullThrottle:AddObject(nearPart)
			cullThrottle:AddObject(farPart)
			local nearData = cullThrottle._lifecycle._objects[nearPart]
			local farData = cullThrottle._lifecycle._objects[farPart]

			-- The far move is staged first, so a first-in-first-out queue would
			-- apply it first. The priority queue must apply the near one first.
			farData.cframe = CFrame.new(camPos + Vector3.new(5000, 0, 0))
			cullThrottle._grid:updateDesiredVoxelKeys(farPart, farData)
			nearData.cframe = CFrame.new(camPos + Vector3.new(150, 0, 0))
			cullThrottle._grid:updateDesiredVoxelKeys(nearPart, nearData)

			local insertOrder = {}
			local realInsert = cullThrottle._grid.insertToVoxel
			cullThrottle._grid.insertToVoxel = function(grid, voxelKey, objectData)
				table.insert(insertOrder, objectData.object)
				return realInsert(grid, voxelKey, objectData)
			end

			cullThrottle._grid:updateObjectVoxels(1, os.clock())
			cullThrottle._grid.insertToVoxel = nil

			expect(insertOrder[1]).toBe(nearPart)
			expect(insertOrder[2]).toBe(farPart)

			nearPart:Destroy()
			farPart:Destroy()
		end)

		it("applies only the latest staged move when a recompute supersedes a queued one", function()
			local part = createMockPart(Vector3.new(50, 50, 50))
			cullThrottle:AddObject(part)
			local objectData = cullThrottle._lifecycle._objects[part]

			-- The first move stages an entry into voxel (4, 0, 0). Before it
			-- applies, a second recompute rebuilds the diff in place for voxel
			-- (8, 0, 0), superseding the first move entirely.
			objectData.cframe = CFrame.new(450, 50, 50)
			cullThrottle._grid:updateDesiredVoxelKeys(part, objectData)
			objectData.cframe = CFrame.new(850, 50, 50)
			cullThrottle._grid:updateDesiredVoxelKeys(part, objectData)

			cullThrottle._grid:updateObjectVoxels(1, os.clock())

			-- Occupancy matches the latest move only, and the superseded
			-- destination was never touched.
			expect(objectData.voxelKeys[Vector3.new(8, 0, 0)]).toBe(true)
			expect(objectData.voxelKeys[Vector3.new(4, 0, 0)]).toBeUndefined()
			expect(objectData.voxelKeys[Vector3.new(0, 0, 0)]).toBeUndefined()
			expect(cullThrottle._grid._voxels[Vector3.new(8, 0, 0)]).toBeDefined()
			expect(cullThrottle._grid._voxels[Vector3.new(4, 0, 0)]).toBeNil()
			expect(cullThrottle._grid._voxels[Vector3.new(0, 0, 0)]).toBeNil()

			part:Destroy()
		end)

		it("skips a queued object whose superseding recompute emptied the diff", function()
			local part = createMockPart(Vector3.new(50, 50, 50))
			cullThrottle:AddObject(part)
			local objectData = cullThrottle._lifecycle._objects[part]

			-- Stage a move out, then a move straight back before the apply. The
			-- second recompute rebuilds the diff empty while the object still
			-- sits in the update queue.
			objectData.cframe = CFrame.new(450, 50, 50)
			cullThrottle._grid:updateDesiredVoxelKeys(part, objectData)
			objectData.cframe = CFrame.new(50, 50, 50)
			cullThrottle._grid:updateDesiredVoxelKeys(part, objectData)
			expect((next(objectData.desiredVoxelKeys))).toBeNil()

			local mutations = 0
			local realInsert = cullThrottle._grid.insertToVoxel
			local realRemove = cullThrottle._grid.removeFromVoxel
			cullThrottle._grid.insertToVoxel = function(...)
				mutations += 1
				return realInsert(...)
			end
			cullThrottle._grid.removeFromVoxel = function(...)
				mutations += 1
				return realRemove(...)
			end

			cullThrottle._grid:updateObjectVoxels(1, os.clock())
			cullThrottle._grid.insertToVoxel = nil
			cullThrottle._grid.removeFromVoxel = nil

			-- The dequeue saw an empty diff and moved on without touching any
			-- voxel, leaving the original occupancy intact.
			expect(mutations).toBe(0)
			expect(objectData.voxelKeys[Vector3.new(0, 0, 0)]).toBe(true)
			expect(cullThrottle._grid._voxels[Vector3.new(0, 0, 0)]).toBeDefined()

			part:Destroy()
		end)

		it("stops mid-queue when the budget runs out and finishes the rest next pass", function()
			local camPos = CameraCache.Position
			local nearPart = createMockPart(camPos + Vector3.new(150, 300, 0))
			local farPart = createMockPart(camPos + Vector3.new(5000, 300, 0))
			cullThrottle:AddObject(nearPart)
			cullThrottle:AddObject(farPart)
			local nearData = cullThrottle._lifecycle._objects[nearPart]
			local farData = cullThrottle._lifecycle._objects[farPart]
			local voxelSize = cullThrottle._config.voxelSize

			nearData.cframe = CFrame.new(camPos + Vector3.new(150, 0, 0))
			cullThrottle._grid:updateDesiredVoxelKeys(nearPart, nearData)
			farData.cframe = CFrame.new(camPos + Vector3.new(5000, 0, 0))
			cullThrottle._grid:updateDesiredVoxelKeys(farPart, farData)

			-- The first apply burns well past the budget, so the pass must stop
			-- there and leave the farther move queued rather than applied or
			-- dropped. The budget is roomy enough that the pass reliably gets
			-- through the first apply before the clock check trips.
			local realInsert = cullThrottle._grid.insertToVoxel
			cullThrottle._grid.insertToVoxel = function(...)
				local spinUntil = os.clock() + 0.02
				local now = os.clock()
				while now < spinUntil do
					now = os.clock()
				end
				return realInsert(...)
			end
			cullThrottle._grid:updateObjectVoxels(0.01, os.clock())
			cullThrottle._grid.insertToVoxel = nil

			expect((next(nearData.desiredVoxelKeys))).toBeNil()
			expect(nearData.voxelKeys[(camPos + Vector3.new(150, 0, 0)) // voxelSize]).toBe(true)
			expect((next(farData.desiredVoxelKeys))).never.toBeNil()
			expect(farData.voxelKeys[(camPos + Vector3.new(5000, 0, 0)) // voxelSize]).toBeUndefined()

			-- The next pass picks the leftover up.
			cullThrottle._grid:updateObjectVoxels(1, os.clock())
			expect((next(farData.desiredVoxelKeys))).toBeNil()
			expect(farData.voxelKeys[(camPos + Vector3.new(5000, 0, 0)) // voxelSize]).toBe(true)

			nearPart:Destroy()
			farPart:Destroy()
		end)

		it("applies nothing on an exhausted budget and keeps the move queued for the next pass", function()
			local part = createMockPart(Vector3.new(50, 50, 50))
			cullThrottle:AddObject(part)
			local objectData = cullThrottle._lifecycle._objects[part]

			objectData.cframe = CFrame.new(450, 50, 50)
			cullThrottle._grid:updateDesiredVoxelKeys(part, objectData)

			-- A zero budget is already spent before the first dequeue, so the
			-- move must survive in the queue rather than being applied or lost.
			cullThrottle._grid:updateObjectVoxels(0, os.clock())

			expect(objectData.voxelKeys[Vector3.new(4, 0, 0)]).toBeUndefined()
			expect((next(objectData.desiredVoxelKeys))).never.toBeNil()

			-- The next pass with budget picks the leftover up.
			cullThrottle._grid:updateObjectVoxels(1, os.clock())

			expect(objectData.voxelKeys[Vector3.new(4, 0, 0)]).toBe(true)
			expect(objectData.voxelKeys[Vector3.new(0, 0, 0)]).toBeUndefined()

			part:Destroy()
		end)

		it("skips a queued move whose object was removed before the apply", function()
			local part = createMockPart(Vector3.new(50, 50, 50))
			cullThrottle:AddObject(part)
			local objectData = cullThrottle._lifecycle._objects[part]

			-- The move sits in the queue's incoming batch when the object is
			-- removed, and removal deliberately leaves batch entries behind for
			-- the apply pass to discard.
			objectData.cframe = CFrame.new(450, 50, 50)
			cullThrottle._grid:updateDesiredVoxelKeys(part, objectData)
			cullThrottle:RemoveObject(part)

			-- Removal purges only the queue proper, so the batch entry survives
			-- to be enqueued and then discarded at dequeue time.
			local batchItems = cullThrottle._grid._updateObjectVoxelsQueue._incomingBatch.items
			expect(table.find(batchItems, part)).never.toBeNil()

			expect(function()
				cullThrottle._grid:updateObjectVoxels(1, os.clock())
			end).never.toThrow()

			-- The stale entry must not resurrect the object into either voxel.
			expect(cullThrottle._grid._voxels[Vector3.new(4, 0, 0)]).toBeNil()
			expect(cullThrottle._grid._voxels[Vector3.new(0, 0, 0)]).toBeNil()

			part:Destroy()
		end)
	end)

	describe("Oriented box fill", function()
		it("fills only truly overlapped voxels under a compound rotation", function()
			-- This stages a long thin part under combined pitch, yaw, and roll.
			-- Its world AABB bulges far past the oriented box, so the fill must
			-- keep the voxels along the part's axis and reject the AABB's empty
			-- corners.
			local cframe = CFrame.new(550, 350, 450) * CFrame.Angles(math.rad(20), math.rad(45), math.rad(30))
			local size = Vector3.new(600, 40, 40)
			local part = createMockPart(nil, size)
			part.CFrame = cframe
			cullThrottle:AddObject(part)
			local objectData = cullThrottle._lifecycle._objects[part]
			local voxelSize = cullThrottle._config.voxelSize

			-- Every voxel containing a point on the part's center line must be
			-- occupied.
			local axis = cframe.XVector
			for _, t in { -250, -100, 0, 100, 250 } do
				local interiorKey = (cframe.Position + axis * t) // voxelSize
				expect(objectData.voxelKeys[interiorKey]).toBe(true)
			end

			-- Points just inside the box's long faces also sit in voxels that
			-- truly overlap the box, so the fill must keep them even though they
			-- ride far off the center line.
			local halfSize = size / 2
			for _, t in { -250, 0, 250 } do
				for _, lateral in
					{
						Vector3.new(0, halfSize.Y - 1, 0),
						Vector3.new(0, -(halfSize.Y - 1), 0),
						Vector3.new(0, 0, halfSize.Z - 1),
						Vector3.new(0, 0, -(halfSize.Z - 1)),
					}
				do
					local samplePoint = cframe * (Vector3.new(t, 0, 0) + lateral)
					expect(objectData.voxelKeys[samplePoint // voxelSize]).toBe(true)
				end
			end

			-- Sweeping the AABB proves the fill rejected every candidate sitting
			-- provably past the box's faces, and the count proves the sweep
			-- exercised real rejections.
			expect(expectNoFillBeyondReach(objectData, cframe, size, voxelSize)).toBeGreaterThan(0)

			part:Destroy()
		end)

		it("rejects whole rows whose constant coordinate is out of reach under a single-axis rotation", function()
			-- Rolling about world Z keeps two of the box's axes perpendicular to
			-- world Z, so their box-local coordinates never vary down a z-row and
			-- eligibility is decided for each row as a whole. The AABB's corners
			-- are full of such rows sitting entirely past the box's long faces,
			-- and losing the whole-row rejection would fill every one of them.
			local cframe = CFrame.new(1050, 1050, 1050) * CFrame.Angles(0, 0, math.rad(45))
			local size = Vector3.new(600, 40, 40)
			local part = createMockPart(nil, size)
			part.CFrame = cframe
			cullThrottle:AddObject(part)
			local objectData = cullThrottle._lifecycle._objects[part]
			local voxelSize = cullThrottle._config.voxelSize

			-- The diagonal center line stays occupied.
			local axis = cframe.XVector
			for _, t in { -250, -100, 0, 100, 250 } do
				local interiorKey = (cframe.Position + axis * t) // voxelSize
				expect(objectData.voxelKeys[interiorKey]).toBe(true)
			end

			expect(expectNoFillBeyondReach(objectData, cframe, size, voxelSize)).toBeGreaterThan(0)

			part:Destroy()
		end)

		it("clears every spanned voxel when the object shrinks below the multi-voxel threshold", function()
			-- This part spans three voxels along x. Shrinking it to a single-cell
			-- object must leave exactly the center voxel occupied, with no ghost
			-- copies lingering in the vacated cells.
			local part = createMockPart(Vector3.new(50, 50, 50), Vector3.new(250, 20, 20))
			cullThrottle:AddObject(part)
			local objectData = cullThrottle._lifecycle._objects[part]

			expect(objectData.voxelKeys[Vector3.new(-1, 0, 0)]).toBe(true)
			expect(objectData.voxelKeys[Vector3.new(1, 0, 0)]).toBe(true)

			-- Stage the shrunken dimensions the way the change connections record
			-- them, then run the recompute and the apply.
			objectData.halfBoundingBox = Vector3.new(2, 2, 2)
			objectData.radius = objectData.halfBoundingBox.Magnitude
			cullThrottle._grid:updateDesiredVoxelKeys(part, objectData)
			cullThrottle._grid:updateObjectVoxels(1, os.clock())

			expect(objectData.voxelKeys[Vector3.new(0, 0, 0)]).toBe(true)
			expect(objectData.voxelKeys[Vector3.new(-1, 0, 0)]).toBeUndefined()
			expect(objectData.voxelKeys[Vector3.new(1, 0, 0)]).toBeUndefined()
			expect(cullThrottle._grid._voxels[Vector3.new(-1, 0, 0)]).toBeNil()
			expect(cullThrottle._grid._voxels[Vector3.new(1, 0, 0)]).toBeNil()
			expect(table.find(cullThrottle._grid._voxels[Vector3.new(0, 0, 0)], objectData)).toBeDefined()

			part:Destroy()
		end)
	end)

	describe("Non-finite geometry", function()
		it("skips the voxel update for a NaN position instead of poisoning the queue priority", function()
			-- A part driven to a NaN position can't be used as a voxel key at all,
			-- and it would feed a NaN into the voxel-maintenance queue priority that
			-- silently corrupts the heap's dequeue order. The recompute must bail
			-- with an empty diff and leave the object in its current voxels.
			local part = createMockPart(Vector3.new(0, 0, 0))
			cullThrottle:AddObject(part)
			local objectData = cullThrottle._lifecycle._objects[part]
			expect(objectData.voxelKeys[Vector3.new(0, 0, 0)]).toBe(true)

			objectData.cframe = CFrame.new(0 / 0, 0 / 0, 0 / 0)
			local diff
			expect(function()
				diff = cullThrottle._grid:updateDesiredVoxelKeys(part, objectData)
			end).never.toThrow()

			-- An empty diff means the guard bailed before deriving any voxel key, so
			-- it staged no membership change and the object keeps its current cell.
			expect(next(diff)).toBeNil()
			expect(objectData.voxelKeys[Vector3.new(0, 0, 0)]).toBe(true)

			part:Destroy()
		end)

		it("skips the multi-voxel fill for an infinite position instead of hanging the frame", function()
			-- A multi-voxel object fills the voxels across its world AABB, and an
			-- infinite position makes that AABB's bounds infinite. The fill loop's
			-- `for x = min, max` would never advance past an infinite bound and would
			-- hang the frame, so the recompute must bail before reaching it.
			local part = createMockPart(Vector3.new(0, 0, 0), Vector3.new(400, 400, 400))
			cullThrottle:AddObject(part)
			local objectData = cullThrottle._lifecycle._objects[part]
			expect(objectData.radius > cullThrottle._config.multiVoxelRadiusThreshold).toBe(true)
			expect(objectData.voxelKeys[Vector3.new(0, 0, 0)]).toBe(true)

			objectData.cframe = CFrame.new(math.huge, 0, 0)
			local diff
			expect(function()
				diff = cullThrottle._grid:updateDesiredVoxelKeys(part, objectData)
			end).never.toThrow()

			-- The guard bailed before the fill, so the diff is empty and the object
			-- keeps the cells it already spanned.
			expect(next(diff)).toBeNil()
			expect(objectData.voxelKeys[Vector3.new(0, 0, 0)]).toBe(true)

			part:Destroy()
		end)
	end)
end)
