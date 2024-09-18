math.randomseed(0) -- Constant seed for reproducibility

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Packages = ReplicatedStorage:WaitForChild("Packages")

local VISIBLE_COLOR = Color3.new(1, 1, 1)
local INVISIBLE_COLOR = Color3.new(0, 0, 0)

local CullThrottle = require(Packages:WaitForChild("CullThrottle"))

local FloatingBlocksUpdater = CullThrottle.new()

-- Change colors of blocks to indicate visibility
FloatingBlocksUpdater.ObjectEnteredView:Connect(function(block)
	block.Color = VISIBLE_COLOR
end)

FloatingBlocksUpdater.ObjectExitedView:Connect(function(block)
	block.Color = INVISIBLE_COLOR
end)

-- We need to tell CullThrottle about all the objects that we want it to manage.
for _, block in CollectionService:GetTagged("FloatingBlock") do
	FloatingBlocksUpdater:addObject(block)
end

CollectionService:GetInstanceAddedSignal("FloatingBlock"):Connect(function(block)
	FloatingBlocksUpdater:addObject(block)
end)

CollectionService:GetInstanceRemovedSignal("FloatingBlock"):Connect(function(block)
	FloatingBlocksUpdater:removeObject(block)
end)

-- Let's make some blocks to run effects on
local blockTimeOffsets = {}

local BlocksFolder = Instance.new("Folder")
BlocksFolder.Name = "Blocks"
for _ = 1, 100 do
	local groupOrigin = Vector3.new(math.random(-800, 800), math.random(-200, 200), math.random(-800, 800))
	for _ = 1, 110 do
		local part = Instance.new("Part")
		part.Size = Vector3.new(1, 1, 1) * math.random(1, 15)
		part.Color = Color3.new() -- Color3.fromHSV(math.random(), 0.5, 1)
		part.CFrame = CFrame.new(
			groupOrigin + Vector3.new(math.random(-120, 120), math.random(-80, 80), math.random(-120, 120))
		) * CFrame.Angles(math.rad(math.random(360)), math.rad(math.random(360)), math.rad(math.random(360)))
		part.Anchored = true
		part.CanCollide = false
		part.CastShadow = false
		part.CanTouch = false
		part.CanQuery = false
		part.Locked = true
		part:AddTag("FloatingBlock")
		part.Parent = BlocksFolder

		blockTimeOffsets[part] = math.random() * 2
	end
end

BlocksFolder.Parent = workspace

----------------------------------------------------------------------------------
-- The rest of this is debug/dev stuff

local Utility = require(script.Utility)

local PlayerGui = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
local ScreenGui = Instance.new("ScreenGui")

local DebugInfo = Instance.new("TextLabel")
DebugInfo.Size = UDim2.fromScale(0.2, 0.1)
DebugInfo.Position = UDim2.fromScale(0.03, 0.03)
DebugInfo.TextXAlignment = Enum.TextXAlignment.Left
DebugInfo.TextYAlignment = Enum.TextYAlignment.Bottom
DebugInfo.TextScaled = true
DebugInfo.BackgroundTransparency = 0.4
DebugInfo.BackgroundColor3 = Color3.new(0, 0, 0)
DebugInfo.TextColor3 = Color3.new(1, 1, 1)
DebugInfo.TextStrokeColor3 = Color3.new(0, 0, 0)
DebugInfo.TextStrokeTransparency = 0.5
DebugInfo.FontFace = Font.fromEnum(Enum.Font.RobotoMono)
DebugInfo.Parent = ScreenGui
ScreenGui.Parent = PlayerGui

task.spawn(function()
	while task.wait(1 / 3) do
		local debugInfoBuffer = {}
		table.insert(debugInfoBuffer, "objects visible: " .. #FloatingBlocksUpdater:getObjectsInView())
		table.insert(
			debugInfoBuffer,
			string.format("compute time: %.2fms", FloatingBlocksUpdater:_getAverageCallTime() * 1000)
		)

		DebugInfo.Text = table.concat(debugInfoBuffer, "\n")
	end
end)

-- Enable gizmo debug views
FloatingBlocksUpdater.DEBUG_MODE = false

-- Use a fake camera to get a third person view
if false then
	local testCam = Instance.new("Part")
	testCam.Name = "_CullThrottleTestCam"
	testCam.Size = Vector3.new(16, 9, 3)
	testCam.Color = Color3.fromRGB(255, 225, 0)
	testCam.CanCollide = false
	testCam.Locked = true
	testCam.CastShadow = false
	testCam.CanTouch = false
	testCam.CanQuery = false
	testCam.Anchored = true
	testCam.Parent = workspace

	local targetCF = CFrame.new()

	task.defer(function()
		while true do
			targetCF = CFrame.new(math.random(-800, 800), math.random(-200, 200), math.random(-800, 800))
				* CFrame.Angles(math.random(-0.1, 0.1), math.random(-3.14, 3.14), math.random(-3.14, 3.14))

			task.wait(5)
		end
	end)

	task.spawn(function()
		while task.wait() do
			local distanceToTarget = (testCam.CFrame.Position - targetCF.Position).Magnitude
			testCam.CFrame = testCam.CFrame:Lerp(targetCF, math.min(1 / distanceToTarget, 1))
		end
	end)
end
