local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("Packages")
local DevPackages = ReplicatedStorage:WaitForChild("DevPackages")

local JestGlobals = require(DevPackages:WaitForChild("JestGlobals"))

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local afterEach = JestGlobals.afterEach

local CullThrottle = Packages:WaitForChild("CullThrottle")
local CameraCache = require(CullThrottle:WaitForChild("Utilities"):WaitForChild("CameraCache"))

describe("CameraCache", function()
	afterEach(function()
		-- CameraCache is a singleton, so restore it to the live camera after tests
		-- that re-init it with nil or a fabricated viewport.
		CameraCache.init(workspace.CurrentCamera)
	end)

	describe("computeAspectRatio", function()
		it("should return width over height for a normal viewport", function()
			expect(CameraCache.computeAspectRatio(Vector2.new(1920, 1080))).toBeCloseTo(1920 / 1080)
		end)

		it("should not divide by zero for a zero-height viewport", function()
			-- Must be finite (0), never inf/NaN, or it would poison the frustum bounds
			expect(CameraCache.computeAspectRatio(Vector2.new(800, 0))).toBe(0)
		end)
	end)

	describe("computeTanHalfVerticalFOV", function()
		local tanHalf70 = math.tan(math.rad(70 / 2))

		it("narrows the max-axis FoV by the aspect ratio for a landscape viewport", function()
			-- The longer axis is horizontal, so the vertical FoV is narrower.
			local aspect = 1920 / 1080
			expect(CameraCache.computeTanHalfVerticalFOV(70, aspect)).toBeCloseTo(tanHalf70 / aspect)
		end)

		it("uses the max-axis FoV directly for a portrait viewport", function()
			-- The longer axis is already the vertical one, so no narrowing applies.
			local aspect = 1080 / 1920
			expect(CameraCache.computeTanHalfVerticalFOV(70, aspect)).toBeCloseTo(tanHalf70)
		end)
	end)

	describe("init", function()
		it("should not error when there is no camera", function()
			expect(function()
				CameraCache.init(nil)
			end).never.toThrow()
			expect(CameraCache.Object).toBeNil()
		end)

		it("should populate cached properties from a camera", function()
			CameraCache.init(workspace.CurrentCamera)

			expect(CameraCache.Object).toBe(workspace.CurrentCamera)
			expect(CameraCache.CFrame).toBeDefined()
			expect(CameraCache.Position).toBeDefined()
			-- AspectRatio is a finite number (equals itself rules out NaN)
			expect(CameraCache.AspectRatio == CameraCache.AspectRatio).toBe(true)
		end)

		it("caches values that match the source camera", function()
			local camera = Instance.new("Camera")
			camera.CFrame = CFrame.new(5, 6, 7)
			camera.FieldOfView = 80
			camera.Parent = workspace

			CameraCache.init(camera)

			expect(CameraCache.Object).toBe(camera)
			expect(CameraCache.CFrame).toBe(camera.CFrame)
			expect(CameraCache.Position).toBe(camera.CFrame.Position)
			-- TanHalfVertFOV is the vertical tan(FoV/2) derived from the camera's
			-- reliable max-axis FoV and the viewport aspect ratio.
			expect(CameraCache.TanHalfVertFOV).toBeCloseTo(
				math.tan(math.rad(camera.MaxAxisFieldOfView / 2)) / math.max(CameraCache.AspectRatio, 1)
			)
			expect(CameraCache.HalfVerticalFOV).toBeCloseTo(math.atan(CameraCache.TanHalfVertFOV))
			expect(CameraCache.HalfHorizontalFOV).toBeCloseTo(
				math.atan(CameraCache.TanHalfVertFOV * CameraCache.AspectRatio)
			)

			camera:Destroy()
		end)

		it("disconnects the previous camera's connections when re-initialized", function()
			local cameraA = Instance.new("Camera")
			cameraA.Parent = workspace
			CameraCache.init(cameraA)

			local oldConnections = {}
			for _, connection in CameraCache._connections do
				table.insert(oldConnections, connection)
			end
			expect(#oldConnections).toBeGreaterThan(0)

			local cameraB = Instance.new("Camera")
			cameraB.Parent = workspace
			CameraCache.init(cameraB)

			-- The first camera's listeners must be dropped, not left double-firing.
			for _, connection in oldConnections do
				expect(connection.Connected).toBe(false)
			end

			cameraA:Destroy()
			cameraB:Destroy()
		end)
	end)

	describe("reactive updates", function()
		it("updates the cached CFrame and Position when the camera moves", function()
			local camera = Instance.new("Camera")
			camera.CFrame = CFrame.new(0, 0, 0)
			camera.Parent = workspace
			CameraCache.init(camera)

			local newCFrame = CFrame.new(10, 20, 30)
			camera.CFrame = newCFrame
			-- The change signal fires deferred, so let it propagate.
			task.wait()

			expect(CameraCache.CFrame).toBe(newCFrame)
			expect(CameraCache.Position).toBe(newCFrame.Position)

			camera:Destroy()
		end)

		it("recomputes TanHalfVertFOV when the field of view changes", function()
			local camera = Instance.new("Camera")
			camera.FieldOfView = 70
			camera.Parent = workspace
			CameraCache.init(camera)

			camera.FieldOfView = 90
			task.wait()

			-- Recomputed from the new FoV: a stale cache would still reflect FoV 70.
			expect(CameraCache.TanHalfVertFOV).toBeCloseTo(
				math.tan(math.rad(camera.MaxAxisFieldOfView / 2)) / math.max(CameraCache.AspectRatio, 1)
			)
			expect(CameraCache.HalfVerticalFOV).toBeCloseTo(math.atan(CameraCache.TanHalfVertFOV))
			expect(CameraCache.HalfHorizontalFOV).toBeCloseTo(
				math.atan(CameraCache.TanHalfVertFOV * CameraCache.AspectRatio)
			)

			camera:Destroy()
		end)
	end)

	describe("cleanup", function()
		it("disconnects all change connections and clears the table", function()
			local camera = Instance.new("Camera")
			camera.Parent = workspace
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

			camera:Destroy()
		end)
	end)

	describe("CurrentCamera changes", function()
		it("re-initializes the cache when workspace.CurrentCamera changes", function()
			-- selene's roblox std marks workspace.CurrentCamera read-only, though it
			-- is assignable at runtime. Aliasing workspace lets us drive the handler
			-- by reassigning the camera without tripping the std-library lint.
			local workspaceRef = workspace
			local originalCamera = workspaceRef.CurrentCamera

			local newCamera = Instance.new("Camera")
			newCamera.CFrame = CFrame.new(123, 456, 789)
			newCamera.Parent = workspace
			workspaceRef.CurrentCamera = newCamera
			task.wait()

			expect(CameraCache.Object).toBe(newCamera)
			expect(CameraCache.Position).toBe(Vector3.new(123, 456, 789))

			workspaceRef.CurrentCamera = originalCamera
			newCamera:Destroy()
			task.wait()
		end)
	end)

	describe("getPlanesAndBounds", function()
		it("returns five frustum plane pairs with unit normals and ordered bounds", function()
			local camera = Instance.new("Camera")
			camera.CFrame = CFrame.new(0, 0, 0)
			camera.FieldOfView = 70
			camera.Parent = workspace
			CameraCache.init(camera)

			local renderDistance = 500
			local voxelSize = 100
			local planes, minBound, maxBound = CameraCache.getPlanesAndBounds(renderDistance, voxelSize)

			-- Four side planes plus the far plane, each stored as a (position, normal) pair.
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

			camera:Destroy()
		end)
	end)
end)
