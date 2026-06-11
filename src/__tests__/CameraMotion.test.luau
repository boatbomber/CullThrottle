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
local Utilities = CullThrottlePackage:WaitForChild("Utilities")
local CameraCache = require(Utilities:WaitForChild("CameraCache"))

describe("CameraMotion", function()
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

	it("flushes to re-anchor the accumulators before f32 precision can decay", function()
		-- Proof expiries are stored as f32 vector components, so the
		-- accumulators are re-anchored at zero (with a full flush) once
		-- enough total motion accumulates.
		cullThrottle._visibilityCache._voxelProofs[Vector3.new(1, 1, 1)] = Vector3.new(100, -1, 1)
		cullThrottle._motion._accumR = 65

		cullThrottle._motion:accumulate()

		expect(next(cullThrottle._visibilityCache._voxelProofs)).toBeNil()
		expect(cullThrottle._motion._accumR).toBe(0)
	end)

	it("flushes all cached proofs when the camera projection changes", function()
		local visibilityCache = cullThrottle._visibilityCache
		visibilityCache._voxelProofs[Vector3.new(1, 1, 1)] = Vector3.new(100, -1, 1)
		visibilityCache._voxelProofs[Vector3.new(2, 2, 2)] = Vector3.new(-1, 100, 1)
		visibilityCache._bucketVerdicts[Vector3.new(0, 0, 0)] =
			{ state = 1, armFactor = 1, sideExpiry = 100, farExpiry = math.huge }
		cullThrottle._motion._accumT = 5

		-- Simulate an observed CameraCache generation bump (FOV, viewport, or
		-- camera replacement).
		cullThrottle._motion._lastCameraGeneration -= 1
		cullThrottle._motion:accumulate()

		expect(next(visibilityCache._voxelProofs)).toBeNil()
		expect(next(visibilityCache._bucketVerdicts)).toBeNil()
		expect(cullThrottle._motion._accumT).toBe(0)
		expect(cullThrottle._motion._lastCameraGeneration).toBe(CameraCache.Generation)
	end)

	it("flushes all cached proofs when the voxel size changes", function()
		local visibilityCache = cullThrottle._visibilityCache
		visibilityCache._voxelProofs[Vector3.new(1, 1, 1)] = Vector3.new(100, -1, 1)
		visibilityCache._voxelProofs[Vector3.new(2, 2, 2)] = Vector3.new(-1, 100, 1)
		visibilityCache._bucketVerdicts[Vector3.new(0, 0, 0)] =
			{ state = 1, armFactor = 1, sideExpiry = 100, farExpiry = math.huge }
		cullThrottle._motion._accumT = 5

		cullThrottle:SetVoxelSize(100)

		expect(next(visibilityCache._voxelProofs)).toBeNil()
		expect(next(visibilityCache._bucketVerdicts)).toBeNil()
		expect(cullThrottle._motion._accumT).toBe(0)
	end)
end)
