_G.NOCOLOR = _G.NOCOLOR

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
