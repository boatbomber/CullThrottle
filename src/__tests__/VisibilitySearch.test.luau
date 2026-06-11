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

describe("VisibilitySearch", function()
	local cullThrottle

	beforeEach(function()
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
	end)

	describe("Volume search", function()
		it("should fully drain the volume search stack after a search", function()
			-- Spread objects across several voxels so the search subdivides and
			-- pushes and pops volumes on the flat stack.
			local parts = {}
			for i = -2, 2 do
				local part = createMockPart(Vector3.new(i * 50, 0, 0))
				cullThrottle:AddObject(part)
				table.insert(parts, part)
			end

			-- A generous budget lets the search run to completion rather than bail
			-- into the cached-visibility fallback (which leaves volumes on the stack).
			cullThrottle._config.searchTimeBudget = 1
			cullThrottle:_findVisibleObjects(os.clock())

			expect(cullThrottle._search._volumesToCheckSize).toBe(0)

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
			-- fallback should re-mark it.
			cullThrottle._visibilityCache._voxelProofs[voxelKey] = Vector3.new(5, -1, 1)
			search._visibleVoxelCount = 0

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
			expect(cullThrottle._perfMetrics._skippedSearch[1]).toBe(1)

			part:Destroy()
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

			-- Four frames is one full rotation through the four bucket volumes.
			local distinctOrigins = {}
			local distinctCount = 0
			for _ = 1, 4 do
				firstOrigin = nil
				cullThrottle:_findVisibleObjects(os.clock())
				expect(firstOrigin).never.toBeNil()
				if not distinctOrigins[firstOrigin] then
					distinctOrigins[firstOrigin] = true
					distinctCount += 1
				end
			end

			-- Every bucket was searched first exactly once.
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

			-- Every key lands in the search buffer in bucket order, and the one
			-- root volume owns exactly that slice.
			expect(count).toBe(4)
			for i, key in keys do
				expect(search._searchVoxelKeys[i]).toBe(key)
			end
			expect(search._volumesToCheckSize).toBe(10)
			expect(search._volumesToCheck[7]).toBe(1)
			expect(search._volumesToCheck[8]).toBe(4)

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

		--[[
			Wraps Frustum.classifyBucket with a counting shim (registered for the
			afterEach restore) and returns a getter for how many classifications
			have run since.
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
			expect(verdict.state).toBe(1)

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
			expect(verdict.state).toBe(1)

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
			expect(verdict.state).toBe(2)

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

		it("trusts a zero-slack stamp while the camera is still, and re-tests once motion passes it", function()
			local voxelKey = Vector3.new(0, 0, 0)
			local search = cullThrottle._search
			local getBoxTests = countBoxTests()

			-- The cell touches the far plane exactly (its inside slack there is
			-- zero), so its proof carries zero slack overall even though the
			-- side planes it straddles have positive exit clearance.
			search:searchSingleVoxel(0, 0, straddlingFrustumPlanes, 0b11111, math.huge, 0, 0, 0, voxelKey)
			expect(getBoxTests()).toBe(1)
			expect(search._visibleVoxelCount).toBe(1)

			-- With the same accumulators (no camera motion), even a zero-slack proof holds.
			search:searchSingleVoxel(0, 0, straddlingFrustumPlanes, 0b11111, math.huge, 0, 0, 0, voxelKey)
			expect(getBoxTests()).toBe(1)
			expect(search._visibleVoxelCount).toBe(2)

			-- Any motion past the stored expiry forces a re-test.
			local proof = cullThrottle._visibilityCache._voxelProofs[voxelKey]
			search:searchSingleVoxel(proof.X + 0.001, 0, straddlingFrustumPlanes, 0b11111, math.huge, 0, 0, 0, voxelKey)
			expect(getBoxTests()).toBe(2)
			expect(search._visibleVoxelCount).toBe(3)
		end)

		it("trusts a culled proof until motion could bring the voxel back into view", function()
			-- This cell is far outside the frustum, so the first check stamps a
			-- culled proof carrying the rejection margin, and further checks are
			-- free until the culled motion metric passes it.
			local voxelKey = Vector3.new(8, 8, 8)
			local search = cullThrottle._search
			local getBoxTests = countBoxTests()

			search:searchSingleVoxel(0, 0, straddlingFrustumPlanes, 0b11111, math.huge, 8, 8, 8, voxelKey)
			expect(getBoxTests()).toBe(1)
			expect(search._visibleVoxelCount).toBe(0)
			local proof = cullThrottle._visibilityCache._voxelProofs[voxelKey]
			expect(proof).toBeDefined()
			-- A culled proof carries no visible expiry.
			expect(proof.X).toBe(-1)
			expect(proof.Y >= 0).toBe(true)

			-- It's still proven culled at the same accumulators, so there's no test
			-- and it isn't visible.
			search:searchSingleVoxel(0, 0, straddlingFrustumPlanes, 0b11111, math.huge, 8, 8, 8, voxelKey)
			expect(getBoxTests()).toBe(1)
			expect(search._visibleVoxelCount).toBe(0)

			-- Once motion passes the stored expiry, the cell is re-tested.
			search:searchSingleVoxel(proof.Y + 0.001, 0, straddlingFrustumPlanes, 0b11111, math.huge, 8, 8, 8, voxelKey)
			expect(getBoxTests()).toBe(2)
		end)

		it("bounds a proof by the slack inherited through masked-out planes", function()
			-- With every plane masked off, the local test proves nothing. The
			-- proof must come from the ancestor's slack, shaved by the safety
			-- margin (capped proofs are exercised with a large inherited slack).
			local voxelKey = Vector3.new(0, 40, 0)
			local search = cullThrottle._search
			local voxelProofs = cullThrottle._visibilityCache._voxelProofs
			search:searchSingleVoxel(5, 0, roomyFrustumPlanes, 0, 0.5, 0, 40, 0, voxelKey)
			expect(voxelProofs[voxelKey].X).toBeCloseTo(5 + 0.5 - 0.01, 5)

			-- The arm covers the cell. It's the center distance plus the half diagonal,
			-- plus the stored slack that translation may consume while it lives.
			local expectedArm = Vector3.new(0.5, 40.5, 0.5).Magnitude + math.sqrt(3) / 2 + 0.49
			expect(voxelProofs[voxelKey].Z).toBeCloseTo(expectedArm, 3)

			voxelProofs[voxelKey] = nil
			search:searchSingleVoxel(5, 0, roomyFrustumPlanes, 0, 100, 0, 40, 0, voxelKey)
			-- This is capped at SLACK_CAP (8 voxels) minus the safety margin.
			expect(voxelProofs[voxelKey].X).toBeCloseTo(5 + 8 - 0.01, 5)
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
			-- unproven cell, and never push child volumes. A proof packs visible
			-- expiry, culled expiry, and arm into X, Y, and Z, so the math.huge
			-- visible expiry here can never lapse.
			local provenKey = Vector3.new(1, 41, 1)
			local unprovenKey = Vector3.new(2, 41, 2)
			local search = cullThrottle._search
			local voxelProofs = cullThrottle._visibilityCache._voxelProofs
			search._searchVoxelKeys[1] = provenKey
			search._searchVoxelKeys[2] = unprovenKey
			voxelProofs[provenKey] = Vector3.new(math.huge, -1, 0)

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
