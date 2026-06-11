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
local culledVoxelProof = TestHelpers.culledVoxelProof
local popVolume = TestHelpers.popVolume
local drainVolumeStack = TestHelpers.drainVolumeStack
local patchFunction = TestHelpers.patchFunction
local straddlingFrustumPlanes = TestHelpers.straddlingFrustumPlanes
local roomyFrustumPlanes = TestHelpers.roomyFrustumPlanes

--[[
	Wraps Frustum.isBoxInFrustum with a counting shim (registered for the
	afterEach restore) and returns a getter for how many tests have run since.
]]
local function countBoxTests(): () -> number
	local boxTests = 0
	local realBox
	realBox = patchFunction(Frustum, "isBoxInFrustum", function(...)
		boxTests += 1
		return realBox(...)
	end)
	return function()
		return boxTests
	end
end

--[[
	Wraps Frustum.classifyBucket with a counting shim (registered for the
	afterEach restore) and returns a getter for how many classifications have
	run since.
]]
local function countClassifyCalls(): () -> number
	local calls = 0
	local realClassify
	realClassify = patchFunction(Frustum, "classifyBucket", function(...)
		calls += 1
		return realClassify(...)
	end)
	return function()
		return calls
	end
end

--[[
	Returns the eight corners of a voxel-space box.
]]
local function boxCorners(x0: number, y0: number, z0: number, x1: number, y1: number, z1: number): { Vector3 }
	return {
		Vector3.new(x0, y0, z0),
		Vector3.new(x1, y0, z0),
		Vector3.new(x0, y1, z0),
		Vector3.new(x1, y1, z0),
		Vector3.new(x0, y0, z1),
		Vector3.new(x1, y0, z1),
		Vector3.new(x0, y1, z1),
		Vector3.new(x1, y1, z1),
	}
end

--[[
	Returns the most camera motion that provably cannot bring the given
	voxel-space box back inside the frustum, which is how deep the box's
	nearest corner sits past the plane that rejects it most strongly. Any sound
	culled margin has to stay at or under this true clearance.
]]
local function maxSoundCulledMargin(
	frustumPlanes: { Vector3 },
	x0: number,
	y0: number,
	z0: number,
	x1: number,
	y1: number,
	z1: number
): number
	local corners = boxCorners(x0, y0, z0, x1, y1, z1)
	local best = 0
	for i = 1, #frustumPlanes, 2 do
		local planePos, planeNormal = frustumPlanes[i], frustumPlanes[i + 1]
		local minDist = math.huge
		for _, corner in corners do
			local dist = (corner - planePos):Dot(planeNormal)
			if dist < minDist then
				minDist = dist
			end
		end
		if minDist > best then
			best = minDist
		end
	end
	return best
end

--[[
	Returns the true clearance from the given fully-inside voxel-space box to
	the nearest frustum plane, which is how far a plane must sweep before it
	can touch the box. Any sound visible slack has to stay under this.
]]
local function trueInsideClearance(
	frustumPlanes: { Vector3 },
	x0: number,
	y0: number,
	z0: number,
	x1: number,
	y1: number,
	z1: number
): number
	local corners = boxCorners(x0, y0, z0, x1, y1, z1)
	local clearance = math.huge
	for i = 1, #frustumPlanes, 2 do
		local planePos, planeNormal = frustumPlanes[i], frustumPlanes[i + 1]
		local maxDist = -math.huge
		for _, corner in corners do
			local dist = (corner - planePos):Dot(planeNormal)
			if dist > maxDist then
				maxDist = dist
			end
		end
		local planeClearance = -maxDist
		if planeClearance < clearance then
			clearance = planeClearance
		end
	end
	return clearance
end

