local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("Packages")
local DevPackages = ReplicatedStorage:WaitForChild("DevPackages")

local JestGlobals = require(DevPackages:WaitForChild("JestGlobals"))

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local beforeEach = JestGlobals.beforeEach
local afterEach = JestGlobals.afterEach

local CullThrottle = Packages:WaitForChild("CullThrottle")
local CameraCache = require(CullThrottle:WaitForChild("Utilities"):WaitForChild("CameraCache"))

describe("CameraCache", function()
	local fabricatedCameras: { Camera } = {}

	--[[
		Builds a Camera parented to workspace and tracks it so the afterEach
		can destroy it even when an assertion fails partway through a test.
	]]
	local function makeCamera(): Camera
		local camera = Instance.new("Camera")
		camera.Parent = workspace
		table.insert(fabricatedCameras, camera)
		return camera
	end

	afterEach(function()
		-- CameraCache is a singleton, so point it back at the live camera after
		-- tests that re-init it with nil or a fabricated camera. This hook runs
		-- after any inner ones, so workspace.CurrentCamera is already restored
		-- by the time we read it here, and the fabricated cameras are no longer
		-- referenced by the cache when they get destroyed.
		CameraCache.init(workspace.CurrentCamera)
		for _, camera in fabricatedCameras do
			camera:Destroy()
		end
		table.clear(fabricatedCameras)
	end)

	describe("computeAspectRatio", function()
		it("returns width over height for a normal viewport", function()
			expect(CameraCache.computeAspectRatio(Vector2.new(1920, 1080))).toBeCloseTo(1920 / 1080)
		end)

		it("returns zero for a zero-height viewport", function()
			-- This must be finite (0) and never inf/NaN, or it would poison the frustum bounds.
			expect(CameraCache.computeAspectRatio(Vector2.new(800, 0))).toBe(0)
		end)
	end)

	describe("computeTanHalfVerticalFOV", function()
		local tanHalf70 = math.tan(math.rad(70 / 2))

		it("narrows the max-axis FoV by the aspect ratio for a landscape viewport", function()
			-- The longer axis is horizontal, so the vertical FoV is narrower. The
			-- expected value is tan(35 degrees) divided by the 16:9 aspect ratio,
			-- precomputed by hand so the test doesn't re-derive itself from the
			-- implementation's own formula.
			expect(CameraCache.computeTanHalfVerticalFOV(70, 1920 / 1080)).toBeCloseTo(0.3938667, 6)
		end)

		it("uses the max-axis FoV directly for a portrait viewport", function()
			-- The longer axis is already the vertical one, so no narrowing applies.
			local aspect = 1080 / 1920
			expect(CameraCache.computeTanHalfVerticalFOV(70, aspect)).toBeCloseTo(tanHalf70)
		end)
	end)

	describe("fovChanged", function()
		it("caches the sine and cosine of both half angles", function()
			local camera = makeCamera()
			camera.MaxAxisFieldOfView = 70
			CameraCache.init(camera)

			-- The viewport is read-only in a headless run, so stage the 16:9
			-- aspect ratio directly and drive the recompute. With a max-axis
			-- FoV of 70 the horizontal half angle is exactly 35 degrees, and
			-- the vertical half angle has tangent tan(35 degrees) * 9/16 =
			-- 0.3938667. The four constants below are hand-derived from those
			-- angles using sin = t / sqrt(1 + t^2) and cos = 1 / sqrt(1 + t^2),
			-- so a swapped axis or a sin standing in for a cos can't slip
			-- through by mirroring the implementation's own fields.
			CameraCache.AspectRatio = 1920 / 1080
			CameraCache.fovChanged()

			expect(CameraCache.SinHalfHorizontalFOV).toBeCloseTo(0.5735764, 6)
			expect(CameraCache.CosHalfHorizontalFOV).toBeCloseTo(0.8191520, 6)
			expect(CameraCache.SinHalfVerticalFOV).toBeCloseTo(0.3664660, 6)
			expect(CameraCache.CosHalfVerticalFOV).toBeCloseTo(0.9304314, 6)
		end)
	end)

	describe("init", function()
		it("bumps the generation without erroring when there is no camera", function()
			local generationBefore = CameraCache.Generation
			expect(function()
				CameraCache.init(nil)
			end).never.toThrow()
			expect(CameraCache.Object).toBeNil()
			-- The bump tells consumers to throw away frustum-derived state, which
			-- matters most here since no motion bound covers a vanished camera.
			expect(CameraCache.Generation).toBeGreaterThan(generationBefore)
		end)

		it("populates the cache from the live CurrentCamera", function()
			CameraCache.init(workspace.CurrentCamera)

			local camera = workspace.CurrentCamera
			expect(CameraCache.Object).toBe(camera)
			expect(CameraCache.CFrame).toBe(camera.CFrame)
			expect(CameraCache.Position).toBe(camera.CFrame.Position)

			-- The aspect ratio is anchored to the live viewport, so an inverted or
			-- stale ratio can't hide behind the FOV tests that consume it.
			local viewport = camera.ViewportSize
			expect(CameraCache.AspectRatio).toBeCloseTo(viewport.X / viewport.Y)
		end)

		it("caches staged values from a fabricated camera", function()
			local camera = makeCamera()
			camera.CFrame = CFrame.new(5, 6, 7)
			camera.FieldOfView = 80

			CameraCache.init(camera)

			expect(CameraCache.Object).toBe(camera)
			expect(CameraCache.CFrame).toBe(camera.CFrame)
			expect(CameraCache.Position).toBe(camera.CFrame.Position)
			-- TanHalfVertFOV is the vertical tan(FoV/2), derived from the camera's
			-- max-axis FoV narrowed by the viewport aspect ratio.
			expect(CameraCache.TanHalfVertFOV).toBeCloseTo(
				math.tan(math.rad(camera.MaxAxisFieldOfView / 2)) / math.max(CameraCache.AspectRatio, 1)
			)
			expect(CameraCache.HalfVerticalFOV).toBeCloseTo(math.atan(CameraCache.TanHalfVertFOV))
			expect(CameraCache.HalfHorizontalFOV).toBeCloseTo(
				math.atan(CameraCache.TanHalfVertFOV * CameraCache.AspectRatio)
			)
		end)

		it("stops tracking the previous camera when re-initialized", function()
			local cameraA = makeCamera()
			CameraCache.init(cameraA)

			local cameraB = makeCamera()
			CameraCache.init(cameraB)

			-- A leftover listener on the first camera would re-read the current
			-- camera and land on values the cache already holds, so comparing
			-- against the second camera can't expose it. Sentinels planted in
			-- the cached fields can, because only a leftover listener would
			-- overwrite them when the first camera mutates.
			local cframeSentinel = CFrame.new(-9999, -9999, -9999)
			CameraCache.CFrame = cframeSentinel
			CameraCache.TanHalfVertFOV = -123

			cameraA.CFrame = CFrame.new(40, 50, 60)
			cameraA.FieldOfView = 100
			task.wait()

			expect(CameraCache.CFrame).toBe(cframeSentinel)
			expect(CameraCache.TanHalfVertFOV).toBe(-123)
		end)
	end)

	describe("Generation", function()
		it("holds still for rigid camera motion", function()
			local camera = makeCamera()
			CameraCache.init(camera)

			-- Rigid motion has a motion bound, so consumers keep their
			-- frustum-derived caches and the generation must hold still. Bumping
			-- here would flush every cache each frame the camera moves.
			local generationBefore = CameraCache.Generation
			camera.CFrame = CFrame.new(10, 20, 30)
			task.wait()
			expect(CameraCache.Generation).toBe(generationBefore)
		end)

		it("holds still for a field of view change", function()
			local camera = makeCamera()
			camera.FieldOfView = 70
			CameraCache.init(camera)

			-- A projection change swings the side planes by at most the half-angle
			-- deltas, which CameraMotion charges as rotation, so the generation
			-- must hold still while the cached trig refreshes.
			local generationBefore = CameraCache.Generation
			local halfVerticalBefore = CameraCache.HalfVerticalFOV
			camera.FieldOfView = 90
			task.wait()
			expect(CameraCache.Generation).toBe(generationBefore)
			expect(CameraCache.HalfVerticalFOV).toBeGreaterThan(halfVerticalBefore)
		end)

		it("bumps when the cache is pointed at a camera", function()
			local generationBefore = CameraCache.Generation
			CameraCache.init(workspace.CurrentCamera)
			expect(CameraCache.Generation).toBeGreaterThan(generationBefore)
		end)
	end)

	describe("reactive updates", function()
		it("updates the cached CFrame and Position when the camera moves", function()
			local camera = makeCamera()
			camera.CFrame = CFrame.new(0, 0, 0)
			CameraCache.init(camera)

			local newCFrame = CFrame.new(10, 20, 30)
			camera.CFrame = newCFrame
			-- The change signal fires deferred, so let it propagate.
			task.wait()

			expect(CameraCache.CFrame).toBe(newCFrame)
			expect(CameraCache.Position).toBe(newCFrame.Position)
		end)

		it("recomputes TanHalfVertFOV when the field of view changes", function()
			local camera = makeCamera()
			camera.FieldOfView = 70
			CameraCache.init(camera)

			camera.FieldOfView = 90
			task.wait()

			-- This is recomputed from the new FoV. A stale cache would still reflect FoV 70.
			expect(CameraCache.TanHalfVertFOV).toBeCloseTo(
				math.tan(math.rad(camera.MaxAxisFieldOfView / 2)) / math.max(CameraCache.AspectRatio, 1)
			)
			expect(CameraCache.HalfVerticalFOV).toBeCloseTo(math.atan(CameraCache.TanHalfVertFOV))
			expect(CameraCache.HalfHorizontalFOV).toBeCloseTo(
				math.atan(CameraCache.TanHalfVertFOV * CameraCache.AspectRatio)
			)
		end)
	end)

	describe("viewportSizeChanged", function()
		it("reflows the aspect ratio and FOV terms from the viewport", function()
			local camera = makeCamera()
			camera.FieldOfView = 70
			CameraCache.init(camera)

			-- Poison the cached values, then drive the viewport handler directly
			-- (ViewportSize itself is read-only in a headless run). It must rebuild
			-- the aspect ratio from the camera's real viewport and reflow the FOV
			-- terms through it. The generation holds still because a projection
			-- reshape is bounded as motion through the half-angle deltas.
			CameraCache.AspectRatio = -123
			CameraCache.TanHalfVertFOV = -123
			local generationBefore = CameraCache.Generation

			CameraCache.viewportSizeChanged()

			local viewport = camera.ViewportSize
			expect(CameraCache.ViewportSize).toBe(viewport)
			expect(CameraCache.AspectRatio).toBeCloseTo(viewport.X / viewport.Y)
			expect(CameraCache.TanHalfVertFOV).toBeCloseTo(
				math.tan(math.rad(camera.MaxAxisFieldOfView / 2)) / math.max(CameraCache.AspectRatio, 1)
			)
			expect(CameraCache.Generation).toBe(generationBefore)
		end)
	end)

	describe("cleanup", function()
		it("stops tracking the camera's property changes", function()
			local camera = makeCamera()
			camera.CFrame = CFrame.new(1, 2, 3)
			camera.FieldOfView = 70
			CameraCache.init(camera)

			local cframeBefore = CameraCache.CFrame
			local tanBefore = CameraCache.TanHalfVertFOV

			CameraCache.cleanup()

			-- The cache still points at this camera after cleanup, so a
			-- listener that survived would pull these mutations straight into
			-- the cached fields.
			camera.CFrame = CFrame.new(400, 500, 600)
			camera.FieldOfView = 110
			task.wait()

			expect(CameraCache.CFrame).toBe(cframeBefore)
			expect(CameraCache.TanHalfVertFOV).toBe(tanBefore)
		end)
	end)

	describe("CurrentCamera changes", function()
		-- selene's roblox std marks workspace.CurrentCamera read-only, though it
		-- is assignable at runtime. Aliasing workspace lets us drive the handler
		-- by reassigning the camera without tripping the std-library lint.
		local workspaceRef = workspace
		local originalCamera: Camera?

		beforeEach(function()
			originalCamera = workspaceRef.CurrentCamera
		end)

		afterEach(function()
			-- The restore lives in a hook so a failed assertion can't strand the
			-- global camera for every later suite that stages objects relative
			-- to the live camera.
			workspaceRef.CurrentCamera = originalCamera
			task.wait()
		end)

		it("re-initializes the cache when workspace.CurrentCamera changes", function()
			local newCamera = makeCamera()
			newCamera.CFrame = CFrame.new(123, 456, 789)
			local generationBefore = CameraCache.Generation
			workspaceRef.CurrentCamera = newCamera
			task.wait()

			expect(CameraCache.Object).toBe(newCamera)
			expect(CameraCache.Position).toBe(Vector3.new(123, 456, 789))
			-- A swap re-anchors the cache at a different camera, and no motion
			-- bound relates frustum planes across a swap, so the generation
			-- must move to tell consumers to discard frustum-derived state.
			expect(CameraCache.Generation).toBeGreaterThan(generationBefore)
		end)

		it("recovers when a camera arrives after initializing with none", function()
			CameraCache.init(nil)
			expect(CameraCache.Object).toBeNil()

			-- The nil init leaves no listeners behind, so recovery rides
			-- entirely on the CurrentCamera handler re-initializing the cache
			-- once a camera shows up.
			local newCamera = makeCamera()
			newCamera.CFrame = CFrame.new(11, 22, 33)
			workspaceRef.CurrentCamera = newCamera
			task.wait()

			expect(CameraCache.Object).toBe(newCamera)
			expect(CameraCache.Position).toBe(Vector3.new(11, 22, 33))
		end)
	end)

	describe("getPlanesAndBounds", function()
		it("returns five frustum plane pairs with unit normals and ordered bounds", function()
			local camera = makeCamera()
			camera.CFrame = CFrame.new(0, 0, 0)
			camera.FieldOfView = 70
			CameraCache.init(camera)

			local renderDistance = 500
			local voxelSize = 100
			local planes, minBound, maxBound = CameraCache.getPlanesAndBounds(renderDistance, voxelSize)

			-- We get four side planes plus the far plane, each stored as a (position, normal) pair.
			expect(#planes).toBe(10)
			expect(typeof(minBound)).toBe("Vector3")
			expect(typeof(maxBound)).toBe("Vector3")

			-- Bounds are voxel-quantized but still ordered min <= max per axis.
			expect(minBound.X <= maxBound.X).toBe(true)
			expect(minBound.Y <= maxBound.Y).toBe(true)
			expect(minBound.Z <= maxBound.Z).toBe(true)

			-- The normals (even indices) are unit length.
			for i = 2, #planes, 2 do
				expect(planes[i].Magnitude).toBeCloseTo(1)
			end
		end)

		it("builds outward-facing planes in voxel coordinates", function()
			local camera = makeCamera()
			camera.CFrame = CFrame.new(200, 100, 300)
			camera.FieldOfView = 70
			CameraCache.init(camera)

			local renderDistance = 500
			local voxelSize = 100
			local planes = CameraCache.getPlanesAndBounds(renderDistance, voxelSize)

			-- Plane positions live in voxel coordinates, so the side planes anchor
			-- at the camera position divided by the voxel size and the far plane
			-- anchors one render distance down the look axis.
			expect(planes[1]).toBe(Vector3.new(2, 1, 3))
			expect(planes[9]).toBe(Vector3.new(2, 1, -2))
			expect(planes[10]).toBe(camera.CFrame.LookVector)

			local function signedDistance(pairIndex: number, point: Vector3): number
				local planePos = planes[pairIndex * 2 - 1]
				local planeNormal = planes[pairIndex * 2]
				return (point - planePos):Dot(planeNormal)
			end

			local look = camera.CFrame.LookVector
			local right = camera.CFrame.RightVector
			local up = camera.CFrame.UpVector
			local cameraPos = camera.CFrame.Position

			-- A point straight ahead at half the render distance sits inside the
			-- frustum, so every outward-facing plane must report it at a negative
			-- distance. A flipped normal shows up as a positive one.
			local insidePoint = (cameraPos + look * (renderDistance / 2)) / voxelSize
			for pairIndex = 1, 5 do
				expect(signedDistance(pairIndex, insidePoint)).toBeLessThan(0)
			end

			-- A point straight ahead past the render distance pokes out the far
			-- plane and nothing else.
			local beyondFar = (cameraPos + look * (renderDistance + 200)) / voxelSize
			for pairIndex = 1, 4 do
				expect(signedDistance(pairIndex, beyondFar)).toBeLessThan(0)
			end
			expect(signedDistance(5, beyondFar)).toBeGreaterThan(0)

			-- A point far off to the right at mid depth pokes out the right plane
			-- and nothing else, which pins each normal to its absolute slot.
			local farRight = (cameraPos + right * 5000 + look * 250) / voxelSize
			expect(signedDistance(1, farRight)).toBeLessThan(0)
			expect(signedDistance(2, farRight)).toBeGreaterThan(0)
			expect(signedDistance(3, farRight)).toBeLessThan(0)
			expect(signedDistance(4, farRight)).toBeLessThan(0)
			expect(signedDistance(5, farRight)).toBeLessThan(0)

			-- A point far above at mid depth pokes out the top plane and nothing
			-- else, which keeps the top and bottom slots from standing in for
			-- each other the way the off-axis probe separates left from right.
			local farUp = (cameraPos + up * 5000 + look * 250) / voxelSize
			expect(signedDistance(1, farUp)).toBeLessThan(0)
			expect(signedDistance(2, farUp)).toBeLessThan(0)
			expect(signedDistance(3, farUp)).toBeGreaterThan(0)
			expect(signedDistance(4, farUp)).toBeLessThan(0)
			expect(signedDistance(5, farUp)).toBeLessThan(0)
		end)

		it("keeps the camera and far-plane corner voxels inside the returned bounds", function()
			-- The rotation makes every axis carry a distinct spread of corner
			-- positions, so a swapped axis or a dropped corner breaks containment.
			local camera = makeCamera()
			camera.CFrame = CFrame.new(170, 80, -240) * CFrame.Angles(-0.3, 0.7, 0)
			camera.FieldOfView = 70
			CameraCache.init(camera)

			local renderDistance = 750
			local voxelSize = 60
			local _, minBound, maxBound = CameraCache.getPlanesAndBounds(renderDistance, voxelSize)

			-- The far-plane corners are derived by hand from the camera state,
			-- with the vertical FoV narrowed by the viewport aspect ratio.
			local viewport = camera.ViewportSize
			local aspectRatio = if viewport.Y > 0 then viewport.X / viewport.Y else 0
			local tanHalfVerticalFOV = math.tan(math.rad(camera.MaxAxisFieldOfView / 2)) / math.max(aspectRatio, 1)
			local farHalfHeight = tanHalfVerticalFOV * renderDistance
			local farHalfWidth = farHalfHeight * aspectRatio
			local farPlaneCFrame = camera.CFrame * CFrame.new(0, 0, -renderDistance)

			local frustumPoints = {
				camera.CFrame.Position,
				farPlaneCFrame * Vector3.new(-farHalfWidth, farHalfHeight, 0),
				farPlaneCFrame * Vector3.new(farHalfWidth, farHalfHeight, 0),
				farPlaneCFrame * Vector3.new(-farHalfWidth, -farHalfHeight, 0),
				farPlaneCFrame * Vector3.new(farHalfWidth, -farHalfHeight, 0),
			}

			local function toVoxel(point: Vector3): Vector3
				return Vector3.new(point.X // voxelSize, point.Y // voxelSize, point.Z // voxelSize)
			end

			-- The AABB seeds the entire search, so the camera's own voxel and
			-- every far-plane corner voxel must land inside it.
			local expectedMin, expectedMax
			for _, point in frustumPoints do
				local voxel = toVoxel(point)
				expect(voxel.X).toBeGreaterThanOrEqual(minBound.X)
				expect(voxel.X).toBeLessThanOrEqual(maxBound.X)
				expect(voxel.Y).toBeGreaterThanOrEqual(minBound.Y)
				expect(voxel.Y).toBeLessThanOrEqual(maxBound.Y)
				expect(voxel.Z).toBeGreaterThanOrEqual(minBound.Z)
				expect(voxel.Z).toBeLessThanOrEqual(maxBound.Z)
				expectedMin = if expectedMin then expectedMin:Min(voxel) else voxel
				expectedMax = if expectedMax then expectedMax:Max(voxel) else voxel
			end

			-- Floor division is monotone, so the bound is exactly the componentwise
			-- min and max of those voxels. Any slack here would mean the bound's
			-- quantization no longer matches how points map to voxels.
			expect(minBound).toBe(expectedMin)
			expect(maxBound).toBe(expectedMax)
		end)

		it("stays finite for a zero aspect ratio", function()
			local camera = makeCamera()
			camera.CFrame = CFrame.new(0, 0, 0)
			camera.FieldOfView = 70
			CameraCache.init(camera)

			-- A zero-height viewport caches a zero aspect ratio, which
			-- collapses the far plane to zero width. The frustum comes out
			-- degenerate but every output stays finite, which is what the
			-- aspect-ratio fallback exists to guarantee. The degenerate plane
			-- orientations aren't worth freezing, so this pins only that the
			-- call succeeds and nothing in the output is NaN or infinite.
			CameraCache.AspectRatio = 0
			CameraCache.fovChanged()

			local planes, minBound, maxBound
			expect(function()
				planes, minBound, maxBound = CameraCache.getPlanesAndBounds(500, 100)
			end).never.toThrow()

			expect(#planes).toBe(10)

			local function expectFinite(vector: Vector3)
				for _, component in { vector.X, vector.Y, vector.Z } do
					-- NaN is the only value that doesn't equal itself, so the
					-- comparison runs in Lua before the matcher sees it.
					expect(component == component).toBe(true)
					expect(math.abs(component) ~= math.huge).toBe(true)
				end
			end

			for _, vector in planes do
				expectFinite(vector)
			end
			expectFinite(minBound)
			expectFinite(maxBound)
		end)
	end)
end)
