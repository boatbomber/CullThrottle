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
local CameraMotion = require(CullThrottlePackage:WaitForChild("CameraMotion"))
local Frustum = require(CullThrottlePackage:WaitForChild("Frustum"))
local Utilities = CullThrottlePackage:WaitForChild("Utilities")
local CameraCache = require(Utilities:WaitForChild("CameraCache"))

local TestHelpers = require(script.Parent.TestHelpers)
local visibleVoxelProof = TestHelpers.visibleVoxelProof
local culledVoxelProof = TestHelpers.culledVoxelProof

describe("CameraMotion", function()
	local cullThrottle
	local originalFieldOfView

	beforeEach(function()
		originalFieldOfView = workspace.CurrentCamera.FieldOfView
		cullThrottle = CullThrottle.new()
	end)

	afterEach(function()
		if cullThrottle then
			cullThrottle:Destroy()
		end
		cullThrottle = nil

		-- Tests that reshape the live camera's projection restore it here so a
		-- failure can't leak the change. The restore fires the projection change
		-- signal deferred, so let it land before the next test captures the
		-- camera generation.
		local camera = workspace.CurrentCamera
		if camera.FieldOfView ~= originalFieldOfView then
			camera.FieldOfView = originalFieldOfView
			task.wait()
		end
	end)

	it("accumulates translation, rotation, and render distance motion separately", function()
		cullThrottle:SetVoxelSize(100)
		local motion = cullThrottle._motion

		-- Pretend the camera sat 100 studs away last frame, which gives one voxel
		-- of translation and no rotation.
		motion._lastCameraCFrame = CameraCache.CFrame * CFrame.new(0, 0, 100)
		motion:accumulate()
		expect(motion._accumT).toBeCloseTo(1, 5)
		expect(motion._accumR).toBeCloseTo(0, 5)

		-- A quarter turn advances only the rotation accumulator.
		motion._lastCameraCFrame = CameraCache.CFrame * CFrame.Angles(0, math.rad(90), 0)
		motion:accumulate()
		expect(motion._accumT).toBeCloseTo(1, 5)
		expect(motion._accumR).toBeCloseTo(math.rad(90), 5)

		-- A render distance change advances only the far accumulator (50 studs is half a voxel here).
		cullThrottle._config.renderDistance += 50
		motion:accumulate()
		expect(motion._accumT).toBeCloseTo(1, 5)
		expect(motion._accumR).toBeCloseTo(math.rad(90), 5)
		expect(motion._accumF).toBeCloseTo(0.5, 5)

		-- A still camera with a settled render distance advances nothing.
		local t, r, f = motion._accumT, motion._accumR, motion._accumF
		motion:accumulate()
		expect(motion._accumT).toBe(t)
		expect(motion._accumR).toBe(r)
		expect(motion._accumF).toBe(f)
	end)

	it("counts the flush when the cache flushes", function()
		local motion = cullThrottle._motion
		local flushCountBefore = motion._flushCount

		-- A flush leaves the accumulators at zero while re-anchoring what they
		-- measure from, and the count is what tells the search's replay gate
		-- that matching readings across one prove nothing.
		motion:flushVisibilityCache()

		expect(motion._flushCount).toBe(flushCountBefore + 1)
	end)

	it("charges pure roll to the rotation accumulator", function()
		local motion = cullThrottle._motion

		-- Roll spins about the look axis, leaving the look vector unchanged while
		-- still swinging the side plane normals, so it must charge the rotation
		-- accumulator like any other turn. A cheaper look-vector-angle measure
		-- would read this as zero motion and trust stale proofs.
		motion._lastCameraCFrame = CameraCache.CFrame * CFrame.Angles(0, 0, math.rad(30))
		motion:accumulate()

		expect(motion._accumR).toBeCloseTo(math.rad(30), 5)
		expect(motion._accumT).toBeCloseTo(0, 5)
	end)

	it("charges a render distance shrink to the far accumulator", function()
		cullThrottle:SetVoxelSize(100)
		local motion = cullThrottle._motion

		-- A shrinking far plane can cull a previously visible bucket, so the
		-- shrink must charge the accumulator by its magnitude just like growth.
		cullThrottle._config.renderDistance -= 50
		motion:accumulate()

		expect(motion._accumF).toBeCloseTo(0.5, 5)
	end)

	it("flushes to re-anchor when the rotation accumulator passes its limit", function()
		-- Proof expiries are stored as f32 vector components, so the
		-- accumulators are re-anchored at zero (with a full flush) once
		-- enough total motion accumulates.
		local visibilityCache = cullThrottle._visibilityCache
		visibilityCache._voxelProofs[Vector3.new(1, 1, 1)] = visibleVoxelProof(100, 1)
		visibilityCache._bucketVerdicts[Vector3.new(0, 0, 0)] =
			{ state = Frustum.BUCKET_CULLED, armFactor = 1, sideExpiry = 100, farExpiry = math.huge }
		local motion = cullThrottle._motion
		motion._accumT = 3
		motion._accumF = 2
		motion._accumR = CameraMotion.ACCUM_ROTATION_FLUSH_LIMIT + 1

		motion:accumulate()

		expect(next(visibilityCache._voxelProofs)).toBeNil()
		expect(next(visibilityCache._bucketVerdicts)).toBeNil()
		expect(motion._accumT).toBe(0)
		expect(motion._accumR).toBe(0)
		expect(motion._accumF).toBe(0)

		-- The flush re-anchors the pose, far plane, and generation to right now,
		-- so an immediate second accumulate must observe no phantom motion.
		motion:accumulate()
		expect(motion._accumT).toBe(0)
		expect(motion._accumR).toBe(0)
		expect(motion._accumF).toBe(0)
	end)

	it("flushes when translation and render distance changes together cross the limit", function()
		-- The translation flush limit counts voxels of translation plus render
		-- distance change, so two accumulators each below the limit on their own
		-- must still flush once their sum crosses it.
		local motion = cullThrottle._motion
		cullThrottle._visibilityCache._voxelProofs[Vector3.new(1, 1, 1)] = visibleVoxelProof(100, 1)
		motion._accumT = CameraMotion.ACCUM_TRANSLATION_FLUSH_LIMIT * 0.75
		motion._accumF = CameraMotion.ACCUM_TRANSLATION_FLUSH_LIMIT * 0.75

		motion:accumulate()

		expect(next(cullThrottle._visibilityCache._voxelProofs)).toBeNil()
		expect(motion._accumT).toBe(0)
		expect(motion._accumF).toBe(0)
	end)

	it("does not flush while the accumulators stay under their limits", function()
		local motion = cullThrottle._motion
		local proofKey = Vector3.new(1, 1, 1)
		cullThrottle._visibilityCache._voxelProofs[proofKey] = visibleVoxelProof(100, 1)
		local stagedT = CameraMotion.ACCUM_TRANSLATION_FLUSH_LIMIT * 0.5
		local stagedF = CameraMotion.ACCUM_TRANSLATION_FLUSH_LIMIT * 0.5 - 1
		local stagedR = CameraMotion.ACCUM_ROTATION_FLUSH_LIMIT - 1
		motion._accumT = stagedT
		motion._accumF = stagedF
		motion._accumR = stagedR

		motion:accumulate()

		-- The limits are f32 precision guards, not correctness bounds, so they
		-- must not fire early. The staged rotation sits just under its limit,
		-- the translation plus render distance sum sits just under its own, and
		-- the cached proof must survive with every accumulator keeping its
		-- reading rather than re-anchoring to zero.
		expect(cullThrottle._visibilityCache._voxelProofs[proofKey]).toBe(visibleVoxelProof(100, 1))
		expect(motion._accumT).toBe(stagedT)
		expect(motion._accumF).toBe(stagedF)
		expect(motion._accumR).toBe(stagedR)
	end)

	it("holds at exactly the flush limits and flushes just past them", function()
		local motion = cullThrottle._motion
		local proofs = cullThrottle._visibilityCache._voxelProofs
		local proofKey = Vector3.new(1, 1, 1)

		-- The re-anchor check is a strict comparison, so readings sitting
		-- exactly at the limits are still trusted.
		proofs[proofKey] = visibleVoxelProof(100, 1)
		motion._accumT = CameraMotion.ACCUM_TRANSLATION_FLUSH_LIMIT
		motion._accumR = CameraMotion.ACCUM_ROTATION_FLUSH_LIMIT
		motion:accumulate()

		expect(proofs[proofKey]).toBe(visibleVoxelProof(100, 1))
		expect(motion._accumT).toBe(CameraMotion.ACCUM_TRANSLATION_FLUSH_LIMIT)
		expect(motion._accumR).toBe(CameraMotion.ACCUM_ROTATION_FLUSH_LIMIT)

		-- One voxel past the translation limit is enough to re-anchor everything.
		motion._accumT = CameraMotion.ACCUM_TRANSLATION_FLUSH_LIMIT + 1
		motion:accumulate()

		expect(next(proofs)).toBeNil()
		expect(motion._accumT).toBe(0)
		expect(motion._accumR).toBe(0)
	end)

	it("charges nothing after a flush re-anchors the render distance and projection baselines", function()
		cullThrottle:SetVoxelSize(100)
		local motion = cullThrottle._motion

		-- Grow the render distance and pretend the projection's vertical
		-- half-angle was smaller, then flush before any accumulate observes
		-- either change. The flush anchors its baselines to the values it reads
		-- right then, so both changes die with it.
		cullThrottle._config.renderDistance += 100
		motion._lastHalfVerticalFOV = CameraCache.HalfVerticalFOV - 0.1
		motion:flushVisibilityCache()

		-- An accumulate with unchanged inputs must charge nothing. A stale
		-- baseline would charge the pre-flush render distance change or
		-- half-angle swing as phantom motion here.
		motion:accumulate()
		expect(motion._accumT).toBe(0)
		expect(motion._accumR).toBe(0)
		expect(motion._accumF).toBe(0)
	end)

	it("charges a field of view change to the rotation accumulator and keeps cached proofs", function()
		local visibilityCache = cullThrottle._visibilityCache
		local proofKey = Vector3.new(1, 1, 1)
		visibilityCache._voxelProofs[proofKey] = visibleVoxelProof(100, 1)
		visibilityCache._bucketVerdicts[Vector3.new(0, 0, 0)] =
			{ state = Frustum.BUCKET_CULLED, armFactor = 1, sideExpiry = 100, farExpiry = math.huge }
		local motion = cullThrottle._motion
		motion._accumT = 5

		-- A real field of view change swings each side plane about the camera by
		-- its half-angle delta, so the rotation accumulator must absorb the
		-- larger of the two deltas while every cached proof survives. We refresh
		-- the camera cache synchronously, the same work the deferred projection
		-- signal would do, rather than yielding a frame for it, since a yielded
		-- frame lets the live camera drift and charge extra motion that throws off
		-- the exact accumulator amounts asserted below.
		local halfVerticalBefore = CameraCache.HalfVerticalFOV
		local halfHorizontalBefore = CameraCache.HalfHorizontalFOV
		local camera = workspace.CurrentCamera
		camera.FieldOfView = if camera.FieldOfView == 80 then 70 else 80
		CameraCache.fovChanged()
		motion:accumulate()

		local expectedCharge = math.max(
			math.abs(CameraCache.HalfVerticalFOV - halfVerticalBefore),
			math.abs(CameraCache.HalfHorizontalFOV - halfHorizontalBefore)
		)
		expect(expectedCharge).toBeGreaterThan(0)
		expect(motion._accumR).toBeCloseTo(expectedCharge, 5)
		expect(motion._accumT).toBeCloseTo(5, 5)
		expect(visibilityCache._voxelProofs[proofKey]).toBe(visibleVoxelProof(100, 1))
		expect(visibilityCache._bucketVerdicts[Vector3.new(0, 0, 0)]).toBeDefined()

		-- A settled projection must not keep charging on later frames.
		motion:accumulate()
		expect(motion._accumR).toBeCloseTo(expectedCharge, 5)
	end)

	it("charges the larger projection half-angle delta to the rotation accumulator", function()
		local motion = cullThrottle._motion

		-- Pretend the projection's half-angles were different last frame, the way
		-- a viewport resize reshapes the aspect ratio. Each plane pair only
		-- swings by its own axis's change, so the larger delta bounds the worst
		-- plane and is what the accumulator must absorb.
		motion._lastHalfVerticalFOV = CameraCache.HalfVerticalFOV - 0.1
		motion._lastHalfHorizontalFOV = CameraCache.HalfHorizontalFOV + 0.04
		motion:accumulate()

		expect(motion._accumR).toBeCloseTo(0.1, 5)
		expect(motion._accumT).toBeCloseTo(0, 5)
	end)

	it("flushes all cached proofs when the camera is replaced", function()
		local visibilityCache = cullThrottle._visibilityCache
		visibilityCache._voxelProofs[Vector3.new(1, 1, 1)] = visibleVoxelProof(100, 1)
		visibilityCache._voxelProofs[Vector3.new(2, 2, 2)] = culledVoxelProof(100, 1)
		visibilityCache._bucketVerdicts[Vector3.new(0, 0, 0)] =
			{ state = Frustum.BUCKET_CULLED, armFactor = 1, sideExpiry = 100, farExpiry = math.huge }
		cullThrottle._motion._accumT = 5

		-- Re-initializing the cache stands in for a camera swap, which bumps the
		-- generation. No motion bound relates the two cameras, so everything
		-- flushes and re-anchors.
		CameraCache.init(workspace.CurrentCamera)
		cullThrottle._motion:accumulate()

		expect(next(visibilityCache._voxelProofs)).toBeNil()
		expect(next(visibilityCache._bucketVerdicts)).toBeNil()
		expect(cullThrottle._motion._accumT).toBe(0)

		-- The flush re-anchors to the new generation, so accumulating again with
		-- the same camera must keep a freshly cached proof instead of flushing
		-- forever.
		visibilityCache._voxelProofs[Vector3.new(3, 3, 3)] = visibleVoxelProof(100, 1)
		cullThrottle._motion:accumulate()
		expect(visibilityCache._voxelProofs[Vector3.new(3, 3, 3)]).toBe(visibleVoxelProof(100, 1))
	end)

	it("flushes all cached proofs when the voxel size changes", function()
		local visibilityCache = cullThrottle._visibilityCache
		visibilityCache._voxelProofs[Vector3.new(1, 1, 1)] = visibleVoxelProof(100, 1)
		visibilityCache._voxelProofs[Vector3.new(2, 2, 2)] = culledVoxelProof(100, 1)
		visibilityCache._bucketVerdicts[Vector3.new(0, 0, 0)] =
			{ state = Frustum.BUCKET_CULLED, armFactor = 1, sideExpiry = 100, farExpiry = math.huge }
		cullThrottle._motion._accumT = 5

		cullThrottle:SetVoxelSize(100)

		expect(next(visibilityCache._voxelProofs)).toBeNil()
		expect(next(visibilityCache._bucketVerdicts)).toBeNil()
		expect(cullThrottle._motion._accumT).toBe(0)
	end)
end)