describe("VisibilitySearch", function()
	local cullThrottle
	local originalFieldOfView

	beforeEach(function()
		originalFieldOfView = workspace.CurrentCamera.FieldOfView
		cullThrottle = CullThrottle.new()
	end)

	afterEach(function()
		-- Frustum is a shared module table, so any counting shims patched onto
		-- it must be unwound before the next test.
		TestHelpers.restorePatches()
		if cullThrottle then
			cullThrottle:Destroy()
		end
		cullThrottle = nil

		-- Tests that reshape the live camera's projection restore it here so a
		-- failure can't leak the change. The restore fires the projection change
		-- signal deferred, so let it land before the next test reads the camera.
		local camera = workspace.CurrentCamera
		if camera.FieldOfView ~= originalFieldOfView then
			camera.FieldOfView = originalFieldOfView
			task.wait()
		end
	end)

	describe("Volume search", function()
		it("should fully drain the volume search stack after a search", function()
			-- Spread objects through the view at increasing depth so the search
			-- subdivides and pushes and pops volumes on the flat stack.
			local camera = workspace.CurrentCamera
			local parts = {}
			for i = 1, 5 do
				local part = createMockPart((camera.CFrame * CFrame.new(0, 0, -100 * i)).Position)
				cullThrottle:AddObject(part)
				table.insert(parts, part)
			end

			-- A generous budget lets the search run to completion rather than bail
			-- into the cached-visibility fallback (which leaves volumes on the stack).
			cullThrottle._config.searchTimeBudget = 1
			cullThrottle:_findVisibleObjects(os.clock())

			local search = cullThrottle._search
			expect(search._volumesToCheckSize).toBe(0)

			-- Draining alone isn't enough. The completed search must also have
			-- surfaced every part's voxel as visible.
			for _, part in parts do
				local voxelKey = next(cullThrottle._lifecycle._objects[part].voxelKeys)
				local found = false
				for i = 1, search._visibleVoxelCount do
					if search._pendingVoxelKeys[i] == voxelKey then
						found = true
						break
					end
				end
				expect(found).toBe(true)
			end

			for _, part in parts do
				part:Destroy()
			end
		end)

		it("should reuse cached visibility for volumes left when the search budget is exhausted", function()
			local part = createMockPart(Vector3.new(0, 0, 0))
			cullThrottle:AddObject(part)
			local objectData = cullThrottle._lifecycle._objects[part]
			local voxelKey = next(objectData.voxelKeys)

			local search = cullThrottle._search

			-- The voxel holds a visibility proof (even a stale one counts, since with
			-- the budget gone the fallback reuses whatever was last proven), so the
			-- fallback should re-mark it. The accumulators sit far past the proof's
			-- expiry to make it stale, so a rewrite that re-validates proofs before
			-- re-marking would fail here.
			cullThrottle._visibilityCache._voxelProofs[voxelKey] = visibleVoxelProof(5, 1)
			cullThrottle._motion._accumT = 50

			-- Leave a single-voxel volume on the stack, as if the search ran out of
			-- time before reaching it, then run the cached-visibility fallback. The
			-- volume points at its key's slice in the seeded search buffer, and the
			-- fallback accumulates into the unsorted pending buffer (the ingest sorts
			-- it afterward), so check there.
			search._searchVoxelKeys[1] = voxelKey
			search._volumesToCheckSize = 0
			search:pushVolume(
				voxelKey.X,
				voxelKey.Y,
				voxelKey.Z,
				voxelKey.X + 1,
				voxelKey.Y + 1,
				voxelKey.Z + 1,
				1,
				1,
				0b11111,
				math.huge
			)
			search:reuseCachedVisibilityForRemainingVolumes()

			local found = false
			for i = 1, search._visibleVoxelCount do
				if search._pendingVoxelKeys[i] == voxelKey then
					found = true
					break
				end
			end
			expect(found).toBe(true)
			local perfMetrics = cullThrottle._perfMetrics
			expect(perfMetrics._skippedSearch[perfMetrics._skippedFramesCursor]).toBe(1)

			part:Destroy()
		end)

		it("re-marks only proven-visible voxels in the fallback and counts every leftover key skipped", function()
			local search = cullThrottle._search
			local voxelProofs = cullThrottle._visibilityCache._voxelProofs
			local visibleKey = Vector3.new(1, 1, 1)
			local culledKey = Vector3.new(2, 2, 2)
			local coldKey = Vector3.new(3, 3, 3)
			search._searchVoxelKeys[1] = visibleKey
			search._searchVoxelKeys[2] = culledKey
			search._searchVoxelKeys[3] = coldKey
			voxelProofs[visibleKey] = visibleVoxelProof(5, 1)
			voxelProofs[culledKey] = culledVoxelProof(5, 1)

			-- Leave one leftover volume owning all three keys, as if the budget
			-- ran out before reaching it. Only the key whose last proof found it
			-- visible may be re-marked. Resurrecting the culled or never-proven
			-- ones would flash provably-invisible voxels into the frame. The
			-- skipped metric counts every key the budget left unverified, the
			-- re-marked one included.
			search._volumesToCheckSize = 0
			search:pushVolume(1, 1, 1, 4, 4, 4, 1, 3, 0b11111, math.huge)
			search._visibleVoxelCount = 0
			search:reuseCachedVisibilityForRemainingVolumes()

			expect(search._visibleVoxelCount).toBe(1)
			expect(search._pendingVoxelKeys[1]).toBe(visibleKey)
			local perfMetrics = cullThrottle._perfMetrics
			expect(perfMetrics._skippedSearch[perfMetrics._skippedFramesCursor]).toBe(3)
		end)

		it("surfaces proven-visible voxels from the volumes a run's exhausted budget never reaches", function()
			-- Six buckets ride the frustum's right side plane at increasing depth,
			-- so each classifies as straddling and pushes its own root volume
			-- holding one key with a valid visible proof. A zero budget exhausts
			-- after the first batch of volume pops, so the rest must flow through
			-- the cached-visibility fallback rather than dropping out of the frame.
			local search = cullThrottle._search
			local voxelProofs = cullThrottle._visibilityCache._voxelProofs
			local part = createMockPart()
			local keys = {
				Vector3.new(5, 5, 1),
				Vector3.new(5, 9, 1),
				Vector3.new(9, 13, 1),
				Vector3.new(13, 17, 1),
				Vector3.new(13, 21, 1),
				Vector3.new(17, 25, 1),
			}
			for _, key in keys do
				cullThrottle._grid:insertToVoxel(key, stubObjectData(part))
				voxelProofs[key] = visibleVoxelProof(math.huge, 0)
			end

			patchFunction(CameraCache, "getPlanesAndBounds", function()
				return roomyFrustumPlanes, Vector3.new(0, 0, 0), Vector3.new(19, 27, 3)
			end)

			cullThrottle._config.searchTimeBudget = 0
			search:run(os.clock())

			-- Every key surfaced exactly once, whether its volume was popped
			-- within the budget or swept up by the fallback afterward, and the
			-- fallback counted its leftover keys into the skipped metric.
			expect(search._visibleVoxelCount).toBe(6)
			for _, key in keys do
				local occurrences = 0
				for i = 1, search._visibleVoxelCount do
					if search._pendingVoxelKeys[i] == key then
						occurrences += 1
					end
				end
				expect(occurrences).toBe(1)
			end
			local perfMetrics = cullThrottle._perfMetrics
			expect(perfMetrics._skippedSearch[perfMetrics._skippedFramesCursor]).toBeGreaterThan(0)

			part:Destroy()
		end)

		it("stamps every voxel of a culled volume provably culled in one pass", function()
			local search = cullThrottle._search
			local voxelProofs = cullThrottle._visibilityCache._voxelProofs
			local keys = {
				Vector3.new(8, 0, 0),
				Vector3.new(9, 1, 1),
				Vector3.new(10, 2, 2),
				Vector3.new(11, 3, 3),
				Vector3.new(8, 1, 2),
				Vector3.new(9, 2, 3),
			}
			for i, key in keys do
				search._searchVoxelKeys[i] = key
			end
			-- The first key carries a visible proof that the staged motion has
			-- expired, so the cold walk bails into the box test and the bulk
			-- stamp must overwrite that stale visible expiry.
			voxelProofs[keys[1]] = visibleVoxelProof(5, 1)

			local getBoxTests = countBoxTests()
			search:searchVolume(10, 0, roomyFrustumPlanes, 8, 0, 0, 12, 4, 4, 1, 6, 0b11111, math.huge)

			-- The whole volume sits outside a side plane, so one box test settles
			-- it. Nothing is visible, no children are pushed, and every key now
			-- carries a culled proof so later frames and the budget fallback can
			-- never resurrect them.
			expect(getBoxTests()).toBe(1)
			expect(search._visibleVoxelCount).toBe(0)
			expect(search._volumesToCheckSize).toBe(0)
			for _, key in keys do
				local proof = voxelProofs[key]
				expect(proof).toBeDefined()
				expect(proof.X).toBe(-1)
				expect(proof.Y >= 10).toBe(true)
				-- The margin stored past the staged motion must stay under this
				-- cell's true clearance to the rejecting plane, or camera motion
				-- could bring the cell back into view while the cache still calls
				-- it provably culled.
				local bound =
					maxSoundCulledMargin(roomyFrustumPlanes, key.X, key.Y, key.Z, key.X + 1, key.Y + 1, key.Z + 1)
				expect(proof.Y - 10 < bound).toBe(true)
				expect(proof.Z > 0).toBe(true)
			end
		end)

		it("stamps every voxel of a fully-inside volume visible in one pass", function()
			local search = cullThrottle._search
			local voxelProofs = cullThrottle._visibilityCache._voxelProofs
			local keys = {
				Vector3.new(0, 40, 0),
				Vector3.new(1, 41, 1),
				Vector3.new(2, 42, 2),
				Vector3.new(3, 43, 3),
				Vector3.new(0, 42, 1),
				Vector3.new(3, 40, 2),
			}
			for i, key in keys do
				search._searchVoxelKeys[i] = key
			end

			local getBoxTests = countBoxTests()
			search:searchVolume(0, 0, roomyFrustumPlanes, 0, 40, 0, 4, 44, 4, 1, 6, 0b11111, math.huge)

			-- The cold walk bails, the one box test proves the volume fully
			-- inside, and the bulk path appends each key exactly once with a
			-- visible proof carrying no culled expiry.
			expect(getBoxTests()).toBe(1)
			expect(search._visibleVoxelCount).toBe(6)
			expect(search._volumesToCheckSize).toBe(0)
			for _, key in keys do
				local proof = voxelProofs[key]
				expect(proof).toBeDefined()
				expect(proof.X > 0).toBe(true)
				expect(proof.Y).toBe(-1)
				expect(proof.Z > 0).toBe(true)

				local occurrences = 0
				for i = 1, search._visibleVoxelCount do
					if search._pendingVoxelKeys[i] == key then
						occurrences += 1
					end
				end
				expect(occurrences).toBe(1)
			end
		end)

		it("drops the walk's partial run when bailing so no voxel is appended twice", function()
			local search = cullThrottle._search
			local voxelProofs = cullThrottle._visibilityCache._voxelProofs
			local keys = {
				Vector3.new(0, 40, 0),
				Vector3.new(1, 41, 1),
				Vector3.new(2, 42, 2),
				Vector3.new(3, 43, 3),
				Vector3.new(0, 42, 1),
				Vector3.new(3, 40, 2),
				Vector3.new(1, 43, 0),
			}
			for i, key in keys do
				search._searchVoxelKeys[i] = key
			end
			-- The first key holds a valid visible proof, so the walk appends it
			-- before the cold majority forces a bail. The bail must drop that
			-- partial run, since the bulk inside path below re-appends the whole
			-- slice, this key included.
			voxelProofs[keys[1]] = visibleVoxelProof(math.huge, 0)

			local getBoxTests = countBoxTests()
			search:searchVolume(0, 0, roomyFrustumPlanes, 0, 40, 0, 4, 44, 4, 1, 7, 0b11111, math.huge)

			-- A single whole-box test proves the walk really bailed into the bulk
			-- path. Re-testing the cold cells one by one would reach the same
			-- visible set with six tests instead.
			expect(getBoxTests()).toBe(1)
			expect(search._visibleVoxelCount).toBe(7)
			local occurrences = 0
			for i = 1, search._visibleVoxelCount do
				if search._pendingVoxelKeys[i] == keys[1] then
					occurrences += 1
				end
			end
			expect(occurrences).toBe(1)
		end)

		it("skips valid culled proofs in the walk without appending or re-testing them", function()
			local search = cullThrottle._search
			local voxelProofs = cullThrottle._visibilityCache._voxelProofs
			local culledKey = Vector3.new(1, 41, 1)
			local provenKey = Vector3.new(2, 42, 2)
			search._searchVoxelKeys[1] = culledKey
			search._searchVoxelKeys[2] = provenKey
			voxelProofs[culledKey] = culledVoxelProof(math.huge, 0)
			voxelProofs[provenKey] = visibleVoxelProof(math.huge, 0)

			local getBoxTests = countBoxTests()
			search:searchVolume(0, 0, roomyFrustumPlanes, 0, 40, 0, 4, 44, 4, 1, 2, 0b11111, math.huge)

			-- The provably-culled voxel is skipped silently (no test, no append)
			-- while the proven-visible one rides the walk into the visible set.
			expect(getBoxTests()).toBe(0)
			expect(search._visibleVoxelCount).toBe(1)
			expect(search._pendingVoxelKeys[1]).toBe(provenKey)
			expect(search._volumesToCheckSize).toBe(0)
		end)

		it("subdivides a straddling bucket to keep in-frustum voxels and drop out-of-frustum ones", function()
			local part = createMockPart()
			local insideKey = Vector3.new(0, 0, 0)
			local outsideKey = Vector3.new(3, 0, 3)
			cullThrottle._grid:insertToVoxel(insideKey, stubObjectData(part))
			cullThrottle._grid:insertToVoxel(outsideKey, stubObjectData(part))

			local search = cullThrottle._search
			search:seedSearchVolumes(straddlingFrustumPlanes, 0, 0, 0, 4, 4, 4)

			-- Drain the stack the way run does, with zero accumulated motion, so
			-- the root volume's straddle mask and inherited slack flow into its
			-- children. A wrong root mask would stop the subdivision from
			-- rejecting the out-of-frustum voxel.
			drainVolumeStack(search, 0, 0, straddlingFrustumPlanes)

			local foundInside, foundOutside = false, false
			for i = 1, search._visibleVoxelCount do
				local key = search._pendingVoxelKeys[i]
				if key == insideKey then
					foundInside = true
				elseif key == outsideKey then
					foundOutside = true
				end
			end
			expect(foundInside).toBe(true)
			expect(foundOutside).toBe(false)

			part:Destroy()
		end)

		it("flips the subdivision push order between frames so each half takes its turn in front", function()
			-- Six cold keys force the proof walk to bail, and the box test
			-- straddles, so the volume splits down its long axis and pushes both
			-- halves. The stack is LIFO, so the half pushed last is searched
			-- first, and the push order must flip with the per-frame rotation
			-- counter or one half would hog the front of the budget every frame.
			local search = cullThrottle._search
			local keys = {
				Vector3.new(0, 0, 0),
				Vector3.new(1, 1, 1),
				Vector3.new(0, 2, 1),
				Vector3.new(2, 2, 2),
				Vector3.new(3, 3, 3),
				Vector3.new(3, 1, 2),
			}
			for i, key in keys do
				search._searchVoxelKeys[i] = key
			end

			search._volumeRotationCounter = 0
			search:searchVolume(0, 0, straddlingFrustumPlanes, 0, 0, 0, 4, 4, 4, 1, 6, 0b11111, math.huge)
			expect(search._volumesToCheckSize).toBe(20)
			local evenFrameFirst = popVolume(search)
			search._volumesToCheckSize = 0

			-- The split partitioned the key buffer in place, so restage it before
			-- running the same volume under the flipped parity.
			for i, key in keys do
				search._searchVoxelKeys[i] = key
			end
			search._volumeRotationCounter = 1
			search:searchVolume(0, 0, straddlingFrustumPlanes, 0, 0, 0, 4, 4, 4, 1, 6, 0b11111, math.huge)
			expect(search._volumesToCheckSize).toBe(20)
			local oddFrameFirst = popVolume(search)

			-- The two parities lead with opposite halves of the same x split.
			expect(evenFrameFirst.x0).never.toBe(oddFrameFirst.x0)
			expect(math.min(evenFrameFirst.x0, oddFrameFirst.x0)).toBe(0)
			expect(math.max(evenFrameFirst.x0, oddFrameFirst.x0)).toBe(2)
		end)

		it("still seeds surviving buckets after a boundary bucket empties", function()
			-- Two voxels in distant buckets, the farther one defining the coarse
			-- bounds. Removing it dirties the bounds, and the next seed must
			-- recompute them around the survivor rather than clamping it out of
			-- the scan.
			local partA = createMockPart()
			local partB = createMockPart()
			local dataB = stubObjectData(partB)
			cullThrottle._grid:insertToVoxel(Vector3.new(1, 41, 1), stubObjectData(partA))
			cullThrottle._grid:insertToVoxel(Vector3.new(40, 80, 40), dataB)

			cullThrottle._grid:removeFromVoxel(Vector3.new(40, 80, 40), dataB)
			expect(cullThrottle._grid._coarseBoundsDirty).toBe(true)

			local search = cullThrottle._search
			search._visibleVoxelCount = 0
			search:seedSearchVolumes(roomyFrustumPlanes, 0, 40, 0, 4, 44, 4)

			expect(cullThrottle._grid._coarseBoundsDirty).toBe(false)
			expect(search._visibleVoxelCount).toBe(1)
			expect(search._pendingVoxelKeys[1]).toBe(Vector3.new(1, 41, 1))

			partA:Destroy()
			partB:Destroy()
		end)

		it("keeps the inclusive max-bound voxel row inside the searched box", function()
			-- The camera bounds arrive as inclusive voxel indices and run converts
			-- them to a half-open box. This voxel sits on the max-bound row of a
			-- straddling bucket, so dropping the conversion's +1 would filter its
			-- key out of the seed and silently cull the outermost row.
			local edgeKey = Vector3.new(15, 21, 3)
			local part = createMockPart()
			cullThrottle._grid:insertToVoxel(edgeKey, stubObjectData(part))

			patchFunction(CameraCache, "getPlanesAndBounds", function()
				return roomyFrustumPlanes, Vector3.new(12, 18, 0), edgeKey
			end)

			cullThrottle._config.searchTimeBudget = 1
			local search = cullThrottle._search
			search:run(os.clock())

			local found = false
			for i = 1, search._visibleVoxelCount do
				if search._pendingVoxelKeys[i] == edgeKey then
					found = true
					break
				end
			end
			expect(found).toBe(true)

			part:Destroy()
		end)

		it("does not scan the bucket just past a box ending exactly on a bucket boundary", function()
			-- The query box is half-open, so a box ending exactly where buckets 0
			-- and 1 meet holds no cell of bucket 1 and the scan must not touch
			-- it. The occupied voxel sits at the very start of bucket 1.
			local part = createMockPart()
			cullThrottle._grid:insertToVoxel(Vector3.new(4, 1, 1), stubObjectData(part))

			local getCalls = countClassifyCalls()
			local search = cullThrottle._search
			expect(search:seedSearchVolumes(roomyFrustumPlanes, 0, 0, 0, 4, 4, 4)).toBe(0)
			expect(getCalls()).toBe(0)
			expect(cullThrottle._visibilityCache._bucketVerdicts[Vector3.new(1, 0, 0)]).toBeNil()

			-- Extending the box one voxel past the boundary brings the bucket
			-- into the scan, so it gets classified.
			search:seedSearchVolumes(roomyFrustumPlanes, 0, 0, 0, 5, 4, 4)
			expect(getCalls()).toBe(1)
			expect(cullThrottle._visibilityCache._bucketVerdicts[Vector3.new(1, 0, 0)]).toBeDefined()

			part:Destroy()
		end)

		it("resolves the same visible set from cached proofs after small camera motion", function()
			local camera = workspace.CurrentCamera
			local parts = {}
			for i = 1, 5 do
				local part = createMockPart((camera.CFrame * CFrame.new(0, 0, -100 * i)).Position)
				cullThrottle:AddObject(part)
				table.insert(parts, part)
			end

			cullThrottle._config.searchTimeBudget = 1
			cullThrottle._config.ingestTimeBudget = 1

			local search = cullThrottle._search
			cullThrottle:_findVisibleObjects(os.clock())

			local firstSet = {}
			local firstCount = 0
			for i = 1, search._visibleVoxelCount do
				firstSet[search._pendingVoxelKeys[i]] = true
				firstCount += 1
			end
			expect(firstCount).toBeGreaterThan(0)

			-- Drift the camera slightly. Every proof the first pass stamped must
			-- either survive this much motion or re-prove to the same verdict,
			-- so the visible set cannot change while the scene and the frustum
			-- stay put. A proof stamped with swapped or inflated components
			-- produces a correct first frame and a wrong second one.
			cullThrottle._motion._accumT = 0.05

			cullThrottle:_findVisibleObjects(os.clock())

			local secondCount = 0
			for i = 1, search._visibleVoxelCount do
				expect(firstSet[search._pendingVoxelKeys[i]]).toBe(true)
				secondCount += 1
			end
			expect(secondCount).toBe(firstCount)

			for _, part in parts do
				part:Destroy()
			end
		end)

		it("keeps proofs with enough clearance across a small field of view change", function()
			local camera = workspace.CurrentCamera
			local parts = {}
			for i = 1, 5 do
				local part = createMockPart((camera.CFrame * CFrame.new(0, 0, -100 * i)).Position)
				cullThrottle:AddObject(part)
				table.insert(parts, part)
			end

			cullThrottle._config.searchTimeBudget = 1
			cullThrottle._config.ingestTimeBudget = 1

			local search = cullThrottle._search
			local getBoxTests = countBoxTests()
			cullThrottle:_findVisibleObjects(os.clock())
			local coldBoxTests = getBoxTests()

			local firstSet = {}
			local firstCount = 0
			for i = 1, search._visibleVoxelCount do
				firstSet[search._pendingVoxelKeys[i]] = true
				firstCount += 1
			end
			expect(firstCount).toBeGreaterThan(0)

			-- Nudge the field of view a couple of degrees wider. The side planes
			-- only swing by the half-angle deltas, so proofs minted with more
			-- clearance than that motion must survive, and the warm pass must
			-- trust them instead of re-testing every box from scratch. The change
			-- signal fires deferred, so let it land before the next pass.
			camera.FieldOfView += 2
			task.wait()

			cullThrottle:_findVisibleObjects(os.clock())
			local warmBoxTests = getBoxTests() - coldBoxTests

			-- Widening the frustum cannot cull anything that was visible, and the
			-- objects sit dead ahead, so the visible set must come back unchanged.
			local secondCount = 0
			for i = 1, search._visibleVoxelCount do
				expect(firstSet[search._pendingVoxelKeys[i]]).toBe(true)
				secondCount += 1
			end
			expect(secondCount).toBe(firstCount)
			expect(warmBoxTests).toBeLessThan(coldBoxTests)

			for _, part in parts do
				part:Destroy()
			end
		end)

		it("preserves live buffers when resized to current occupancy", function()
			local search = cullThrottle._search
			local keys = { Vector3.new(1, 1, 1), Vector3.new(2, 2, 2), Vector3.new(3, 3, 3) }
			for i, key in keys do
				search._visibleVoxelKeys[i] = key
				search._pendingVoxelKeys[i] = key
				search._searchVoxelKeys[i] = key
			end
			search._visibleVoxelCount = 3
			search:pushVolume(1, 2, 3, 4, 5, 6, 1, 3, 0b10101, 0.5)

			search:resizeBuffers()

			for i, key in keys do
				expect(search._visibleVoxelKeys[i]).toBe(key)
				expect(search._pendingVoxelKeys[i]).toBe(key)
				-- The leftover volume's [lo, hi] slice indexes into the seed
				-- buffer, so those slots must survive alongside it.
				expect(search._searchVoxelKeys[i]).toBe(key)
			end
			-- The leftover volume survives with every field intact.
			expect(search._volumesToCheckSize).toBe(10)
			local volume = popVolume(search)
			expect(volume.x0).toBe(1)
			expect(volume.y0).toBe(2)
			expect(volume.z0).toBe(3)
			expect(volume.x1).toBe(4)
			expect(volume.y1).toBe(5)
			expect(volume.z1).toBe(6)
			expect(volume.lo).toBe(1)
			expect(volume.hi).toBe(3)
			expect(volume.planeMask).toBe(0b10101)
			expect(volume.inheritedSlack).toBe(0.5)
		end)

		it("rebuilds the seed and proof-walk scratch buffers on resize", function()
			-- A burst frame can leave these two scratch buffers holding thousands
			-- of slots that every later frame clears without shrinking. Capacity
			-- isn't observable from Luau, so the rebuild is pinned by the buffers
			-- coming back as fresh tables. With no volumes left on the stack,
			-- nothing references the old contents.
			local search = cullThrottle._search
			for i = 1, 64 do
				search._searchVoxelKeys[i] = Vector3.new(i, 0, 0)
				search._unprovenVoxelKeys[i] = Vector3.new(i, 1, 0)
			end
			local searchKeysBefore = search._searchVoxelKeys
			local unprovenBefore = search._unprovenVoxelKeys

			search:resizeBuffers()

			expect(search._searchVoxelKeys).never.toBe(searchKeysBefore)
			expect(search._unprovenVoxelKeys).never.toBe(unprovenBefore)
		end)

		it("rotates the first-searched volume so each bucket gets a turn", function()
			-- The search seeds one root volume per occupied coarse bucket, and
			-- _volumeRotationCounter chooses which one is moved to the top of the
			-- LIFO stack so it is searched first. A zero search budget bails right
			-- after the first clock check, so the first searchVolume call each
			-- frame is the chosen bucket.
			cullThrottle._config.voxelSize = 50
			cullThrottle._config.searchTimeBudget = 0
			-- A zero-width range pins the render distance so the controller can't
			-- adjust it between frames, and 3000 keeps every part well within range.
			cullThrottle:SetRenderDistanceRange(NumberRange.new(3000, 3000))

			-- These four parts ride the right frustum side plane at increasing depth.
			-- Sitting on a plane makes each part's coarse bucket straddle the
			-- frustum, and only straddling buckets push root volumes (culled and
			-- fully-inside buckets are resolved by the verdict cache without ever
			-- reaching the volume stack). Depth steps of 400 studs keep
			-- consecutive parts in distinct coarse buckets (a bucket spans 4 voxels,
			-- which is 200 studs, and the step moves at least 400 on some axis).
			local camCFrame = workspace.CurrentCamera.CFrame
			local tanHalfHorizontalFov = CameraCache.SinHalfHorizontalFOV / CameraCache.CosHalfHorizontalFOV
			local parts = {}
			for i = 1, 4 do
				local depth = 300 + (i - 1) * 400
				local part = createMockPart((camCFrame * CFrame.new(tanHalfHorizontalFov * depth, 0, -depth)).Position)
				cullThrottle:AddObject(part)
				table.insert(parts, part)
			end

			-- This is patched on the subsystem instance, so it dies with the test.
			local realSearchVolume = cullThrottle._search.searchVolume
			local firstOrigin = nil
			cullThrottle._search.searchVolume = function(
				search,
				accumTF,
				accumR,
				frustumPlanes,
				x0,
				y0,
				z0,
				x1,
				y1,
				z1,
				lo,
				hi,
				planeMask,
				inheritedSlack
			)
				if firstOrigin == nil then
					firstOrigin = Vector3.new(x0, y0, z0)
				end
				return realSearchVolume(
					search,
					accumTF,
					accumR,
					frustumPlanes,
					x0,
					y0,
					z0,
					x1,
					y1,
					z1,
					lo,
					hi,
					planeMask,
					inheritedSlack
				)
			end

			-- Eight frames give the rotation a window of two full passes over the
			-- four bucket volumes.
			local distinctOrigins = {}
			local distinctCount = 0
			for _ = 1, 8 do
				firstOrigin = nil
				cullThrottle:_findVisibleObjects(os.clock())
				expect(firstOrigin).never.toBeNil()
				if not distinctOrigins[firstOrigin] then
					distinctOrigins[firstOrigin] = true
					distinctCount += 1
				end
			end

			-- The contract is fairness rather than a strict cycle, so all the
			-- test demands is that every bucket led the search at least once
			-- across the window.
			expect(distinctCount).toBe(4)

			for _, part in parts do
				part:Destroy()
			end
		end)

		it("surfaces every in-frustum object spread across the seeded buckets", function()
			-- The seed hands each occupied coarse bucket its own root volume and
			-- slice of the key buffer. Spread objects through the view in a cone
			-- (so they land in distinct voxels across many buckets), then confirm
			-- the seed and the in-bucket partitions drop none of them.
			local camCFrame = workspace.CurrentCamera.CFrame

			-- Small voxels make the spread objects occupy distinct, widely separated voxels.
			cullThrottle:SetVoxelSize(40)
			cullThrottle._config.searchTimeBudget = 1
			cullThrottle._config.ingestTimeBudget = 1

			-- Offsets scale with depth to stay safely inside the FOV at every distance.
			local parts = {}
			for _, depth in { 100, 300, 500 } do
				for _, sx in { -1, 1 } do
					for _, sy in { -1, 1 } do
						local offset = CFrame.new(sx * depth * 0.2, sy * depth * 0.1, -depth)
						local part = createMockPart((camCFrame * offset).Position)
						cullThrottle:AddObject(part)
						table.insert(parts, part)
					end
				end
			end

			local visibleObjects = cullThrottle:GetVisibleObjects()

			-- Each object is in front of the camera and within range, so the seed
			-- must surface all of them.
			for _, part in parts do
				expect(table.find(visibleObjects, part)).never.toBeNil()
			end

			for _, part in parts do
				part:Destroy()
			end
		end)
	end)

	describe("Bucket bulk copies", function()
		it("appends a whole bucket after the keys already pending", function()
			local search = cullThrottle._search

			-- Seed the pending buffer with an existing key so the append's
			-- destination offset matters. Landing one slot low overwrites it, and
			-- landing one slot high leaves a hole.
			local existingKey = Vector3.new(9, 9, 9)
			search._pendingVoxelKeys[1] = existingKey
			search._visibleVoxelCount = 1

			local bucket = { Vector3.new(0, 40, 0), Vector3.new(1, 41, 1), Vector3.new(2, 42, 2) }
			search:appendWholeBucketToVisible(bucket, 0, 40, 0)

			expect(search._visibleVoxelCount).toBe(4)
			expect(search._pendingVoxelKeys[1]).toBe(existingKey)
			expect(search._pendingVoxelKeys[2]).toBe(bucket[1])
			expect(search._pendingVoxelKeys[3]).toBe(bucket[2])
			expect(search._pendingVoxelKeys[4]).toBe(bucket[3])
		end)

		it("seeds every key of a straddling bucket that sits fully inside the query box", function()
			-- The straddling fixture's planes all cut through the first coarse
			-- bucket's box, and the query box below exactly covers that box, so the
			-- seed takes the unfiltered interior copy for the whole bucket.
			local part = createMockPart()
			local keys = {
				Vector3.new(0, 0, 0),
				Vector3.new(1, 1, 1),
				Vector3.new(2, 2, 3),
				Vector3.new(3, 3, 2),
			}
			for _, key in keys do
				cullThrottle._grid:insertToVoxel(key, stubObjectData(part))
			end

			local search = cullThrottle._search
			local count = search:seedSearchVolumes(straddlingFrustumPlanes, 0, 0, 0, 4, 4, 4)

			-- Every key lands in the search buffer (the order within the slice
			-- is not promised), and the one root volume owns exactly that slice.
			expect(count).toBe(4)
			for _, key in keys do
				local found = false
				for i = 1, count do
					if search._searchVoxelKeys[i] == key then
						found = true
						break
					end
				end
				expect(found).toBe(true)
			end
			expect(search._volumesToCheckSize).toBe(10)
			local volume = popVolume(search)
			expect(volume.lo).toBe(1)
			expect(volume.hi).toBe(4)
			-- The root volume continues from the classification's partial proof.
			-- The mask's bits follow the fixture's plane array order, so 0b10101
			-- marks its first and third side planes plus the far plane as
			-- straddled, and the inherited slack is the min slack of the planes
			-- the box sits fully inside of (the other two side planes touch the
			-- box exactly, so zero).
			expect(volume.planeMask).toBe(0b10101)
			expect(volume.inheritedSlack).toBeCloseTo(0, 4)

			part:Destroy()
		end)
	end)

	describe("Motion-proof visibility cache", function()
		-- This is the same camera as the roomy fixture with the far plane only
		-- 5 voxels out, so a bucket a few voxels ahead is culled by the far plane
		-- specifically.
		local shortFarFrustumPlanes: { Vector3 } = {
			Vector3.new(0, 0, 0),
			Vector3.new(-0, -0.779599547, 0.626278222),
			Vector3.new(0, 0, 0),
			Vector3.new(0, -0.779599547, -0.626278222),
			Vector3.new(0, 0, 0),
			Vector3.new(0.819152057, -0.573576391, 0),
			Vector3.new(0, 0, 0),
			Vector3.new(-0.819152057, -0.573576391, -0),
			Vector3.new(0, 5, 0),
			Vector3.new(0, 1, 0),
		}

		it("skips a culled bucket without re-classifying until motion can overturn the proof", function()
			-- Bucket (2, 0, 0) sits far to the camera's right, so it's culled by a
			-- side plane with a clearance of about 3.6 voxels.
			local part = createMockPart()
			cullThrottle._grid:insertToVoxel(Vector3.new(8, 0, 0), stubObjectData(part))

			local search = cullThrottle._search
			local count = search:seedSearchVolumes(roomyFrustumPlanes, 0, 0, 0, 16, 16, 16)
			expect(count).toBe(0)
			expect(search._volumesToCheckSize).toBe(0)
			expect(search._visibleVoxelCount).toBe(0)

			local verdict = cullThrottle._visibilityCache._bucketVerdicts[Vector3.new(2, 0, 0)]
			expect(verdict).toBeDefined()
			expect(verdict.state).toBe(Frustum.BUCKET_CULLED)

			local getCalls = countClassifyCalls()

			-- A small translation stays under the clearance, so the bucket is still
			-- skipped with no frustum math at all.
			cullThrottle._motion._accumT = 1
			expect(search:seedSearchVolumes(roomyFrustumPlanes, 0, 0, 0, 16, 16, 16)).toBe(0)
			expect(getCalls()).toBe(0)

			-- A side-culled bucket is culled at any render distance, so even a
			-- huge render distance change can't expire it.
			cullThrottle._motion._accumF = 1000
			expect(search:seedSearchVolumes(roomyFrustumPlanes, 0, 0, 0, 16, 16, 16)).toBe(0)
			expect(getCalls()).toBe(0)

			-- Translation past the clearance expires the proof and forces a
			-- fresh classification.
			cullThrottle._motion._accumT = 4
			expect(search:seedSearchVolumes(roomyFrustumPlanes, 0, 0, 0, 16, 16, 16)).toBe(0)
			expect(getCalls()).toBe(1)

			part:Destroy()
		end)

		it("keeps skipping a culled bucket when new voxels appear inside it", function()
			-- The verdict describes the bucket's box, not its contents, so a new
			-- voxel inside a provably-culled bucket is provably culled too.
			local partA = createMockPart()
			local partB = createMockPart()
			cullThrottle._grid:insertToVoxel(Vector3.new(8, 0, 0), stubObjectData(partA))

			local search = cullThrottle._search
			search:seedSearchVolumes(roomyFrustumPlanes, 0, 0, 0, 16, 16, 16)
			expect(cullThrottle._visibilityCache._bucketVerdicts[Vector3.new(2, 0, 0)]).toBeDefined()

			local getCalls = countClassifyCalls()
			cullThrottle._grid:insertToVoxel(Vector3.new(9, 0, 0), stubObjectData(partB))

			local count = search:seedSearchVolumes(roomyFrustumPlanes, 0, 0, 0, 16, 16, 16)
			expect(count).toBe(0)
			expect(search._visibleVoxelCount).toBe(0)
			expect(getCalls()).toBe(0)

			partA:Destroy()
			partB:Destroy()
		end)

		it("expires a far-culled bucket on render distance change", function()
			-- Bucket (0, 2, 0) is straight ahead but past the short far plane, so
			-- it's culled by the far plane with a clearance of about 1.5 voxels.
			local part = createMockPart()
			cullThrottle._grid:insertToVoxel(Vector3.new(1, 9, 1), stubObjectData(part))

			local search = cullThrottle._search
			search:seedSearchVolumes(shortFarFrustumPlanes, 0, 0, 0, 16, 16, 16)
			local verdict = cullThrottle._visibilityCache._bucketVerdicts[Vector3.new(0, 2, 0)]
			expect(verdict).toBeDefined()
			expect(verdict.state).toBe(Frustum.BUCKET_CULLED)

			local getCalls = countClassifyCalls()

			-- A render distance change smaller than the clearance is survivable.
			cullThrottle._motion._accumF = 1
			search:seedSearchVolumes(shortFarFrustumPlanes, 0, 0, 0, 16, 16, 16)
			expect(getCalls()).toBe(0)

			-- One larger than the clearance could have brought the bucket into
			-- range, so the proof expires.
			cullThrottle._motion._accumF = 2
			search:seedSearchVolumes(shortFarFrustumPlanes, 0, 0, 0, 16, 16, 16)
			expect(getCalls()).toBe(1)

			part:Destroy()
		end)

		it("expires a voxel proof when render distance change alone passes its expiry", function()
			-- The voxel sits inside the frustum within a straddling bucket, so the
			-- search stamps it a visible proof with a positive expiry. Voxel
			-- proofs charge render distance change at full weight alongside
			-- translation, so growing that accumulator alone must spend the
			-- expiry the same way moving the camera would.
			local part = createMockPart()
			local voxelKey = Vector3.new(4, 11, 1)
			cullThrottle._grid:insertToVoxel(voxelKey, stubObjectData(part))

			patchFunction(CameraCache, "getPlanesAndBounds", function()
				return roomyFrustumPlanes, Vector3.new(4, 8, 0), Vector3.new(7, 11, 3)
			end)

			cullThrottle._config.searchTimeBudget = 1
			local search = cullThrottle._search
			local voxelProofs = cullThrottle._visibilityCache._voxelProofs
			search:run(os.clock())

			local proof = voxelProofs[voxelKey]
			expect(proof).toBeDefined()
			expect(proof.X > 0).toBe(true)

			local getBoxTests = countBoxTests()

			-- A render distance change under the stored expiry trusts the proof,
			-- so the voxel surfaces with no fresh frustum math.
			cullThrottle._motion._accumF = proof.X * 0.5
			search._visibleVoxelCount = 0
			search:run(os.clock())
			expect(getBoxTests()).toBe(0)
			expect(search._visibleVoxelCount).toBe(1)

			-- One past the expiry, with zero translation and rotation, expires
			-- the proof and forces a fresh test that re-proves the verdict.
			cullThrottle._motion._accumF = proof.X + 0.01
			search._visibleVoxelCount = 0
			search:run(os.clock())
			expect(getBoxTests()).toBe(1)
			expect(search._visibleVoxelCount).toBe(1)
			expect(voxelProofs[voxelKey].X > proof.X).toBe(true)

			part:Destroy()
		end)

		it("charges rotation against a culled-bucket verdict at its own arm", function()
			-- Bucket (2, 0, 0) sits far to the camera's right, so it's culled by
			-- a side plane and the verdict's rotation budget is its side expiry
			-- over its arm.
			local part = createMockPart()
			cullThrottle._grid:insertToVoxel(Vector3.new(8, 0, 0), stubObjectData(part))

			local search = cullThrottle._search
			search:seedSearchVolumes(roomyFrustumPlanes, 0, 0, 0, 16, 16, 16)
			local verdict = cullThrottle._visibilityCache._bucketVerdicts[Vector3.new(2, 0, 0)]
			expect(verdict).toBeDefined()
			expect(verdict.state).toBe(Frustum.BUCKET_CULLED)

			local getCalls = countClassifyCalls()

			-- Rotation under the budget keeps the bucket provably culled with no
			-- frustum math.
			local rotationBudget = verdict.sideExpiry / verdict.armFactor
			cullThrottle._motion._accumR = rotationBudget * 0.99
			expect(search:seedSearchVolumes(roomyFrustumPlanes, 0, 0, 0, 16, 16, 16)).toBe(0)
			expect(getCalls()).toBe(0)

			-- Rotation alone past the budget could swing the side plane back
			-- onto the bucket, so the verdict expires and the box is
			-- re-classified.
			cullThrottle._motion._accumR = rotationBudget * 1.01
			expect(search:seedSearchVolumes(roomyFrustumPlanes, 0, 0, 0, 16, 16, 16)).toBe(0)
			expect(getCalls()).toBe(1)

			part:Destroy()
		end)

		it("trusts a bucket verdict at exactly its clearance boundary", function()
			-- The verdict check is inclusive, so motion landing exactly on the
			-- stored expiry still trusts the verdict and only motion past it
			-- expires the proof. A perfectly still camera riding a zero-clearance
			-- verdict takes this same comparison.
			local part = createMockPart()
			cullThrottle._grid:insertToVoxel(Vector3.new(8, 0, 0), stubObjectData(part))

			local search = cullThrottle._search
			search:seedSearchVolumes(roomyFrustumPlanes, 0, 0, 0, 16, 16, 16)
			local verdict = cullThrottle._visibilityCache._bucketVerdicts[Vector3.new(2, 0, 0)]
			expect(verdict.state).toBe(Frustum.BUCKET_CULLED)

			local getCalls = countClassifyCalls()

			-- Exactly at the boundary the verdict still holds.
			cullThrottle._motion._accumT = verdict.sideExpiry
			search:seedSearchVolumes(roomyFrustumPlanes, 0, 0, 0, 16, 16, 16)
			expect(getCalls()).toBe(0)

			-- The smallest step past it forces a re-classification.
			cullThrottle._motion._accumT = verdict.sideExpiry + 1e-4
			search:seedSearchVolumes(roomyFrustumPlanes, 0, 0, 0, 16, 16, 16)
			expect(getCalls()).toBe(1)

			part:Destroy()
		end)

		it("drops a stale cached verdict when its bucket reclassifies as straddling", function()
			-- The first coarse bucket's box straddles the fixture frustum. Stage
			-- an expired culled verdict on it, so the seed has to re-classify,
			-- find it straddling, and delete the record outright, since a
			-- straddling bucket stores no verdict at all.
			local part = createMockPart()
			cullThrottle._grid:insertToVoxel(Vector3.new(1, 1, 1), stubObjectData(part))

			local bucketVerdicts = cullThrottle._visibilityCache._bucketVerdicts
			bucketVerdicts[Vector3.new(0, 0, 0)] = {
				state = Frustum.BUCKET_CULLED,
				armFactor = 0,
				sideExpiry = 0,
				farExpiry = 0,
			}
			cullThrottle._motion._accumT = 1

			local search = cullThrottle._search
			local count = search:seedSearchVolumes(straddlingFrustumPlanes, 0, 0, 0, 4, 4, 4)

			-- The bucket's key went to the subdivision search and the stale
			-- record is gone. A surviving record would keep resolving the bucket
			-- from cached state it no longer earns.
			expect(count).toBe(1)
			expect(bucketVerdicts[Vector3.new(0, 0, 0)]).toBeNil()

			part:Destroy()
		end)

		it("resolves a fully-inside bucket by appending its live key list with no volumes", function()
			local partA = createMockPart()
			local partB = createMockPart()
			local keyA = Vector3.new(1, 41, 1)
			cullThrottle._grid:insertToVoxel(keyA, stubObjectData(partA))

			local search = cullThrottle._search
			local count = search:seedSearchVolumes(roomyFrustumPlanes, 0, 40, 0, 4, 44, 4)
			expect(count).toBe(0)
			expect(search._volumesToCheckSize).toBe(0)
			expect(search._visibleVoxelCount).toBe(1)
			expect(search._pendingVoxelKeys[1]).toBe(keyA)

			local verdict = cullThrottle._visibilityCache._bucketVerdicts[Vector3.new(0, 10, 0)]
			expect(verdict).toBeDefined()
			expect(verdict.state).toBe(Frustum.BUCKET_INSIDE)

			-- A voxel added after the proof is picked up on the next pass without
			-- any new frustum work, since the verdict covers the bucket's whole box.
			local getCalls = countClassifyCalls()
			local keyB = Vector3.new(2, 42, 2)
			cullThrottle._grid:insertToVoxel(keyB, stubObjectData(partB))
			search._visibleVoxelCount = 0

			search:seedSearchVolumes(roomyFrustumPlanes, 0, 40, 0, 4, 44, 4)
			expect(search._visibleVoxelCount).toBe(2)
			expect(getCalls()).toBe(0)

			partA:Destroy()
			partB:Destroy()
		end)

		it("trusts an inside-bucket verdict within its clearance and expires past it", function()
			local part = createMockPart()
			cullThrottle._grid:insertToVoxel(Vector3.new(1, 41, 1), stubObjectData(part))

			local search = cullThrottle._search
			search:seedSearchVolumes(roomyFrustumPlanes, 0, 40, 0, 4, 44, 4)
			local verdict = cullThrottle._visibilityCache._bucketVerdicts[Vector3.new(0, 10, 0)]
			expect(verdict).toBeDefined()
			expect(verdict.state).toBe(Frustum.BUCKET_INSIDE)

			local getCalls = countClassifyCalls()

			-- Translation under the side clearance (about 19 voxels for this
			-- bucket) trusts the verdict, so its keys are bulk-appended with no
			-- frustum math at all.
			cullThrottle._motion._accumT = 18
			search._visibleVoxelCount = 0
			search:seedSearchVolumes(roomyFrustumPlanes, 0, 40, 0, 4, 44, 4)
			expect(getCalls()).toBe(0)
			expect(search._visibleVoxelCount).toBe(1)

			-- Translation past the clearance could have swept a side plane onto
			-- the bucket, so the verdict expires and the box is re-classified.
			cullThrottle._motion._accumT = 20
			search._visibleVoxelCount = 0
			search:seedSearchVolumes(roomyFrustumPlanes, 0, 40, 0, 4, 44, 4)
			expect(getCalls()).toBe(1)
			expect(search._visibleVoxelCount).toBe(1)

			part:Destroy()
		end)

		it("expires an inside-bucket verdict when render distance change spends its far clearance", function()
			local part = createMockPart()
			cullThrottle._grid:insertToVoxel(Vector3.new(1, 41, 1), stubObjectData(part))

			local search = cullThrottle._search
			search:seedSearchVolumes(roomyFrustumPlanes, 0, 40, 0, 4, 44, 4)
			expect(cullThrottle._visibilityCache._bucketVerdicts[Vector3.new(0, 10, 0)].state).toBe(
				Frustum.BUCKET_INSIDE
			)

			local getCalls = countClassifyCalls()

			-- The far plane sits 100 voxels out, leaving this bucket about 54
			-- voxels of far clearance, so a smaller render distance change keeps
			-- the verdict.
			cullThrottle._motion._accumF = 50
			search._visibleVoxelCount = 0
			search:seedSearchVolumes(roomyFrustumPlanes, 0, 40, 0, 4, 44, 4)
			expect(getCalls()).toBe(0)
			expect(search._visibleVoxelCount).toBe(1)

			-- A larger one could pull the far plane onto the bucket, so the
			-- verdict expires.
			cullThrottle._motion._accumF = 56
			search:seedSearchVolumes(roomyFrustumPlanes, 0, 40, 0, 4, 44, 4)
			expect(getCalls()).toBe(1)

			part:Destroy()
		end)

		it("charges rotation against an inside-bucket verdict at its own arm", function()
			local part = createMockPart()
			cullThrottle._grid:insertToVoxel(Vector3.new(1, 41, 1), stubObjectData(part))

			local search = cullThrottle._search
			search:seedSearchVolumes(roomyFrustumPlanes, 0, 40, 0, 4, 44, 4)
			local verdict = cullThrottle._visibilityCache._bucketVerdicts[Vector3.new(0, 10, 0)]
			expect(verdict.state).toBe(Frustum.BUCKET_INSIDE)
			-- The arm covers the bucket from the camera (about 42 voxels out)
			-- plus the slack translation may consume while the verdict lives.
			expect(verdict.armFactor).toBeGreaterThan(40)

			local getCalls = countClassifyCalls()

			-- The rotation debit is the angle times the arm, so the budget this
			-- verdict can absorb is its side expiry over its arm.
			local rotationBudget = verdict.sideExpiry / verdict.armFactor
			cullThrottle._motion._accumR = rotationBudget * 0.99
			search._visibleVoxelCount = 0
			search:seedSearchVolumes(roomyFrustumPlanes, 0, 40, 0, 4, 44, 4)
			expect(getCalls()).toBe(0)
			expect(search._visibleVoxelCount).toBe(1)

			cullThrottle._motion._accumR = rotationBudget * 1.01
			search:seedSearchVolumes(roomyFrustumPlanes, 0, 40, 0, 4, 44, 4)
			expect(getCalls()).toBe(1)

			part:Destroy()
		end)

		it("trusts a zero-slack stamp while the camera is still, and re-tests once motion passes it", function()
			local voxelKey = Vector3.new(0, 0, 0)
			local search = cullThrottle._search
			local getBoxTests = countBoxTests()

			-- The cell touches the far plane exactly (its inside slack there is
			-- zero), so its proof stores exactly zero slack even though the side
			-- planes it straddles have positive exit clearance.
			search:searchSingleVoxel(0, 0, straddlingFrustumPlanes, 0b11111, math.huge, 0, 0, 0, voxelKey)
			expect(getBoxTests()).toBe(1)
			expect(search._visibleVoxelCount).toBe(1)
			local proof = cullThrottle._visibilityCache._voxelProofs[voxelKey]
			expect(proof.X).toBe(0)

			-- With the same accumulators (no camera motion), even a zero-slack proof holds.
			search:searchSingleVoxel(0, 0, straddlingFrustumPlanes, 0b11111, math.huge, 0, 0, 0, voxelKey)
			expect(getBoxTests()).toBe(1)
			expect(search._visibleVoxelCount).toBe(2)

			-- The cell sits flush against the far plane, so any motion at all is
			-- past a zero-slack stamp and forces a re-test.
			search:searchSingleVoxel(0.001, 0, straddlingFrustumPlanes, 0b11111, math.huge, 0, 0, 0, voxelKey)
			expect(getBoxTests()).toBe(2)
			expect(search._visibleVoxelCount).toBe(3)
		end)

		it("trusts a culled proof until motion could bring the voxel back into view", function()
			-- This cell sits far outside the frustum's right side plane (and only
			-- that plane), so the first check stamps a culled proof carrying the
			-- rejection margin, and further checks are free until the culled
			-- motion metric passes it.
			local voxelKey = Vector3.new(8, 0, 0)
			local search = cullThrottle._search
			local getBoxTests = countBoxTests()

			search:searchSingleVoxel(0, 0, straddlingFrustumPlanes, 0b11111, math.huge, 8, 0, 0, voxelKey)
			expect(getBoxTests()).toBe(1)
			expect(search._visibleVoxelCount).toBe(0)
			local proof = cullThrottle._visibilityCache._voxelProofs[voxelKey]
			expect(proof).toBeDefined()
			-- A culled proof carries no visible expiry.
			expect(proof.X).toBe(-1)
			-- The stored margin must stay under the cell's true clearance to the
			-- rejecting plane, or motion could bring the cell back into view
			-- while the cache still calls it provably culled. The sphere fast
			-- path understates the true clearance by at most the circumscribing
			-- radius plus the safety shave, so the margin also can't collapse to
			-- a uselessly small window.
			local maxMargin = maxSoundCulledMargin(straddlingFrustumPlanes, 8, 0, 0, 9, 1, 1)
			expect(proof.Y < maxMargin).toBe(true)
			expect(proof.Y > maxMargin - 1).toBe(true)

			-- It's still proven culled at the same accumulators, so there's no test
			-- and it isn't visible.
			search:searchSingleVoxel(0, 0, straddlingFrustumPlanes, 0b11111, math.huge, 8, 0, 0, voxelKey)
			expect(getBoxTests()).toBe(1)
			expect(search._visibleVoxelCount).toBe(0)

			-- Once motion passes the stored expiry, the cell is re-tested.
			search:searchSingleVoxel(proof.Y + 0.001, 0, straddlingFrustumPlanes, 0b11111, math.huge, 8, 0, 0, voxelKey)
			expect(getBoxTests()).toBe(2)
		end)

		it("bounds a proof by the slack inherited through masked-out planes", function()
			-- With every plane masked off, the local test proves nothing, so the
			-- proof's slack can only come from the ancestor's clearance.
			local voxelKey = Vector3.new(0, 40, 0)
			local search = cullThrottle._search
			local voxelProofs = cullThrottle._visibilityCache._voxelProofs
			search:searchSingleVoxel(5, 0, roomyFrustumPlanes, 0, 0.5, 0, 40, 0, voxelKey)

			-- The stored slack is the inherited clearance shaved by the safety
			-- margin, so it must stay strictly under the geometry it came from
			-- while remaining a usable positive window.
			local smallSlack = voxelProofs[voxelKey].X - 5
			expect(smallSlack).toBeGreaterThan(0)
			expect(smallSlack < 0.5).toBe(true)

			-- The arm covers the cell (its center distance plus the covering
			-- half diagonal) plus at most the slack translation may consume
			-- while the proof lives.
			local armBase = Vector3.new(0.5, 40.5, 0.5).Magnitude + math.sqrt(3) / 2
			expect(voxelProofs[voxelKey].Z >= armBase).toBe(true)
			expect(voxelProofs[voxelKey].Z < armBase + 0.5).toBe(true)

			-- A larger inherited clearance may store more slack, never less, and
			-- never more than its own geometry.
			voxelProofs[voxelKey] = nil
			search:searchSingleVoxel(5, 0, roomyFrustumPlanes, 0, 2, 0, 40, 0, voxelKey)
			local widerSlack = voxelProofs[voxelKey].X - 5
			expect(widerSlack >= smallSlack).toBe(true)
			expect(widerSlack < 2).toBe(true)

			-- Past the cap, a huge clearance stores the same bounded slack as a
			-- vastly larger one, so no single proof can grow arbitrarily stale.
			voxelProofs[voxelKey] = nil
			search:searchSingleVoxel(5, 0, roomyFrustumPlanes, 0, 100, 0, 40, 0, voxelKey)
			local cappedSlack = voxelProofs[voxelKey].X - 5
			voxelProofs[voxelKey] = nil
			search:searchSingleVoxel(5, 0, roomyFrustumPlanes, 0, 1000, 0, 40, 0, voxelKey)
			local hugeSlack = voxelProofs[voxelKey].X - 5
			expect(cappedSlack >= widerSlack).toBe(true)
			expect(cappedSlack < 100).toBe(true)
			expect(hugeSlack).toBeCloseTo(cappedSlack, 5)
		end)

		it("gives a straddling voxel its measured exit clearance as slack", function()
			-- Voxel (14, 20, 0) pokes through the roomy frustum's right side
			-- plane, so it's visible, and provably stays visible until motion
			-- could sweep that plane fully past it (about 0.57 voxels here).
			local voxelKey = Vector3.new(14, 20, 0)
			local search = cullThrottle._search
			local getBoxTests = countBoxTests()

			search:searchSingleVoxel(0, 0, roomyFrustumPlanes, 0b11111, math.huge, 14, 20, 0, voxelKey)
			expect(getBoxTests()).toBe(1)
			expect(search._visibleVoxelCount).toBe(1)

			local proof = cullThrottle._visibilityCache._voxelProofs[voxelKey]
			expect(proof.X > 0.4).toBe(true)
			expect(proof.X < 0.7).toBe(true)

			-- Motion under the exit clearance trusts the proof, with no frustum math.
			search:searchSingleVoxel(0.3, 0, roomyFrustumPlanes, 0b11111, math.huge, 14, 20, 0, voxelKey)
			expect(getBoxTests()).toBe(1)
			expect(search._visibleVoxelCount).toBe(2)

			-- Motion past it forces a re-proof.
			search:searchSingleVoxel(proof.X + 0.001, 0, roomyFrustumPlanes, 0b11111, math.huge, 14, 20, 0, voxelKey)
			expect(getBoxTests()).toBe(2)
		end)

		it("charges rotation against each proof at its own arm", function()
			local voxelKey = Vector3.new(0, 40, 0)
			local search = cullThrottle._search
			local getBoxTests = countBoxTests()

			search:searchSingleVoxel(0, 0, roomyFrustumPlanes, 0b11111, math.huge, 0, 40, 0, voxelKey)
			expect(getBoxTests()).toBe(1)

			-- The cell sits about 40 voxels out, so its rotation budget is its
			-- own slack over roughly that arm, not over a global worst case.
			local proof = cullThrottle._visibilityCache._voxelProofs[voxelKey]
			local rotationBudget = proof.X / proof.Z
			expect(rotationBudget > 0.1).toBe(true)

			-- Bound the stored slack by the cell's true clearance to the nearest
			-- plane first, so the arm identity below can't be satisfied by a bug
			-- that inflates the slack on both sides at once.
			local maxSlack = trueInsideClearance(roomyFrustumPlanes, 0, 40, 0, 1, 41, 1)
			expect(proof.X > 0).toBe(true)
			expect(proof.X < maxSlack).toBe(true)

			-- The stored arm is this cell's own geometry, its center distance
			-- plus the covering half diagonal plus the stored slack, so a global
			-- or hardcoded arm would show up here.
			expect(proof.Z).toBeCloseTo(Vector3.new(0.5, 40.5, 0.5).Magnitude + math.sqrt(3) / 2 + proof.X, 3)

			search:searchSingleVoxel(
				0,
				rotationBudget * 0.99,
				roomyFrustumPlanes,
				0b11111,
				math.huge,
				0,
				40,
				0,
				voxelKey
			)
			expect(getBoxTests()).toBe(1)

			search:searchSingleVoxel(
				0,
				rotationBudget * 1.01,
				roomyFrustumPlanes,
				0b11111,
				math.huge,
				0,
				40,
				0,
				voxelKey
			)
			expect(getBoxTests()).toBe(2)
		end)

		it("re-tests scattered expired voxels without re-subdividing the volume", function()
			-- Two occupied voxels share a volume. One holds a valid proof and the
			-- other holds none. The walk should keep the proven one, test just the
			-- unproven cell, and never push child volumes. The math.huge visible
			-- expiry can never lapse.
			local provenKey = Vector3.new(1, 41, 1)
			local unprovenKey = Vector3.new(2, 41, 2)
			local search = cullThrottle._search
			local voxelProofs = cullThrottle._visibilityCache._voxelProofs
			search._searchVoxelKeys[1] = provenKey
			search._searchVoxelKeys[2] = unprovenKey
			voxelProofs[provenKey] = visibleVoxelProof(math.huge, 0)

			local getBoxTests = countBoxTests()

			search:searchVolume(0, 0, roomyFrustumPlanes, 0, 40, 0, 4, 44, 4, 1, 2, 0b11111, math.huge)

			-- There's one cell test for the unproven voxel, with no volume box test
			-- and no splits.
			expect(getBoxTests()).toBe(1)
			expect(search._volumesToCheckSize).toBe(0)
			expect(search._visibleVoxelCount).toBe(2)
			expect(voxelProofs[unprovenKey]).toBeDefined()
		end)
	end)
end)
