math.randomseed(0) -- Constant seed for reproducibility

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")

local CullThrottle = require(Packages:WaitForChild("CullThrottle"))

local Utility = require(script.Utility)
local Blocks = require(script.Blocks)

local _VISIBLE_COLOR = Color3.fromRGB(166, 35, 91)
local INVISIBLE_COLOR = Color3.fromRGB(60, 84, 101)
local TAG = "FloatingBlock"

-- Let's make some blocks to run effects on
local BlocksFolder = Instance.new("Folder")
BlocksFolder.Name = "Blocks"

local blockTimeOffsets = {}

for _, block in Blocks.generateBlockClusters(200, 20_000) do
	block:AddTag(TAG)
	block.Color = INVISIBLE_COLOR
	block.Parent = BlocksFolder

	blockTimeOffsets[block] = math.random() * 2
end

BlocksFolder.Parent = workspace

-- We need to tell CullThrottle about all the objects that we want it to manage.
local FloatingBlocksUpdater = CullThrottle.new()
-- FloatingBlocksUpdater:setRenderDistance(800)

for _, block in CollectionService:GetTagged(TAG) do
	FloatingBlocksUpdater:addObject(block)
end

CollectionService:GetInstanceAddedSignal(TAG):Connect(function(block)
	FloatingBlocksUpdater:addObject(block)
end)

CollectionService:GetInstanceRemovedSignal(TAG):Connect(function(block)
	FloatingBlocksUpdater:removeObject(block)
end)

-- Change colors of blocks to indicate visibility
-- FloatingBlocksUpdater.ObjectEnteredView:Connect(function(block)
-- 	block.Color = VISIBLE_COLOR
-- end)

FloatingBlocksUpdater.ObjectExitedView:Connect(function(block)
	block.Color = INVISIBLE_COLOR
end)

-- Change color of block to indicate refresh rate
local blocks, cframes = {}, {}
RunService.RenderStepped:Connect(function()
	table.clear(blocks)
	table.clear(cframes)

	for block, dt in FloatingBlocksUpdater:iterObjectsToUpdate() do
		if dt > 0.5 then
			-- This object hasn't been visible in a while so let's
			-- avoid a jump in the spin animation and just start spinning
			-- from where we are
			dt = 1 / 30
		end

		Utility.applyHeatmapColor(
			block,
			1 - (dt - FloatingBlocksUpdater.Config.bestRefreshRate) / FloatingBlocksUpdater.Config.refreshRateRange
		)

		table.insert(blocks, block)
		table.insert(cframes, block.CFrame * CFrame.Angles(0, math.rad(90) * dt, 0))
	end

	workspace:BulkMoveTo(blocks, cframes, Enum.BulkMoveMode.FireCFrameChanged)
end)

----------------------------------------------------------------------------------
-- The rest of this is debug/dev stuff

local DEBUG = false

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
FloatingBlocksUpdater.DEBUG_MODE = DEBUG

-- Use a fake camera to get a third person view
if DEBUG then
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
