_G.NOCOLOR = _G.NOCOLOR

local RunService = game:GetService("RunService")
if not RunService:IsStudio() then
	-- Do not run tests in live game
	return
end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("Packages")
local DevPackages = ReplicatedStorage:WaitForChild("DevPackages")

local Jest = require(DevPackages:WaitForChild("Jest"))

local runCLIOptions = {
	verbose = true,
	ci = false,
}

local projects = {
	Packages:WaitForChild("CullThrottle"),
}

Jest.runCLI(script, runCLIOptions, projects):await()

return nil
