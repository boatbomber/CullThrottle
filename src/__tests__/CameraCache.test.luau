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
		it("should return width over height for a normal viewport", function()
			expect(CameraCache.computeAspectRatio(Vector2.new(1920, 1080))).toBeCloseTo(1920 / 1080)
		end)

		it("should not divide by zero for a zero-height viewport", function()
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

		it("should populate cached properties from a camera", function()
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

		it("caches values that match the source camera", function()
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

		it("disconnects the previous camera's connections when re-initialized", function()
			local cameraA = makeCamera()
			CameraCache.init(cameraA)

			local oldConnections = {}
			for _, connection in CameraCache._connections do
				table.insert(oldConnections, connection)
			end
			expect(#oldConnections).toBeGreaterThan(0)

			local cameraB = makeCamera()
			CameraCache.init(cameraB)

			-- The first camera's listeners must be dropped, not left double-firing.
			for _, connection in oldConnections do
				expect(connection.Connected).toBe(false)
			end
		end)
	end)

	describe("Generation", function()
		it("holds still for camera motion and field of view changes", function()
			local camera = makeCamera()
			camera.FieldOfView = 70
			CameraCache.init(camera)

			-- Rigid motion has a motion bound, so consumers keep their
			-- frustum-derived caches and the generation must hold still. Bumping
			-- here would flush every cache each frame the camera moves.
			local generationBefore = CameraCache.Generation
			camera.CFrame = CFrame.new(10, 20, 30)
			task.wait()
			expect(CameraCache.Generation).toBe(generationBefore)

			-- A projection change swings the side planes by at most the half-angle
			-- deltas, which CameraMotion charges as rotation, so the generation
			-- must hold still here too while the cached trig refreshes.
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
		it("disconnects all change connections and clears the table", function()
			local camera = makeCamera()
			CameraCache.init(camera)

			local connections = {}
			for _, connection in CameraCache._connections do
				table.insert(connections, connection)
			end
			expect(#connections).toBeGreaterThan(0)

			CameraCache.cleanup()

			for _, connection in connections do
				expect(connection.Connected).toBe(false)
			end
			expect(next(CameraCache._connections)).toBeNil()
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
			workspaceRef.CurrentCamera = newCamera
			task.wait()

			expect(CameraCache.Object).toBe(newCamera)
			expect(CameraCache.Position).toBe(Vector3.new(123, 456, 789))
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
	end)
end)
