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
		CameraCache:init(workspace.CurrentCamera)
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

	describe("init", function()
		it("should not error when there is no camera", function()
			expect(function()
				CameraCache:init(nil)
			end).never.toThrow()
			expect(CameraCache.Object).toBeNil()
		end)

		it("should populate cached properties from a camera", function()
			CameraCache:init(workspace.CurrentCamera)

			expect(CameraCache.Object).toBe(workspace.CurrentCamera)
			expect(CameraCache.CFrame).toBeDefined()
			expect(CameraCache.Position).toBeDefined()
			-- AspectRatio is a finite number (equals itself rules out NaN)
			expect(CameraCache.AspectRatio == CameraCache.AspectRatio).toBe(true)
		end)
	end)
end)
