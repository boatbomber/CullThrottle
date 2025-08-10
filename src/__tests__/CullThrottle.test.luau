local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages, DevPackages = ReplicatedStorage:WaitForChild("Packages"), ReplicatedStorage:WaitForChild("DevPackages")

local JestGlobals = require(DevPackages:WaitForChild("JestGlobals"))

local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local CullThrottle = require(Packages:WaitForChild("CullThrottle"))

describe("CullThrottle", function()
	describe("TODO", function()
		it("should have unit tests", function()
			expect(true).toBe(true)
		end)
	end)
end)
